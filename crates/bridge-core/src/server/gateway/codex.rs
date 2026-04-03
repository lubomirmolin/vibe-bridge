use super::mapping::{
    extract_generated_thread_title, map_thread_snapshot, map_thread_summary, parse_model_options,
    payload_contains_hidden_message, payload_primary_text,
};
use super::*;

impl CodexGateway {
    pub async fn bootstrap(&self) -> Result<GatewayBootstrap, String> {
        let config = self.config.clone();
        tokio::task::spawn_blocking(move || {
            let mut transport = connect_read_transport(&config)?;
            let summaries = fetch_thread_summaries(&mut transport, &config)?;
            let models = fetch_model_catalog(&mut transport);
            Ok(GatewayBootstrap {
                summaries,
                models,
                message: None,
            })
        })
        .await
        .map_err(|error| format!("codex bootstrap task failed: {error}"))?
    }

    pub async fn fetch_thread_snapshot(
        &self,
        thread_id: &str,
    ) -> Result<ThreadSnapshotDto, String> {
        let config = self.config.clone();
        let thread_id = thread_id.to_string();
        let reserved_transports = Arc::clone(&self.reserved_transports);
        tokio::task::spawn_blocking(move || {
            if !is_provider_thread_id(&thread_id, ProviderKind::Codex) {
                return fetch_thread_snapshot_from_archive(&config, &thread_id);
            }
            let mut transport = take_reserved_transport(&reserved_transports, &thread_id)
                .unwrap_or(connect_read_transport(&config)?);
            let snapshot = match read_thread_with_resume(&mut transport, &thread_id, true) {
                Ok(payload) => map_thread_snapshot(payload.thread),
                Err(error) if error.contains("not found") => {
                    return fetch_thread_snapshot_from_archive(&config, &thread_id);
                }
                Err(error) => return Err(error),
            };
            reserve_transport(&reserved_transports, thread_id, transport);
            Ok(snapshot)
        })
        .await
        .map_err(|error| format!("codex thread snapshot task failed: {error}"))?
    }

    pub async fn create_thread(
        &self,
        provider: ProviderKind,
        workspace: &str,
        model: Option<&str>,
    ) -> Result<ThreadSnapshotDto, String> {
        if provider == ProviderKind::ClaudeCode {
            return self.create_claude_thread(workspace).await;
        }
        let config = self.config.clone();
        let workspace = workspace.to_string();
        let model = model.map(str::to_string);
        let reserved_transports = Arc::clone(&self.reserved_transports);
        tokio::task::spawn_blocking(move || -> Result<ThreadSnapshotDto, String> {
            let mut transport = connect_transport(&config)?;
            let mut params = serde_json::Map::new();
            params.insert("cwd".to_string(), Value::String(workspace));
            if let Some(model) = model {
                params.insert("model".to_string(), Value::String(model));
            }

            let response = transport.request("thread/start", Value::Object(params))?;
            let payload: CodexThreadStartResult = serde_json::from_value(response)
                .map_err(|error| format!("invalid thread/start response from codex: {error}"))?;
            let reserved_thread_id = provider_thread_id(ProviderKind::Codex, &payload.thread.id);
            let thread = match read_thread_with_resume(&mut transport, &payload.thread.id, true) {
                Ok(thread) => thread,
                Err(error) if should_read_without_turns(&error) => {
                    read_thread_with_resume(&mut transport, &payload.thread.id, false)?
                }
                Err(error) if should_resume_thread(&error) => {
                    let snapshot = map_thread_snapshot(payload.thread);
                    reserve_transport(&reserved_transports, reserved_thread_id, transport);
                    return Ok(snapshot);
                }
                Err(error) => return Err(error),
            };
            let snapshot = map_thread_snapshot(thread.thread);
            reserve_transport(&reserved_transports, reserved_thread_id, transport);
            Ok(snapshot)
        })
        .await
        .map_err(|error| format!("codex create_thread task failed: {error}"))?
    }

