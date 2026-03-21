use chrono::{SecondsFormat, TimeZone, Utc};
use serde::Deserialize;
use serde_json::Value;
use shared_contracts::{
    AccessMode, ApprovalSummaryDto, BridgeEventEnvelope, BridgeEventKind, CONTRACT_VERSION,
    GitStatusDto, ThreadDetailDto, ThreadSnapshotDto, ThreadStatus, ThreadSummaryDto,
    ThreadTimelineAnnotationsDto, ThreadTimelineEntryDto, ThreadTimelineExplorationKind,
    ThreadTimelineGroupKind, TurnMutationAcceptedDto,
};
use std::sync::mpsc;

use crate::codex_runtime::CodexRuntimeMode;
use crate::codex_transport::CodexJsonTransport;
use crate::rewrite::config::RewriteCodexConfig;
use crate::thread_api::{CodexNotificationNormalizer, CodexNotificationStream};

#[derive(Debug, Clone)]
pub struct CodexGateway {
    config: RewriteCodexConfig,
}

#[derive(Debug, Clone)]
pub struct GatewayBootstrap {
    pub summaries: Vec<ThreadSummaryDto>,
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

    pub fn new(config: RewriteCodexConfig) -> Self {
        Self { config }
    }

    pub async fn bootstrap(&self) -> Result<GatewayBootstrap, String> {
        let config = self.config.clone();
        tokio::task::spawn_blocking(move || {
            let mut transport = connect_transport(&config)?;
            let summaries = fetch_thread_summaries(&mut transport)?;
            Ok(GatewayBootstrap {
                summaries,
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
        tokio::task::spawn_blocking(move || {
            let mut transport = connect_transport(&config)?;
            let payload = read_thread_with_resume(&mut transport, &thread_id, true)?;
            Ok(map_thread_snapshot(payload.thread))
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
            let thread = match read_thread_with_resume(&mut transport, &payload.thread.id, true) {
                Ok(thread) => thread,
                Err(error) if should_read_without_turns(&error) => {
                    read_thread_with_resume(&mut transport, &payload.thread.id, false)?
                }
                Err(error) if should_resume_thread(&error) => {
                    return Ok(map_thread_snapshot(payload.thread));
                }
                Err(error) => return Err(error),
            };
            Ok(map_thread_snapshot(thread.thread))
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

    pub fn start_turn_streaming<F>(
        &self,
        thread_id: &str,
        prompt: &str,
        on_event: F,
    ) -> Result<GatewayTurnMutation, String>
    where
        F: Fn(BridgeEventEnvelope<Value>) + Send + 'static,
    {
        let config = self.config.clone();
        let thread_id = thread_id.to_string();
        let prompt = prompt.to_string();
        let (result_tx, result_rx) = mpsc::sync_channel(1);

        std::thread::spawn(move || {
            let mut transport = match connect_transport(&config) {
                Ok(transport) => transport,
                Err(error) => {
                    let _ = result_tx.send(Err(error));
                    return;
                }
            };

            let _ = resume_thread(&mut transport, &thread_id);
            let payload = match start_turn_with_resume(&mut transport, &thread_id, &prompt) {
                Ok(payload) => payload,
                Err(error) => {
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
) -> Result<CodexTurnStartResult, String> {
    match start_turn(transport, thread_id, prompt) {
        Ok(response) => Ok(response),
        Err(error) if should_resume_thread(&error) => {
            resume_thread(transport, thread_id)?;
            start_turn(transport, thread_id, prompt)
        }
        Err(error) => Err(error),
    }
}

fn start_turn(
    transport: &mut CodexJsonTransport,
    thread_id: &str,
    prompt: &str,
) -> Result<CodexTurnStartResult, String> {
    let response = transport.request(
        "turn/start",
        serde_json::json!({
            "threadId": thread_id,
            "input": [{
                "type": "text",
                "text": prompt,
                "text_elements": [],
            }],
        }),
    )?;
    serde_json::from_value(response)
        .map_err(|error| format!("invalid turn/start response from codex: {error}"))
}

fn connect_transport(config: &RewriteCodexConfig) -> Result<CodexJsonTransport, String> {
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

fn fetch_thread_summaries(
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
        .or(thread.preview.as_deref())
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
    let entries = map_thread_timeline_entries(&thread);
    let git_status = Some(map_git_status(&thread));

    ThreadSnapshotDto {
        contract_version: CONTRACT_VERSION.to_string(),
        thread: detail,
        entries,
        approvals: Vec::<ApprovalSummaryDto>::new(),
        git_status,
    }
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
        .or(thread.preview.as_deref())
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
    serde_json::json!({
        "id": item.get("id").and_then(Value::as_str).unwrap_or_default(),
        "type": "command",
        "command": item
            .get("command")
            .or_else(|| item.get("name"))
            .and_then(Value::as_str)
            .unwrap_or_default(),
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
    use super::{derive_repository_name_from_cwd, parse_repository_name_from_origin};

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
}
