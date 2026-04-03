use super::mapping::derive_repository_name_from_cwd;
use super::*;

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
                let message = if let Some(summary) = summarize_claude_stderr(&stderr_output)
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

fn build_claude_placeholder_snapshot(thread_id: &str, workspace: &str) -> ThreadSnapshotDto {
    let timestamp = Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true);
    let git_context = detect_git_context(workspace);
    let repository = git_context.repository.clone();
    let branch = git_context.branch.clone();
    ThreadSnapshotDto {
        contract_version: CONTRACT_VERSION.to_string(),
        thread: ThreadDetailDto {
            contract_version: CONTRACT_VERSION.to_string(),
            thread_id: thread_id.to_string(),
            native_thread_id: native_thread_id_for_provider(thread_id, ProviderKind::ClaudeCode)
                .unwrap_or(thread_id)
                .to_string(),
            provider: ProviderKind::ClaudeCode,
            client: shared_contracts::ThreadClientKind::Bridge,
            title: "New thread".to_string(),
            status: ThreadStatus::Idle,
            workspace: workspace.to_string(),
            repository: repository.clone(),
            branch: branch.clone(),
            created_at: timestamp.clone(),
            updated_at: timestamp,
            source: "bridge".to_string(),
            access_mode: AccessMode::ControlWithApprovals,
            last_turn_summary: String::new(),
            active_turn_id: None,
        },
        entries: Vec::new(),
        approvals: Vec::new(),
        git_status: Some(GitStatusDto {
            workspace: workspace.to_string(),
            repository,
            branch,
            remote: git_context.remote,
            dirty: false,
            ahead_by: 0,
            behind_by: 0,
        }),
        pending_user_input: None,
    }
}

#[derive(Debug, Clone)]
struct WorkspaceGitContext {
    repository: String,
    branch: String,
    remote: Option<String>,
}

fn detect_git_context(workspace: &str) -> WorkspaceGitContext {
    let repository = run_git_output(workspace, ["rev-parse", "--show-toplevel"])
        .ok()
        .as_deref()
        .and_then(super::mapping::derive_repository_name_from_path)
        .or_else(|| derive_repository_name_from_cwd(workspace))
        .unwrap_or_else(|| "unknown-repository".to_string());
    let branch = run_git_output(workspace, ["rev-parse", "--abbrev-ref", "HEAD"])
        .ok()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| "unknown".to_string());
    let remote = run_git_output(workspace, ["remote", "get-url", "origin"])
        .ok()
        .filter(|value| !value.trim().is_empty());

    WorkspaceGitContext {
        repository,
        branch,
        remote,
    }
}

fn run_git_output<I, S>(workspace: &str, args: I) -> Result<String, String>
where
    I: IntoIterator<Item = S>,
    S: AsRef<std::ffi::OsStr>,
{
    let output = Command::new("git")
        .arg("-C")
        .arg(workspace)
        .args(args)
        .output()
        .map_err(|error| format!("failed to run git: {error}"))?;
    if !output.status.success() {
        return Err(String::from_utf8_lossy(&output.stderr).trim().to_string());
    }

    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

pub(super) fn claude_session_archive_path(workspace: &str, session_id: &str) -> Option<PathBuf> {
    let claude_home = std::env::var_os("CLAUDE_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".claude")))?;
    Some(
        claude_home
            .join("projects")
            .join(claude_project_slug(workspace))
            .join(format!("{session_id}.jsonl")),
    )
}

pub(super) fn claude_project_slug(workspace: &str) -> String {
    workspace
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() || matches!(ch, '.' | '_' | '-') {
                ch
            } else {
                '-'
            }
        })
        .collect()
}

pub(super) fn build_claude_input_message(
    prompt: &str,
    images: &[String],
) -> Result<String, String> {
    let content = build_claude_message_content(prompt, images)?;
    serde_json::to_string(&json!({
        "type": "user",
        "message": {
            "role": "user",
            "content": content,
        },
        "parent_tool_use_id": Value::Null,
    }))
    .map(|line| format!("{line}\n"))
    .map_err(|error| format!("failed to encode Claude turn input: {error}"))
}

pub(super) fn build_claude_message_content(
    prompt: &str,
    images: &[String],
) -> Result<Value, String> {
    let trimmed_prompt = prompt.trim();
    if images.is_empty() {
        return Ok(Value::String(trimmed_prompt.to_string()));
    }

    let mut blocks = Vec::new();
    if !trimmed_prompt.is_empty() {
        blocks.push(json!({
            "type": "text",
            "text": trimmed_prompt,
        }));
    }
    for (index, image) in images.iter().enumerate() {
        let parsed = parse_data_url_image(image)
            .map_err(|error| format!("image attachment {} is invalid: {error}", index + 1))?;
        blocks.push(json!({
            "type": "image",
            "source": {
                "type": "base64",
                "media_type": parsed.mime_type,
                "data": parsed.base64_data,
            },
        }));
    }

    Ok(Value::Array(blocks))
}

pub(super) struct ParsedDataUrlImage {
    pub(super) mime_type: String,
    pub(super) base64_data: String,
}

