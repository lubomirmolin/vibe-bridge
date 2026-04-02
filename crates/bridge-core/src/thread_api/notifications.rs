use std::collections::{HashMap, HashSet};

use serde::Deserialize;
use serde_json::{Value, json};
use shared_contracts::{BridgeEventEnvelope, BridgeEventKind, ProviderKind, ThreadStatus};

use crate::codex_transport::CodexJsonTransport;
use crate::incremental_text::merge_incremental_text;

use super::patch_diff::resolve_apply_patch_to_unified_diff;
use super::rpc::CodexThreadStatus;
use super::timeline::{
    build_timeline_event_envelope, current_timestamp_string, map_codex_status_to_lifecycle_state,
    map_thread_status, normalize_custom_tool_output, payload_contains_hidden_message,
    value_to_text,
};
use super::{
    is_file_change_custom_tool, is_file_change_text, native_thread_id_for_provider,
    provider_thread_id,
};

#[derive(Debug)]
pub struct CodexNotificationStream {
    transport: CodexJsonTransport,
    normalizer: CodexNotificationNormalizer,
}

#[derive(Debug, Default)]
pub(crate) struct CodexNotificationNormalizer {
    active_turn_id_by_thread: HashMap<String, String>,
    items_by_event_id: HashMap<String, Value>,
    message_event_ids_with_delta: HashSet<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
struct CodexDeltaNotification {
    delta: String,
    #[serde(rename = "itemId")]
    item_id: String,
    #[serde(rename = "threadId")]
    thread_id: String,
    #[serde(rename = "turnId")]
    turn_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
struct CodexThreadStatusChangedNotification {
    #[serde(rename = "threadId")]
    thread_id: String,
    status: CodexThreadStatus,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
struct CodexThreadRealtimeItemAddedNotification {
    #[serde(rename = "threadId")]
    thread_id: String,
    item: Value,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
struct CodexItemLifecycleNotification {
    #[serde(rename = "threadId")]
    thread_id: String,
    #[serde(rename = "turnId", default)]
    turn_id: Option<String>,
    item: Value,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
struct CodexTurnNotification {
    #[serde(rename = "threadId")]
    thread_id: String,
    turn: CodexTurnHandle,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
struct CodexTurnHandle {
    id: String,
    status: Option<String>,
}

impl CodexNotificationStream {
    pub fn start(command: &str, args: &[String], endpoint: Option<&str>) -> Result<Self, String> {
        Ok(Self {
            transport: CodexJsonTransport::start(command, args, endpoint)?,
            normalizer: CodexNotificationNormalizer::default(),
        })
    }

    pub fn resume_thread(&mut self, thread_id: &str) -> Result<(), String> {
        let native_thread_id =
            native_thread_id_for_provider(thread_id, ProviderKind::Codex).unwrap_or(thread_id);
        self.transport
            .request(
                "thread/resume",
                json!({
                    "threadId": native_thread_id,
                }),
            )
            .map(|_| ())
    }

    pub fn unsubscribe_thread(&mut self, thread_id: &str) -> Result<(), String> {
        let native_thread_id =
            native_thread_id_for_provider(thread_id, ProviderKind::Codex).unwrap_or(thread_id);
        self.transport
            .request(
                "thread/unsubscribe",
                json!({
                    "threadId": native_thread_id,
                }),
            )
            .map(|_| ())
    }

