use super::super::*;

pub(crate) fn summarize_claude_stderr(stderr_output: &str) -> Option<String> {
    let lines = stderr_output
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .collect::<Vec<_>>();
    if lines.is_empty() {
        return None;
    }

    let preferred = lines
        .iter()
        .copied()
        .find(|line| looks_like_claude_error_summary(line))
        .map(|line| truncate_for_mobile_error(line, 240));
    if preferred.is_some() {
        return preferred;
    }

    let fallback = lines
        .iter()
        .copied()
        .find(|line| !looks_like_claude_stack_noise(line))
        .map(|line| truncate_for_mobile_error(line, 240));
    if fallback.is_some() {
        return fallback;
    }

    Some("Claude CLI crashed before it returned a usable error message.".to_string())
}

fn looks_like_claude_error_summary(line: &str) -> bool {
    let normalized = line.to_ascii_lowercase();
    normalized.starts_with("error:")
        || normalized.contains("invalid session")
        || normalized.contains("already in use")
        || normalized.contains("permission denied")
        || normalized.contains("not found")
        || normalized.contains("unsupported")
        || normalized.contains("authentication")
        || normalized.contains("rate limit")
        || normalized.contains("timed out")
}

fn looks_like_claude_stack_noise(line: &str) -> bool {
    if line.starts_with("file://") || line.starts_with("at ") || line.starts_with("node:") {
        return true;
    }

    let punctuation_count = line
        .chars()
        .filter(|ch| matches!(ch, '{' | '}' | '(' | ')' | ';' | '=' | ',' | '[' | ']'))
        .count();
    (line.len() > 160 && punctuation_count > 20)
        || (punctuation_count > 8
            && (line.starts_with("`)}")
                || line.contains(".error.")
                || line.contains("function ")
                || line.contains("exports=")))
}

fn truncate_for_mobile_error(line: &str, max_chars: usize) -> String {
    let mut trimmed = line.trim().to_string();
    if trimmed.chars().count() <= max_chars {
        return trimmed;
    }

    trimmed = trimmed.chars().take(max_chars.saturating_sub(3)).collect();
    trimmed.push_str("...");
    trimmed
}

pub(super) fn build_claude_assistant_event(
    thread_id: &str,
    value: &Value,
) -> Option<BridgeEventEnvelope<Value>> {
    if value.get("type").and_then(Value::as_str) != Some("assistant") {
        return None;
    }
    let message = value.get("message")?;
    let message_id = message.get("id").and_then(Value::as_str)?.trim();
    if message_id.is_empty() {
        return None;
    }
    let text = claude_message_text(message)?;
    if text.trim().is_empty() {
        return None;
    }

    Some(BridgeEventEnvelope::new(
        message_id.to_string(),
        thread_id.to_string(),
        BridgeEventKind::MessageDelta,
        Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true),
        json!({
            "id": message_id,
            "type": "message",
            "role": "assistant",
            "text": text,
        }),
    ))
}

pub(super) fn build_claude_partial_assistant_event(
    thread_id: &str,
    message_id: &str,
    text: &str,
) -> BridgeEventEnvelope<Value> {
    BridgeEventEnvelope::new(
        message_id.to_string(),
        thread_id.to_string(),
        BridgeEventKind::MessageDelta,
        Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true),
        json!({
            "id": message_id,
            "type": "message",
            "role": "assistant",
            "text": text,
        }),
    )
}

pub(super) fn parse_claude_message_start(value: &Value) -> Option<String> {
    if value.get("type").and_then(Value::as_str) != Some("stream_event") {
        return None;
    }
    let event = value.get("event")?;
    if event.get("type").and_then(Value::as_str) != Some("message_start") {
        return None;
    }
    event
        .get("message")?
        .get("id")?
        .as_str()
        .map(ToString::to_string)
}

pub(super) fn parse_claude_text_delta(value: &Value) -> Option<String> {
    if value.get("type").and_then(Value::as_str) != Some("stream_event") {
        return None;
    }
    let event = value.get("event")?;
    if event.get("type").and_then(Value::as_str) != Some("content_block_delta") {
        return None;
    }
    if event.get("delta")?.get("type")?.as_str() != Some("text_delta") {
        return None;
    }
    event
        .get("delta")?
        .get("text")?
        .as_str()
        .map(ToString::to_string)
}

pub(super) fn parse_claude_control_request_id(value: &Value) -> Option<String> {
    if value.get("type").and_then(Value::as_str) != Some("control_request") {
        return None;
    }
    value
        .get("request_id")
        .and_then(Value::as_str)
        .map(ToString::to_string)
}

