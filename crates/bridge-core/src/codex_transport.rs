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
        .map(|_| ())
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
            let response = self
                .next_message(method)?
                .ok_or_else(|| format!("codex upstream closed while waiting for '{method}'"))?;
            let Some(response_id) = response.get("id").and_then(Value::as_i64) else {
                continue;
            };

            if response_id != id {
                self.pending_messages.push_back(response);
                continue;
            }

            return parse_codex_rpc_response(method, response);
        }
    }

    pub fn next_message(&mut self, context: &str) -> Result<Option<Value>, String> {
        if let Some(message) = self.pending_messages.pop_front() {
            return Ok(Some(message));
        }

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
