use std::collections::HashMap;

use serde::Deserialize;
use serde_json::{Value, json};
use shared_contracts::{BridgeEventEnvelope, BridgeEventKind, ProviderKind};

use crate::codex_transport::CodexJsonTransport;
use crate::incremental_text::merge_incremental_text;
use crate::server::timeline_events::{build_timeline_event_envelope, current_timestamp_string};
use crate::thread_identity::{native_thread_id_for_provider, provider_thread_id};

use super::super::mapping::{normalize_codex_item_payload, payload_contains_hidden_message};

#[derive(Debug)]
pub struct CodexNotificationStream {
    transport: CodexJsonTransport,
    normalizer: CodexNotificationNormalizer,
}

#[derive(Debug, Default)]
pub(crate) struct CodexNotificationNormalizer {
    active_turn_id_by_thread: HashMap<String, String>,
    items_by_event_id: HashMap<String, Value>,
    item_event_id_by_thread_item: HashMap<(String, String), String>,
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

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
struct CodexThreadStatus {
    #[serde(rename = "type")]
    kind: String,
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

    #[allow(dead_code)]
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
                        "status": map_codex_status_to_thread_status_wire(&notification.status.kind),
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
        let event_id = self.resolve_item_event_id(&thread_id, turn_id.as_deref(), &item_id);
        self.items_by_event_id
            .insert(event_id.clone(), item.clone());

        if is_message_item(&item) && phase != ItemLifecyclePhase::Completed {
            return None;
        }

        let (kind, payload) = normalize_codex_item_payload(&item)?;
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
        let event_id = self.resolve_item_event_id(
            &thread_id,
            Some(notification.turn_id.as_str()),
            &notification.item_id,
        );
        let canonical_item_type = canonicalize_codex_item_type(item_type);
        let payload = self
            .items_by_event_id
            .entry(event_id.clone())
            .or_insert_with(|| {
                synthesize_realtime_item(canonical_item_type, &notification.item_id, target)
            });

        apply_delta_to_item_payload(payload, &notification.delta, target);

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
            _ => normalize_codex_item_payload(payload)?,
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