    pub fn start_turn_streaming<F, G, H, I>(
        &self,
        thread_id: &str,
        request: TurnStartRequest,
        on_event: F,
        on_control_request: H,
        on_turn_completed: G,
        on_stream_finished: I,
    ) -> Result<GatewayTurnMutation, String>
    where
        F: Fn(BridgeEventEnvelope<Value>) + Send + 'static,
        H: Fn(GatewayTurnControlRequest) -> Result<Option<Value>, String> + Send + Sync + 'static,
        G: Fn(String) + Send + 'static,
        I: Fn(String) + Send + Sync + 'static,
    {
        if is_provider_thread_id(thread_id, ProviderKind::ClaudeCode) {
            return self.start_claude_turn_streaming(
                thread_id,
                request,
                on_event,
                on_control_request,
                on_turn_completed,
                on_stream_finished,
            );
        }

        let config = self.config.clone();
        let thread_id = thread_id.to_string();
        let TurnStartRequest {
            prompt,
            images,
            model,
            effort,
            permission_mode: _,
        } = request;
        let reserved_transports = Arc::clone(&self.reserved_transports);
        let on_control_request = Arc::new(on_control_request);
        let on_stream_finished = Arc::new(on_stream_finished);
        let (result_tx, result_rx) = mpsc::sync_channel(1);

        std::thread::spawn(move || {
            let reserved_transport = take_reserved_transport(&reserved_transports, &thread_id);
            let had_reserved_transport = reserved_transport.is_some();
            let mut transport = match reserved_transport {
                Some(transport) => transport,
                None => match connect_transport(&config) {
                    Ok(transport) => transport,
                    Err(error) => {
                        let _ = result_tx.send(Err(error));
                        return;
                    }
                },
            };

            let payload = if had_reserved_transport {
                match start_turn(
                    &mut transport,
                    &thread_id,
                    &prompt,
                    &images,
                    model.as_deref(),
                    effort.as_deref(),
                ) {
                    Ok(payload) => payload,
                    Err(error) if should_resume_thread(&error) => {
                        match start_turn_with_resume(
                            &mut transport,
                            &thread_id,
                            &prompt,
                            &images,
                            model.as_deref(),
                            effort.as_deref(),
                        ) {
                            Ok(payload) => payload,
                            Err(error) => {
                                reserve_transport(
                                    &reserved_transports,
                                    thread_id.clone(),
                                    transport,
                                );
                                let _ = result_tx.send(Err(error));
                                return;
                            }
                        }
                    }
                    Err(error) => {
                        reserve_transport(&reserved_transports, thread_id.clone(), transport);
                        let _ = result_tx.send(Err(error));
                        return;
                    }
                }
            } else {
                match start_turn_with_resume(
                    &mut transport,
                    &thread_id,
                    &prompt,
                    &images,
                    model.as_deref(),
                    effort.as_deref(),
                ) {
                    Ok(payload) => payload,
                    Err(error) => {
                        let _ = result_tx.send(Err(error));
                        return;
                    }
                }
            };

            let result = GatewayTurnMutation {
                response: TurnMutationAcceptedDto {
                    contract_version: CONTRACT_VERSION.to_string(),
                    thread_id: thread_id.clone(),
                    thread_status: ThreadStatus::Running,
                    message: format!("turn {} started", payload.turn.id),
                    turn_id: Some(payload.turn.id.clone()),
                },
                turn_id: Some(payload.turn.id),
            };
            if result_tx.send(Ok(result.clone())).is_err() {
                on_stream_finished(thread_id.clone());
                return;
            }

            let mut normalizer = CodexNotificationNormalizer::default();
            loop {
                let message = match transport.next_message("turn stream") {
                    Ok(Some(message)) => message,
                    Ok(None) => break,
                    Err(_) => break,
                };
                if let Some(request_id) = message.get("id").cloned() {
                    let Some(method) = message.get("method").and_then(Value::as_str) else {
                        continue;
                    };
                    let params = message.get("params").cloned().unwrap_or(Value::Null);
                    match on_control_request(GatewayTurnControlRequest::CodexApproval {
                        request_id: request_id.clone(),
                        method: method.to_string(),
                        params,
                    }) {
                        Ok(Some(response_payload)) => {
                            if let Err(error) = transport.respond(&request_id, response_payload) {
                                eprintln!(
                                    "failed to send codex control response for {thread_id}: {error}"
                                );
                                break;
                            }
                        }
                        Ok(None) => {}
                        Err(error) => {
                            let _ = transport.respond_error(&request_id, -32000, &error);
                        }
                    }
                    continue;
                }

                let Some(method) = message.get("method").and_then(Value::as_str) else {
                    continue;
                };
                let params = message.get("params").cloned().unwrap_or(Value::Null);

                if let Some(event) = normalizer.normalize(method, &params)
                    && event.thread_id == thread_id
                {
                    on_event(event);
                }

                if method == "turn/completed" {
                    on_turn_completed(thread_id.clone());
                    break;
                }
            }
            on_stream_finished(thread_id.clone());
        });

        result_rx
            .recv()
            .map_err(|error| format!("failed to receive codex turn-start result: {error}"))?
    }

