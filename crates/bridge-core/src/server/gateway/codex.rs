pub(super) mod actor;
mod archive;
mod models;
pub(super) mod notifications;
mod rpc;
mod titles;
mod transport;

use std::fmt::Write as _;

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
    should_resume_thread, start_ephemeral_read_only_thread, start_structured_turn,
};
pub(crate) use titles::normalize_generated_thread_title;
use titles::{build_thread_title_output_schema, build_thread_title_prompt};
use transport::{connect_read_transport, connect_transport};

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
        let actors = Arc::clone(&self.codex_thread_actors);
        tokio::task::spawn_blocking(move || {
            if !is_provider_thread_id(&thread_id, ProviderKind::Codex) {
                return fetch_thread_snapshot_from_archive(&config, &thread_id);
            }
            actors.actor(&thread_id, &config).fetch_snapshot()
        })
        .await
        .map_err(|error| format!("codex thread snapshot task failed: {error}"))?
    }

    pub async fn thread_lifecycle_state(
        &self,
        thread_id: &str,
    ) -> Result<GatewayThreadLifecycleState, String> {
        if is_provider_thread_id(thread_id, ProviderKind::ClaudeCode) {
            let thread_id = thread_id.to_string();
            let is_active = self
                .active_claude_processes
                .lock()
                .expect("active claude process lock should not be poisoned")
                .contains_key(&thread_id);
            return Ok(GatewayThreadLifecycleState {
                active_turn_id: is_active.then_some(thread_id),
                stream_active: is_active,
            });
        }
        if !is_provider_thread_id(thread_id, ProviderKind::Codex) {
            return Ok(GatewayThreadLifecycleState::default());
        }
        let config = self.config.clone();
        let thread_id = thread_id.to_string();
        let actor = self.codex_thread_actors.actor(&thread_id, &config);
        tokio::task::spawn_blocking(move || actor.lifecycle_state())
            .await
            .map_err(|error| format!("codex thread lifecycle task failed: {error}"))?
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
        let actors = Arc::clone(&self.codex_thread_actors);
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
                    let _ = actors.prime_actor(&reserved_thread_id, &config, transport)?;
                    return Ok(snapshot);
                }
                Err(error) => return Err(error),
            };
            let snapshot = map_thread_snapshot(thread.thread);
            let _ = actors.prime_actor(&reserved_thread_id, &config, transport)?;
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
        I: Fn(String, GatewayTurnStreamActivity) + Send + Sync + 'static,
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
        let actor = self.codex_thread_actors.actor(&thread_id, &config);
        let on_control_request = Arc::new(on_control_request);
        let on_stream_finished = Arc::new(on_stream_finished);
        actor.start_turn_streaming(
            request,
            Box::new(on_event),
            on_control_request,
            Box::new(on_turn_completed),
            on_stream_finished,
        )
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
                    client_message_id: None,
                    client_turn_intent_id: None,
                },
                turn_id: None,
            });
        }
        let config = self.config.clone();
        let thread_id = thread_id.to_string();
        let turn_id = turn_id.to_string();
        let actor = self.codex_thread_actors.actor(&thread_id, &config);
        tokio::task::spawn_blocking(move || actor.interrupt_turn(turn_id))
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
        let actor = self.codex_thread_actors.actor(&thread_id, &config);
        tokio::task::spawn_blocking(move || actor.resolve_active_turn_id())
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
        let actor = self.codex_thread_actors.actor(&thread_id, &config);
        tokio::task::spawn_blocking(move || actor.set_thread_name(name))
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

fn summarize_snapshot_for_debug(snapshot: &ThreadSnapshotDto) -> String {
    let mut buffer = String::new();
    let message_count = snapshot
        .entries
        .iter()
        .filter(|entry| entry.kind == BridgeEventKind::MessageDelta)
        .count();
    let status_count = snapshot
        .entries
        .iter()
        .filter(|entry| entry.kind == BridgeEventKind::ThreadStatusChanged)
        .count();
    let recent_entries = snapshot
        .entries
        .iter()
        .rev()
        .take(5)
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .map(|entry| {
            format!(
                "{}:{:?}:{}",
                entry.event_id,
                entry.kind,
                entry
                    .payload
                    .get("type")
                    .and_then(Value::as_str)
                    .or_else(|| entry.payload.get("status").and_then(Value::as_str))
                    .unwrap_or("-")
            )
        })
        .collect::<Vec<_>>()
        .join(",");
    let latest_message = snapshot
        .entries
        .iter()
        .rev()
        .find(|entry| entry.kind == BridgeEventKind::MessageDelta)
        .and_then(|entry| {
            entry
                .payload
                .get("text")
                .and_then(Value::as_str)
                .or_else(|| entry.payload.get("delta").and_then(Value::as_str))
                .map(|text| truncate_for_debug(text, 80))
        })
        .unwrap_or_else(|| "<none>".to_string());
    let _ = write!(
        buffer,
        "status={:?} updated_at={} entries={} messages={} statuses={} last_message={} recent=[{}]",
        snapshot.thread.status,
        snapshot.thread.updated_at,
        snapshot.entries.len(),
        message_count,
        status_count,
        latest_message,
        recent_entries
    );
    buffer
}

fn truncate_for_debug(value: &str, max_chars: usize) -> String {
    let trimmed = value.trim();
    if trimmed.chars().count() <= max_chars {
        return trimmed.to_string();
    }
    let mut truncated = trimmed.chars().take(max_chars).collect::<String>();
    truncated.push_str("...");
    truncated
}