pub(super) fn parse_claude_control_cancel_request_id(value: &Value) -> Option<String> {
    if value.get("type").and_then(Value::as_str) != Some("control_cancel_request") {
        return None;
    }
    value
        .get("request_id")
        .and_then(Value::as_str)
        .map(ToString::to_string)
}

pub(super) fn bind_claude_sdk_listener() -> Result<(TcpListener, String), String> {
    let listener = TcpListener::bind(("127.0.0.1", 0))
        .map_err(|error| format!("failed to bind local Claude SDK bridge listener: {error}"))?;
    let address = listener
        .local_addr()
        .map_err(|error| format!("failed to inspect local Claude SDK bridge listener: {error}"))?;
    Ok((listener, format!("ws://127.0.0.1:{}", address.port())))
}

pub(super) fn accept_claude_sdk_connection(
    listener: &TcpListener,
    child_handle: &Arc<Mutex<Child>>,
    thread_id: &str,
) -> Result<WebSocket<TcpStream>, String> {
    listener.set_nonblocking(true).map_err(|error| {
        format!("failed to configure local Claude SDK bridge listener for {thread_id}: {error}")
    })?;

    loop {
        match listener.accept() {
            Ok((stream, _)) => {
                stream.set_nonblocking(false).map_err(|error| {
                    format!(
                        "failed to switch Claude SDK bridge stream to blocking mode for {thread_id}: {error}"
                    )
                })?;
                let _ = stream.set_nodelay(true);
                return accept(stream).map_err(|error| {
                    format!("failed to accept Claude SDK bridge websocket for {thread_id}: {error}")
                });
            }
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                let exited = child_handle
                    .lock()
                    .expect("claude child lock should not be poisoned")
                    .try_wait()
                    .map_err(|wait_error| {
                        format!(
                            "failed to poll Claude child while waiting for SDK bridge for {thread_id}: {wait_error}"
                        )
                    })?
                    .is_some();
                if exited {
                    return Err(format!(
                        "Claude exited before it connected to the local SDK bridge for {thread_id}"
                    ));
                }
                std::thread::sleep(Duration::from_millis(25));
            }
            Err(error) => {
                return Err(format!(
                    "failed to accept Claude SDK bridge connection for {thread_id}: {error}"
                ));
            }
        }
    }
}

pub(super) fn read_claude_sdk_message(
    socket: &mut WebSocket<TcpStream>,
) -> Result<Option<Value>, String> {
    loop {
        let message = socket
            .read()
            .map_err(|error| format!("failed reading Claude SDK websocket frame: {error}"))?;
        match message {
            Message::Text(text) => {
                let trimmed = text.trim();
                if trimmed.is_empty() {
                    continue;
                }
                match serde_json::from_str::<Value>(trimmed) {
                    Ok(value) => return Ok(Some(value)),
                    Err(_) => continue,
                }
            }
            Message::Binary(bytes) => {
                let text = String::from_utf8(bytes.to_vec()).map_err(|error| {
                    format!("failed decoding Claude SDK websocket frame: {error}")
                })?;
                let trimmed = text.trim();
                if trimmed.is_empty() {
                    continue;
                }
                match serde_json::from_str::<Value>(trimmed) {
                    Ok(value) => return Ok(Some(value)),
                    Err(_) => continue,
                }
            }
            Message::Ping(payload) => {
                socket
                    .send(Message::Pong(payload))
                    .map_err(|error| format!("failed responding to Claude SDK ping: {error}"))?;
            }
            Message::Pong(_) | Message::Frame(_) => {}
            Message::Close(_) => return Ok(None),
        }
    }
}

fn write_claude_sdk_message(
    socket: &mut WebSocket<TcpStream>,
    payload: &Value,
    context: &str,
) -> Result<(), String> {
    let frame = serde_json::to_string(payload)
        .map_err(|error| format!("failed to serialize Claude SDK {context}: {error}"))?;
    socket
        .send(Message::Text(format!("{frame}\n").into()))
        .map_err(|error| format!("failed to write Claude SDK {context}: {error}"))
}

pub(super) fn write_claude_sdk_control_request(
    socket: &mut WebSocket<TcpStream>,
    request_id: &str,
    session_id: &str,
    request: Value,
) -> Result<(), String> {
    write_claude_sdk_message(
        socket,
        &json!({
            "type": "control_request",
            "session_id": session_id,
            "request_id": request_id,
            "request": request,
        }),
        "control request",
    )
}