    pub fn next_event(&mut self) -> Result<Option<BridgeEventEnvelope<Value>>, String> {
        loop {
            let Some(message) = self.transport.next_message("notification")? else {
                return Ok(None);
            };

            if message.get("id").is_some() {
                continue;
            }

            let Some(method) = message.get("method").and_then(Value::as_str) else {
                continue;
            };
            let params = message.get("params").cloned().unwrap_or(Value::Null);

            if let Some(event) = self.normalizer.normalize(method, &params) {
                return Ok(Some(event));
            }
        }
    }
}

impl CodexNotificationNormalizer {
    pub(crate) fn normalize(
        &mut self,
        method: &str,
        params: &Value,
    ) -> Option<BridgeEventEnvelope<Value>> {
        match method {
            "turn/started" => {
                let notification: CodexTurnNotification =
                    serde_json::from_value(params.clone()).ok()?;
                let thread_id = normalize_codex_notification_thread_id(&notification.thread_id);
                self.active_turn_id_by_thread
                    .insert(thread_id, notification.turn.id);
                None
            }
            "turn/completed" => {
                let notification: CodexTurnNotification =
                    serde_json::from_value(params.clone()).ok()?;
                let thread_id = normalize_codex_notification_thread_id(&notification.thread_id);
                if self
                    .active_turn_id_by_thread
                    .get(&thread_id)
                    .is_some_and(|turn_id| turn_id == &notification.turn.id)
                {
                    self.active_turn_id_by_thread.remove(&thread_id);
                }
                let occurred_at = current_timestamp_string();
                Some(BridgeEventEnvelope::new(
                    format!("{thread_id}-status-{occurred_at}"),
                    thread_id,
                    BridgeEventKind::ThreadStatusChanged,
                    occurred_at,
                    json!({
                        "status": map_codex_turn_status_to_wire_status(notification.turn.status.as_deref()),
                        "reason": "turn_completed",
                    }),
                ))
            }
            "thread/status/changed" => {
                let notification: CodexThreadStatusChangedNotification =
                    serde_json::from_value(params.clone()).ok()?;
                let thread_id = normalize_codex_notification_thread_id(&notification.thread_id);
                let occurred_at = current_timestamp_string();
                Some(BridgeEventEnvelope::new(
                    format!("{thread_id}-status-{occurred_at}"),
                    thread_id,
                    BridgeEventKind::ThreadStatusChanged,
                    occurred_at,
                    json!({
                        "status": match map_thread_status(&map_codex_status_to_lifecycle_state(&notification.status.kind)) {
                            ThreadStatus::Idle => "idle",
                            ThreadStatus::Running => "running",
                            ThreadStatus::Completed => "completed",
                            ThreadStatus::Interrupted => "interrupted",
                            ThreadStatus::Failed => "failed",
                        },
                        "reason": "upstream_notification",
                    }),
                ))
            }
            "thread/realtime/itemAdded" => {
                let notification: CodexThreadRealtimeItemAddedNotification =
                    serde_json::from_value(params.clone()).ok()?;
                self.normalize_item_added(notification)
            }
            "item/started" => {
                let notification: CodexItemLifecycleNotification =
                    serde_json::from_value(params.clone()).ok()?;
                self.normalize_item_lifecycle(notification, ItemLifecyclePhase::Started)
            }
            "item/completed" => {
                let notification: CodexItemLifecycleNotification =
                    serde_json::from_value(params.clone()).ok()?;
                self.normalize_item_lifecycle(notification, ItemLifecyclePhase::Completed)
            }
            _ => parse_item_delta_method(method)
                .and_then(|(item_type, target)| self.normalize_delta(params, item_type, target)),
        }
    }

    fn normalize_item_added(
        &mut self,
        notification: CodexThreadRealtimeItemAddedNotification,
    ) -> Option<BridgeEventEnvelope<Value>> {
        self.normalize_item_payload(
            normalize_codex_notification_thread_id(&notification.thread_id),
            None,
            notification.item,
            ItemLifecyclePhase::Added,
        )
    }

    fn normalize_item_lifecycle(
        &mut self,
        notification: CodexItemLifecycleNotification,
        phase: ItemLifecyclePhase,
    ) -> Option<BridgeEventEnvelope<Value>> {
        self.normalize_item_payload(
            normalize_codex_notification_thread_id(&notification.thread_id),
            notification.turn_id,
            notification.item,
            phase,
        )
    }

    fn normalize_item_payload(
        &mut self,
        thread_id: String,
        turn_id: Option<String>,
        item: Value,
        phase: ItemLifecyclePhase,
    ) -> Option<BridgeEventEnvelope<Value>> {
        let item_id = item.get("id").and_then(Value::as_str)?.to_string();
        let event_id = turn_id
            .map(|turn_id| format!("{turn_id}-{item_id}"))
            .unwrap_or_else(|| self.event_id_for_item(&thread_id, &item_id));
        self.items_by_event_id
            .insert(event_id.clone(), item.clone());

        if is_message_item(&item) {
            let should_publish_message_fallback = phase == ItemLifecyclePhase::Completed
                && !self.message_event_ids_with_delta.contains(&event_id);
            if !should_publish_message_fallback {
                return None;
            }
        }

        let (kind, payload) = normalize_realtime_item_payload(&item)?;
        if !should_publish_live_payload(kind, &payload) {
            return None;
        }
        Some(build_timeline_event_envelope(
            event_id,
            thread_id,
            kind,
            current_timestamp_string(),
            payload,
        ))
    }

