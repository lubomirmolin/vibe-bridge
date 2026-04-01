use std::collections::VecDeque;
use std::io::{BufRead, BufReader, Write};
use std::net::TcpStream;
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};

use serde_json::{Value, json};
use shared_contracts::CONTRACT_VERSION;
use tungstenite::stream::MaybeTlsStream;
use tungstenite::{Message, WebSocket, connect};

#[derive(Debug)]
pub struct CodexJsonTransport {
    next_id: i64,
    pending_messages: VecDeque<Value>,
    connection: CodexConnection,
}

#[derive(Debug)]
enum CodexConnection {
    Stdio {
        child: Child,
        stdin: ChildStdin,
        stdout: BufReader<ChildStdout>,
    },
    WebSocket {
        socket: WebSocket<MaybeTlsStream<TcpStream>>,
    },
}

impl CodexJsonTransport {
    pub fn start(command: &str, args: &[String], endpoint: Option<&str>) -> Result<Self, String> {
        if let Some(endpoint) = endpoint {
            let socket = connect_to_codex_websocket(endpoint).map_err(|error| {
                format!("failed to connect to codex app-server websocket '{endpoint}': {error}")
            })?;
            let mut transport = Self {
                next_id: 1,
                pending_messages: VecDeque::new(),
                connection: CodexConnection::WebSocket { socket },
            };
            transport.initialize()?;
            return Ok(transport);
        }

        let mut command_args = if args.is_empty() {
            vec!["app-server".to_string()]
        } else {
            args.to_vec()
        };

        if !command_args.iter().any(|arg| arg == "--listen") {
            command_args.push("--listen".to_string());
            command_args.push("stdio://".to_string());
        }

        let mut child = Command::new(command)
            .args(command_args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|error| {
                format!("failed to spawn codex app-server via '{command}': {error}")
            })?;

        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| "failed to acquire codex app-server stdin".to_string())?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| "failed to acquire codex app-server stdout".to_string())?;

        let mut transport = Self {
            next_id: 1,
            pending_messages: VecDeque::new(),
            connection: CodexConnection::Stdio {
                child,
                stdin,
                stdout: BufReader::new(stdout),
            },
        };
        transport.initialize()?;
        Ok(transport)
    }

    fn initialize(&mut self) -> Result<(), String> {
        self.request(
            "initialize",
            json!({
                "clientInfo": {
                    "name": "bridge-core",
                    "version": CONTRACT_VERSION,
                }
            }),
        )
        .map(|_| ())?;
        let notification = json!({
            "method": "initialized",
        });
        let line = serde_json::to_string(&notification).map_err(|error| {
            format!("failed to serialize codex rpc notification 'initialized': {error}")
        })?;
        self.send_line("initialized", &line)
    }

    pub fn request(&mut self, method: &str, params: Value) -> Result<Value, String> {
        let id = self.next_id;
        self.next_id += 1;

        let payload = json!({
            "id": id,
            "method": method,
            "params": params,
        });
        let line = serde_json::to_string(&payload).map_err(|error| {
            format!("failed to serialize codex rpc request '{method}': {error}")
        })?;

        self.send_line(method, &line)?;

        loop {
            if let Some(response) = pop_matching_pending_response(&mut self.pending_messages, id) {
                return parse_codex_rpc_response(method, response);
            }

            let response = self
                .read_wire_message(method)?
                .ok_or_else(|| format!("codex upstream closed while waiting for '{method}'"))?;
            if let Some(response) =
                preserve_or_match_request_message(&mut self.pending_messages, id, response)
            {
                return parse_codex_rpc_response(method, response);
            }
        }
    }

    pub fn respond(&mut self, request_id: &Value, result: Value) -> Result<(), String> {
        let payload = json!({
            "id": request_id,
            "result": result,
        });
        let line = serde_json::to_string(&payload)
            .map_err(|error| format!("failed to serialize codex rpc response: {error}"))?;
        self.send_line("rpc/respond", &line)
    }

    pub fn respond_error(
        &mut self,
        request_id: &Value,
        code: i64,
        message: &str,
    ) -> Result<(), String> {
        let payload = json!({
            "id": request_id,
            "error": {
                "code": code,
                "message": message,
            },
        });
        let line = serde_json::to_string(&payload)
            .map_err(|error| format!("failed to serialize codex rpc error response: {error}"))?;
        self.send_line("rpc/respond_error", &line)
    }

    pub fn next_message(&mut self, context: &str) -> Result<Option<Value>, String> {
        if let Some(message) = self.pending_messages.pop_front() {
            return Ok(Some(message));
        }

        self.read_wire_message(context)
    }

    fn read_wire_message(&mut self, context: &str) -> Result<Option<Value>, String> {
        match &mut self.connection {
            CodexConnection::Stdio { stdout, .. } => loop {
                let mut line = String::new();
                let bytes_read = stdout.read_line(&mut line).map_err(|error| {
                    format!("failed to read codex message for '{context}': {error}")
                })?;
                if bytes_read == 0 {
                    return Ok(None);
                }

                match serde_json::from_str(line.trim()) {
                    Ok(message) => return Ok(Some(message)),
                    Err(_) => continue,
                }
            },
            CodexConnection::WebSocket { socket } => loop {
                let message = socket.read().map_err(|error| {
                    format!("failed to read codex websocket message for '{context}': {error}")
                })?;
                match message {
                    Message::Text(text) => {
                        let value = serde_json::from_str(text.as_ref()).map_err(|error| {
                            format!(
                                "failed to parse codex websocket message for '{context}' as JSON: {error}"
                            )
                        })?;
                        return Ok(Some(value));
                    }
                    Message::Binary(bytes) => {
                        let text = String::from_utf8(bytes.to_vec()).map_err(|error| {
                            format!(
                                "failed to decode binary codex websocket message for '{context}': {error}"
                            )
                        })?;
                        let value = serde_json::from_str(&text).map_err(|error| {
                            format!(
                                "failed to parse binary codex websocket message for '{context}' as JSON: {error}"
                            )
                        })?;
                        return Ok(Some(value));
                    }
                    Message::Ping(_) | Message::Pong(_) | Message::Frame(_) => {}
                    Message::Close(_) => return Ok(None),
                }
            },
        }
    }

    fn send_line(&mut self, method: &str, line: &str) -> Result<(), String> {
        match &mut self.connection {
            CodexConnection::Stdio { stdin, .. } => {
                writeln!(stdin, "{line}").map_err(|error| {
                    format!("failed to write codex rpc request '{method}': {error}")
                })?;
                stdin.flush().map_err(|error| {
                    format!("failed to flush codex rpc request '{method}': {error}")
                })
            }
            CodexConnection::WebSocket { socket } => socket
                .send(Message::Text(line.to_string()))
                .map_err(|error| {
                    format!("failed to send codex rpc request '{method}' over websocket: {error}")
                }),
        }
    }
}