    fn resolve_item_event_id(
        &mut self,
        thread_id: &str,
        turn_id: Option<&str>,
        item_id: &str,
    ) -> String {
        let key = (thread_id.to_string(), item_id.to_string());
        if let Some(turn_id) = turn_id.filter(|value| !value.trim().is_empty()) {
            let event_id = format!("{turn_id}-{item_id}");
            self.item_event_id_by_thread_item
                .insert(key, event_id.clone());
            return event_id;
        }

        if let Some(existing) = self.item_event_id_by_thread_item.get(&key) {
            return existing.clone();
        }

        if let Some(turn_id) = self.active_turn_id_by_thread.get(thread_id) {
            let event_id = format!("{turn_id}-{item_id}");
            self.item_event_id_by_thread_item
                .insert(key, event_id.clone());
            return event_id;
        }

        item_id.to_string()
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

fn map_codex_status_to_thread_status_wire(status_kind: &str) -> &'static str {
    match status_kind {
        "active" => "running",
        "systemError" => "failed",
        _ => "idle",
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

fn canonicalize_codex_item_type(item_type: &str) -> &str {
    match item_type {
        "function_call" => "functionCall",
        "function_call_output" => "functionCallOutput",
        "custom_tool_call" => "customToolCall",
        "custom_tool_call_output" => "customToolCallOutput",
        "web_search_call" => "webSearch",
        other => other,
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
    use super::*;
    use crate::server::gateway::legacy_archive::load_archive_timeline_entries_for_session_path;
    use crate::server::projection::ProjectionStore;
    use shared_contracts::{
        ProviderKind, ThreadClientKind, ThreadSnapshotDto, ThreadStatus, ThreadSummaryDto,
    };
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[derive(Debug, Deserialize)]
    struct RawNotificationFixture {
        method: String,
        params: Value,
    }

    #[test]
    fn act_turn_fixture_replays_raw_notifications_into_stable_event_order() {
        let events = replay_fixture("act_turn_notifications.jsonl");

        assert_eq!(events.len(), 6);
        assert_eq!(events[0].kind, BridgeEventKind::ThreadStatusChanged);
        assert_eq!(events[1].kind, BridgeEventKind::MessageDelta);
        assert_eq!(events[2].kind, BridgeEventKind::MessageDelta);
        assert_eq!(events[3].kind, BridgeEventKind::MessageDelta);
        assert_eq!(events[4].kind, BridgeEventKind::MessageDelta);
        assert_eq!(events[5].kind, BridgeEventKind::ThreadStatusChanged);

        assert_eq!(events[1].event_id, "turn-act-1-item-user-1");
        assert_eq!(events[2].event_id, "turn-act-1-item-user-1");
        assert_eq!(events[3].event_id, "turn-act-1-item-assistant-1");
        assert_eq!(events[4].event_id, "turn-act-1-item-assistant-1");
        assert!(
            events
                .iter()
                .all(|event| event.thread_id == "codex:thread-act")
        );
    }

    #[tokio::test]
    async fn act_turn_fixture_materializes_user_and_assistant_history_without_loss() {
        let events = replay_fixture("act_turn_notifications.jsonl");
        let store = store_for_thread("codex:thread-act").await;
        for event in &events {
            store.apply_live_event(event).await;
        }

        let snapshot = store
            .snapshot("codex:thread-act")
            .await
            .expect("fixture should materialize a snapshot");
        assert_eq!(snapshot.thread.status, ThreadStatus::Completed);

        let message_entries: Vec<_> = snapshot
            .entries
            .iter()
            .filter(|entry| entry.kind == BridgeEventKind::MessageDelta)
            .collect();
        assert_eq!(message_entries.len(), 2);
        assert_eq!(message_entries[0].payload["role"], "user");
        assert_eq!(
            message_entries[0].payload["text"],
            "Why can't you run dart formatter?"
        );
        assert_eq!(message_entries[1].payload["role"], "assistant");
        assert_eq!(
            message_entries[1].payload["text"],
            "Because the formatter is unavailable."
        );
    }

    #[tokio::test]
    async fn plan_turn_fixture_materializes_plan_snapshot_from_raw_notifications() {
        let events = replay_fixture("plan_turn_notifications.jsonl");
        let store = store_for_thread("codex:thread-plan").await;
        for event in &events {
            store.apply_live_event(event).await;
        }

        let snapshot = store
            .snapshot("codex:thread-plan")
            .await
            .expect("fixture should materialize a snapshot");
        assert_eq!(snapshot.thread.status, ThreadStatus::Completed);

        let plan_entry = snapshot
            .entries
            .iter()
            .find(|entry| entry.kind == BridgeEventKind::PlanDelta)
            .expect("plan entry should exist");
        assert_eq!(
            plan_entry.payload["text"],
            "1 out of 2 tasks completed\n1. Inspect bridge payload\n2. Add Flutter card"
        );
    }

    #[tokio::test]
    async fn tool_turn_fixture_materializes_command_and_file_change_history() {
        let events = replay_fixture("tool_turn_notifications.jsonl");
        let store = store_for_thread("codex:thread-tools").await;
        for event in &events {
            store.apply_live_event(event).await;
        }

        let snapshot = store
            .snapshot("codex:thread-tools")
            .await
            .expect("fixture should materialize a snapshot");
        assert_eq!(snapshot.thread.status, ThreadStatus::Completed);

        let command_entry = snapshot
            .entries
            .iter()
            .find(|entry| entry.event_id == "turn-tools-1-tool-search")
            .expect("command entry should exist");
        assert_eq!(command_entry.kind, BridgeEventKind::CommandDelta);
        assert_eq!(command_entry.payload["command"], "exec_command");
        assert_eq!(command_entry.payload["output"], "README.md:1: NEEDLE");

        let file_change_entry = snapshot
            .entries
            .iter()
            .find(|entry| entry.event_id == "turn-tools-1-tool-edit")
            .expect("file change entry should exist");
        assert_eq!(file_change_entry.kind, BridgeEventKind::FileChange);
        assert_eq!(file_change_entry.payload["path"], "tmp/probe.txt");

        let assistant_entry = snapshot
            .entries
            .iter()
            .find(|entry| entry.event_id == "turn-tools-1-item-assistant-1")
            .expect("assistant entry should exist");
        assert_eq!(assistant_entry.kind, BridgeEventKind::MessageDelta);
        assert_eq!(assistant_entry.payload["text"], "Needle applied.");
    }

    #[test]
    fn late_message_completion_without_turn_id_reuses_existing_event_id() {
        let events = replay_inline_notifications(
            r#"
{"jsonrpc":"2.0","method":"turn/started","params":{"threadId":"thread-late","turn":{"id":"turn-late-1","status":"inProgress"}}}
{"jsonrpc":"2.0","method":"thread/status/changed","params":{"threadId":"thread-late","status":{"type":"active"}}}
{"jsonrpc":"2.0","method":"item/agentMessage/delta","params":{"threadId":"thread-late","turnId":"turn-late-1","itemId":"item-assistant-1","delta":"Hello"}}
{"jsonrpc":"2.0","method":"turn/completed","params":{"threadId":"thread-late","turn":{"id":"turn-late-1","status":"completed"}}}
{"jsonrpc":"2.0","method":"item/completed","params":{"threadId":"thread-late","item":{"id":"item-assistant-1","type":"agentMessage","text":"Hello."}}}
"#,
        );

        let assistant_events: Vec<_> = events
            .iter()
            .filter(|event| event.kind == BridgeEventKind::MessageDelta)
            .collect();
        assert_eq!(assistant_events.len(), 2);
        assert_eq!(assistant_events[0].event_id, "turn-late-1-item-assistant-1");
        assert_eq!(assistant_events[1].event_id, "turn-late-1-item-assistant-1");
        assert_eq!(assistant_events[1].payload["text"], "Hello.");
    }

    #[tokio::test]
    async fn late_message_completion_without_turn_id_updates_existing_assistant_entry() {
        let events = replay_inline_notifications(
            r#"
{"jsonrpc":"2.0","method":"turn/started","params":{"threadId":"thread-late","turn":{"id":"turn-late-1","status":"inProgress"}}}
{"jsonrpc":"2.0","method":"thread/status/changed","params":{"threadId":"thread-late","status":{"type":"active"}}}
{"jsonrpc":"2.0","method":"item/agentMessage/delta","params":{"threadId":"thread-late","turnId":"turn-late-1","itemId":"item-assistant-1","delta":"Hello"}}
{"jsonrpc":"2.0","method":"turn/completed","params":{"threadId":"thread-late","turn":{"id":"turn-late-1","status":"completed"}}}
{"jsonrpc":"2.0","method":"item/completed","params":{"threadId":"thread-late","item":{"id":"item-assistant-1","type":"agentMessage","text":"Hello."}}}
"#,
        );
        let store = store_for_thread("codex:thread-late").await;
        for event in &events {
            store.apply_live_event(event).await;
        }

        let snapshot = store
            .snapshot("codex:thread-late")
            .await
            .expect("fixture should materialize a snapshot");
        assert_eq!(snapshot.thread.status, ThreadStatus::Completed);

        let assistant_entries: Vec<_> = snapshot
            .entries
            .iter()
            .filter(|entry| {
                entry.kind == BridgeEventKind::MessageDelta
                    && entry
                        .payload
                        .get("role")
                        .and_then(Value::as_str)
                        .is_some_and(|role| role == "assistant")
            })
            .collect();
        assert_eq!(assistant_entries.len(), 1);
        assert_eq!(
            assistant_entries[0].event_id,
            "turn-late-1-item-assistant-1"
        );
        assert_eq!(assistant_entries[0].payload["text"], "Hello.");
    }

    #[tokio::test]
    async fn live_notifications_converge_with_rollout_truth_for_completed_turn() {
        let native_thread_id = "thread-parity";
        let thread_id = format!("codex:{native_thread_id}");
        let live_events = replay_inline_notifications(
            r#"
{"jsonrpc":"2.0","method":"turn/started","params":{"threadId":"thread-parity","turn":{"id":"turn-parity-1","status":"inProgress"}}}
{"jsonrpc":"2.0","method":"thread/status/changed","params":{"threadId":"thread-parity","status":{"type":"active"}}}
{"jsonrpc":"2.0","method":"item/userMessage/delta","params":{"threadId":"thread-parity","turnId":"turn-parity-1","itemId":"item-user-1","delta":"Hello parity?"}}
{"jsonrpc":"2.0","method":"item/agentMessage/delta","params":{"threadId":"thread-parity","turnId":"turn-parity-1","itemId":"item-assistant-1","delta":"Parity answer from assistant."}}
{"jsonrpc":"2.0","method":"item/completed","params":{"threadId":"thread-parity","item":{"id":"item-assistant-1","type":"agentMessage","text":"Parity answer from assistant."}}}
{"jsonrpc":"2.0","method":"turn/completed","params":{"threadId":"thread-parity","turn":{"id":"turn-parity-1","status":"completed"}}}
"#,
        );
        let live_store = store_for_thread(&thread_id).await;
        for event in &live_events {
            live_store.apply_live_event(event).await;
        }
        let live_snapshot = live_store
            .snapshot(&thread_id)
            .await
            .expect("live fixture should materialize a snapshot");

        let archive_events = replay_archive_rollout(
            native_thread_id,
            r#"
{"timestamp":"2026-04-06T09:00:00.000Z","type":"session_meta","payload":{"id":"thread-parity","timestamp":"2026-04-06T09:00:00.000Z","cwd":"/tmp/codex-fixture","source":"cli","git":{"branch":"main","repository_url":"git@github.com:openai/codex-mobile-companion.git"}}}
{"timestamp":"2026-04-06T09:00:01.000Z","type":"event_msg","payload":{"type":"task_started"}}
{"timestamp":"2026-04-06T09:00:02.000Z","type":"event_msg","payload":{"type":"user_message","message":"Hello parity?"}}
{"timestamp":"2026-04-06T09:00:03.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Parity answer from assistant."}],"phase":"final_answer"}}
{"timestamp":"2026-04-06T09:00:04.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-parity-1","last_agent_message":"Parity answer from assistant."}}
"#,
        );
        let archive_store = store_for_thread(&thread_id).await;
        for event in &archive_events {
            archive_store.apply_live_event(event).await;
        }
        let archive_snapshot = archive_store
            .snapshot(&thread_id)
            .await
            .expect("archive fixture should materialize a snapshot");

        assert_eq!(live_snapshot.thread.status, ThreadStatus::Completed);
        assert_eq!(archive_snapshot.thread.status, ThreadStatus::Completed);
        assert_eq!(
            snapshot_message_text(&live_snapshot, "user").as_deref(),
            Some("Hello parity?")
        );
        assert_eq!(
            snapshot_message_text(&archive_snapshot, "user").as_deref(),
            Some("Hello parity?")
        );
        assert_eq!(
            snapshot_message_text(&live_snapshot, "assistant").as_deref(),
            snapshot_message_text(&archive_snapshot, "assistant").as_deref()
        );
        assert_eq!(
            snapshot_message_text(&live_snapshot, "assistant").as_deref(),
            Some("Parity answer from assistant.")
        );
    }