    fn normalize_delta(
        &mut self,
        params: &Value,
        item_type: &str,
        target: DeltaTarget,
    ) -> Option<BridgeEventEnvelope<Value>> {
        let notification: CodexDeltaNotification = serde_json::from_value(params.clone()).ok()?;
        let thread_id = normalize_codex_notification_thread_id(&notification.thread_id);
        let event_id = format!("{}-{}", notification.turn_id, notification.item_id);
        let canonical_item_type = canonicalize_codex_item_type(item_type);
        let payload = self
            .items_by_event_id
            .entry(event_id.clone())
            .or_insert_with(|| {
                synthesize_realtime_item(canonical_item_type, &notification.item_id, target)
            });

        apply_delta_to_item_payload(payload, &notification.delta, target);
        if matches!(canonical_item_type, "agentMessage" | "userMessage") {
            self.message_event_ids_with_delta.insert(event_id.clone());
        }

        let (kind, normalized_payload) = match (canonical_item_type, target) {
            ("userMessage", DeltaTarget::Text) => (
                BridgeEventKind::MessageDelta,
                json!({
                    "id": notification.item_id,
                    "type": "userMessage",
                    "role": "user",
                    "delta": notification.delta,
                    "replace": false,
                }),
            ),
            ("agentMessage", DeltaTarget::Text) => (
                BridgeEventKind::MessageDelta,
                json!({
                    "id": notification.item_id,
                    "type": "agentMessage",
                    "role": "assistant",
                    "delta": notification.delta,
                    "replace": false,
                }),
            ),
            ("plan", DeltaTarget::Text) => (
                BridgeEventKind::PlanDelta,
                json!({
                    "id": notification.item_id,
                    "type": "plan",
                    "delta": notification.delta,
                    "replace": false,
                }),
            ),
            _ => normalize_realtime_item_payload(payload)?,
        };
        if !should_publish_live_payload(kind, &normalized_payload) {
            return None;
        }
        Some(build_timeline_event_envelope(
            event_id,
            thread_id,
            kind,
            current_timestamp_string(),
            normalized_payload,
        ))
    }