    pub async fn interrupt_turn(
        &self,
        thread_id: &str,
        turn_id: &str,
    ) -> Result<GatewayTurnMutation, String> {
        if is_provider_thread_id(thread_id, ProviderKind::ClaudeCode) {
            let thread_id = thread_id.to_string();
            let active_process = self
                .active_claude_processes
                .lock()
                .expect("active claude process lock should not be poisoned")
                .get(&thread_id)
                .cloned()
                .ok_or_else(|| format!("no active Claude turn found for thread {thread_id}"))?;
            self.interrupted_claude_threads
                .lock()
                .expect("interrupted claude thread lock should not be poisoned")
                .insert(thread_id.clone());
            active_process
                .lock()
                .expect("claude child lock should not be poisoned")
                .kill()
                .map_err(|error| format!("failed to interrupt Claude turn: {error}"))?;
            return Ok(GatewayTurnMutation {
                response: TurnMutationAcceptedDto {
                    contract_version: CONTRACT_VERSION.to_string(),
                    thread_id,
                    thread_status: ThreadStatus::Interrupted,
                    message: "interrupt requested".to_string(),
                    turn_id: None,
                },
                turn_id: None,
            });
        }
        let config = self.config.clone();
        let thread_id = thread_id.to_string();
        let turn_id = turn_id.to_string();
        tokio::task::spawn_blocking(move || -> Result<GatewayTurnMutation, String> {
            let native_thread_id =
                native_thread_id_for_provider(&thread_id, ProviderKind::Codex)
                    .ok_or_else(|| format!("thread {thread_id} is not a codex thread"))?;
            let mut transport = connect_transport(&config)?;
            transport.request(
                "turn/interrupt",
                serde_json::json!({
                    "threadId": native_thread_id,
                    "turnId": turn_id,
                }),
            )?;
            Ok(GatewayTurnMutation {
                response: TurnMutationAcceptedDto {
                    contract_version: CONTRACT_VERSION.to_string(),
                    thread_id,
                    thread_status: ThreadStatus::Interrupted,
                    message: "interrupt requested".to_string(),
                    turn_id: None,
                },
                turn_id: None,
            })
        })
        .await
        .map_err(|error| format!("codex interrupt_turn task failed: {error}"))?
    }

    pub async fn resolve_active_turn_id(&self, thread_id: &str) -> Result<String, String> {
        if is_provider_thread_id(thread_id, ProviderKind::ClaudeCode) {
            let thread_id = thread_id.to_string();
            return self
                .active_claude_processes
                .lock()
                .expect("active claude process lock should not be poisoned")
                .contains_key(&thread_id)
                .then_some(thread_id.clone())
                .ok_or_else(|| format!("no active Claude turn found for thread {thread_id}"));
        }
        let config = self.config.clone();
        let thread_id = thread_id.to_string();
        let reserved_transports = Arc::clone(&self.reserved_transports);
        tokio::task::spawn_blocking(move || -> Result<String, String> {
            let mut transport = take_reserved_transport(&reserved_transports, &thread_id)
                .unwrap_or(connect_read_transport(&config)?);
            let payload = read_thread_with_resume(&mut transport, &thread_id, true)?;
            let active_turn_id = payload
                .thread
                .turns
                .last()
                .map(|turn| turn.id.clone())
                .ok_or_else(|| format!("no active turn found for thread {thread_id}"))?;
            reserve_transport(&reserved_transports, thread_id, transport);
            Ok(active_turn_id)
        })
        .await
        .map_err(|error| format!("codex resolve_active_turn_id task failed: {error}"))?
    }