    fn replay_fixture(path: &str) -> Vec<BridgeEventEnvelope<Value>> {
        let raw = match path {
            "act_turn_notifications.jsonl" => {
                include_str!("test_fixtures/act_turn_notifications.jsonl")
            }
            "plan_turn_notifications.jsonl" => {
                include_str!("test_fixtures/plan_turn_notifications.jsonl")
            }
            "tool_turn_notifications.jsonl" => {
                include_str!("test_fixtures/tool_turn_notifications.jsonl")
            }
            _ => panic!("unknown codex notification fixture: {path}"),
        };
        replay_raw_notifications(raw)
    }

    fn replay_inline_notifications(raw: &str) -> Vec<BridgeEventEnvelope<Value>> {
        replay_raw_notifications(raw)
    }

    fn replay_archive_rollout(
        native_thread_id: &str,
        raw_rollout: &str,
    ) -> Vec<BridgeEventEnvelope<Value>> {
        let temp_root = std::env::temp_dir().join(format!(
            "bridge-core-rollout-parity-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .expect("system clock should be after unix epoch")
                .as_nanos()
        ));
        fs::create_dir_all(&temp_root).expect("temp rollout directory should be created");
        let rollout_path = temp_root.join(format!(
            "rollout-2026-04-06T09-00-00-{native_thread_id}.jsonl"
        ));
        fs::write(&rollout_path, raw_rollout.trim())
            .expect("test rollout fixture should be written");

        let timeline_entries =
            load_archive_timeline_entries_for_session_path(native_thread_id, &rollout_path);
        let _ = fs::remove_dir_all(&temp_root);

        let thread_id = format!("codex:{native_thread_id}");
        timeline_entries
            .into_iter()
            .map(|entry| {
                BridgeEventEnvelope::new(
                    entry.event_id,
                    thread_id.clone(),
                    entry.kind,
                    entry.occurred_at,
                    entry.payload,
                )
            })
            .collect()
    }

