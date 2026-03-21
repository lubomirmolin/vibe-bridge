use std::collections::HashMap;
use std::sync::Arc;

use serde_json::Value;
use shared_contracts::{
    ApprovalSummaryDto, BridgeEventEnvelope, BridgeEventKind, ThreadSnapshotDto, ThreadStatus,
    ThreadSummaryDto, ThreadTimelineEntryDto, ThreadTimelinePageDto,
};
use tokio::sync::RwLock;

#[derive(Debug, Default, Clone)]
pub struct ProjectionStore {
    inner: Arc<RwLock<ProjectionState>>,
}

#[derive(Debug, Default)]
struct ProjectionState {
    summaries: HashMap<String, ThreadSummaryDto>,
    snapshots: HashMap<String, ThreadSnapshotDto>,
    approvals: HashMap<String, ApprovalSummaryDto>,
}

impl ProjectionStore {
    pub fn new() -> Self {
        Self::default()
    }

    pub async fn replace_summaries(&self, summaries: Vec<ThreadSummaryDto>) {
        let mut state = self.inner.write().await;
        state.summaries = summaries
            .into_iter()
            .map(|summary| (summary.thread_id.clone(), summary))
            .collect();
    }

    pub async fn list_summaries(&self) -> Vec<ThreadSummaryDto> {
        let state = self.inner.read().await;
        let mut summaries: Vec<_> = state.summaries.values().cloned().collect();
        summaries.sort_by(|left, right| right.updated_at.cmp(&left.updated_at));
        summaries
    }

    pub async fn put_snapshot(&self, snapshot: ThreadSnapshotDto) {
        let mut state = self.inner.write().await;
        state
            .snapshots
            .insert(snapshot.thread.thread_id.clone(), snapshot);
    }

    pub async fn snapshot(&self, thread_id: &str) -> Option<ThreadSnapshotDto> {
        let state = self.inner.read().await;
        state.snapshots.get(thread_id).cloned()
    }

    pub async fn list_approvals(&self) -> Vec<ApprovalSummaryDto> {
        let state = self.inner.read().await;
        let mut approvals: Vec<_> = state.approvals.values().cloned().collect();
        approvals.sort_by(|left, right| left.approval_id.cmp(&right.approval_id));
        approvals
    }

    pub async fn timeline_page(
        &self,
        thread_id: &str,
        before: Option<&str>,
        limit: usize,
    ) -> Option<ThreadTimelinePageDto> {
        let state = self.inner.read().await;
        let snapshot = state.snapshots.get(thread_id)?;
        let normalized_limit = limit.max(1);
        let end_index = before
            .and_then(|cursor| {
                snapshot
                    .entries
                    .iter()
                    .position(|entry| entry.event_id == cursor)
            })
            .unwrap_or(snapshot.entries.len());
        let start_index = end_index.saturating_sub(normalized_limit);
        let has_more_before = start_index > 0;
        let next_before = has_more_before.then(|| snapshot.entries[start_index].event_id.clone());

        Some(ThreadTimelinePageDto {
            contract_version: snapshot.contract_version.clone(),
            thread: snapshot.thread.clone(),
            entries: snapshot.entries[start_index..end_index].to_vec(),
            next_before,
            has_more_before,
        })
    }

    pub async fn apply_live_event(&self, event: &BridgeEventEnvelope<Value>) {
        let mut state = self.inner.write().await;
        if let Some(summary) = state.summaries.get_mut(&event.thread_id) {
            summary.updated_at = event.occurred_at.clone();
            if event.kind == BridgeEventKind::ThreadStatusChanged
                && let Some(next_status) = event
                    .payload
                    .get("status")
                    .and_then(Value::as_str)
                    .map(parse_thread_status)
            {
                summary.status = next_status;
            }
        }

        if let Some(snapshot) = state.snapshots.get_mut(&event.thread_id) {
            snapshot.thread.updated_at = event.occurred_at.clone();
            if event.kind == BridgeEventKind::ThreadStatusChanged
                && let Some(next_status) = event
                    .payload
                    .get("status")
                    .and_then(Value::as_str)
                    .map(parse_thread_status)
            {
                snapshot.thread.status = next_status;
            }

            let existing_entry_index = snapshot
                .entries
                .iter()
                .position(|entry| entry.event_id == event.event_id);
            let aggregated_payload = merge_live_payload(
                existing_entry_index
                    .and_then(|index| snapshot.entries.get(index))
                    .map(|entry| &entry.payload),
                event.kind,
                &event.payload,
            );
            let summary = summarize_live_payload(event.kind, &aggregated_payload);
            if !summary.trim().is_empty() {
                snapshot.thread.last_turn_summary = summary.clone();
            }

            let next_entry = ThreadTimelineEntryDto {
                event_id: event.event_id.clone(),
                kind: event.kind,
                occurred_at: event.occurred_at.clone(),
                summary,
                payload: aggregated_payload,
                annotations: event.annotations.clone(),
            };

            if let Some(index) = existing_entry_index {
                snapshot.entries[index] = next_entry;
            } else {
                snapshot.entries.push(next_entry);
            }
        }
    }

