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

pub(super) fn build_claude_tool_call_event_from_control_request(
    thread_id: &str,
    request: &Value,
    tool_name_by_id: &mut HashMap<String, String>,
    file_change_tool_ids: &mut HashSet<String>,
    emitted_tool_use_ids: &mut HashSet<String>,
) -> Option<BridgeEventEnvelope<Value>> {
    if request.get("subtype").and_then(Value::as_str) != Some("can_use_tool") {
        return None;
    }

    let tool_name = request
        .get("display_name")
        .or_else(|| request.get("tool_name"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or("tool");
    let tool_use_id = request
        .get("tool_use_id")
        .or_else(|| request.get("toolUseID"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())?;
    let input = request.get("input").cloned().unwrap_or(Value::Null);

    build_claude_tool_call_event(
        thread_id,
        tool_use_id,
        tool_name,
        input,
        tool_name_by_id,
        file_change_tool_ids,
        emitted_tool_use_ids,
    )
}

pub(super) fn build_claude_tool_events_from_message(
    thread_id: &str,
    value: &Value,
    tool_name_by_id: &mut HashMap<String, String>,
    file_change_tool_ids: &mut HashSet<String>,
    emitted_tool_use_ids: &mut HashSet<String>,
    emitted_tool_result_ids: &mut HashSet<String>,
) -> Vec<BridgeEventEnvelope<Value>> {
    let Some(message) = value.get("message") else {
        return Vec::new();
    };
    let Some(content) = message.get("content").and_then(Value::as_array) else {
        return Vec::new();
    };

    let mut events = Vec::new();
    for item in content {
        match item.get("type").and_then(Value::as_str).unwrap_or_default() {
            "tool_use" => {
                let Some(tool_use_id) = item
                    .get("id")
                    .and_then(Value::as_str)
                    .map(str::trim)
                    .filter(|value| !value.is_empty())
                else {
                    continue;
                };
                let tool_name = item
                    .get("name")
                    .and_then(Value::as_str)
                    .map(str::trim)
                    .filter(|value| !value.is_empty())
                    .unwrap_or("tool");
                let input = item.get("input").cloned().unwrap_or(Value::Null);
                if let Some(event) = build_claude_tool_call_event(
                    thread_id,
                    tool_use_id,
                    tool_name,
                    input,
                    tool_name_by_id,
                    file_change_tool_ids,
                    emitted_tool_use_ids,
                ) {
                    events.push(event);
                }
            }
            "tool_result" => {
                let Some(tool_use_id) = item
                    .get("tool_use_id")
                    .or_else(|| item.get("toolUseID"))
                    .and_then(Value::as_str)
                    .map(str::trim)
                    .filter(|value| !value.is_empty())
                    .map(str::to_string)
                else {
                    continue;
                };
                if !emitted_tool_result_ids.insert(tool_use_id.clone()) {
                    continue;
                }

                let tool_name = tool_name_by_id
                    .get(&tool_use_id)
                    .cloned()
                    .unwrap_or_else(|| "tool".to_string());
                let is_file_change = file_change_tool_ids.contains(&tool_use_id);
                let output = normalize_claude_tool_result_output(item);

                let payload = if is_file_change {
                    json!({
                        "id": tool_use_id,
                        "type": "file_change",
                        "command": tool_name,
                        "tool_use_id": item.get("tool_use_id").or_else(|| item.get("toolUseID")).cloned().unwrap_or(Value::String(tool_use_id.clone())),
                        "resolved_unified_diff": output,
                        "output": output,
                        "path": "",
                    })
                } else {
                    json!({
                        "id": tool_use_id,
                        "type": "command",
                        "command": tool_name,
                        "tool_use_id": item.get("tool_use_id").or_else(|| item.get("toolUseID")).cloned().unwrap_or(Value::String(tool_use_id.clone())),
                        "output": output,
                    })
                };

                events.push(BridgeEventEnvelope::new(
                    format!("{thread_id}-claude-tool-result-{tool_use_id}"),
                    thread_id.to_string(),
                    if is_file_change {
                        BridgeEventKind::FileChange
                    } else {
                        BridgeEventKind::CommandDelta
                    },
                    Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true),
                    payload,
                ));
            }
            _ => {}
        }
    }

    events
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

fn build_claude_tool_call_event(
    thread_id: &str,
    tool_use_id: &str,
    tool_name: &str,
    input: Value,
    tool_name_by_id: &mut HashMap<String, String>,
    file_change_tool_ids: &mut HashSet<String>,
    emitted_tool_use_ids: &mut HashSet<String>,
) -> Option<BridgeEventEnvelope<Value>> {
    if !emitted_tool_use_ids.insert(tool_use_id.to_string()) {
        return None;
    }

    let input_text = value_to_text(&input).unwrap_or_default();
    let is_file_change = is_claude_file_change_tool(tool_name) || is_file_change_text(&input_text);
    tool_name_by_id.insert(tool_use_id.to_string(), tool_name.to_string());
    if is_file_change {
        file_change_tool_ids.insert(tool_use_id.to_string());
    }

    let payload = if is_file_change {
        json!({
            "id": tool_use_id,
            "type": "file_change",
            "command": tool_name,
            "tool_use_id": tool_use_id,
            "change": input_text,
            "resolved_unified_diff": input_text,
            "output": input_text,
            "input": input,
            "path": "",
        })
    } else {
        json!({
            "id": tool_use_id,
            "type": "command",
            "command": tool_name,
            "tool_use_id": tool_use_id,
            "arguments": input,
            "output": format!("Called {tool_name}"),
        })
    };

    Some(BridgeEventEnvelope::new(
        format!("{thread_id}-claude-tool-call-{tool_use_id}"),
        thread_id.to_string(),
        if is_file_change {
            BridgeEventKind::FileChange
        } else {
            BridgeEventKind::CommandDelta
        },
        Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true),
        payload,
    ))
}

fn normalize_claude_tool_result_output(item: &Value) -> String {
    if let Some(tool_use_result) = item.get("toolUseResult") {
        if let Some(stdout) = tool_use_result.get("stdout").and_then(Value::as_str) {
            let stderr = tool_use_result
                .get("stderr")
                .and_then(Value::as_str)
                .unwrap_or_default();
            let combined = [stdout.trim_end(), stderr.trim_end()]
                .into_iter()
                .filter(|value| !value.is_empty())
                .collect::<Vec<_>>()
                .join("\n");
            if !combined.is_empty() {
                return combined;
            }
        }
        if let Some(content) = tool_use_result.get("content") {
            let text = value_to_text(content).unwrap_or_default();
            if !text.trim().is_empty() {
                return text;
            }
        }
    }

    match item.get("content") {
        Some(Value::String(text)) => text.to_string(),
        Some(Value::Array(values)) => values
            .iter()
            .filter_map(|value| {
                value.as_str().map(ToString::to_string).or_else(|| {
                    value
                        .get("text")
                        .and_then(Value::as_str)
                        .map(ToString::to_string)
                })
            })
            .collect::<Vec<_>>()
            .join("\n"),
        Some(value) => value_to_text(value).unwrap_or_default(),
        None => String::new(),
    }
}

fn is_claude_file_change_tool(tool_name: &str) -> bool {
    matches!(
        tool_name.trim().to_ascii_lowercase().as_str(),
        "edit" | "write" | "multiedit" | "notebookedit"
    )
}

fn is_file_change_text(text: &str) -> bool {
    if text.is_empty() {
        return false;
    }

    text.contains("Updated the following files:")
        || text.contains("*** Begin Patch")
        || text.contains("*** Update File:")
        || text.contains("*** Add File:")
        || text.contains("[diff_block_start]")
        || text.contains("diff --git ")
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

fn value_to_text(value: &Value) -> Option<String> {
    match value {
        Value::String(text) => Some(text.clone()),
        Value::Null => None,
        other => serde_json::to_string(other).ok(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn claude_control_request_emits_command_event() {
        let mut tool_name_by_id = HashMap::new();
        let mut file_change_tool_ids = HashSet::new();
        let mut emitted_tool_use_ids = HashSet::new();
        let request = json!({
            "subtype": "can_use_tool",
            "display_name": "Bash",
            "tool_use_id": "tool-1",
            "input": { "cmd": "ls -la" },
        });

        let event = build_claude_tool_call_event_from_control_request(
            "claude:thread-1",
            &request,
            &mut tool_name_by_id,
            &mut file_change_tool_ids,
            &mut emitted_tool_use_ids,
        )
        .expect("tool call event should be emitted");

        assert_eq!(event.kind, BridgeEventKind::CommandDelta);
        assert_eq!(event.payload["command"], "Bash");
        assert_eq!(event.payload["arguments"], json!({"cmd":"ls -la"}));
        assert_eq!(event.payload["output"], "Called Bash");
    }

    #[test]
    fn claude_message_tool_result_emits_command_output_event() {
        let mut tool_name_by_id = HashMap::new();
        let mut file_change_tool_ids = HashSet::new();
        let mut emitted_tool_use_ids = HashSet::new();
        let mut emitted_tool_result_ids = HashSet::new();

        let _ = build_claude_tool_call_event_from_control_request(
            "claude:thread-1",
            &json!({
                "subtype": "can_use_tool",
                "display_name": "Bash",
                "tool_use_id": "tool-1",
                "input": { "cmd": "pwd" },
            }),
            &mut tool_name_by_id,
            &mut file_change_tool_ids,
            &mut emitted_tool_use_ids,
        );

        let events = build_claude_tool_events_from_message(
            "claude:thread-1",
            &json!({
                "type": "user",
                "message": {
                    "content": [{
                        "type": "tool_result",
                        "tool_use_id": "tool-1",
                        "content": "/workspace\n",
                    }]
                }
            }),
            &mut tool_name_by_id,
            &mut file_change_tool_ids,
            &mut emitted_tool_use_ids,
            &mut emitted_tool_result_ids,
        );

        assert_eq!(events.len(), 1);
        assert_eq!(events[0].kind, BridgeEventKind::CommandDelta);
        assert_eq!(events[0].payload["command"], "Bash");
        assert_eq!(events[0].payload["output"], "/workspace\n");
    }

    #[test]
    fn claude_assistant_tool_use_emits_file_change_event_without_control_request() {
        let mut tool_name_by_id = HashMap::new();
        let mut file_change_tool_ids = HashSet::new();
        let mut emitted_tool_use_ids = HashSet::new();
        let mut emitted_tool_result_ids = HashSet::new();

        let events = build_claude_tool_events_from_message(
            "claude:thread-1",
            &json!({
                "type": "assistant",
                "message": {
                    "content": [{
                        "type": "tool_use",
                        "id": "tool-edit-1",
                        "name": "Edit",
                        "input": { "patch": "*** Begin Patch\n*** Update File: src/main.rs\n*** End Patch" }
                    }]
                }
            }),
            &mut tool_name_by_id,
            &mut file_change_tool_ids,
            &mut emitted_tool_use_ids,
            &mut emitted_tool_result_ids,
        );

        assert_eq!(events.len(), 1);
        assert_eq!(events[0].kind, BridgeEventKind::FileChange);
        assert_eq!(events[0].payload["command"], "Edit");
        assert!(
            events[0].payload["resolved_unified_diff"]
                .as_str()
                .unwrap_or_default()
                .contains("*** Update File: src/main.rs")
        );
    }
}