    pub async fn set_thread_name(&self, thread_id: &str, name: &str) -> Result<(), String> {
        if !is_provider_thread_id(thread_id, ProviderKind::Codex) {
            return Err(format!(
                "thread {thread_id} belongs to a read-only provider; renaming is only implemented for codex threads"
            ));
        }
        let config = self.config.clone();
        let thread_id = thread_id.to_string();
        let name = name.trim().to_string();
        tokio::task::spawn_blocking(move || -> Result<(), String> {
            if name.is_empty() {
                return Ok(());
            }

            let native_thread_id =
                native_thread_id_for_provider(&thread_id, ProviderKind::Codex)
                    .ok_or_else(|| format!("thread {thread_id} is not a codex thread"))?;
            let mut transport = connect_transport(&config)?;
            transport.request(
                "thread/name/set",
                json!({
                    "threadId": native_thread_id,
                    "name": name,
                }),
            )?;
            Ok(())
        })
        .await
        .map_err(|error| format!("codex set_thread_name task failed: {error}"))?
    }

    pub async fn generate_thread_title_candidate(
        &self,
        workspace: &str,
        prompt: &str,
        model: Option<&str>,
    ) -> Result<Option<String>, String> {
        let config = self.config.clone();
        let workspace = workspace.to_string();
        let prompt = prompt.to_string();
        let model = model.map(str::to_string);
        tokio::task::spawn_blocking(move || -> Result<Option<String>, String> {
            let normalized_prompt = prompt.trim();
            if normalized_prompt.is_empty() {
                return Ok(None);
            }

            let mut transport = connect_transport(&config)?;
            let title_thread_id =
                start_ephemeral_read_only_thread(&mut transport, &workspace, model.as_deref())?;
            let turn = start_structured_turn(
                &mut transport,
                &title_thread_id,
                &build_thread_title_prompt(normalized_prompt),
                build_thread_title_output_schema(),
                model.as_deref(),
                Some("low"),
            )?;
            let agent_message = read_structured_agent_message(
                &mut transport,
                &title_thread_id,
                &turn.turn.id,
                "thread title generation",
            )?;
            Ok(extract_generated_thread_title(agent_message.as_deref()))
        })
        .await
        .map_err(|error| format!("codex generate_thread_title task failed: {error}"))?
    }
}

fn should_resume_thread(error: &str) -> bool {
    error.contains("thread not found")
}

fn should_read_without_turns(error: &str) -> bool {
    error.contains("includeTurns is unavailable before first user message")
        || error.contains("is not materialized yet")
}

fn read_thread_with_resume(
    transport: &mut CodexJsonTransport,
    thread_id: &str,
    include_turns: bool,
) -> Result<CodexThreadReadResult, String> {
    match read_thread(transport, thread_id, include_turns) {
        Ok(response) => Ok(response),
        Err(error) if should_resume_thread(&error) => {
            resume_thread(transport, thread_id)?;
            read_thread(transport, thread_id, include_turns)
        }
        Err(error) => Err(error),
    }
}

fn read_thread(
    transport: &mut CodexJsonTransport,
    thread_id: &str,
    include_turns: bool,
) -> Result<CodexThreadReadResult, String> {
    let native_thread_id = native_thread_id_for_provider(thread_id, ProviderKind::Codex)
        .ok_or_else(|| format!("thread {thread_id} is not a codex thread"))?;
    let response = transport.request(
        "thread/read",
        serde_json::json!({
            "threadId": native_thread_id,
            "includeTurns": include_turns,
        }),
    )?;
    serde_json::from_value(response)
        .map_err(|error| format!("invalid thread/read response from codex: {error}"))
}

fn resume_thread(
    transport: &mut CodexJsonTransport,
    thread_id: &str,
) -> Result<CodexThread, String> {
    let native_thread_id = native_thread_id_for_provider(thread_id, ProviderKind::Codex)
        .ok_or_else(|| format!("thread {thread_id} is not a codex thread"))?;
    let response = transport.request(
        "thread/resume",
        serde_json::json!({
            "threadId": native_thread_id,
        }),
    )?;
    let payload: CodexThreadResumeResult = serde_json::from_value(response)
        .map_err(|error| format!("invalid thread/resume response from codex: {error}"))?;
    Ok(payload.thread)
}

fn start_turn_with_resume(
    transport: &mut CodexJsonTransport,
    thread_id: &str,
    prompt: &str,
    images: &[String],
    model: Option<&str>,
    effort: Option<&str>,
) -> Result<CodexTurnStartResult, String> {
    match start_turn(transport, thread_id, prompt, images, model, effort) {
        Ok(response) => Ok(response),
        Err(error) if should_resume_thread(&error) => {
            if let Err(resume_error) = resume_thread(transport, thread_id)
                && !resume_error.contains("no rollout found")
            {
                return Err(resume_error);
            }
            start_turn(transport, thread_id, prompt, images, model, effort)
        }
        Err(error) => Err(error),
    }
}