    pub async fn mark_thread_running(&self, thread_id: &str, occurred_at: &str) {
        let mut state = self.inner.write().await;
        if let Some(summary) = state.summaries.get_mut(thread_id) {
            summary.status = ThreadStatus::Running;
            summary.updated_at = occurred_at.to_string();
        }
        if let Some(snapshot) = state.snapshots.get_mut(thread_id) {
            snapshot.thread.status = ThreadStatus::Running;
            snapshot.thread.updated_at = occurred_at.to_string();
        }
    }

    pub async fn mark_thread_status(
        &self,
        thread_id: &str,
        status: ThreadStatus,
        occurred_at: &str,
    ) {
        let mut state = self.inner.write().await;
        if let Some(summary) = state.summaries.get_mut(thread_id) {
            summary.status = status;
            summary.updated_at = occurred_at.to_string();
        }
        if let Some(snapshot) = state.snapshots.get_mut(thread_id) {
            snapshot.thread.status = status;
            snapshot.thread.updated_at = occurred_at.to_string();
        }
    }
}

fn parse_thread_status(raw: &str) -> ThreadStatus {
    match raw {
        "running" => ThreadStatus::Running,
        "completed" => ThreadStatus::Completed,
        "interrupted" => ThreadStatus::Interrupted,
        "failed" => ThreadStatus::Failed,
        _ => ThreadStatus::Idle,
    }
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

fn merge_live_payload(existing: Option<&Value>, kind: BridgeEventKind, incoming: &Value) -> Value {
    match kind {
        BridgeEventKind::MessageDelta => {
            let replace = incoming
                .get("replace")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            let existing_text = existing
                .and_then(|payload| payload.get("text"))
                .and_then(Value::as_str)
                .unwrap_or_default();
            let next_text = merge_incremental_text(
                existing_text,
                incoming
                    .get("delta")
                    .or_else(|| incoming.get("text"))
                    .and_then(Value::as_str)
                    .unwrap_or_default(),
                replace,
            );

            serde_json::json!({
                "id": incoming.get("id").and_then(Value::as_str).or_else(|| existing.and_then(|payload| payload.get("id")).and_then(Value::as_str)).unwrap_or_default(),
                "type": "message",
                "role": incoming.get("role").and_then(Value::as_str).or_else(|| existing.and_then(|payload| payload.get("role")).and_then(Value::as_str)).unwrap_or("assistant"),
                "text": next_text,
            })
        }
        BridgeEventKind::PlanDelta => {
            let replace = incoming
                .get("replace")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            let existing_text = existing
                .and_then(|payload| payload.get("text"))
                .and_then(Value::as_str)
                .unwrap_or_default();
            let next_text = merge_incremental_text(
                existing_text,
                incoming
                    .get("delta")
                    .or_else(|| incoming.get("text"))
                    .and_then(Value::as_str)
                    .unwrap_or_default(),
                replace,
            );

            serde_json::json!({
                "id": incoming.get("id").and_then(Value::as_str).or_else(|| existing.and_then(|payload| payload.get("id")).and_then(Value::as_str)).unwrap_or_default(),
                "type": "plan",
                "text": next_text,
            })
        }
        BridgeEventKind::CommandDelta => {
            let replace = incoming
                .get("replace")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            let existing_output = existing
                .and_then(|payload| payload.get("output"))
                .and_then(Value::as_str)
                .unwrap_or_default();
            let next_output = merge_incremental_text(
                existing_output,
                incoming
                    .get("delta")
                    .or_else(|| incoming.get("output"))
                    .and_then(Value::as_str)
                    .unwrap_or_default(),
                replace,
            );

            serde_json::json!({
                "id": incoming.get("id").and_then(Value::as_str).or_else(|| existing.and_then(|payload| payload.get("id")).and_then(Value::as_str)).unwrap_or_default(),
                "type": "command",
                "command": incoming.get("command").and_then(Value::as_str).or_else(|| existing.and_then(|payload| payload.get("command")).and_then(Value::as_str)).unwrap_or_default(),
                "cmd": incoming.get("cmd").cloned().or_else(|| existing.and_then(|payload| payload.get("cmd")).cloned()),
                "workdir": incoming.get("workdir").cloned().or_else(|| incoming.get("cwd").cloned()).or_else(|| existing.and_then(|payload| payload.get("workdir")).cloned()),
                "output": next_output,
            })
        }
        BridgeEventKind::FileChange => {
            let replace = incoming
                .get("replace")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            let existing_diff = existing
                .and_then(|payload| payload.get("resolved_unified_diff"))
                .and_then(Value::as_str)
                .unwrap_or_default();
            let next_diff = merge_incremental_text(
                existing_diff,
                incoming
                    .get("delta")
                    .or_else(|| incoming.get("resolved_unified_diff"))
                    .and_then(Value::as_str)
                    .unwrap_or_default(),
                replace,
            );

            serde_json::json!({
                "id": incoming.get("id").and_then(Value::as_str).or_else(|| existing.and_then(|payload| payload.get("id")).and_then(Value::as_str)).unwrap_or_default(),
                "type": "file_change",
                "path": incoming.get("path").and_then(Value::as_str).or_else(|| existing.and_then(|payload| payload.get("path")).and_then(Value::as_str)).unwrap_or_default(),
                "resolved_unified_diff": next_diff,
            })
        }
        _ => incoming.clone(),
    }
}

fn merge_incremental_text(existing: &str, incoming: &str, replace: bool) -> String {
    if replace {
        incoming.to_string()
    } else {
        format!("{existing}{incoming}")
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::ProjectionStore;
    use shared_contracts::{
        AccessMode, BridgeEventEnvelope, BridgeEventKind, CONTRACT_VERSION, ThreadDetailDto,
        ThreadSnapshotDto, ThreadStatus, ThreadSummaryDto,
    };

    #[tokio::test]
    async fn returns_summaries_newest_first() {
        let store = ProjectionStore::new();
        store
            .replace_summaries(vec![
                ThreadSummaryDto {
                    contract_version: CONTRACT_VERSION.to_string(),
                    thread_id: "thread-1".to_string(),
                    title: "Older".to_string(),
                    status: ThreadStatus::Idle,
                    workspace: "/tmp/a".to_string(),
                    repository: "repo-a".to_string(),
                    branch: "main".to_string(),
                    updated_at: "2026-03-21T10:00:00Z".to_string(),
                },
                ThreadSummaryDto {
                    contract_version: CONTRACT_VERSION.to_string(),
                    thread_id: "thread-2".to_string(),
                    title: "Newer".to_string(),
                    status: ThreadStatus::Running,
                    workspace: "/tmp/b".to_string(),
                    repository: "repo-b".to_string(),
                    branch: "main".to_string(),
                    updated_at: "2026-03-21T11:00:00Z".to_string(),
                },
            ])
            .await;

        let summaries = store.list_summaries().await;
        assert_eq!(summaries.len(), 2);
        assert_eq!(summaries[0].thread_id, "thread-2");
        assert_eq!(summaries[1].thread_id, "thread-1");
    }

    #[tokio::test]
    async fn apply_live_event_updates_hot_snapshot_and_pages_history() {
        let store = ProjectionStore::new();
        store
            .replace_summaries(vec![ThreadSummaryDto {
                contract_version: CONTRACT_VERSION.to_string(),
                thread_id: "thread-1".to_string(),
                title: "Hot thread".to_string(),
                status: ThreadStatus::Idle,
                workspace: "/tmp/a".to_string(),
                repository: "repo-a".to_string(),
                branch: "main".to_string(),
                updated_at: "2026-03-21T10:00:00Z".to_string(),
            }])
            .await;
        store
            .put_snapshot(ThreadSnapshotDto {
                contract_version: CONTRACT_VERSION.to_string(),
                thread: ThreadDetailDto {
                    contract_version: CONTRACT_VERSION.to_string(),
                    thread_id: "thread-1".to_string(),
                    title: "Hot thread".to_string(),
                    status: ThreadStatus::Idle,
                    workspace: "/tmp/a".to_string(),
                    repository: "repo-a".to_string(),
                    branch: "main".to_string(),
                    created_at: "2026-03-21T09:00:00Z".to_string(),
                    updated_at: "2026-03-21T10:00:00Z".to_string(),
                    source: "cli".to_string(),
                    access_mode: AccessMode::ControlWithApprovals,
                    last_turn_summary: "initial".to_string(),
                },
                entries: vec![],
                approvals: vec![],
                git_status: None,
            })
            .await;

        store
            .apply_live_event(&BridgeEventEnvelope {
                contract_version: CONTRACT_VERSION.to_string(),
                event_id: "evt-1".to_string(),
                thread_id: "thread-1".to_string(),
                kind: BridgeEventKind::MessageDelta,
                occurred_at: "2026-03-21T10:01:00Z".to_string(),
                payload: json!({
                    "id": "msg-1",
                    "type": "message",
                    "role": "assistant",
                    "text": "streamed text",
                }),
                annotations: None,
            })
            .await;

        let snapshot = store
            .snapshot("thread-1")
            .await
            .expect("snapshot should exist");
        assert_eq!(snapshot.thread.updated_at, "2026-03-21T10:01:00Z");
        assert_eq!(snapshot.thread.last_turn_summary, "streamed text");
        assert_eq!(snapshot.entries.len(), 1);
        assert_eq!(snapshot.entries[0].summary, "streamed text");

        let page = store
            .timeline_page("thread-1", None, 1)
            .await
            .expect("timeline page should exist");
        assert_eq!(page.entries.len(), 1);
        assert!(!page.has_more_before);
        assert_eq!(page.entries[0].event_id, "evt-1");
    }
}