pub(super) fn parse_data_url_image(data_url: &str) -> Result<ParsedDataUrlImage, String> {
    let trimmed = data_url.trim();
    let Some((metadata, payload)) = trimmed.split_once(',') else {
        return Err("data URL is missing a payload".to_string());
    };
    if !metadata.starts_with("data:") {
        return Err("image must be a data URL".to_string());
    }
    if !metadata.contains(";base64") {
        return Err("image data URL must be base64-encoded".to_string());
    }

    let mime_type = metadata
        .trim_start_matches("data:")
        .split(';')
        .next()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| "image data URL is missing a MIME type".to_string())?;
    if !matches!(
        mime_type,
        "image/jpeg" | "image/png" | "image/gif" | "image/webp"
    ) {
        return Err(format!(
            "unsupported MIME type {mime_type}; Claude Code currently supports image/jpeg, image/png, image/gif, and image/webp"
        ));
    }

    let base64_data = payload.trim();
    let decoded = base64::engine::general_purpose::STANDARD
        .decode(base64_data)
        .map_err(|error| format!("invalid base64 payload: {error}"))?;
    if decoded.is_empty() {
        return Err("image payload is empty".to_string());
    }

    Ok(ParsedDataUrlImage {
        mime_type: mime_type.to_string(),
        base64_data: base64_data.to_string(),
    })
}

pub(super) fn summarize_claude_stderr(stderr_output: &str) -> Option<String> {
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

fn build_claude_assistant_event(
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

fn build_claude_partial_assistant_event(
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

fn parse_claude_message_start(value: &Value) -> Option<String> {
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

fn parse_claude_text_delta(value: &Value) -> Option<String> {
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

fn parse_claude_control_request_id(value: &Value) -> Option<String> {
    if value.get("type").and_then(Value::as_str) != Some("control_request") {
        return None;
    }
    value
        .get("request_id")
        .and_then(Value::as_str)
        .map(ToString::to_string)
}

fn parse_claude_control_cancel_request_id(value: &Value) -> Option<String> {
    if value.get("type").and_then(Value::as_str) != Some("control_cancel_request") {
        return None;
    }
    value
        .get("request_id")
        .and_then(Value::as_str)
        .map(ToString::to_string)
}

fn bind_claude_sdk_listener() -> Result<(TcpListener, String), String> {
    let listener = TcpListener::bind(("127.0.0.1", 0))
        .map_err(|error| format!("failed to bind local Claude SDK bridge listener: {error}"))?;
    let address = listener
        .local_addr()
        .map_err(|error| format!("failed to inspect local Claude SDK bridge listener: {error}"))?;
    Ok((listener, format!("ws://127.0.0.1:{}", address.port())))
}

fn accept_claude_sdk_connection(
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

fn read_claude_sdk_message(socket: &mut WebSocket<TcpStream>) -> Result<Option<Value>, String> {
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

fn write_claude_sdk_control_request(
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

fn write_claude_stdin_control_response(
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

fn write_claude_stdin_control_error_response(
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

fn write_claude_turn_input(stdin: &Arc<Mutex<ChildStdin>>, bytes: &[u8]) -> Result<(), String> {
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

fn summarize_claude_stdout(stdout_output: &str) -> Option<String> {
    stdout_output
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .find(|line| looks_like_claude_error_summary(line))
        .map(|line| truncate_for_mobile_error(line, 240))
}

fn summarize_claude_process_failure(
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

fn build_claude_status_event(thread_id: &str, value: &Value) -> Option<BridgeEventEnvelope<Value>> {
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

fn build_thread_status_event(
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

fn remove_claude_process(
    active_claude_processes: &Arc<Mutex<HashMap<String, Arc<Mutex<Child>>>>>,
    thread_id: &str,
) {
    active_claude_processes
        .lock()
        .expect("active claude process lock should not be poisoned")
        .remove(thread_id);
}

pub(super) fn fallback_claude_model_options() -> Vec<ModelOptionDto> {
    vec![
        ModelOptionDto {
            id: "claude-sonnet-4-6".to_string(),
            model: "claude-sonnet-4-6".to_string(),
            display_name: "Claude Sonnet 4.6".to_string(),
            description: String::new(),
            is_default: true,
            default_reasoning_effort: Some("medium".to_string()),
            supported_reasoning_efforts: claude_reasoning_efforts(),
        },
        ModelOptionDto {
            id: "claude-opus-4-6".to_string(),
            model: "claude-opus-4-6".to_string(),
            display_name: "Claude Opus 4.6".to_string(),
            description: String::new(),
            is_default: false,
            default_reasoning_effort: Some("high".to_string()),
            supported_reasoning_efforts: claude_reasoning_efforts(),
        },
        ModelOptionDto {
            id: "claude-sonnet-4-5".to_string(),
            model: "claude-sonnet-4-5".to_string(),
            display_name: "Claude Sonnet 4.5".to_string(),
            description: String::new(),
            is_default: false,
            default_reasoning_effort: Some("medium".to_string()),
            supported_reasoning_efforts: claude_reasoning_efforts(),
        },
        ModelOptionDto {
            id: "claude-opus-4-5".to_string(),
            model: "claude-opus-4-5".to_string(),
            display_name: "Claude Opus 4.5".to_string(),
            description: String::new(),
            is_default: false,
            default_reasoning_effort: Some("high".to_string()),
            supported_reasoning_efforts: claude_reasoning_efforts(),
        },
    ]
}

fn claude_reasoning_efforts() -> Vec<ReasoningEffortOptionDto> {
    vec![
        ReasoningEffortOptionDto {
            reasoning_effort: "low".to_string(),
            description: None,
        },
        ReasoningEffortOptionDto {
            reasoning_effort: "medium".to_string(),
            description: None,
        },
        ReasoningEffortOptionDto {
            reasoning_effort: "high".to_string(),
            description: None,
        },
        ReasoningEffortOptionDto {
            reasoning_effort: "max".to_string(),
            description: None,
        },
    ]
}