impl Drop for CodexJsonTransport {
    fn drop(&mut self) {
        if let CodexConnection::Stdio { child, .. } = &mut self.connection {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

fn connect_to_codex_websocket(
    endpoint: &str,
) -> Result<WebSocket<MaybeTlsStream<TcpStream>>, Box<tungstenite::Error>> {
    let (socket, _) = connect(endpoint).map_err(Box::new)?;
    Ok(socket)
}

fn parse_codex_rpc_response(method: &str, response: Value) -> Result<Value, String> {
    if let Some(error) = response.get("error") {
        return Err(format!(
            "codex rpc request '{method}' failed: {}",
            error
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or("unknown error")
        ));
    }

    response
        .get("result")
        .cloned()
        .ok_or_else(|| format!("codex rpc response for '{method}' did not include result"))
}

fn preserve_or_match_request_message(
    pending_messages: &mut VecDeque<Value>,
    request_id: i64,
    message: Value,
) -> Option<Value> {
    let Some(response_id) = message.get("id").and_then(Value::as_i64) else {
        pending_messages.push_back(message);
        return None;
    };

    if response_id != request_id {
        pending_messages.push_back(message);
        return None;
    }

    Some(message)
}

fn pop_matching_pending_response(
    pending_messages: &mut VecDeque<Value>,
    request_id: i64,
) -> Option<Value> {
    let mut remaining = VecDeque::with_capacity(pending_messages.len());
    let mut matched = None;

    while let Some(message) = pending_messages.pop_front() {
        if matched.is_none() && message.get("id").and_then(Value::as_i64) == Some(request_id) {
            matched = Some(message);
            continue;
        }
        remaining.push_back(message);
    }

    *pending_messages = remaining;
    matched
}

#[cfg(test)]
mod tests {
    use std::collections::VecDeque;

    use serde_json::json;

    use super::{pop_matching_pending_response, preserve_or_match_request_message};

    #[test]
    fn preserve_or_match_request_message_keeps_notifications() {
        let mut pending_messages = VecDeque::new();
        let matched = preserve_or_match_request_message(
            &mut pending_messages,
            7,
            json!({
                "method": "turn/started",
                "params": {
                    "threadId": "thr_123",
                }
            }),
        );

        assert!(matched.is_none());
        assert_eq!(pending_messages.len(), 1);
        assert_eq!(pending_messages[0]["method"], "turn/started");
    }

    #[test]
    fn preserve_or_match_request_message_returns_matching_response() {
        let mut pending_messages = VecDeque::new();
        let matched = preserve_or_match_request_message(
            &mut pending_messages,
            7,
            json!({
                "id": 7,
                "result": {
                    "turn": { "id": "turn_123" }
                }
            }),
        )
        .expect("response should match");

        assert!(pending_messages.is_empty());
        assert_eq!(matched["result"]["turn"]["id"], "turn_123");
    }

    #[test]
    fn pop_matching_pending_response_returns_only_matching_response() {
        let mut pending_messages = VecDeque::from(vec![
            json!({
                "method": "turn/started",
                "params": {
                    "threadId": "thr_123",
                }
            }),
            json!({
                "id": 7,
                "result": {
                    "turn": { "id": "turn_123" }
                }
            }),
        ]);

        let matched =
            pop_matching_pending_response(&mut pending_messages, 7).expect("response should match");

        assert_eq!(matched["result"]["turn"]["id"], "turn_123");
        assert_eq!(pending_messages.len(), 1);
        assert_eq!(pending_messages[0]["method"], "turn/started");
    }
}
