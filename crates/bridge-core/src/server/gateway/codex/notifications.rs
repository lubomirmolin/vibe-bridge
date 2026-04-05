use std::collections::{HashMap, HashSet};

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
    use crate::server::projection::ProjectionStore;
    use shared_contracts::{ProviderKind, ThreadClientKind, ThreadStatus, ThreadSummaryDto};

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