fn write_claude_stdin_message(
    stdin: &Arc<Mutex<ChildStdin>>,
    payload: &Value,
    context: &str,
) -> Result<(), String> {
    let frame = serde_json::to_string(payload)
        .map_err(|error| format!("failed to serialize Claude stdin {context}: {error}"))?;
    let mut stdin = stdin
        .lock()
        .expect("claude stdin lock should not be poisoned");
    stdin
        .write_all(frame.as_bytes())
        .map_err(|error| format!("failed to write Claude stdin {context}: {error}"))?;
    stdin
        .write_all(b"\n")
        .map_err(|error| format!("failed to terminate Claude stdin {context}: {error}"))?;
    stdin
        .flush()
        .map_err(|error| format!("failed to flush Claude stdin {context}: {error}"))
}

pub(super) fn write_claude_stdin_control_response(
    stdin: &Arc<Mutex<ChildStdin>>,
    request_id: &str,
    response_payload: Value,
) -> Result<(), String> {
    write_claude_stdin_message(
        stdin,
        &json!({
            "type": "control_response",
            "response": {
                "subtype": "success",
                "request_id": request_id,
                "response": response_payload,
            },
        }),
        "control response",
    )
}

pub(super) fn write_claude_stdin_control_error_response(
    stdin: &Arc<Mutex<ChildStdin>>,
    request_id: &str,
    error_message: &str,
) -> Result<(), String> {
    write_claude_stdin_message(
        stdin,
        &json!({
            "type": "control_response",
            "response": {
                "subtype": "error",
                "request_id": request_id,
                "error": error_message,
            },
        }),
        "control error response",
    )
}

pub(super) fn write_claude_turn_input(
    stdin: &Arc<Mutex<ChildStdin>>,
    bytes: &[u8],
) -> Result<(), String> {
    let mut stdin = stdin
        .lock()
        .expect("claude stdin lock should not be poisoned");
    stdin
        .write_all(bytes)
        .map_err(|error| format!("failed to write Claude turn input: {error}"))?;
    stdin
        .flush()
        .map_err(|error| format!("failed to flush Claude turn input: {error}"))
}

pub(super) fn summarize_claude_stdout(stdout_output: &str) -> Option<String> {
    stdout_output
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .find(|line| looks_like_claude_error_summary(line))
        .map(|line| truncate_for_mobile_error(line, 240))
}

pub(super) fn summarize_claude_process_failure(
    base_message: String,
    stdout_output: &str,
    stderr_output: &str,
) -> String {
    if let Some(summary) =
        summarize_claude_stderr(stderr_output).or_else(|| summarize_claude_stdout(stdout_output))
    {
        format!("{base_message}: {summary}")
    } else {
        base_message
    }
}

fn claude_message_text(message: &Value) -> Option<String> {
    let content = message.get("content")?.as_array()?;
    let text = content
        .iter()
        .filter(|item| item.get("type").and_then(Value::as_str) == Some("text"))
        .filter_map(|item| item.get("text").and_then(Value::as_str))
        .collect::<Vec<_>>()
        .join("\n");
    let trimmed = text.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_string())
}

pub(super) fn build_claude_status_event(
    thread_id: &str,
    value: &Value,
) -> Option<BridgeEventEnvelope<Value>> {
    if value.get("type").and_then(Value::as_str) != Some("result") {
        return None;
    }

    let is_error = value
        .get("is_error")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let status = if is_error {
        ThreadStatus::Failed
    } else {
        ThreadStatus::Completed
    };
    let reason = if is_error {
        "claude_result_error"
    } else {
        "claude_result"
    };
    Some(build_thread_status_event(thread_id, status, reason))
}

pub(super) fn build_thread_status_event(
    thread_id: &str,
    status: ThreadStatus,
    reason: &str,
) -> BridgeEventEnvelope<Value> {
    let occurred_at = Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true);
    BridgeEventEnvelope::new(
        format!("{thread_id}-status-{occurred_at}"),
        thread_id.to_string(),
        BridgeEventKind::ThreadStatusChanged,
        occurred_at,
        json!({
            "status": match status {
                ThreadStatus::Idle => "idle",
                ThreadStatus::Running => "running",
                ThreadStatus::Completed => "completed",
                ThreadStatus::Interrupted => "interrupted",
                ThreadStatus::Failed => "failed",
            },
            "reason": reason,
        }),
    )
}

pub(super) fn remove_claude_process(
    active_claude_processes: &Arc<Mutex<HashMap<String, Arc<Mutex<Child>>>>>,
    thread_id: &str,
) {
    active_claude_processes
        .lock()
        .expect("active claude process lock should not be poisoned")
        .remove(thread_id);
}
