mod input;
mod models;
mod snapshot;
mod stream;

use super::*;
pub(crate) use input::build_claude_input_message;
#[cfg(test)]
pub(crate) use input::{build_claude_message_content, parse_data_url_image};
pub(crate) use models::fallback_claude_model_options;
use snapshot::build_claude_placeholder_snapshot;
#[cfg(test)]
pub(crate) use snapshot::claude_project_slug;
pub(crate) use snapshot::claude_session_archive_path;
#[cfg(test)]
pub(crate) use stream::summarize_claude_stderr;
use stream::{
    accept_claude_sdk_connection, bind_claude_sdk_listener, build_claude_assistant_event,
    build_claude_partial_assistant_event, build_claude_status_event,
    build_claude_tool_call_event_from_control_request, build_claude_tool_events_from_message,
    build_thread_status_event, parse_claude_control_cancel_request_id,
    parse_claude_control_request_id, parse_claude_message_start, parse_claude_text_delta,
    read_claude_sdk_message, remove_claude_process, summarize_claude_process_failure,
    summarize_claude_stdout, write_claude_sdk_control_request,
    write_claude_stdin_control_error_response, write_claude_stdin_control_response,
    write_claude_turn_input,
};

impl CodexGateway {
    pub(super) async fn create_claude_thread(
        &self,
        workspace: &str,
    ) -> Result<ThreadSnapshotDto, String> {
        let normalized_workspace = workspace.trim();
        if normalized_workspace.is_empty() {
            return Err("workspace path cannot be empty".to_string());
        }

        let thread_id = provider_thread_id(ProviderKind::ClaudeCode, &Uuid::new_v4().to_string());
        let snapshot = build_claude_placeholder_snapshot(&thread_id, normalized_workspace);
        self.claude_thread_workspaces
            .lock()
            .expect("claude thread workspace lock should not be poisoned")
            .insert(thread_id, normalized_workspace.to_string());
        Ok(snapshot)
    }