    fn replay_raw_notifications(raw: &str) -> Vec<BridgeEventEnvelope<Value>> {
        let notifications: Vec<RawNotificationFixture> = raw
            .lines()
            .filter(|line| !line.trim().is_empty())
            .map(|line| {
                serde_json::from_str::<RawNotificationFixture>(line)
                    .expect("fixture notification should decode")
            })
            .collect();
        let mut normalizer = CodexNotificationNormalizer::default();

        notifications
            .into_iter()
            .filter_map(|notification| {
                normalizer.normalize(&notification.method, &notification.params)
            })
            .collect()
    }

    fn snapshot_message_text(snapshot: &ThreadSnapshotDto, role: &str) -> Option<String> {
        snapshot
            .entries
            .iter()
            .find(|entry| {
                entry.kind == BridgeEventKind::MessageDelta
                    && entry
                        .payload
                        .get("role")
                        .and_then(Value::as_str)
                        .is_some_and(|entry_role| entry_role == role)
            })
            .and_then(|entry| entry.payload.get("text").and_then(Value::as_str))
            .map(ToString::to_string)
    }

    async fn store_for_thread(thread_id: &str) -> ProjectionStore {
        let store = ProjectionStore::new();
        store
            .replace_summaries(vec![ThreadSummaryDto {
                contract_version: shared_contracts::CONTRACT_VERSION.to_string(),
                thread_id: thread_id.to_string(),
                native_thread_id: thread_id
                    .strip_prefix("codex:")
                    .unwrap_or(thread_id)
                    .to_string(),
                provider: ProviderKind::Codex,
                client: ThreadClientKind::Cli,
                title: "Fixture thread".to_string(),
                status: ThreadStatus::Idle,
                workspace: "/tmp/codex-fixture".to_string(),
                repository: "codex-mobile-companion".to_string(),
                branch: "main".to_string(),
                updated_at: "2026-04-05T00:00:00Z".to_string(),
            }])
            .await;
        store
    }
}