fn start_ephemeral_read_only_thread(
    transport: &mut CodexJsonTransport,
    workspace: &str,
    model: Option<&str>,
) -> Result<String, String> {
    let mut params = serde_json::Map::new();
    params.insert("cwd".to_string(), Value::String(workspace.to_string()));
    params.insert(
        "approvalPolicy".to_string(),
        Value::String("never".to_string()),
    );
    params.insert(
        "sandbox".to_string(),
        Value::String("read-only".to_string()),
    );
    params.insert("ephemeral".to_string(), Value::Bool(true));
    params.insert("persistExtendedHistory".to_string(), Value::Bool(false));
    params.insert("experimentalRawEvents".to_string(), Value::Bool(false));
    params.insert(
        "config".to_string(),
        json!({
            "web_search": "disabled",
            "model_reasoning_effort": "low",
        }),
    );
    if let Some(model) = model {
        params.insert("model".to_string(), Value::String(model.to_string()));
    }

    let response = transport.request("thread/start", Value::Object(params))?;
    let payload: CodexThreadStartResult = serde_json::from_value(response)
        .map_err(|error| format!("invalid thread/start response from codex: {error}"))?;
    Ok(payload.thread.id)
}

fn start_turn(
    transport: &mut CodexJsonTransport,
    thread_id: &str,
    prompt: &str,
    images: &[String],
    model: Option<&str>,
    effort: Option<&str>,
) -> Result<CodexTurnStartResult, String> {
    let native_thread_id = native_thread_id_for_provider(thread_id, ProviderKind::Codex)
        .ok_or_else(|| format!("thread {thread_id} is not a codex thread"))?;
    let mut params = serde_json::Map::new();
    params.insert(
        "threadId".to_string(),
        Value::String(native_thread_id.to_string()),
    );
    params.insert("input".to_string(), build_turn_start_input(prompt, images));
    if let Some(model) = model {
        params.insert("model".to_string(), Value::String(model.to_string()));
    }
    if let Some(effort) = effort {
        params.insert("effort".to_string(), Value::String(effort.to_string()));
    }

    let response = transport.request("turn/start", Value::Object(params))?;
    serde_json::from_value(response)
        .map_err(|error| format!("invalid turn/start response from codex: {error}"))
}

fn start_structured_turn(
    transport: &mut CodexJsonTransport,
    thread_id: &str,
    prompt: &str,
    output_schema: Value,
    model: Option<&str>,
    effort: Option<&str>,
) -> Result<CodexTurnStartResult, String> {
    let mut params = serde_json::Map::new();
    params.insert("threadId".to_string(), Value::String(thread_id.to_string()));
    params.insert("input".to_string(), build_turn_start_input(prompt, &[]));
    params.insert("summary".to_string(), Value::String("auto".to_string()));
    params.insert("outputSchema".to_string(), output_schema);
    if let Some(model) = model {
        params.insert("model".to_string(), Value::String(model.to_string()));
    }
    if let Some(effort) = effort {
        params.insert("effort".to_string(), Value::String(effort.to_string()));
    }

    let response = transport.request("turn/start", Value::Object(params))?;
    serde_json::from_value(response)
        .map_err(|error| format!("invalid turn/start response from codex: {error}"))
}

pub(super) fn build_turn_start_input(prompt: &str, images: &[String]) -> Value {
    let mut input = Vec::new();
    if !prompt.trim().is_empty() {
        input.push(serde_json::json!({
            "type": "text",
            "text": prompt,
            "text_elements": [],
        }));
    }
    for image in images
        .iter()
        .map(|image| image.trim())
        .filter(|image| !image.is_empty())
    {
        input.push(serde_json::json!({
            "type": "image",
            "url": image,
        }));
    }

    Value::Array(input)
}