    pub(super) fn start_claude_turn_streaming<F, G, H, I>(
        &self,
        thread_id: &str,
        request: TurnStartRequest,
        on_event: F,
        on_control_request: H,
        on_turn_completed: G,
        _on_stream_finished: I,
    ) -> Result<GatewayTurnMutation, String>
    where
        F: Fn(BridgeEventEnvelope<Value>) + Send + 'static,
        H: Fn(GatewayTurnControlRequest) -> Result<Option<Value>, String> + Send + Sync + 'static,
        G: Fn(String) + Send + 'static,
        I: Fn(String) + Send + Sync + 'static,
    {
        if !is_provider_thread_id(thread_id, ProviderKind::ClaudeCode) {
            return Err(format!("thread {thread_id} is not a Claude Code thread"));
        }

        let thread_id = thread_id.to_string();
        let native_thread_id = native_thread_id_for_provider(&thread_id, ProviderKind::ClaudeCode)
            .ok_or_else(|| format!("thread {thread_id} is not a Claude Code thread"))?
            .to_string();
        let workspace = self
            .claude_thread_workspaces
            .lock()
            .expect("claude thread workspace lock should not be poisoned")
            .get(&thread_id)
            .cloned()
            .or_else(|| {
                super::codex::fetch_thread_snapshot_from_archive(&self.config, &thread_id)
                    .ok()
                    .map(|snapshot| snapshot.thread.workspace)
            })
            .ok_or_else(|| format!("workspace for Claude thread {thread_id} is unavailable"))?;
        let active_claude_processes = Arc::clone(&self.active_claude_processes);
        let interrupted_claude_threads = Arc::clone(&self.interrupted_claude_threads);
        let on_control_request = Arc::new(on_control_request);
        let (result_tx, result_rx) = mpsc::sync_channel(1);

        std::thread::spawn(move || {
            let session_exists = claude_session_archive_path(&workspace, &native_thread_id)
                .is_some_and(|path| path.is_file());
            let (sdk_listener, sdk_url) = match bind_claude_sdk_listener() {
                Ok(listener) => listener,
                Err(error) => {
                    let _ = result_tx.send(Err(error));
                    return;
                }
            };
            let mut command = Command::new("claude");
            command
                .current_dir(&workspace)
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .env("CLAUDE_CODE_ENVIRONMENT_KIND", "bridge")
                .arg("--print")
                .arg("--verbose")
                .arg("--include-partial-messages")
                .arg("--output-format")
                .arg("stream-json")
                .arg("--input-format")
                .arg("stream-json")
                .arg("--replay-user-messages")
                .arg("--sdk-url")
                .arg(&sdk_url)
                .arg("--permission-mode")
                .arg(request.permission_mode.as_deref().unwrap_or("default"));
            if session_exists {
                command.arg("--resume").arg(&native_thread_id);
            } else {
                command.arg("--session-id").arg(&native_thread_id);
            }
            if let Some(model) = request
                .model
                .as_deref()
                .map(str::trim)
                .filter(|value| !value.is_empty())
            {
                command.arg("--model").arg(model);
            }
            if let Some(effort) = request
                .effort
                .as_deref()
                .map(str::trim)
                .filter(|value| !value.is_empty())
            {
                command.arg("--effort").arg(effort);
            }

            let mut child = match command.spawn() {
                Ok(child) => child,
                Err(error) => {
                    let _ = result_tx.send(Err(format!("failed to start claude: {error}")));
                    return;
                }
            };
            let stdout = match child.stdout.take() {
                Some(stdout) => stdout,
                None => {
                    let _ = result_tx.send(Err("Claude process did not expose stdout".to_string()));
                    let _ = child.kill();
                    let _ = child.wait();
                    return;
                }
            };
            let stdin = match child.stdin.take() {
                Some(stdin) => stdin,
                None => {
                    let _ = result_tx.send(Err("Claude process did not expose stdin".to_string()));
                    let _ = child.kill();
                    let _ = child.wait();
                    return;
                }
            };
            let stderr = child.stderr.take();
            let input_line = match build_claude_input_message(&request.prompt, &request.images) {
                Ok(line) => line,
                Err(error) => {
                    let _ = result_tx.send(Err(error));
                    let _ = child.kill();
                    let _ = child.wait();
                    return;
                }
            };
            let child_handle = Arc::new(Mutex::new(child));
            active_claude_processes
                .lock()
                .expect("active claude process lock should not be poisoned")
                .insert(thread_id.clone(), Arc::clone(&child_handle));

            let stdin_handle = Arc::new(Mutex::new(stdin));
            let stdout_reader = std::thread::spawn(move || {
                let mut stdout_output = String::new();
                for line in BufReader::new(stdout).lines() {
                    let Ok(line) = line else {
                        break;
                    };
                    stdout_output.push_str(&line);
                    stdout_output.push('\n');
                    let trimmed = line.trim();
                    if trimmed.is_empty() {
                        continue;
                    }
                }
                stdout_output
            });
            let stderr_reader = std::thread::spawn(move || {
                let mut stderr_output = String::new();
                if let Some(mut stderr) = stderr {
                    let _ = stderr.read_to_string(&mut stderr_output);
                }
                stderr_output
            });
            let mut sdk_socket =
                match accept_claude_sdk_connection(&sdk_listener, &child_handle, &thread_id) {
                    Ok(socket) => socket,
                    Err(error) => {
                        remove_claude_process(&active_claude_processes, &thread_id);
                        let stdout_output = stdout_reader.join().unwrap_or_default();
                        let stderr_output = stderr_reader.join().unwrap_or_default();
                        if !stdout_output.trim().is_empty() {
                            eprintln!("claude stdout for {thread_id}: {}", stdout_output.trim());
                        }
                        if !stderr_output.trim().is_empty() {
                            eprintln!("claude stderr for {thread_id}: {}", stderr_output.trim());
                        }
                        let _ = result_tx.send(Err(summarize_claude_process_failure(
                            error,
                            &stdout_output,
                            &stderr_output,
                        )));
                        return;
                    }
                };
            let initialize_request_id = Uuid::new_v4().to_string();
            if let Err(error) = write_claude_sdk_control_request(
                &mut sdk_socket,
                &initialize_request_id,
                &native_thread_id,
                json!({
                    "subtype": "initialize",
                }),
            ) {
                let _ = child_handle
                    .lock()
                    .expect("claude child lock should not be poisoned")
                    .kill();
                remove_claude_process(&active_claude_processes, &thread_id);
                let stdout_output = stdout_reader.join().unwrap_or_default();
                let stderr_output = stderr_reader.join().unwrap_or_default();
                if !stdout_output.trim().is_empty() {
                    eprintln!("claude stdout for {thread_id}: {}", stdout_output.trim());
                }
                if !stderr_output.trim().is_empty() {
                    eprintln!("claude stderr for {thread_id}: {}", stderr_output.trim());
                }
                let _ = result_tx.send(Err(summarize_claude_process_failure(
                    error,
                    &stdout_output,
                    &stderr_output,
                )));
                return;
            }

            let turn_id = format!("claude-turn-{native_thread_id}");
            let accepted = GatewayTurnMutation {
                response: TurnMutationAcceptedDto {
                    contract_version: CONTRACT_VERSION.to_string(),
                    thread_id: thread_id.clone(),
                    thread_status: ThreadStatus::Running,
                    message: format!("turn {turn_id} started"),
                    turn_id: Some(turn_id.clone()),
                },
                turn_id: Some(turn_id),
            };
            let mut did_ack = false;
            let mut did_report_turn_start = false;
            let mut did_emit_completion = false;
            let mut did_emit_assistant_output = false;
            let mut did_send_input = false;
            let mut current_assistant_message_id: Option<String> = None;
            let mut current_assistant_text = String::new();
            let mut tool_name_by_id = HashMap::new();
            let mut file_change_tool_ids = HashSet::new();
            let mut emitted_tool_use_ids = HashSet::new();
            let mut emitted_tool_result_ids = HashSet::new();

            loop {
                let value = match read_claude_sdk_message(&mut sdk_socket) {
                    Ok(Some(value)) => value,
                    Ok(None) => break,
                    Err(error) => {
                        eprintln!("failed to read Claude SDK message for {thread_id}: {error}");
                        break;
                    }
                };
                if let Some(request_id) = parse_claude_control_request_id(&value) {
                    let request = value
                        .get("request")
                        .cloned()
                        .unwrap_or(Value::Object(serde_json::Map::new()));
                    match request.get("subtype").and_then(Value::as_str) {
                        Some("can_use_tool") => {
                            if let Some(event) = build_claude_tool_call_event_from_control_request(
                                &thread_id,
                                &request,
                                &mut tool_name_by_id,
                                &mut file_change_tool_ids,
                                &mut emitted_tool_use_ids,
                            ) {
                                on_event(event);
                            }
                            match on_control_request(GatewayTurnControlRequest::ClaudeCanUseTool {
                                request_id: request_id.clone(),
                                request,
                            }) {
                                Ok(Some(response_payload)) => {
                                    if let Err(error) = write_claude_stdin_control_response(
                                        &stdin_handle,
                                        &request_id,
                                        response_payload,
                                    ) {
                                        eprintln!(
                                            "failed to write Claude stdin control response for {thread_id}: {error}"
                                        );
                                        break;
                                    }
                                }
                                Ok(None) => {}
                                Err(error) => {
                                    if let Err(write_error) =
                                        write_claude_stdin_control_error_response(
                                            &stdin_handle,
                                            &request_id,
                                            &error,
                                        )
                                    {
                                        eprintln!(
                                            "failed to write Claude stdin control error response for {thread_id}: {write_error}"
                                        );
                                        break;
                                    }
                                }
                            }
                        }
                        _ => {
                            if let Err(error) = write_claude_stdin_control_error_response(
                                &stdin_handle,
                                &request_id,
                                "unsupported control request subtype",
                            ) {
                                eprintln!(
                                    "failed to write Claude stdin control error response for {thread_id}: {error}"
                                );
                                break;
                            }
                        }
                    }
                    continue;
                }

                if let Some(cancel_request_id) = parse_claude_control_cancel_request_id(&value) {
                    let _ = on_control_request(GatewayTurnControlRequest::ClaudeControlCancel {
                        request_id: cancel_request_id,
                    });
                    continue;
                }

                if !did_ack
                    && value.get("type").and_then(Value::as_str) == Some("system")
                    && value.get("subtype").and_then(Value::as_str) == Some("init")
                {
                    if result_tx.send(Ok(accepted.clone())).is_err() {
                        remove_claude_process(&active_claude_processes, &thread_id);
                        return;
                    }
                    did_report_turn_start = true;
                    did_ack = true;
                }

                if value.get("type").and_then(Value::as_str) == Some("control_response") {
                    let Some(response) = value.get("response") else {
                        continue;
                    };
                    let Some(request_id) = response.get("request_id").and_then(Value::as_str)
                    else {
                        continue;
                    };
                    if request_id != initialize_request_id {
                        continue;
                    }
                    if response.get("subtype").and_then(Value::as_str) != Some("success") {
                        let error = response
                            .get("error")
                            .and_then(Value::as_str)
                            .unwrap_or("Claude SDK initialization failed")
                            .to_string();
                        let _ = result_tx.send(Err(error));
                        did_report_turn_start = true;
                        break;
                    }
                    if !did_send_input {
                        if let Err(error) =
                            write_claude_turn_input(&stdin_handle, input_line.as_bytes())
                        {
                            let _ = result_tx.send(Err(error));
                            did_report_turn_start = true;
                            break;
                        }
                        did_send_input = true;
                    }
                    if !did_ack {
                        if result_tx.send(Ok(accepted.clone())).is_err() {
                            remove_claude_process(&active_claude_processes, &thread_id);
                            return;
                        }
                        did_report_turn_start = true;
                        did_ack = true;
                    }
                    continue;
                }

                for event in build_claude_tool_events_from_message(
                    &thread_id,
                    &value,
                    &mut tool_name_by_id,
                    &mut file_change_tool_ids,
                    &mut emitted_tool_use_ids,
                    &mut emitted_tool_result_ids,
                ) {
                    on_event(event);
                }

                if let Some(event) = build_claude_assistant_event(&thread_id, &value) {
                    did_emit_assistant_output = true;
                    on_event(event);
                }

                if let Some(message_id) = parse_claude_message_start(&value) {
                    current_assistant_message_id = Some(message_id);
                    current_assistant_text.clear();
                }

                if let Some(delta) = parse_claude_text_delta(&value)
                    && let Some(message_id) = current_assistant_message_id.as_deref()
                {
                    current_assistant_text.push_str(&delta);
                    did_emit_assistant_output = true;
                    on_event(build_claude_partial_assistant_event(
                        &thread_id,
                        message_id,
                        &current_assistant_text,
                    ));
                }

                if let Some(status_event) = build_claude_status_event(&thread_id, &value) {
                    if !did_ack {
                        let _ = result_tx.send(Ok(accepted.clone()));
                        did_report_turn_start = true;
                    }
                    on_event(status_event);
                    did_emit_completion = true;
                    on_turn_completed(thread_id.clone());
                    break;
                }
            }

            let exit_status = child_handle
                .lock()
                .expect("claude child lock should not be poisoned")
                .wait();
            remove_claude_process(&active_claude_processes, &thread_id);
            let stdout_output = stdout_reader.join().unwrap_or_default();
            let stderr_output = stderr_reader.join().unwrap_or_default();
            if !stdout_output.trim().is_empty() {
                eprintln!("claude stdout for {thread_id}: {}", stdout_output.trim());
            }
            if !stderr_output.trim().is_empty() {
                eprintln!("claude stderr for {thread_id}: {}", stderr_output.trim());
            }

            if !did_emit_completion {
                let was_interrupted = interrupted_claude_threads
                    .lock()
                    .expect("interrupted claude thread lock should not be poisoned")
                    .remove(&thread_id);
                let status = if was_interrupted {
                    ThreadStatus::Interrupted
                } else {
                    ThreadStatus::Failed
                };
                let reason = if was_interrupted {
                    "interrupt_requested"
                } else {
                    "claude_process_exited"
                };
                on_event(build_thread_status_event(&thread_id, status, reason));
                on_turn_completed(thread_id.clone());
            }

            if !did_report_turn_start {
                let exit_message = match exit_status {
                    Ok(status) if !status.success() => format!(
                        "Claude process exited with status {}",
                        status.code().unwrap_or_default()
                    ),
                    Ok(_) if did_emit_assistant_output => "Claude turn completed".to_string(),
                    Ok(_) if !did_send_input => {
                        "Claude exited before the SDK bridge accepted the turn".to_string()
                    }
                    Ok(_) => "Claude exited before the turn was accepted".to_string(),
                    Err(error) => format!("failed waiting for Claude process: {error}"),
                };
                let message = if let Some(summary) = stream::summarize_claude_stderr(&stderr_output)
                    .or_else(|| summarize_claude_stdout(&stdout_output))
                {
                    format!("{exit_message}: {summary}")
                } else {
                    exit_message
                };
                let _ = result_tx.send(Err(message));
            }
        });

        result_rx
            .recv()
            .map_err(|error| format!("failed to receive Claude turn-start result: {error}"))?
    }
}
