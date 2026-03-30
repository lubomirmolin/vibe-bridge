use chrono::{SecondsFormat, TimeZone, Utc};
use serde::Deserialize;
use serde_json::{Value, json};
use shared_contracts::{
    AccessMode, ApprovalSummaryDto, BridgeEventEnvelope, BridgeEventKind, CONTRACT_VERSION,
    GitStatusDto, ModelOptionDto, ReasoningEffortOptionDto, ThreadDetailDto, ThreadSnapshotDto,
    ThreadStatus, ThreadSummaryDto, ThreadTimelineAnnotationsDto, ThreadTimelineEntryDto,
    ThreadTimelineExplorationKind, ThreadTimelineGroupKind, TurnMutationAcceptedDto,
};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, mpsc};
use std::time::{Duration, Instant};

use crate::codex_runtime::CodexRuntimeMode;
use crate::codex_transport::CodexJsonTransport;
use crate::server::config::BridgeCodexConfig;
use crate::thread_api::{
    CodexNotificationNormalizer, CodexNotificationStream, ThreadApiService,
    load_archive_timeline_entries_for_session_path, load_archive_timeline_entries_for_thread,
};

#[derive(Debug, Clone)]
pub struct CodexGateway {
    config: BridgeCodexConfig,
    reserved_transports: Arc<Mutex<HashMap<String, ReservedTransport>>>,
}

#[derive(Debug)]
struct ReservedTransport {
    reserved_at: Instant,
    transport: CodexJsonTransport,
}

#[derive(Debug, Clone)]
pub struct GatewayBootstrap {
    pub summaries: Vec<ThreadSummaryDto>,
    pub models: Vec<ModelOptionDto>,
    pub message: Option<String>,
}

#[derive(Debug, Clone)]
pub struct GatewayTurnMutation {
    pub response: TurnMutationAcceptedDto,
    pub turn_id: Option<String>,
}

#[derive(Debug, Deserialize)]
struct CodexThreadListResult {
    data: Vec<CodexThread>,
    #[serde(rename = "nextCursor")]
    next_cursor: Option<String>,
}

#[derive(Debug, Deserialize)]
struct CodexThreadReadResult {
    thread: CodexThread,
}

#[derive(Debug, Deserialize)]
struct CodexThreadResumeResult {
    thread: CodexThread,
}

#[derive(Debug, Deserialize)]
struct CodexThreadStartResult {
    thread: CodexThread,
}

#[derive(Debug, Deserialize)]
struct CodexTurnStartResult {
    turn: CodexTurnHandle,
}

#[derive(Debug, Deserialize)]
struct CodexTurnHandle {
    id: String,
}

#[derive(Debug, Deserialize)]
struct CodexThread {
    id: String,
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    preview: Option<String>,
    status: CodexThreadStatus,
    cwd: String,
    #[serde(default)]
    path: Option<String>,
    #[serde(rename = "gitInfo")]
    git_info: Option<CodexGitInfo>,
    #[serde(rename = "createdAt", default)]
    created_at: i64,
    #[serde(rename = "updatedAt")]
    updated_at: i64,
    #[serde(default)]
    source: Value,
    #[serde(default)]
    turns: Vec<CodexTurn>,
}

#[derive(Debug, Deserialize)]
struct CodexThreadStatus {
    #[serde(rename = "type")]
    kind: String,
}

#[derive(Debug, Deserialize)]
struct CodexGitInfo {
    branch: Option<String>,
    #[serde(rename = "originUrl")]
    origin_url: Option<String>,
}

#[derive(Debug, Deserialize)]
struct CodexTurn {
    id: String,
    #[serde(default)]
    items: Vec<Value>,
}

impl CodexGateway {
    const MAX_THREADS_TO_FETCH: usize = 100;
    const RESERVED_TRANSPORT_TTL: Duration = Duration::from_secs(120);
    const THREAD_TITLE_MAX_CHARS: usize = 80;