fn read_structured_agent_message(
    transport: &mut CodexJsonTransport,
    thread_id: &str,
    turn_id: &str,
    context: &str,
) -> Result<Option<String>, String> {
    let mut latest_agent_message: Option<String> = None;

    while let Some(message) = transport.next_message(context)? {
        if message.get("id").is_some() {
            continue;
        }

        let Some(method) = message.get("method").and_then(Value::as_str) else {
            continue;
        };
        let params = message.get("params").cloned().unwrap_or(Value::Null);

        match method {
            "item/agentMessage/delta" => {
                if params.get("threadId").and_then(Value::as_str) != Some(thread_id) {
                    continue;
                }
                let notification_turn_id = params.get("turnId").and_then(Value::as_str);
                if notification_turn_id.is_some() && notification_turn_id != Some(turn_id) {
                    continue;
                }
                let delta = params
                    .get("delta")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                if delta.is_empty() {
                    continue;
                }
                let next_value = latest_agent_message
                    .take()
                    .unwrap_or_default()
                    .chars()
                    .chain(delta.chars())
                    .collect::<String>();
                latest_agent_message = Some(next_value);
            }
            "item/completed" => {
                if params.get("threadId").and_then(Value::as_str) != Some(thread_id) {
                    continue;
                }
                let notification_turn_id = params.get("turnId").and_then(Value::as_str);
                if notification_turn_id.is_some() && notification_turn_id != Some(turn_id) {
                    continue;
                }
                let Some(item) = params.get("item") else {
                    continue;
                };
                if item.get("type").and_then(Value::as_str) != Some("agentMessage") {
                    continue;
                }
                latest_agent_message = item
                    .get("text")
                    .and_then(Value::as_str)
                    .map(ToString::to_string);
            }
            "turn/completed" => {
                if params
                    .get("threadId")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    != thread_id
                {
                    continue;
                }
                if params
                    .get("turn")
                    .and_then(|turn| turn.get("id"))
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    != turn_id
                {
                    continue;
                }
                let status = params
                    .get("turn")
                    .and_then(|turn| turn.get("status"))
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                if status != "completed" {
                    return Ok(None);
                }
                return Ok(latest_agent_message);
            }
            _ => {}
        }
    }

    Ok(latest_agent_message)
}

fn build_thread_title_prompt(prompt: &str) -> String {
    [
        "Generate a concise thread title for the user's request.",
        "Write the result into the structured response field title.",
        "Rules:",
        "- Keep the title under 80 characters.",
        "- Use plain text only in the title field.",
        "- Prefer an imperative title when the request is actionable.",
        "- Preserve important product or framework names like Flutter, Rust, macOS, Android, iOS, Codex, and Tailscale.",
        "- Do not include quotes, markdown, trailing punctuation, or filler words like 'Please' or 'Help me'.",
        "",
        "User request:",
        prompt,
    ]
    .join("\n")
}

fn build_thread_title_output_schema() -> Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "properties": {
            "title": {
                "type": "string",
                "minLength": 4,
                "maxLength": CodexGateway::THREAD_TITLE_MAX_CHARS,
            }
        },
        "required": ["title"],
    })
}

pub(super) fn normalize_generated_thread_title(raw_title: &str) -> Option<String> {
    let normalized_whitespace = raw_title.split_whitespace().collect::<Vec<_>>().join(" ");
    let trimmed = normalized_whitespace
        .trim_matches(|ch: char| ch == '"' || ch == '\'' || ch == '`')
        .trim();
    if trimmed.is_empty() || mapping::is_placeholder_thread_title(trimmed) {
        return None;
    }

    let mut title = trimmed.to_string();
    if title.chars().count() > CodexGateway::THREAD_TITLE_MAX_CHARS {
        title = title
            .chars()
            .take(CodexGateway::THREAD_TITLE_MAX_CHARS)
            .collect::<String>()
            .trim()
            .to_string();
    }

    while title.ends_with('.') || title.ends_with(':') || title.ends_with(';') {
        title.pop();
    }

    let normalized = title.trim();
    if normalized.is_empty() || mapping::is_placeholder_thread_title(normalized) {
        return None;
    }
    Some(normalized.to_string())
}

fn connect_transport(config: &BridgeCodexConfig) -> Result<CodexJsonTransport, String> {
    match config.mode {
        CodexRuntimeMode::Attach => {
            CodexJsonTransport::start(&config.command, &config.args, config.endpoint.as_deref())
        }
        CodexRuntimeMode::Spawn => CodexJsonTransport::start(&config.command, &config.args, None),
        CodexRuntimeMode::Auto => {
            if let Some(endpoint) = config.endpoint.as_deref()
                && let Ok(transport) =
                    CodexJsonTransport::start(&config.command, &config.args, Some(endpoint))
            {
                return Ok(transport);
            }
            CodexJsonTransport::start(&config.command, &config.args, None)
        }
    }
}

