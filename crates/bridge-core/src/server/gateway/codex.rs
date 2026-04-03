mod archive;
mod models;
mod rpc;
mod titles;
mod transport;

use super::mapping::{extract_generated_thread_title, map_thread_snapshot};
use super::*;
pub(crate) use archive::fetch_thread_snapshot_from_archive;
#[cfg(test)]
pub(crate) use archive::fetch_thread_summaries_from_archive;
use archive::{fetch_model_catalog, fetch_thread_summaries};
pub(crate) use models::fallback_model_options;
#[cfg(test)]
pub(crate) use rpc::build_turn_start_input;
use rpc::{
    read_structured_agent_message, read_thread_with_resume, should_read_without_turns,
    should_resume_thread, start_ephemeral_read_only_thread, start_structured_turn, start_turn,
    start_turn_with_resume,
};
pub(crate) use titles::normalize_generated_thread_title;
use titles::{build_thread_title_output_schema, build_thread_title_prompt};
use transport::{
    connect_read_transport, connect_transport, reserve_transport, take_reserved_transport,
};

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