    pub fn new(config: BridgeCodexConfig) -> Self {
        Self {
            config,
            reserved_transports: Arc::new(Mutex::new(HashMap::new())),
        }
    }

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
            let mut transport = take_reserved_transport(&reserved_transports, &thread_id)
                .unwrap_or(connect_read_transport(&config)?);
            let payload = read_thread_with_resume(&mut transport, &thread_id, true)?;
            let snapshot = map_thread_snapshot(payload.thread);
            reserve_transport(&reserved_transports, thread_id, transport);
            Ok(snapshot)
        })
        .await
        .map_err(|error| format!("codex thread snapshot task failed: {error}"))?
    }

    pub async fn create_thread(
        &self,
        workspace: &str,
        model: Option<&str>,
    ) -> Result<ThreadSnapshotDto, String> {
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
            let thread_id = payload.thread.id.clone();
            let thread = match read_thread_with_resume(&mut transport, &payload.thread.id, true) {
                Ok(thread) => thread,
                Err(error) if should_read_without_turns(&error) => {
                    read_thread_with_resume(&mut transport, &payload.thread.id, false)?
                }
                Err(error) if should_resume_thread(&error) => {
                    let snapshot = map_thread_snapshot(payload.thread);
                    reserve_transport(&reserved_transports, thread_id, transport);
                    return Ok(snapshot);
                }
                Err(error) => return Err(error),
            };
            let snapshot = map_thread_snapshot(thread.thread);
            reserve_transport(&reserved_transports, thread_id, transport);
            Ok(snapshot)
        })
        .await
        .map_err(|error| format!("codex create_thread task failed: {error}"))?
    }

    pub fn notification_stream(&self) -> Result<CodexNotificationStream, String> {
        let endpoint = match self.config.mode {
            CodexRuntimeMode::Spawn => None,
            _ => self.config.endpoint.as_deref(),
        };
        CodexNotificationStream::start(&self.config.command, &self.config.args, endpoint)
    }

    pub fn desktop_ipc_socket_path(&self) -> Option<PathBuf> {
        self.config.desktop_ipc_socket_path.clone()
    }

    pub fn start_turn_streaming<F, G>(
        &self,
        thread_id: &str,
        prompt: &str,
        images: &[String],
        model: Option<&str>,
        effort: Option<&str>,
        on_event: F,
        on_turn_completed: G,
    ) -> Result<GatewayTurnMutation, String>
    where
        F: Fn(BridgeEventEnvelope<Value>) + Send + 'static,
        G: Fn(String) + Send + 'static,
    {
        let config = self.config.clone();
        let thread_id = thread_id.to_string();
        let prompt = prompt.to_string();
        let images = images.to_vec();
        let model = model.map(str::to_string);
        let effort = effort.map(str::to_string);
        let reserved_transports = Arc::clone(&self.reserved_transports);
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

            let _ = resume_thread(&mut transport, &thread_id);
            let payload = match start_turn_with_resume(
                &mut transport,
                &thread_id,
                &prompt,
                &images,
                model.as_deref(),
                effort.as_deref(),
            ) {
                Ok(payload) => payload,
                Err(error) => {
                    if had_reserved_transport {
                        reserve_transport(&reserved_transports, thread_id.clone(), transport);
                    }
                    let _ = result_tx.send(Err(error));
                    return;
                }
            };

            let result = GatewayTurnMutation {
                response: TurnMutationAcceptedDto {
                    contract_version: CONTRACT_VERSION.to_string(),
                    thread_id: thread_id.clone(),
                    thread_status: ThreadStatus::Running,
                    message: format!("turn {} started", payload.turn.id),
                },
                turn_id: Some(payload.turn.id),
            };

            if result_tx.send(Ok(result.clone())).is_err() {
                return;
            }

            let mut normalizer = CodexNotificationNormalizer::default();
            while let Ok(Some(message)) = transport.next_message("turn stream") {
                if message.get("id").is_some() {
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
        let config = self.config.clone();
        let thread_id = thread_id.to_string();
        let turn_id = turn_id.to_string();
        tokio::task::spawn_blocking(move || -> Result<GatewayTurnMutation, String> {
            let mut transport = connect_transport(&config)?;
            transport.request(
                "turn/interrupt",
                serde_json::json!({
                    "threadId": thread_id,
                    "turnId": turn_id,
                }),
            )?;
            Ok(GatewayTurnMutation {
                response: TurnMutationAcceptedDto {
                    contract_version: CONTRACT_VERSION.to_string(),
                    thread_id,
                    thread_status: ThreadStatus::Interrupted,
                    message: "interrupt requested".to_string(),
                },
                turn_id: None,
            })
        })
        .await
        .map_err(|error| format!("codex interrupt_turn task failed: {error}"))?
    }

    pub async fn set_thread_name(&self, thread_id: &str, name: &str) -> Result<(), String> {
        let config = self.config.clone();
        let thread_id = thread_id.to_string();
        let name = name.trim().to_string();
        tokio::task::spawn_blocking(move || -> Result<(), String> {
            if name.is_empty() {
                return Ok(());
            }

            let mut transport = connect_transport(&config)?;
            transport.request(
                "thread/name/set",
                json!({
                    "threadId": thread_id,
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
    let response = transport.request(
        "thread/read",
        serde_json::json!({
            "threadId": thread_id,
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
    let response = transport.request(
        "thread/resume",
        serde_json::json!({
            "threadId": thread_id,
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
            resume_thread(transport, thread_id)?;
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
    let mut params = serde_json::Map::new();
    params.insert("threadId".to_string(), Value::String(thread_id.to_string()));
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

fn build_turn_start_input(prompt: &str, images: &[String]) -> Value {
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

fn extract_generated_thread_title(agent_message: Option<&str>) -> Option<String> {
    let agent_message = agent_message?.trim();
    if agent_message.is_empty() {
        return None;
    }

    let parsed = serde_json::from_str::<Value>(agent_message).ok();
    let raw_title = parsed
        .as_ref()
        .and_then(|value| value.get("title"))
        .and_then(Value::as_str)
        .unwrap_or(agent_message);
    normalize_generated_thread_title(raw_title)
}

fn normalize_generated_thread_title(raw_title: &str) -> Option<String> {
    let normalized_whitespace = raw_title.split_whitespace().collect::<Vec<_>>().join(" ");
    let trimmed = normalized_whitespace
        .trim_matches(|ch: char| ch == '"' || ch == '\'' || ch == '`')
        .trim();
    if trimmed.is_empty() || is_placeholder_thread_title(trimmed) {
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
    if normalized.is_empty() || is_placeholder_thread_title(normalized) {
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
        Ok(summaries) if !summaries.is_empty() => Ok(summaries),
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

fn fetch_thread_summaries_from_archive(
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

fn fallback_model_options() -> Vec<ModelOptionDto> {
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

fn parse_model_options(result: Value) -> Vec<ModelOptionDto> {
    let Some(items) = result.get("data").and_then(Value::as_array) else {
        return Vec::new();
    };

    items.iter().filter_map(parse_model_option).collect()
}

fn parse_model_option(item: &Value) -> Option<ModelOptionDto> {
    let model = value_text(item.get("model")).or_else(|| value_text(item.get("id")))?;
    let id = value_text(item.get("id")).unwrap_or_else(|| model.clone());
    let display_name = value_text(item.get("displayName"))
        .or_else(|| value_text(item.get("display_name")))
        .unwrap_or_else(|| model.clone());
    let description = value_text(item.get("description")).unwrap_or_default();
    let default_reasoning_effort = value_text(item.get("defaultReasoningEffort"))
        .or_else(|| value_text(item.get("default_reasoning_effort")));
    let supported_reasoning_efforts = parse_reasoning_efforts(
        item.get("supportedReasoningEfforts")
            .or_else(|| item.get("supported_reasoning_efforts")),
    );
    let is_default = item
        .get("isDefault")
        .and_then(Value::as_bool)
        .unwrap_or_else(|| {
            item.get("is_default")
                .and_then(Value::as_bool)
                .unwrap_or(false)
        });

    Some(ModelOptionDto {
        id,
        model,
        display_name,
        description,
        is_default,
        default_reasoning_effort,
        supported_reasoning_efforts,
    })
}

fn parse_reasoning_efforts(value: Option<&Value>) -> Vec<ReasoningEffortOptionDto> {
    let Some(items) = value.and_then(Value::as_array) else {
        return Vec::new();
    };

    items
        .iter()
        .filter_map(|item| {
            let effort = value_text(item.get("reasoningEffort"))
                .or_else(|| value_text(item.get("reasoning_effort")))?;
            let description = value_text(item.get("description"));
            Some(ReasoningEffortOptionDto {
                reasoning_effort: effort,
                description,
            })
        })
        .collect()
}

fn value_text(value: Option<&Value>) -> Option<String> {
    let value = value?;
    match value {
        Value::String(text) => {
            let trimmed = text.trim();
            if trimmed.is_empty() {
                None
            } else {
                Some(trimmed.to_string())
            }
        }
        Value::Number(number) => Some(number.to_string()),
        _ => None,
    }
}

fn is_placeholder_thread_title(title: &str) -> bool {
    let normalized = title.trim().to_lowercase();
    normalized.is_empty()
        || normalized == "untitled thread"
        || normalized == "new thread"
        || normalized == "fresh session"
}

fn map_thread_summary(thread: CodexThread) -> ThreadSummaryDto {
    let repository = thread
        .git_info
        .as_ref()
        .and_then(|git| git.origin_url.as_deref())
        .and_then(parse_repository_name_from_origin)
        .or_else(|| derive_repository_name_from_cwd(&thread.cwd))
        .unwrap_or_else(|| "unknown-repository".to_string());
    let branch = thread
        .git_info
        .and_then(|git| git.branch)
        .unwrap_or_else(|| "unknown".to_string());
    let title = thread
        .name
        .as_deref()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or("Untitled thread")
        .to_string();

    ThreadSummaryDto {
        contract_version: CONTRACT_VERSION.to_string(),
        thread_id: thread.id,
        title,
        status: map_thread_status(&thread.status.kind),
        workspace: thread.cwd,
        repository,
        branch,
        updated_at: unix_timestamp_to_iso8601(thread.updated_at),
    }
}

fn map_thread_snapshot(thread: CodexThread) -> ThreadSnapshotDto {
    let detail = map_thread_detail(&thread);
    let entries = {
        let rpc_entries = map_thread_timeline_entries(&thread);
        let archive_entries = thread
            .path
            .as_deref()
            .map(std::path::Path::new)
            .filter(|path| path.is_absolute() && path.exists())
            .map(|path| load_archive_timeline_entries_for_session_path(&thread.id, path))
            .unwrap_or_else(|| load_archive_timeline_entries_for_thread(&thread.id));
        prefer_archive_timeline_when_rpc_lacks_tool_events(rpc_entries, archive_entries)
    };
    let git_status = Some(map_git_status(&thread));

    ThreadSnapshotDto {
        contract_version: CONTRACT_VERSION.to_string(),
        thread: detail,
        entries,
        approvals: Vec::<ApprovalSummaryDto>::new(),
        git_status,
        pending_user_input: None,
    }
}

fn prefer_archive_timeline_when_rpc_lacks_tool_events(
    rpc_entries: Vec<ThreadTimelineEntryDto>,
    archive_entries: Vec<ThreadTimelineEntryDto>,
) -> Vec<ThreadTimelineEntryDto> {
    if has_tool_events(&rpc_entries) {
        return rpc_entries;
    }

    if has_tool_events(&archive_entries) {
        return archive_entries;
    }

    rpc_entries
}

fn has_tool_events(entries: &[ThreadTimelineEntryDto]) -> bool {
    entries.iter().any(|entry| {
        matches!(
            entry.kind,
            BridgeEventKind::CommandDelta | BridgeEventKind::FileChange
        )
    })
}

fn map_thread_detail(thread: &CodexThread) -> ThreadDetailDto {
    let repository = thread
        .git_info
        .as_ref()
        .and_then(|git| git.origin_url.as_deref())
        .and_then(parse_repository_name_from_origin)
        .or_else(|| derive_repository_name_from_cwd(&thread.cwd))
        .unwrap_or_else(|| "unknown-repository".to_string());
    let branch = thread
        .git_info
        .as_ref()
        .and_then(|git| git.branch.clone())
        .unwrap_or_else(|| "unknown".to_string());
    let title = thread
        .name
        .as_deref()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or("Untitled thread")
        .to_string();

    ThreadDetailDto {
        contract_version: CONTRACT_VERSION.to_string(),
        thread_id: thread.id.clone(),
        title,
        status: map_thread_status(&thread.status.kind),
        workspace: thread.cwd.clone(),
        repository,
        branch,
        created_at: unix_timestamp_to_iso8601(thread.created_at),
        updated_at: unix_timestamp_to_iso8601(thread.updated_at),
        source: thread.source.as_str().unwrap_or("unknown").to_string(),
        access_mode: AccessMode::ControlWithApprovals,
        last_turn_summary: thread.preview.clone().unwrap_or_default(),
    }
}

fn map_git_status(thread: &CodexThread) -> GitStatusDto {
    GitStatusDto {
        workspace: thread.cwd.clone(),
        repository: thread
            .git_info
            .as_ref()
            .and_then(|git| git.origin_url.as_deref())
            .and_then(parse_repository_name_from_origin)
            .or_else(|| derive_repository_name_from_cwd(&thread.cwd))
            .unwrap_or_else(|| "unknown-repository".to_string()),
        branch: thread
            .git_info
            .as_ref()
            .and_then(|git| git.branch.clone())
            .unwrap_or_else(|| "unknown".to_string()),
        remote: thread
            .git_info
            .as_ref()
            .and_then(|git| git.origin_url.clone()),
        dirty: false,
        ahead_by: 0,
        behind_by: 0,
    }
}

fn map_thread_timeline_entries(thread: &CodexThread) -> Vec<ThreadTimelineEntryDto> {
    let mut entries = Vec::new();

    for turn in &thread.turns {
        for (index, item) in turn.items.iter().enumerate() {
            let Some((kind, payload)) = normalize_codex_item_payload(item) else {
                continue;
            };
            if kind == BridgeEventKind::MessageDelta && payload_contains_hidden_message(&payload) {
                continue;
            }

            let item_id = item
                .get("id")
                .and_then(Value::as_str)
                .map(ToString::to_string)
                .unwrap_or_else(|| format!("{}-{index}", turn.id));
            let event_id = format!("{}-{item_id}", turn.id);

            entries.push(ThreadTimelineEntryDto {
                event_id: event_id.clone(),
                kind,
                occurred_at: codex_item_occurred_at(item, &turn.id, thread.updated_at),
                summary: summarize_live_payload(kind, &payload),
                annotations: timeline_annotations_for_event(&event_id, kind, &payload),
                payload,
            });
        }
    }

    entries
}

fn unix_timestamp_to_iso8601(timestamp: i64) -> String {
    let millis = if timestamp.abs() >= 1_000_000_000_000 {
        timestamp
    } else {
        timestamp.saturating_mul(1000)
    };

    Utc.timestamp_millis_opt(millis)
        .single()
        .unwrap_or_else(Utc::now)
        .to_rfc3339_opts(SecondsFormat::Millis, true)
}

fn map_thread_status(kind: &str) -> ThreadStatus {
    match kind {
        "idle" => ThreadStatus::Idle,
        "active" => ThreadStatus::Running,
        "systemError" => ThreadStatus::Failed,
        _ => ThreadStatus::Idle,
    }
}

fn parse_repository_name_from_origin(origin_url: &str) -> Option<String> {
    let trimmed = origin_url.trim().trim_end_matches('/');
    let repository = trimmed
        .rsplit(['/', ':'])
        .next()?
        .trim_end_matches(".git")
        .trim();
    (!repository.is_empty()).then(|| repository.to_string())
}

fn derive_repository_name_from_cwd(cwd: &str) -> Option<String> {
    cwd.rsplit('/')
        .find(|segment| !segment.trim().is_empty())
        .map(|segment| segment.trim().to_string())
}

fn codex_item_occurred_at(item: &Value, turn_id: &str, thread_updated_at: i64) -> String {
    codex_timestamp_from_item(item)
        .or_else(|| uuid_v7_timestamp_to_iso8601(turn_id))
        .unwrap_or_else(|| unix_timestamp_to_iso8601(thread_updated_at))
}

fn codex_timestamp_from_item(item: &Value) -> Option<String> {
    const KEYS: [&str; 8] = [
        "timestamp",
        "occurredAt",
        "updatedAt",
        "createdAt",
        "startedAt",
        "completedAt",
        "startTime",
        "endTime",
    ];

    KEYS.iter()
        .filter_map(|key| item.get(*key))
        .find_map(value_to_timestamp)
}

fn value_to_timestamp(value: &Value) -> Option<String> {
    match value {
        Value::String(text) => {
            let trimmed = text.trim();
            if trimmed.is_empty() {
                None
            } else if let Ok(parsed_numeric) = trimmed.parse::<i64>() {
                Some(unix_timestamp_to_iso8601(parsed_numeric))
            } else {
                Some(trimmed.to_string())
            }
        }
        Value::Number(number) => number.as_i64().map(unix_timestamp_to_iso8601).or_else(|| {
            number
                .as_u64()
                .map(|value| unix_timestamp_to_iso8601(value as i64))
        }),
        _ => None,
    }
}

fn uuid_v7_timestamp_to_iso8601(value: &str) -> Option<String> {
    let compact = value.chars().filter(|ch| *ch != '-').collect::<String>();
    if compact.len() != 32 || !compact.chars().all(|ch| ch.is_ascii_hexdigit()) {
        return None;
    }
    if compact
        .chars()
        .nth(12)
        .is_none_or(|version| !version.eq_ignore_ascii_case(&'7'))
    {
        return None;
    }

    let millis = i64::from_str_radix(&compact[0..12], 16).ok()?;
    Some(unix_timestamp_to_iso8601(millis))
}

fn normalize_codex_item_payload(item: &Value) -> Option<(BridgeEventKind, Value)> {
    let item_type = canonicalize_codex_item_type(item.get("type").and_then(Value::as_str)?);
    match item_type {
        "userMessage" => Some((
            BridgeEventKind::MessageDelta,
            normalize_message_item(item, "user"),
        )),
        "agentMessage" => Some((
            BridgeEventKind::MessageDelta,
            normalize_message_item(item, "assistant"),
        )),
        "plan" => Some((BridgeEventKind::PlanDelta, normalize_plan_item(item))),
        "commandExecution" => Some((BridgeEventKind::CommandDelta, normalize_command_item(item))),
        "fileChange" => Some((
            BridgeEventKind::FileChange,
            normalize_file_change_item(item),
        )),
        "functionCall" | "customToolCall" => normalize_codex_tool_invocation_item(item),
        "functionCallOutput" | "customToolCallOutput" => normalize_codex_tool_output_item(item),
        _ => None,
    }
}

fn canonicalize_codex_item_type(item_type: &str) -> &str {
    match item_type {
        "function_call" => "functionCall",
        "function_call_output" => "functionCallOutput",
        "custom_tool_call" => "customToolCall",
        "custom_tool_call_output" => "customToolCallOutput",
        other => other,
    }
}

fn normalize_codex_tool_invocation_item(item: &Value) -> Option<(BridgeEventKind, Value)> {
    let tool_name = item
        .get("name")
        .and_then(Value::as_str)
        .or_else(|| item.get("command").and_then(Value::as_str))
        .unwrap_or("command");
    if tool_name == "update_plan"
        && let Some(payload) = normalize_update_plan_tool_item(item)
    {
        return Some((BridgeEventKind::PlanDelta, payload));
    }
    let input = item
        .get("input")
        .cloned()
        .or_else(|| item.get("arguments").cloned())
        .unwrap_or(Value::Null);
    let input_text = value_to_text(&input).unwrap_or_default();
    let is_file_change = is_file_change_custom_tool(tool_name) || is_file_change_text(&input_text);

    let mut payload = item.clone();
    if let Some(object) = payload.as_object_mut() {
        object.insert("command".to_string(), Value::String(tool_name.to_string()));
        if is_file_change {
            if !input_text.trim().is_empty() {
                object.insert("change".to_string(), Value::String(input_text));
            }
        } else if !object.contains_key("arguments") {
            object.insert("arguments".to_string(), input);
        }
    }

    Some((
        if is_file_change {
            BridgeEventKind::FileChange
        } else {
            BridgeEventKind::CommandDelta
        },
        if is_file_change {
            normalize_file_change_item(&payload)
        } else {
            normalize_command_item(&payload)
        },
    ))
}

fn normalize_update_plan_tool_item(item: &Value) -> Option<Value> {
    let plan_input = parse_update_plan_input(
        item.get("input")
            .or_else(|| item.get("arguments"))
            .unwrap_or(&Value::Null),
    )?;
    let steps = normalize_update_plan_steps(&plan_input);
    let explanation = plan_input
        .get("explanation")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string);
    if steps.is_empty() && explanation.is_none() {
        return None;
    }

    let total_count = steps.len();
    let completed_count = steps
        .iter()
        .filter(|step| step.get("status").and_then(Value::as_str) == Some("completed"))
        .count();
    let text =
        render_update_plan_text(explanation.as_deref(), &steps, completed_count, total_count);

    let mut payload = json!({
        "id": item.get("id").and_then(Value::as_str).unwrap_or_default(),
        "type": "plan",
        "text": text,
    });
    if let Some(object) = payload.as_object_mut() {
        if let Some(explanation) = explanation {
            object.insert("explanation".to_string(), Value::String(explanation));
        }
        if !steps.is_empty() {
            object.insert("steps".to_string(), Value::Array(steps));
            object.insert("completed_count".to_string(), json!(completed_count));
            object.insert("total_count".to_string(), json!(total_count));
        }
    }

    Some(payload)
}

fn parse_update_plan_input(input: &Value) -> Option<Value> {
    match input {
        Value::String(text) => serde_json::from_str::<Value>(text).ok(),
        Value::Object(_) => Some(input.clone()),
        _ => None,
    }
}

fn normalize_update_plan_steps(plan_input: &Value) -> Vec<Value> {
    plan_input
        .get("plan")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|entry| {
            let step = entry
                .get("step")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|value| !value.is_empty())?;
            let status = entry
                .get("status")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .unwrap_or("pending");
            Some(json!({
                "step": step,
                "status": status,
            }))
        })
        .collect()
}

fn render_update_plan_text(
    explanation: Option<&str>,
    steps: &[Value],
    completed_count: usize,
    total_count: usize,
) -> String {
    if total_count == 0 {
        return explanation.unwrap_or_default().to_string();
    }

    let task_label = if total_count == 1 { "task" } else { "tasks" };
    let mut lines = vec![format!(
        "{completed_count} out of {total_count} {task_label} completed"
    )];
    lines.extend(steps.iter().enumerate().filter_map(|(index, step)| {
        step.get("step")
            .and_then(Value::as_str)
            .map(|value| format!("{}. {value}", index + 1))
    }));
    lines.join("\n")
}

fn normalize_codex_tool_output_item(item: &Value) -> Option<(BridgeEventKind, Value)> {
    let output = item
        .get("output")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let normalized_output = normalize_custom_tool_output(output);
    let is_file_change = is_file_change_text(&normalized_output);

    let mut payload = item.clone();
    if let Some(object) = payload.as_object_mut() {
        object.insert("output".to_string(), Value::String(normalized_output));
    }

    Some((
        if is_file_change {
            BridgeEventKind::FileChange
        } else {
            BridgeEventKind::CommandDelta
        },
        if is_file_change {
            normalize_file_change_item(&payload)
        } else {
            normalize_command_item(&payload)
        },
    ))
}

fn normalize_message_item(item: &Value, role: &str) -> Value {
    let mut payload = serde_json::json!({
        "id": item.get("id").and_then(Value::as_str).unwrap_or_default(),
        "type": "message",
        "role": role,
        "text": extract_message_text(item),
    });

    let images = extract_message_images(item);
    if !images.is_empty()
        && let Some(object) = payload.as_object_mut()
    {
        object.insert(
            "images".to_string(),
            Value::Array(images.into_iter().map(Value::String).collect()),
        );
    }

    payload
}

fn normalize_plan_item(item: &Value) -> Value {
    serde_json::json!({
        "id": item.get("id").and_then(Value::as_str).unwrap_or_default(),
        "type": "plan",
        "text": item.get("text").and_then(Value::as_str).unwrap_or_default(),
    })
}

fn normalize_command_item(item: &Value) -> Value {
    let arguments = item
        .get("arguments")
        .cloned()
        .or_else(|| item.get("input").cloned())
        .unwrap_or(Value::Null);

    serde_json::json!({
        "id": item.get("id").and_then(Value::as_str).unwrap_or_default(),
        "type": "command",
        "command": item
            .get("command")
            .or_else(|| item.get("name"))
            .and_then(Value::as_str)
            .unwrap_or_default(),
        "arguments": arguments,
        "output": item
            .get("output")
            .or_else(|| item.get("aggregatedOutput"))
            .and_then(Value::as_str)
            .unwrap_or_default(),
        "cmd": item.get("cmd").and_then(Value::as_str),
        "workdir": item.get("cwd").and_then(Value::as_str),
    })
}

fn normalize_file_change_item(item: &Value) -> Value {
    serde_json::json!({
        "id": item.get("id").and_then(Value::as_str).unwrap_or_default(),
        "type": "file_change",
        "resolved_unified_diff": item
            .get("resolved_unified_diff")
            .or_else(|| item.get("output"))
            .or_else(|| item.get("change"))
            .and_then(Value::as_str)
            .unwrap_or_default(),
        "path": extract_file_change_path(item),
    })
}

fn extract_message_text(item: &Value) -> String {
    if let Some(text) = item.get("text").and_then(Value::as_str) {
        return text.to_string();
    }

    item.get("content")
        .and_then(Value::as_array)
        .map(|content| {
            content
                .iter()
                .filter_map(|entry| entry.get("text").and_then(Value::as_str))
                .map(str::trim)
                .filter(|text| !text.is_empty())
                .collect::<Vec<_>>()
                .join("\n")
        })
        .unwrap_or_default()
}

fn extract_message_images(item: &Value) -> Vec<String> {
    item.get("content")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|entry| {
            entry
                .get("image_url")
                .or_else(|| entry.get("url"))
                .or_else(|| entry.get("path"))
                .and_then(Value::as_str)
        })
        .filter(|image| !image.trim().is_empty())
        .map(ToString::to_string)
        .collect()
}

fn extract_file_change_path(item: &Value) -> String {
    item.get("path")
        .or_else(|| item.get("file"))
        .and_then(Value::as_str)
        .map(ToString::to_string)
        .or_else(|| {
            item.get("changes")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .find_map(|change| change.get("path").and_then(Value::as_str))
                .map(ToString::to_string)
        })
        .unwrap_or_default()
}

fn is_file_change_custom_tool(tool_name: &str) -> bool {
    matches!(
        tool_name,
        "apply_patch" | "replace_file_content" | "multi_replace_file_content"
    ) || tool_name.contains("edit_file")
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

fn normalize_custom_tool_output(raw_output: &str) -> String {
    if raw_output.trim().is_empty() {
        return String::new();
    }

    if let Ok(decoded) = serde_json::from_str::<Value>(raw_output)
        && let Some(text) = decoded.get("output").and_then(Value::as_str)
    {
        return text.to_string();
    }

    raw_output.to_string()
}

fn payload_contains_hidden_message(payload: &Value) -> bool {
    payload_primary_text(payload)
        .map(is_hidden_archive_message)
        .unwrap_or(false)
}

fn payload_primary_text(payload: &Value) -> Option<&str> {
    for key in ["text", "delta", "message"] {
        if let Some(value) = payload.get(key).and_then(Value::as_str) {
            let trimmed = value.trim();
            if !trimmed.is_empty() {
                return Some(trimmed);
            }
        }
    }

    payload
        .get("content")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .find_map(|item| item.get("text").and_then(Value::as_str))
        .map(str::trim)
        .filter(|text| !text.is_empty())
}

fn is_hidden_archive_message(message: &str) -> bool {
    let trimmed = message.trim();
    trimmed.starts_with("# AGENTS.md instructions for ")
        || trimmed.starts_with("<permissions instructions>")
        || trimmed.starts_with("<app-context>")
        || trimmed.starts_with("<environment_context>")
        || trimmed.starts_with("<collaboration_mode>")
}

fn summarize_live_payload(kind: BridgeEventKind, payload: &Value) -> String {
    match kind {
        BridgeEventKind::MessageDelta | BridgeEventKind::PlanDelta => payload
            .get("text")
            .or_else(|| payload.get("delta"))
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
        BridgeEventKind::UserInputRequested => payload
            .get("title")
            .or_else(|| payload.get("detail"))
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
        BridgeEventKind::CommandDelta => payload
            .get("output")
            .or_else(|| payload.get("aggregatedOutput"))
            .or_else(|| payload.get("command"))
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
        BridgeEventKind::FileChange => payload
            .get("resolved_unified_diff")
            .or_else(|| payload.get("output"))
            .and_then(Value::as_str)
            .unwrap_or_else(|| {
                payload
                    .get("path")
                    .or_else(|| payload.get("file"))
                    .and_then(Value::as_str)
                    .unwrap_or_default()
            })
            .to_string(),
        BridgeEventKind::ThreadStatusChanged => payload
            .get("status")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
        BridgeEventKind::ApprovalRequested => payload
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
        BridgeEventKind::SecurityAudit => payload
            .get("reason")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
    }
}

fn timeline_annotations_for_event(
    event_id: &str,
    kind: BridgeEventKind,
    payload: &Value,
) -> Option<ThreadTimelineAnnotationsDto> {
    let exploration_kind = classify_exploration_kind(kind, payload)?;
    let command = extract_exploration_command(payload)?;

    Some(ThreadTimelineAnnotationsDto {
        group_kind: Some(ThreadTimelineGroupKind::Exploration),
        group_id: derive_exploration_group_id(event_id, payload),
        exploration_kind: Some(exploration_kind),
        entry_label: exploration_entry_label(exploration_kind, command.as_str()),
    })
}

fn classify_exploration_kind(
    kind: BridgeEventKind,
    payload: &Value,
) -> Option<ThreadTimelineExplorationKind> {
    if kind != BridgeEventKind::CommandDelta {
        return None;
    }

    let command = extract_exploration_command(payload)?;
    let normalized_command = command.trim().to_lowercase();
    if is_exploration_read_command(&normalized_command) {
        Some(ThreadTimelineExplorationKind::Read)
    } else if is_exploration_search_command(&normalized_command) {
        Some(ThreadTimelineExplorationKind::Search)
    } else {
        None
    }
}

fn extract_exploration_command(payload: &Value) -> Option<String> {
    [
        payload.get("command"),
        payload.get("action"),
        payload.get("arguments"),
        payload.get("input"),
        payload.get("output"),
        payload.get("aggregatedOutput"),
    ]
    .into_iter()
    .flatten()
    .filter_map(extract_shell_like_command)
    .find(|command| {
        let normalized = command.trim().to_lowercase();
        is_exploration_read_command(&normalized) || is_exploration_search_command(&normalized)
    })
}

fn extract_shell_like_command(value: &Value) -> Option<String> {
    match value {
        Value::Null => None,
        Value::String(text) => {
            let trimmed = text.trim();
            if trimmed.is_empty() {
                return None;
            }
            if let Ok(parsed) = serde_json::from_str::<Value>(trimmed) {
                return extract_shell_like_command(&parsed)
                    .or_else(|| parse_background_command(trimmed));
            }
            parse_background_command(trimmed).or_else(|| Some(trimmed.to_string()))
        }
        Value::Object(object) => object
            .get("cmd")
            .or_else(|| object.get("command"))
            .or_else(|| object.get("action"))
            .and_then(extract_shell_like_command)
            .or_else(|| object.get("input").and_then(extract_shell_like_command))
            .or_else(|| object.get("arguments").and_then(extract_shell_like_command)),
        Value::Array(values) => values.iter().find_map(extract_shell_like_command),
        other => {
            value_to_text(other).and_then(|text| extract_shell_like_command(&Value::String(text)))
        }
    }
}

fn parse_background_command(raw: &str) -> Option<String> {
    raw.lines()
        .find_map(|line| line.strip_prefix("Command:"))
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
}

fn value_to_text(value: &Value) -> Option<String> {
    match value {
        Value::String(text) => Some(text.clone()),
        Value::Null => None,
        other => serde_json::to_string(other).ok(),
    }
}

fn is_exploration_read_command(command: &str) -> bool {
    command.starts_with("nl -ba ")
        || command.starts_with("cat ")
        || command.starts_with("bat ")
        || command.starts_with("sed -n ")
        || command.starts_with("head ")
        || command.starts_with("tail ")
        || command.starts_with("git diff ")
        || command.starts_with("git show ")
        || command == "git status"
        || command.starts_with("git status ")
        || command == "pwd"
}

fn is_exploration_search_command(command: &str) -> bool {
    command == "ls"
        || command.starts_with("ls ")
        || command == "tree"
        || command.starts_with("tree ")
        || command.starts_with("fd ")
        || command.starts_with("git grep ")
        || command.starts_with("git ls-files")
        || command.starts_with("rg -n ")
        || command.starts_with("rg --files ")
        || command == "rg"
        || command.starts_with("rg ")
        || command.starts_with("find ")
        || command.starts_with("grep ")
        || command.starts_with("search_query ")
}

fn derive_exploration_group_id(event_id: &str, payload: &Value) -> Option<String> {
    let item_id = payload.get("id").and_then(Value::as_str)?.trim();
    let turn_prefix = event_id.strip_suffix(&format!("-{item_id}"))?.trim();
    if turn_prefix.is_empty() {
        return None;
    }

    Some(format!("exploration:{turn_prefix}"))
}

fn exploration_entry_label(
    exploration_kind: ThreadTimelineExplorationKind,
    command: &str,
) -> Option<String> {
    match exploration_kind {
        ThreadTimelineExplorationKind::Read => {
            extract_file_name_from_command(command).map(|file_name| format!("Read {file_name}"))
        }
        ThreadTimelineExplorationKind::Search => Some("Search".to_string()),
    }
}

fn extract_file_name_from_command(command: &str) -> Option<String> {
    command
        .split_whitespace()
        .map(|segment| segment.trim_matches(|ch| ch == '"' || ch == '\'' || ch == '`'))
        .rfind(|segment| segment.contains('/') || segment.contains('.'))
        .and_then(|path| path.rsplit('/').next())
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
}

#[cfg(test)]
mod tests {
    use super::{
        CodexGateway, CodexThread, build_turn_start_input, derive_repository_name_from_cwd,
        extract_generated_thread_title, fetch_thread_summaries_from_archive, map_thread_summary,
        normalize_codex_item_payload, normalize_generated_thread_title, parse_model_options,
        parse_repository_name_from_origin, prefer_archive_timeline_when_rpc_lacks_tool_events,
    };
    use crate::codex_runtime::CodexRuntimeMode;
    use crate::server::config::BridgeCodexConfig;
    use serde_json::json;
    use shared_contracts::{BridgeEventKind, ThreadTimelineEntryDto};
    use std::fs;
    use std::sync::mpsc;
    use std::time::{Duration, Instant};

    #[test]
    fn parses_repository_name_from_origin_url() {
        assert_eq!(
            parse_repository_name_from_origin("git@github.com:openai/codex.git"),
            Some("codex".to_string())
        );
    }

    #[test]
    fn derives_repository_name_from_workspace_path() {
        assert_eq!(
            derive_repository_name_from_cwd("/Users/test/project"),
            Some("project".to_string())
        );
    }

    #[test]
    fn function_call_command_payload_preserves_arguments_for_mobile_formatting() {
        let item = json!({
            "id": "tool-1",
            "type": "functionCall",
            "name": "exec_command",
            "arguments": "{\"cmd\":\"flutter analyze\"}",
        });

        let (kind, payload) =
            normalize_codex_item_payload(&item).expect("function call should normalize");
        assert_eq!(kind, BridgeEventKind::CommandDelta);
        assert_eq!(payload["command"], "exec_command");
        assert_eq!(payload["arguments"], "{\"cmd\":\"flutter analyze\"}");
    }

    #[test]
    fn update_plan_function_call_normalizes_to_plan_delta() {
        let item = json!({
            "id": "tool-2",
            "type": "functionCall",
            "name": "update_plan",
            "arguments": "{\"plan\":[{\"step\":\"Inspect bridge payload\",\"status\":\"completed\"},{\"step\":\"Add Flutter card\",\"status\":\"in_progress\"}]}"
        });

        let (kind, payload) =
            normalize_codex_item_payload(&item).expect("update_plan should normalize");
        assert_eq!(kind, BridgeEventKind::PlanDelta);
        assert_eq!(payload["type"], "plan");
        assert_eq!(payload["completed_count"], 1);
        assert_eq!(payload["total_count"], 2);
        assert_eq!(
            payload["text"].as_str(),
            Some("1 out of 2 tasks completed\n1. Inspect bridge payload\n2. Add Flutter card")
        );
    }

    #[test]
    fn turn_start_input_includes_text_and_image_parts() {
        let input = build_turn_start_input(
            "Describe this image",
            &["data:image/png;base64,AAA".to_string()],
        );

        assert_eq!(
            input,
            json!([
                {
                    "type": "text",
                    "text": "Describe this image",
                    "text_elements": [],
                },
                {
                    "type": "image",
                    "url": "data:image/png;base64,AAA",
                }
            ])
        );
    }

    #[test]
    fn normalize_message_item_preserves_image_urls_from_codex_content() {
        let item = json!({
            "id": "msg-1",
            "type": "userMessage",
            "content": [
                {
                    "type": "text",
                    "text": "Screenshot attached",
                },
                {
                    "type": "image",
                    "url": "data:image/png;base64,AAA",
                }
            ],
        });

        let (kind, payload) =
            normalize_codex_item_payload(&item).expect("message should normalize");
        assert_eq!(kind, BridgeEventKind::MessageDelta);
        assert_eq!(payload["role"], "user");
        assert_eq!(payload["images"], json!(["data:image/png;base64,AAA"]));
    }

    #[test]
    fn parses_model_catalog_from_codex_response() {
        let models = parse_model_options(json!({
            "data": [
                {
                    "id": "gpt-5.4",
                    "model": "gpt-5.4",
                    "displayName": "GPT-5.4",
                    "description": "Best reasoning",
                    "isDefault": true,
                    "defaultReasoningEffort": "high",
                    "supportedReasoningEfforts": [
                        {"reasoningEffort": "medium"},
                        {"reasoningEffort": "high"}
                    ]
                }
            ]
        }));

        assert_eq!(models.len(), 1);
        assert_eq!(models[0].id, "gpt-5.4");
        assert_eq!(models[0].display_name, "GPT-5.4");
        assert!(models[0].is_default);
        assert_eq!(models[0].default_reasoning_effort.as_deref(), Some("high"));
        assert_eq!(models[0].supported_reasoning_efforts.len(), 2);
    }

    #[test]
    fn generated_thread_title_is_normalized() {
        assert_eq!(
            normalize_generated_thread_title("  \"Fix stale thread state.\"  "),
            Some("Fix stale thread state".to_string())
        );
        assert_eq!(normalize_generated_thread_title("Untitled thread"), None);
    }

    #[test]
    fn generated_thread_title_prefers_structured_json_field() {
        assert_eq!(
            extract_generated_thread_title(Some(r#"{"title":"Add todo list to Flutter app"}"#)),
            Some("Add todo list to Flutter app".to_string())
        );
    }

    #[test]
    fn thread_summary_ignores_preview_when_name_is_missing() {
        let summary = map_thread_summary(CodexThread {
            id: "thread-1".to_string(),
            name: None,
            preview: Some("This should stay a preview".to_string()),
            status: super::CodexThreadStatus {
                kind: "idle".to_string(),
            },
            cwd: "/Users/test/project".to_string(),
            path: None,
            git_info: Some(super::CodexGitInfo {
                branch: Some("main".to_string()),
                origin_url: Some("git@github.com:openai/codex-mobile-companion.git".to_string()),
            }),
            created_at: 0,
            updated_at: 0,
            source: json!("cli"),
            turns: Vec::new(),
        });

        assert_eq!(summary.title, "Untitled thread");
    }

    #[test]
    fn archive_timeline_is_preferred_when_rpc_has_only_messages() {
        let rpc_entries = vec![ThreadTimelineEntryDto {
            event_id: "evt-msg".to_string(),
            kind: BridgeEventKind::MessageDelta,
            occurred_at: "2026-03-21T10:00:00.000Z".to_string(),
            summary: "assistant message".to_string(),
            payload: json!({"text":"assistant message"}),
            annotations: None,
        }];

        let archive_entries = vec![
            ThreadTimelineEntryDto {
                event_id: "evt-msg-archive".to_string(),
                kind: BridgeEventKind::MessageDelta,
                occurred_at: "2026-03-21T10:00:00.000Z".to_string(),
                summary: "assistant message".to_string(),
                payload: json!({"text":"assistant message"}),
                annotations: None,
            },
            ThreadTimelineEntryDto {
                event_id: "evt-cmd".to_string(),
                kind: BridgeEventKind::CommandDelta,
                occurred_at: "2026-03-21T10:00:01.000Z".to_string(),
                summary: "Called exec_command".to_string(),
                payload: json!({"command":"exec_command","arguments":"{\"cmd\":\"pwd\"}"}),
                annotations: None,
            },
        ];

        let selected =
            prefer_archive_timeline_when_rpc_lacks_tool_events(rpc_entries, archive_entries);

        assert_eq!(selected.len(), 2);
        assert_eq!(selected[1].kind, BridgeEventKind::CommandDelta);
    }

    #[test]
    fn archive_fallback_surfaces_threads_when_live_list_is_empty() {
        let codex_home =
            std::env::temp_dir().join(format!("gateway-archive-fallback-{}", std::process::id()));
        let sessions_directory = codex_home.join("sessions/2026/03/23");
        fs::create_dir_all(&sessions_directory).expect("test sessions directory should exist");
        fs::write(
            sessions_directory.join("rollout-2026-03-23T18-04-18-thread-archive-no-index.jsonl"),
            concat!(
                r#"{"timestamp":"2026-03-23T18:04:20.876Z","type":"session_meta","payload":{"id":"thread-archive-no-index","timestamp":"2026-03-23T18:04:18.254Z","cwd":"/home/lubo/codex-mobile-companion/apps/linux-shell","source":"cli","git":{"branch":"main","repository_url":"git@github.com:openai/codex-mobile-companion.git"}}}"#,
                "\n",
                r#"{"timestamp":"2026-03-23T18:04:21.018Z","type":"event_msg","payload":{"type":"user_message","message":"hello"}}"#,
                "\n"
            ),
        )
        .expect("session log should be writable");

        let previous_codex_home = std::env::var_os("CODEX_HOME");
        unsafe {
            std::env::set_var("CODEX_HOME", &codex_home);
        }

        let summaries = fetch_thread_summaries_from_archive(&BridgeCodexConfig {
            mode: CodexRuntimeMode::Spawn,
            endpoint: None,
            command: "definitely-missing-codex".to_string(),
            args: vec!["app-server".to_string()],
            desktop_ipc_socket_path: None,
        })
        .expect("archive fallback should load thread summaries");

        unsafe {
            if let Some(previous_codex_home) = previous_codex_home {
                std::env::set_var("CODEX_HOME", previous_codex_home);
            } else {
                std::env::remove_var("CODEX_HOME");
            }
        }
        let _ = fs::remove_dir_all(&codex_home);

        assert_eq!(summaries.len(), 1);
        assert_eq!(summaries[0].thread_id, "thread-archive-no-index");
        assert_eq!(summaries[0].repository, "codex-mobile-companion");
    }

    #[test]
    #[ignore = "requires a live local Codex app-server"]
    fn live_create_thread_and_stream_turn_response() {
        let runtime = tokio::runtime::Runtime::new().expect("runtime should build");
        runtime.block_on(async {
            let workspace = std::env::var("CODEX_LIVE_TEST_WORKSPACE")
                .ok()
                .filter(|value| !value.trim().is_empty())
                .unwrap_or_else(|| {
                    std::env::current_dir()
                        .expect("cwd should resolve")
                        .display()
                        .to_string()
                });
            let codex_bin = std::env::var("CODEX_LIVE_TEST_CODEX_BIN")
                .ok()
                .filter(|value| !value.trim().is_empty())
                .unwrap_or_else(|| "codex".to_string());

            let gateway = CodexGateway::new(BridgeCodexConfig {
                mode: CodexRuntimeMode::Spawn,
                endpoint: None,
                command: codex_bin,
                args: vec!["app-server".to_string()],
                desktop_ipc_socket_path: None,
            });

            let create_started_at = Instant::now();
            let snapshot = tokio::time::timeout(
                Duration::from_secs(10),
                gateway.create_thread(&workspace, None),
            )
            .await
            .expect("create_thread should not hang")
            .expect("create_thread should succeed");
            assert!(
                !snapshot.thread.thread_id.trim().is_empty(),
                "create_thread returned an empty thread id"
            );
            assert_eq!(snapshot.thread.workspace, workspace);
            eprintln!(
                "LIVE_GATEWAY_CREATE thread_id={} create_ms={}",
                snapshot.thread.thread_id,
                create_started_at.elapsed().as_millis()
            );

            let token = format!("LIVE_GATEWAY_TOKEN_{}", snapshot.thread.thread_id);
            let prompt = format!("Reply with exactly {token}");
            let (event_tx, event_rx) = mpsc::channel();
            gateway
                .start_turn_streaming(
                    &snapshot.thread.thread_id,
                    &prompt,
                    &[],
                    None,
                    None,
                    move |event| {
                        let _ = event_tx.send(event);
                    },
                    |_| {},
                )
                .expect("turn should start");

            let wait_deadline = Instant::now() + Duration::from_secs(60);
            let mut saw_token = false;
            while Instant::now() < wait_deadline {
                let Ok(event) = event_rx.recv_timeout(Duration::from_secs(5)) else {
                    continue;
                };
                if event.kind != BridgeEventKind::MessageDelta {
                    continue;
                }

                let payload_text =
                    serde_json::to_string(&event.payload).expect("payload should serialize");
                if payload_text.contains(&token) {
                    saw_token = true;
                    break;
                }
            }

            assert!(
                saw_token,
                "did not observe assistant stream payload containing {token}"
            );
        });
    }
}