fn connect_read_transport(config: &BridgeCodexConfig) -> Result<CodexJsonTransport, String> {
    match config.mode {
        CodexRuntimeMode::Spawn => connect_transport(config),
        CodexRuntimeMode::Attach | CodexRuntimeMode::Auto => {
            CodexJsonTransport::start(&config.command, &config.args, None)
                .or_else(|_| connect_transport(config))
        }
    }
}

fn take_reserved_transport(
    reserved_transports: &Arc<Mutex<HashMap<String, ReservedTransport>>>,
    thread_id: &str,
) -> Option<CodexJsonTransport> {
    let mut reserved = reserved_transports
        .lock()
        .expect("reserved transport lock should not be poisoned");
    prune_reserved_transports(&mut reserved);
    reserved.remove(thread_id).map(|entry| entry.transport)
}

fn reserve_transport(
    reserved_transports: &Arc<Mutex<HashMap<String, ReservedTransport>>>,
    thread_id: String,
    transport: CodexJsonTransport,
) {
    let mut reserved = reserved_transports
        .lock()
        .expect("reserved transport lock should not be poisoned");
    prune_reserved_transports(&mut reserved);
    reserved.insert(
        thread_id,
        ReservedTransport {
            reserved_at: Instant::now(),
            transport,
        },
    );
}

fn prune_reserved_transports(reserved: &mut HashMap<String, ReservedTransport>) {
    reserved.retain(|_, entry| entry.reserved_at.elapsed() <= CodexGateway::RESERVED_TRANSPORT_TTL);
}

fn fetch_thread_summaries(
    transport: &mut CodexJsonTransport,
    config: &BridgeCodexConfig,
) -> Result<Vec<ThreadSummaryDto>, String> {
    match fetch_live_thread_summaries(transport) {
        Ok(summaries) if !summaries.is_empty() => {
            let archive_summaries = fetch_thread_summaries_from_archive(config)?;
            Ok(merge_thread_summaries(summaries, archive_summaries))
        }
        Ok(_) => fetch_thread_summaries_from_archive(config),
        Err(live_error) => {
            let fallback = fetch_thread_summaries_from_archive(config)?;
            if fallback.is_empty() {
                Err(live_error)
            } else {
                Ok(fallback)
            }
        }
    }
}

fn fetch_live_thread_summaries(
    transport: &mut CodexJsonTransport,
) -> Result<Vec<ThreadSummaryDto>, String> {
    let mut summaries = Vec::new();
    let mut cursor: Option<String> = None;

    loop {
        if summaries.len() >= CodexGateway::MAX_THREADS_TO_FETCH {
            break;
        }

        let mut params = serde_json::Map::new();
        if let Some(cursor) = &cursor {
            params.insert("cursor".to_string(), Value::String(cursor.clone()));
        }

        let response = transport.request("thread/list", Value::Object(params))?;
        let payload: CodexThreadListResult = serde_json::from_value(response)
            .map_err(|error| format!("invalid thread/list response from codex: {error}"))?;

        let remaining = CodexGateway::MAX_THREADS_TO_FETCH.saturating_sub(summaries.len());
        summaries.extend(
            payload
                .data
                .into_iter()
                .take(remaining)
                .map(map_thread_summary),
        );

        if let Some(next_cursor) = payload.next_cursor {
            cursor = Some(next_cursor);
        } else {
            break;
        }
    }

    Ok(summaries)
}

pub(super) fn fetch_thread_summaries_from_archive(
    config: &BridgeCodexConfig,
) -> Result<Vec<ThreadSummaryDto>, String> {
    let endpoint = match config.mode {
        CodexRuntimeMode::Spawn => None,
        _ => config.endpoint.as_deref(),
    };
    Ok(
        ThreadApiService::from_codex_app_server(&config.command, &config.args, endpoint)?
            .list_response()
            .threads,
    )
}

fn merge_thread_summaries(
    live_summaries: Vec<ThreadSummaryDto>,
    archive_summaries: Vec<ThreadSummaryDto>,
) -> Vec<ThreadSummaryDto> {
    let mut merged = live_summaries;
    let live_thread_ids = merged
        .iter()
        .map(|summary| summary.thread_id.clone())
        .collect::<std::collections::HashSet<_>>();
    merged.extend(
        archive_summaries
            .into_iter()
            .filter(|summary| !live_thread_ids.contains(&summary.thread_id)),
    );
    merged
}