    fn event_id_for_item(&self, thread_id: &str, item_id: &str) -> String {
        self.active_turn_id_by_thread
            .get(thread_id)
            .map(|turn_id| format!("{turn_id}-{item_id}"))
            .unwrap_or_else(|| item_id.to_string())
    }
}

fn map_codex_turn_status_to_wire_status(status: Option<&str>) -> &'static str {
    match status.unwrap_or("completed") {
        "interrupted" => "interrupted",
        "failed" => "failed",
        "inProgress" => "running",
        _ => "completed",
    }
}

fn normalize_codex_notification_thread_id(thread_id: &str) -> String {
    let native_thread_id =
        native_thread_id_for_provider(thread_id, ProviderKind::Codex).unwrap_or(thread_id);
    provider_thread_id(ProviderKind::Codex, native_thread_id)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum DeltaTarget {
    Text,
    CommandOutput,
    FileDiff,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ItemLifecyclePhase {
    Added,
    Started,
    Completed,
}

pub(super) fn normalize_realtime_item_payload(item: &Value) -> Option<(BridgeEventKind, Value)> {
    normalize_codex_item_payload(item, None)
}

pub(crate) fn should_publish_live_payload(kind: BridgeEventKind, payload: &Value) -> bool {
    match kind {
        BridgeEventKind::MessageDelta | BridgeEventKind::PlanDelta => {
            if kind == BridgeEventKind::MessageDelta && payload_contains_hidden_message(payload) {
                return false;
            }
            payload
                .get("text")
                .or_else(|| payload.get("delta"))
                .and_then(Value::as_str)
                .is_some_and(|text| !text.trim().is_empty())
                || payload
                    .get("content")
                    .and_then(Value::as_array)
                    .is_some_and(|content| !content.is_empty())
        }
        BridgeEventKind::CommandDelta => {
            payload
                .get("output")
                .or_else(|| payload.get("aggregatedOutput"))
                .or_else(|| payload.get("command"))
                .and_then(Value::as_str)
                .is_some_and(|text| !text.trim().is_empty())
                || payload.get("arguments").is_some()
        }
        BridgeEventKind::FileChange => {
            payload
                .get("resolved_unified_diff")
                .or_else(|| payload.get("output"))
                .or_else(|| payload.get("change"))
                .and_then(Value::as_str)
                .is_some_and(|text| !text.trim().is_empty())
                || payload
                    .get("changes")
                    .and_then(Value::as_array)
                    .is_some_and(|changes| !changes.is_empty())
        }
        _ => true,
    }
}

pub(crate) fn normalize_codex_item_payload(
    item: &Value,
    workspace_path: Option<&str>,
) -> Option<(BridgeEventKind, Value)> {
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
        "plan" => Some((
            BridgeEventKind::PlanDelta,
            json!({
                "id": item.get("id").and_then(Value::as_str).unwrap_or_default(),
                "type": "plan",
                "text": item.get("text").and_then(Value::as_str).unwrap_or_default(),
            }),
        )),
        "commandExecution" => {
            let mut payload = item.clone();
            if let Some(output) = item.get("aggregatedOutput").and_then(Value::as_str)
                && let Some(object) = payload.as_object_mut()
            {
                object.insert("output".to_string(), Value::String(output.to_string()));
            }
            Some((BridgeEventKind::CommandDelta, payload))
        }
        "fileChange" => Some((BridgeEventKind::FileChange, item.clone())),
        "functionCall" | "customToolCall" => {
            normalize_codex_tool_invocation_item(item, workspace_path)
        }
        "functionCallOutput" | "customToolCallOutput" => normalize_codex_tool_output_item(item),
        _ => None,
    }
}

fn normalize_message_item(item: &Value, role: &str) -> Value {
    let mut payload = json!({
        "id": item.get("id").and_then(Value::as_str).unwrap_or_default(),
        "type": if role == "user" {
            "userMessage"
        } else {
            "agentMessage"
        },
        "role": role,
        "text": extract_codex_message_text(item),
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

fn extract_codex_message_text(item: &Value) -> String {
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

fn canonicalize_codex_item_type(item_type: &str) -> &str {
    match item_type {
        "function_call" => "functionCall",
        "function_call_output" => "functionCallOutput",
        "custom_tool_call" => "customToolCall",
        "custom_tool_call_output" => "customToolCallOutput",
        other => other,
    }
}

fn normalize_codex_tool_invocation_item(
    item: &Value,
    workspace_path: Option<&str>,
) -> Option<(BridgeEventKind, Value)> {
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
                object.insert("change".to_string(), Value::String(input_text.clone()));
            }
            if !object.contains_key("resolved_unified_diff")
                && let Some(resolved_diff) =
                    resolve_apply_patch_to_unified_diff(&input_text, workspace_path)
            {
                object.insert(
                    "resolved_unified_diff".to_string(),
                    Value::String(resolved_diff),
                );
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
        payload,
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
        payload,
    ))
}

fn parse_item_delta_method(method: &str) -> Option<(&str, DeltaTarget)> {
    let mut parts = method.split('/');
    match (parts.next(), parts.next(), parts.next(), parts.next()) {
        (Some("item"), Some(item_type), Some("delta"), None) => Some((
            item_type,
            match canonicalize_codex_item_type(item_type) {
                "agentMessage" | "userMessage" | "plan" => DeltaTarget::Text,
                "fileChange" => DeltaTarget::FileDiff,
                _ => DeltaTarget::Text,
            },
        )),
        (Some("item"), Some(item_type), Some("outputDelta"), None) => Some((
            item_type,
            match canonicalize_codex_item_type(item_type) {
                "fileChange" => DeltaTarget::FileDiff,
                _ => DeltaTarget::CommandOutput,
            },
        )),
        _ => None,
    }
}

fn synthesize_realtime_item(item_type: &str, item_id: &str, target: DeltaTarget) -> Value {
    match target {
        DeltaTarget::Text => json!({
            "id": item_id,
            "type": item_type,
            "text": "",
        }),
        DeltaTarget::CommandOutput => json!({
            "id": item_id,
            "type": item_type,
            "output": "",
            "aggregatedOutput": "",
            "status": "inProgress",
            "command": "",
            "cwd": "",
            "commandActions": [],
        }),
        DeltaTarget::FileDiff => json!({
            "id": item_id,
            "type": item_type,
            "resolved_unified_diff": "",
            "status": "inProgress",
            "changes": [],
        }),
    }
}

fn apply_delta_to_item_payload(item: &mut Value, delta: &str, target: DeltaTarget) {
    let Some(object) = item.as_object_mut() else {
        return;
    };

    match target {
        DeltaTarget::Text => {
            let next_text = merge_incremental_text(
                object
                    .get("text")
                    .and_then(Value::as_str)
                    .unwrap_or_default(),
                delta,
                false,
            );
            object.insert("text".to_string(), Value::String(next_text));
        }
        DeltaTarget::CommandOutput => {
            let next_output = merge_incremental_text(
                object
                    .get("aggregatedOutput")
                    .or_else(|| object.get("output"))
                    .and_then(Value::as_str)
                    .unwrap_or_default(),
                delta,
                false,
            );
            object.insert(
                "aggregatedOutput".to_string(),
                Value::String(next_output.clone()),
            );
            object.insert("output".to_string(), Value::String(next_output));
        }
        DeltaTarget::FileDiff => {
            let next_diff = merge_incremental_text(
                object
                    .get("resolved_unified_diff")
                    .or_else(|| object.get("output"))
                    .and_then(Value::as_str)
                    .unwrap_or_default(),
                delta,
                false,
            );
            object.insert(
                "resolved_unified_diff".to_string(),
                Value::String(next_diff.clone()),
            );
            object.insert("output".to_string(), Value::String(next_diff));
        }
    }
}

fn is_message_item(item: &Value) -> bool {
    matches!(
        canonicalize_codex_item_type(item.get("type").and_then(Value::as_str).unwrap_or_default()),
        "agentMessage" | "userMessage"
    )
}

#[cfg(test)]
mod tests {
    use serde_json::json;
    use shared_contracts::{BridgeEventKind, ProviderKind};

    use super::{
        CodexNotificationNormalizer, normalize_codex_item_payload,
        normalize_codex_notification_thread_id, should_publish_live_payload,
    };
    use crate::thread_api::provider_thread_id;

    #[test]
    fn codex_notification_thread_ids_normalize_to_provider_thread_ids() {
        assert_eq!(
            normalize_codex_notification_thread_id("thread-123"),
            provider_thread_id(ProviderKind::Codex, "thread-123")
        );
        assert_eq!(
            normalize_codex_notification_thread_id("codex:thread-123"),
            provider_thread_id(ProviderKind::Codex, "thread-123")
        );
    }

    #[test]
    fn custom_tool_apply_patch_is_classified_as_file_change() {
        let (kind, payload) = normalize_codex_item_payload(
            &json!({
                "id": "item-1",
                "type": "custom_tool_call",
                "name": "apply_patch",
                "input": "*** Begin Patch\n*** Add File: note.txt\n@@\n+hello\n*** End Patch\n"
            }),
            Some("/tmp"),
        )
        .expect("payload should normalize");

        assert_eq!(kind, BridgeEventKind::FileChange);
        assert!(payload.get("change").is_some());
    }

    #[test]
    fn delta_notifications_publish_raw_text_deltas_and_skip_hidden_messages() {
        let mut normalizer = CodexNotificationNormalizer::default();
        let _ = normalizer.normalize(
            "turn/started",
            &json!({
                "threadId": "thread-123",
                "turn": {"id": "turn-1", "items": []}
            }),
        );

        let first = normalizer
            .normalize(
                "item/agentMessage/delta",
                &json!({
                    "threadId": "thread-123",
                    "turnId": "turn-1",
                    "itemId": "item-1",
                    "delta": "Hello"
                }),
            )
            .expect("first delta should publish");
        assert_eq!(first.thread_id, "codex:thread-123");
        assert_eq!(
            first.payload.get("delta").and_then(|v| v.as_str()),
            Some("Hello")
        );
        assert_eq!(
            first.payload.get("replace").and_then(|v| v.as_bool()),
            Some(false)
        );
        assert!(should_publish_live_payload(first.kind, &first.payload));

        let hidden = normalize_codex_item_payload(
            &json!({
                "id": "item-2",
                "type": "agentMessage",
                "text": "# AGENTS.md instructions for /repo"
            }),
            None,
        )
        .expect("hidden payload still normalizes");
        assert!(!should_publish_live_payload(hidden.0, &hidden.1));
    }

    #[test]
    fn thread_status_notifications_publish_provider_thread_ids() {
        let mut normalizer = CodexNotificationNormalizer::default();

        let event = normalizer
            .normalize(
                "thread/status/changed",
                &json!({
                    "threadId": "thread-456",
                    "status": {"type": "active"}
                }),
            )
            .expect("status notification should publish");

        assert_eq!(event.thread_id, "codex:thread-456");
        assert_eq!(event.kind, BridgeEventKind::ThreadStatusChanged);
        assert_eq!(event.payload["status"], "running");
    }

    #[test]
    fn turn_completed_notifications_publish_terminal_thread_status() {
        let mut normalizer = CodexNotificationNormalizer::default();
        let _ = normalizer.normalize(
            "turn/started",
            &json!({
                "threadId": "thread-789",
                "turn": {"id": "turn-1", "status": "inProgress"}
            }),
        );

        let event = normalizer
            .normalize(
                "turn/completed",
                &json!({
                    "threadId": "thread-789",
                    "turn": {"id": "turn-1", "status": "completed"}
                }),
            )
            .expect("turn/completed should publish");

        assert_eq!(event.thread_id, "codex:thread-789");
        assert_eq!(event.kind, BridgeEventKind::ThreadStatusChanged);
        assert_eq!(event.payload["status"], "completed");
        assert_eq!(event.payload["reason"], "turn_completed");
    }
}