pub(super) fn fetch_thread_snapshot_from_archive(
    config: &BridgeCodexConfig,
    thread_id: &str,
) -> Result<ThreadSnapshotDto, String> {
    let endpoint = match config.mode {
        CodexRuntimeMode::Spawn => None,
        _ => config.endpoint.as_deref(),
    };
    let service = ThreadApiService::from_codex_app_server_thread(
        &config.command,
        &config.args,
        endpoint,
        thread_id,
    )?;
    let detail = service
        .detail_response(thread_id)
        .ok_or_else(|| format!("thread {thread_id} not found"))?;
    let timeline = service
        .timeline_page_response(thread_id, None, 500)
        .ok_or_else(|| format!("thread {thread_id} not found"))?;
    let (entries, pending_user_input) = filter_hidden_timeline_entries_and_extract_pending_input(
        thread_id,
        timeline.entries,
        timeline.pending_user_input,
    );
    let git_status = service
        .git_status_response(thread_id)
        .map(|response| GitStatusDto {
            workspace: response.repository.workspace,
            repository: response.repository.repository,
            branch: response.repository.branch,
            remote: (!response.repository.remote.trim().is_empty())
                .then_some(response.repository.remote),
            dirty: response.status.dirty,
            ahead_by: response.status.ahead_by,
            behind_by: response.status.behind_by,
        });

    Ok(ThreadSnapshotDto {
        contract_version: CONTRACT_VERSION.to_string(),
        thread: detail.thread,
        entries,
        approvals: Vec::new(),
        git_status,
        pending_user_input,
    })
}

fn filter_hidden_timeline_entries_and_extract_pending_input(
    thread_id: &str,
    entries: Vec<ThreadTimelineEntryDto>,
    pending_user_input: Option<PendingUserInputDto>,
) -> (Vec<ThreadTimelineEntryDto>, Option<PendingUserInputDto>) {
    let mut next_pending_user_input = pending_user_input;
    let visible_entries = entries
        .into_iter()
        .filter(|entry| {
            if entry.kind != BridgeEventKind::MessageDelta
                || !payload_contains_hidden_message(&entry.payload)
            {
                return true;
            }

            if next_pending_user_input.is_none()
                && let Some(message_text) = payload_primary_text(&entry.payload)
            {
                next_pending_user_input = parse_pending_user_input_payload(message_text, thread_id);
            }
            false
        })
        .collect();

    (visible_entries, next_pending_user_input)
}

fn fetch_model_catalog(transport: &mut CodexJsonTransport) -> Vec<ModelOptionDto> {
    match transport.request(
        "model/list",
        serde_json::json!({
            "cursor": Value::Null,
            "limit": 50,
            "includeHidden": false,
        }),
    ) {
        Ok(response) => {
            let models = parse_model_options(response);
            if models.is_empty() {
                fallback_model_options()
            } else {
                models
            }
        }
        Err(_) => fallback_model_options(),
    }
}

pub(super) fn fallback_model_options() -> Vec<ModelOptionDto> {
    vec![
        ModelOptionDto {
            id: "gpt-5".to_string(),
            model: "gpt-5".to_string(),
            display_name: "GPT-5".to_string(),
            description: String::new(),
            is_default: true,
            default_reasoning_effort: Some("medium".to_string()),
            supported_reasoning_efforts: fallback_reasoning_efforts(),
        },
        ModelOptionDto {
            id: "gpt-5-mini".to_string(),
            model: "gpt-5-mini".to_string(),
            display_name: "GPT-5 Mini".to_string(),
            description: String::new(),
            is_default: false,
            default_reasoning_effort: Some("medium".to_string()),
            supported_reasoning_efforts: fallback_reasoning_efforts(),
        },
        ModelOptionDto {
            id: "o4-mini".to_string(),
            model: "o4-mini".to_string(),
            display_name: "o4-mini".to_string(),
            description: String::new(),
            is_default: false,
            default_reasoning_effort: Some("high".to_string()),
            supported_reasoning_efforts: fallback_reasoning_efforts(),
        },
    ]
}

fn fallback_reasoning_efforts() -> Vec<ReasoningEffortOptionDto> {
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
    ]
}
