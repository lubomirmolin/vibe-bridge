pub(crate) mod item_state;

use std::collections::HashMap;
use std::sync::Arc;

use serde_json::Value;
use shared_contracts::{
    AccessMode, ApprovalStatus, ApprovalSummaryDto, BridgeEventEnvelope, BridgeEventKind,
    PendingUserInputDto, ThreadSnapshotDto, ThreadStatus, ThreadSummaryDto, ThreadTimelineEntryDto,
    ThreadTimelinePageDto,
};
use tokio::sync::RwLock;

use crate::server::controls::ApprovalRecordDto;
use crate::thread_api::RepositoryContextDto;
use item_state::{
    ProjectionItemPhase, ThreadItemProjectionState, infer_item_phase, is_incremental_item_kind,
    materialize_entries,
};

#[derive(Debug, Default, Clone)]
pub struct ProjectionStore {
    inner: Arc<RwLock<ProjectionState>>,
}

#[derive(Debug, Default)]
struct ProjectionState {
    summaries: HashMap<String, ThreadSummaryDto>,
    snapshots: HashMap<String, ThreadSnapshotDto>,
    approvals: HashMap<String, ApprovalSummaryDto>,
    approval_records: HashMap<String, ApprovalRecordDto>,
    latest_bridge_seq_by_thread: HashMap<String, u64>,
    item_states_by_thread: HashMap<String, HashMap<String, ThreadItemProjectionState>>,
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
        let summaries_by_thread_id = state.summaries.clone();
        state.snapshots.retain(|thread_id, snapshot| {
            summaries_by_thread_id
                .get(thread_id)
                .map(|summary| {
                    summary.updated_at <= snapshot.thread.updated_at
                        || should_preserve_live_running_snapshot(snapshot, summary)
                })
                .unwrap_or(true)
        });
    }

    pub async fn list_summaries(&self) -> Vec<ThreadSummaryDto> {
        let state = self.inner.read().await;
        let mut summaries: Vec<_> = state.summaries.values().cloned().collect();
        summaries.sort_by(|left, right| right.updated_at.cmp(&left.updated_at));
        summaries
    }

    pub async fn summary_status(&self, thread_id: &str) -> Option<ThreadStatus> {
        let state = self.inner.read().await;
        state.summaries.get(thread_id).map(|summary| summary.status)
    }

    pub async fn thread_title(&self, thread_id: &str) -> Option<String> {
        let state = self.inner.read().await;
        state
            .snapshots
            .get(thread_id)
            .map(|snapshot| snapshot.thread.title.clone())
            .or_else(|| {
                state
                    .summaries
                    .get(thread_id)
                    .map(|summary| summary.title.clone())
            })
    }

    #[allow(dead_code)]
    pub async fn put_snapshot(&self, snapshot: ThreadSnapshotDto) {
        let mut state = self.inner.write().await;
        for approval in &snapshot.approvals {
            state
                .approvals
                .insert(approval.approval_id.clone(), approval.clone());
        }
        let thread_id = snapshot.thread.thread_id.clone();
        seed_item_states_from_snapshot(&mut state, &snapshot);
        let mut next_snapshot = snapshot;
        if let Some(item_states) = state.item_states_by_thread.get(&thread_id) {
            next_snapshot.entries = materialize_entries(item_states);
        }
        state.snapshots.insert(thread_id, next_snapshot);
    }

    pub async fn snapshot(&self, thread_id: &str) -> Option<ThreadSnapshotDto> {
        let state = self.inner.read().await;
        state.snapshots.get(thread_id).cloned()
    }

    pub async fn list_approval_records(&self) -> Vec<ApprovalRecordDto> {
        let state = self.inner.read().await;
        let mut approvals: Vec<_> = state.approval_records.values().cloned().collect();
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
            pending_user_input: snapshot.pending_user_input.clone(),
            next_before,
            has_more_before,
            latest_bridge_seq: state.latest_bridge_seq_by_thread.get(thread_id).copied(),
        })
    }

    pub async fn apply_live_event(&self, event: &BridgeEventEnvelope<Value>) {
        self.apply_live_event_with_phase(event, infer_item_phase(event))
            .await;
    }

    pub async fn apply_live_event_with_phase(
        &self,
        event: &BridgeEventEnvelope<Value>,
        phase: ProjectionItemPhase,
    ) {
        let mut state = self.inner.write().await;
        let next_item_entries = if is_incremental_item_kind(event.kind) {
            apply_item_state_event(&mut state, &event.thread_id, event, phase);
            state
                .item_states_by_thread
                .get(&event.thread_id)
                .map(materialize_entries)
        } else {
            None
        };
        let approval_update = (event.kind == BridgeEventKind::ApprovalRequested)
            .then(|| approval_summary_from_payload(&event.payload, &event.thread_id))
            .flatten();
        if let Some(summary) = state.summaries.get_mut(&event.thread_id) {
            summary.updated_at = event.occurred_at.clone();
            if let Some(next_title) = event
                .payload
                .get("title")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|title| !title.is_empty())
            {
                summary.title = next_title.to_string();
            }
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
            if let Some(next_title) = event
                .payload
                .get("title")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|title| !title.is_empty())
            {
                snapshot.thread.title = next_title.to_string();
            }
            if event.kind == BridgeEventKind::ThreadStatusChanged
                && let Some(next_status) = event
                    .payload
                    .get("status")
                    .and_then(Value::as_str)
                    .map(parse_thread_status)
            {
                snapshot.thread.status = next_status;
                if next_status != ThreadStatus::Running {
                    snapshot.thread.active_turn_id = None;
                }
            }

            if event.kind == BridgeEventKind::UserInputRequested {
                snapshot.pending_user_input = pending_user_input_from_payload(&event.payload);
            } else if is_incremental_item_kind(event.kind) {
                snapshot.entries = next_item_entries.clone().unwrap_or_default();
                if let Some(entry) = snapshot
                    .entries
                    .iter()
                    .find(|entry| entry.event_id == event.event_id)
                    .filter(|entry| !entry.summary.trim().is_empty())
                {
                    snapshot.thread.last_turn_summary = entry.summary.clone();
                }
            } else {
                let existing_entry_index = snapshot
                    .entries
                    .iter()
                    .position(|entry| entry.event_id == event.event_id);
                let aggregated_payload = event.payload.clone();
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

            if let Some(approval) = approval_update.as_ref() {
                if let Some(index) = snapshot
                    .approvals
                    .iter()
                    .position(|existing| existing.approval_id == approval.approval_id)
                {
                    snapshot.approvals[index] = approval.clone();
                } else {
                    snapshot.approvals.push(approval.clone());
                }
            }
        }

        if let Some(approval) = approval_update {
            state
                .approvals
                .insert(approval.approval_id.clone(), approval);
        }
    }

    pub async fn merge_snapshot_repair(
        &self,
        snapshot: &ThreadSnapshotDto,
        latest_bridge_seq: Option<u64>,
    ) {
        let mut state = self.inner.write().await;
        let thread_id = snapshot.thread.thread_id.clone();
        if let Some(sequence) = latest_bridge_seq {
            state
                .latest_bridge_seq_by_thread
                .insert(thread_id.clone(), sequence);
        }

        if let Some(existing_snapshot) = state.snapshots.get_mut(&thread_id) {
            existing_snapshot.thread = snapshot.thread.clone();
            existing_snapshot.approvals = snapshot.approvals.clone();
            existing_snapshot.git_status = snapshot.git_status.clone();
            existing_snapshot.pending_user_input = snapshot.pending_user_input.clone();
        } else {
            state.snapshots.insert(thread_id.clone(), snapshot.clone());
        }

        merge_item_states_from_snapshot(&mut state, snapshot);
        let next_entries = state
            .item_states_by_thread
            .get(&thread_id)
            .map(materialize_entries)
            .unwrap_or_default();
        if let Some(existing_snapshot) = state.snapshots.get_mut(&thread_id) {
            existing_snapshot.entries = next_entries;
        }
    }

    pub async fn latest_bridge_seq(&self, thread_id: &str) -> Option<u64> {
        let state = self.inner.read().await;
        state.latest_bridge_seq_by_thread.get(thread_id).copied()
    }

    pub async fn set_latest_bridge_seq(&self, thread_id: &str, bridge_seq: u64) {
        let mut state = self.inner.write().await;
        state
            .latest_bridge_seq_by_thread
            .insert(thread_id.to_string(), bridge_seq);
    }

    pub async fn mark_thread_running(
        &self,
        thread_id: &str,
        occurred_at: &str,
        active_turn_id: Option<&str>,
    ) {
        let mut state = self.inner.write().await;
        if let Some(summary) = state.summaries.get_mut(thread_id) {
            summary.status = ThreadStatus::Running;
            summary.updated_at = occurred_at.to_string();
        }
        if let Some(snapshot) = state.snapshots.get_mut(thread_id) {
            snapshot.thread.status = ThreadStatus::Running;
            snapshot.thread.updated_at = occurred_at.to_string();
            snapshot.thread.active_turn_id = active_turn_id.map(ToString::to_string);
        }
    }

    #[allow(dead_code)]
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
            if status != ThreadStatus::Running {
                snapshot.thread.active_turn_id = None;
            }
        }
    }

    pub async fn update_thread_title(
        &self,
        thread_id: &str,
        title: &str,
        occurred_at: &str,
    ) -> Option<ThreadStatus> {
        let normalized_title = title.trim();
        if normalized_title.is_empty() {
            return None;
        }

        let mut state = self.inner.write().await;
        let mut status = None;
        if let Some(summary) = state.summaries.get_mut(thread_id) {
            summary.title = normalized_title.to_string();
            summary.updated_at = occurred_at.to_string();
            status = Some(summary.status);
        }
        if let Some(snapshot) = state.snapshots.get_mut(thread_id) {
            snapshot.thread.title = normalized_title.to_string();
            snapshot.thread.updated_at = occurred_at.to_string();
            status = Some(snapshot.thread.status);
        }
        status
    }

    pub async fn set_access_mode(&self, access_mode: AccessMode) {
        let mut state = self.inner.write().await;
        for snapshot in state.snapshots.values_mut() {
            snapshot.thread.access_mode = access_mode;
        }
    }

    pub async fn upsert_approval_record(&self, approval: ApprovalRecordDto) {
        let mut state = self.inner.write().await;
        upsert_approval_locked(&mut state, approval);
    }

    pub async fn set_pending_user_input(
        &self,
        thread_id: &str,
        pending_user_input: Option<PendingUserInputDto>,
    ) {
        let mut state = self.inner.write().await;
        if let Some(snapshot) = state.snapshots.get_mut(thread_id) {
            snapshot.pending_user_input = pending_user_input;
        }
    }

    pub async fn update_git_state(
        &self,
        thread_id: &str,
        repository: &RepositoryContextDto,
        status: &crate::thread_api::GitStatusDto,
        occurred_at: Option<&str>,
        last_turn_summary: Option<&str>,
    ) {
        let mut state = self.inner.write().await;

        if let Some(summary) = state.summaries.get_mut(thread_id) {
            summary.repository = repository.repository.clone();
            summary.branch = repository.branch.clone();
            if let Some(occurred_at) = occurred_at {
                summary.updated_at = occurred_at.to_string();
            }
        }

        if let Some(snapshot) = state.snapshots.get_mut(thread_id) {
            snapshot.thread.repository = repository.repository.clone();
            snapshot.thread.branch = repository.branch.clone();
            if let Some(occurred_at) = occurred_at {
                snapshot.thread.updated_at = occurred_at.to_string();
            }
            if let Some(last_turn_summary) = last_turn_summary {
                snapshot.thread.last_turn_summary = last_turn_summary.to_string();
            }
            snapshot.git_status = Some(shared_contracts::GitStatusDto {
                workspace: repository.workspace.clone(),
                repository: repository.repository.clone(),
                branch: repository.branch.clone(),
                remote: (repository.remote != "unknown").then(|| repository.remote.clone()),
                dirty: status.dirty,
                ahead_by: status.ahead_by,
                behind_by: status.behind_by,
            });
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

fn should_preserve_live_running_snapshot(
    snapshot: &ThreadSnapshotDto,
    summary: &ThreadSummaryDto,
) -> bool {
    snapshot.thread.status == ThreadStatus::Running && summary.status == ThreadStatus::Idle
}

fn approval_summary_from_payload(payload: &Value, thread_id: &str) -> Option<ApprovalSummaryDto> {
    let approval_id = payload.get("approval_id")?.as_str()?.to_string();
    let action = payload.get("action")?.as_str()?.to_string();
    let status = payload
        .get("status")
        .and_then(Value::as_str)
        .map(parse_approval_status)
        .unwrap_or(ApprovalStatus::Pending);
    let reason = payload
        .get("reason")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    let target = payload
        .get("target")
        .and_then(Value::as_str)
        .map(str::to_string)
        .filter(|value| !value.trim().is_empty());

    Some(ApprovalSummaryDto {
        approval_id,
        thread_id: thread_id.to_string(),
        action,
        status,
        reason,
        target,
    })
}

fn parse_approval_status(raw: &str) -> ApprovalStatus {
    match raw {
        "approved" => ApprovalStatus::Approved,
        "rejected" => ApprovalStatus::Rejected,
        _ => ApprovalStatus::Pending,
    }
}

fn upsert_approval_locked(state: &mut ProjectionState, approval: ApprovalRecordDto) {
    let summary = approval_summary_from_record(&approval);
    if let Some(snapshot) = state.snapshots.get_mut(&approval.thread_id) {
        if let Some(index) = snapshot
            .approvals
            .iter()
            .position(|existing| existing.approval_id == approval.approval_id)
        {
            snapshot.approvals[index] = summary.clone();
        } else {
            snapshot.approvals.push(summary.clone());
        }
    }
    state
        .approvals
        .insert(approval.approval_id.clone(), summary);
    state
        .approval_records
        .insert(approval.approval_id.clone(), approval);
}

fn approval_summary_from_record(approval: &ApprovalRecordDto) -> ApprovalSummaryDto {
    ApprovalSummaryDto {
        approval_id: approval.approval_id.clone(),
        thread_id: approval.thread_id.clone(),
        action: approval.action.clone(),
        status: match approval.status {
            crate::server::controls::ApprovalStatus::Pending => ApprovalStatus::Pending,
            crate::server::controls::ApprovalStatus::Approved => ApprovalStatus::Approved,
            crate::server::controls::ApprovalStatus::Rejected => ApprovalStatus::Rejected,
        },
        reason: approval.reason.clone(),
        target: (!approval.target.trim().is_empty()).then(|| approval.target.clone()),
    }
}

#[allow(dead_code)]
fn seed_item_states_from_snapshot(state: &mut ProjectionState, snapshot: &ThreadSnapshotDto) {
    let item_states = state
        .item_states_by_thread
        .entry(snapshot.thread.thread_id.clone())
        .or_default();
    for entry in &snapshot.entries {
        item_states.insert(
            entry.event_id.clone(),
            ThreadItemProjectionState::seed_from_entry(entry),
        );
    }
}

fn merge_item_states_from_snapshot(state: &mut ProjectionState, snapshot: &ThreadSnapshotDto) {
    for entry in &snapshot.entries {
        let repair_event = BridgeEventEnvelope {
            contract_version: snapshot.contract_version.clone(),
            event_id: entry.event_id.clone(),
            thread_id: snapshot.thread.thread_id.clone(),
            kind: entry.kind,
            occurred_at: entry.occurred_at.clone(),
            payload: entry.payload.clone(),
            annotations: entry.annotations.clone(),
            bridge_seq: None,
        };
        apply_item_state_event(
            state,
            &snapshot.thread.thread_id,
            &repair_event,
            ProjectionItemPhase::Repair,
        );
    }
}

fn apply_item_state_event(
    state: &mut ProjectionState,
    thread_id: &str,
    event: &BridgeEventEnvelope<Value>,
    phase: ProjectionItemPhase,
) {
    let item_states = state
        .item_states_by_thread
        .entry(thread_id.to_string())
        .or_default();
    let next_state =
        ThreadItemProjectionState::apply_event(item_states.get(&event.event_id), event, phase);
    item_states.insert(event.event_id.clone(), next_state);
}

fn pending_user_input_from_payload(payload: &Value) -> Option<PendingUserInputDto> {
    match payload.get("state").and_then(Value::as_str) {
        Some("resolved") => None,
        Some("pending") | None => serde_json::from_value(payload.clone()).ok(),
        Some(_) => None,
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
        BridgeEventKind::ThreadStatusChanged => {
            if payload.get("reason").and_then(Value::as_str) == Some("turn_started") {
                String::new()
            } else {
                payload
                    .get("status")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string()
            }
        }
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

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::{ProjectionItemPhase, ProjectionStore};
    use shared_contracts::{
        AccessMode, BridgeEventEnvelope, BridgeEventKind, CONTRACT_VERSION, ThreadDetailDto,
        ThreadSnapshotDto, ThreadStatus, ThreadSummaryDto, ThreadTimelineEntryDto,
    };

    #[tokio::test]
    async fn returns_summaries_newest_first() {
        let store = ProjectionStore::new();
        store
            .replace_summaries(vec![
                ThreadSummaryDto {
                    contract_version: CONTRACT_VERSION.to_string(),
                    thread_id: "thread-1".to_string(),
                    native_thread_id: "thread-1".to_string(),
                    provider: shared_contracts::ProviderKind::Codex,
                    client: shared_contracts::ThreadClientKind::Cli,
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
                    native_thread_id: "thread-2".to_string(),
                    provider: shared_contracts::ProviderKind::Codex,
                    client: shared_contracts::ThreadClientKind::Cli,
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
                native_thread_id: "thread-1".to_string(),
                provider: shared_contracts::ProviderKind::Codex,
                client: shared_contracts::ThreadClientKind::Cli,
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
                    native_thread_id: "thread-1".to_string(),
                    provider: shared_contracts::ProviderKind::Codex,
                    client: shared_contracts::ThreadClientKind::Cli,
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
                    active_turn_id: None,
                },
                entries: vec![],
                approvals: vec![],
                git_status: None,
                pending_user_input: None,
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
                bridge_seq: None,
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

    #[tokio::test]
    async fn apply_live_message_event_preserves_images() {
        let store = ProjectionStore::new();
        store
            .replace_summaries(vec![ThreadSummaryDto {
                contract_version: CONTRACT_VERSION.to_string(),
                thread_id: "thread-1".to_string(),
                native_thread_id: "thread-1".to_string(),
                provider: shared_contracts::ProviderKind::Codex,
                client: shared_contracts::ThreadClientKind::Cli,
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
                    native_thread_id: "thread-1".to_string(),
                    provider: shared_contracts::ProviderKind::Codex,
                    client: shared_contracts::ThreadClientKind::Cli,
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
                    active_turn_id: None,
                },
                entries: vec![],
                approvals: vec![],
                git_status: None,
                pending_user_input: None,
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
                    "role": "user",
                    "text": "See attachment",
                    "images": ["data:image/png;base64,AAA"],
                }),
                annotations: None,
                bridge_seq: None,
            })
            .await;

        let snapshot = store
            .snapshot("thread-1")
            .await
            .expect("snapshot should exist");
        assert_eq!(
            snapshot.entries[0].payload["images"],
            json!(["data:image/png;base64,AAA"])
        );
    }

    #[tokio::test]
    async fn apply_live_message_event_merges_cumulative_text_without_duplicate_prefixes() {
        let store = ProjectionStore::new();
        store
            .replace_summaries(vec![ThreadSummaryDto {
                contract_version: CONTRACT_VERSION.to_string(),
                thread_id: "thread-1".to_string(),
                native_thread_id: "thread-1".to_string(),
                provider: shared_contracts::ProviderKind::Codex,
                client: shared_contracts::ThreadClientKind::Cli,
                title: "Hot thread".to_string(),
                status: ThreadStatus::Running,
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
                    native_thread_id: "thread-1".to_string(),
                    provider: shared_contracts::ProviderKind::Codex,
                    client: shared_contracts::ThreadClientKind::Cli,
                    title: "Hot thread".to_string(),
                    status: ThreadStatus::Running,
                    workspace: "/tmp/a".to_string(),
                    repository: "repo-a".to_string(),
                    branch: "main".to_string(),
                    created_at: "2026-03-21T09:00:00Z".to_string(),
                    updated_at: "2026-03-21T10:00:00Z".to_string(),
                    source: "cli".to_string(),
                    access_mode: AccessMode::ControlWithApprovals,
                    last_turn_summary: "initial".to_string(),
                    active_turn_id: None,
                },
                entries: vec![],
                approvals: vec![],
                git_status: None,
                pending_user_input: None,
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
                    "delta": "I'm",
                    "replace": true,
                }),
                annotations: None,
                bridge_seq: None,
            })
            .await;

        store
            .apply_live_event(&BridgeEventEnvelope {
                contract_version: CONTRACT_VERSION.to_string(),
                event_id: "evt-1".to_string(),
                thread_id: "thread-1".to_string(),
                kind: BridgeEventKind::MessageDelta,
                occurred_at: "2026-03-21T10:01:01Z".to_string(),
                payload: json!({
                    "id": "msg-1",
                    "type": "message",
                    "role": "assistant",
                    "delta": "I'm checking",
                    "replace": false,
                }),
                annotations: None,
                bridge_seq: None,
            })
            .await;

        let snapshot = store
            .snapshot("thread-1")
            .await
            .expect("snapshot should exist");
        assert_eq!(snapshot.entries[0].payload["text"], "I'm checking");
    }

    #[tokio::test]
    async fn replace_summaries_invalidates_stale_snapshot_when_summary_is_newer() {
        let store = ProjectionStore::new();
        store
            .replace_summaries(vec![ThreadSummaryDto {
                contract_version: CONTRACT_VERSION.to_string(),
                thread_id: "thread-1".to_string(),
                native_thread_id: "thread-1".to_string(),
                provider: shared_contracts::ProviderKind::Codex,
                client: shared_contracts::ThreadClientKind::Cli,
                title: "Thread".to_string(),
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
                    native_thread_id: "thread-1".to_string(),
                    provider: shared_contracts::ProviderKind::Codex,
                    client: shared_contracts::ThreadClientKind::Cli,
                    title: "Thread".to_string(),
                    status: ThreadStatus::Idle,
                    workspace: "/tmp/a".to_string(),
                    repository: "repo-a".to_string(),
                    branch: "main".to_string(),
                    created_at: "2026-03-21T09:00:00Z".to_string(),
                    updated_at: "2026-03-21T10:00:00Z".to_string(),
                    source: "cli".to_string(),
                    access_mode: AccessMode::ControlWithApprovals,
                    last_turn_summary: "older summary".to_string(),
                    active_turn_id: None,
                },
                entries: vec![ThreadTimelineEntryDto {
                    event_id: "evt-1".to_string(),
                    kind: BridgeEventKind::MessageDelta,
                    occurred_at: "2026-03-21T10:00:00Z".to_string(),
                    summary: "older summary".to_string(),
                    payload: json!({
                        "id": "msg-1",
                        "type": "message",
                        "role": "assistant",
                        "text": "older summary",
                    }),
                    annotations: None,
                }],
                approvals: vec![],
                git_status: None,
                pending_user_input: None,
            })
            .await;

        store
            .replace_summaries(vec![ThreadSummaryDto {
                contract_version: CONTRACT_VERSION.to_string(),
                thread_id: "thread-1".to_string(),
                native_thread_id: "thread-1".to_string(),
                provider: shared_contracts::ProviderKind::Codex,
                client: shared_contracts::ThreadClientKind::Cli,
                title: "Thread".to_string(),
                status: ThreadStatus::Idle,
                workspace: "/tmp/a".to_string(),
                repository: "repo-a".to_string(),
                branch: "main".to_string(),
                updated_at: "2026-03-21T10:05:00Z".to_string(),
            }])
            .await;

        assert!(
            store.snapshot("thread-1").await.is_none(),
            "stale cached snapshots should be evicted so the next detail/history read refetches"
        );
    }

    #[tokio::test]
    async fn replace_summaries_keeps_running_snapshot_when_newer_summary_regresses_to_idle() {
        let store = ProjectionStore::new();
        store
            .replace_summaries(vec![ThreadSummaryDto {
                contract_version: CONTRACT_VERSION.to_string(),
                thread_id: "thread-1".to_string(),
                native_thread_id: "thread-1".to_string(),
                provider: shared_contracts::ProviderKind::Codex,
                client: shared_contracts::ThreadClientKind::Cli,
                title: "Thread".to_string(),
                status: ThreadStatus::Running,
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
                    native_thread_id: "thread-1".to_string(),
                    provider: shared_contracts::ProviderKind::Codex,
                    client: shared_contracts::ThreadClientKind::Cli,
                    title: "Thread".to_string(),
                    status: ThreadStatus::Running,
                    workspace: "/tmp/a".to_string(),
                    repository: "repo-a".to_string(),
                    branch: "main".to_string(),
                    created_at: "2026-03-21T09:00:00Z".to_string(),
                    updated_at: "2026-03-21T10:00:10Z".to_string(),
                    source: "cli".to_string(),
                    access_mode: AccessMode::ControlWithApprovals,
                    last_turn_summary: "working".to_string(),
                    active_turn_id: Some("turn-1".to_string()),
                },
                entries: vec![ThreadTimelineEntryDto {
                    event_id: "evt-1".to_string(),
                    kind: BridgeEventKind::MessageDelta,
                    occurred_at: "2026-03-21T10:00:10Z".to_string(),
                    summary: "working".to_string(),
                    payload: json!({
                        "id": "msg-1",
                        "type": "message",
                        "role": "assistant",
                        "text": "working",
                    }),
                    annotations: None,
                }],
                approvals: vec![],
                git_status: None,
                pending_user_input: None,
            })
            .await;

        store
            .replace_summaries(vec![ThreadSummaryDto {
                contract_version: CONTRACT_VERSION.to_string(),
                thread_id: "thread-1".to_string(),
                native_thread_id: "thread-1".to_string(),
                provider: shared_contracts::ProviderKind::Codex,
                client: shared_contracts::ThreadClientKind::Cli,
                title: "Thread".to_string(),
                status: ThreadStatus::Idle,
                workspace: "/tmp/a".to_string(),
                repository: "repo-a".to_string(),
                branch: "main".to_string(),
                updated_at: "2026-03-21T10:05:00Z".to_string(),
            }])
            .await;

        let snapshot = store
            .snapshot("thread-1")
            .await
            .expect("running cached snapshot should be preserved");
        assert_eq!(snapshot.thread.status, ThreadStatus::Running);
        assert_eq!(snapshot.entries.len(), 1);
    }

    #[tokio::test]
    async fn apply_live_plan_event_preserves_structured_steps() {
        let store = ProjectionStore::new();
        store
            .replace_summaries(vec![ThreadSummaryDto {
                contract_version: CONTRACT_VERSION.to_string(),
                thread_id: "thread-1".to_string(),
                native_thread_id: "thread-1".to_string(),
                provider: shared_contracts::ProviderKind::Codex,
                client: shared_contracts::ThreadClientKind::Cli,
                title: "Thread".to_string(),
                status: ThreadStatus::Running,
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
                    native_thread_id: "thread-1".to_string(),
                    provider: shared_contracts::ProviderKind::Codex,
                    client: shared_contracts::ThreadClientKind::Cli,
                    title: "Thread".to_string(),
                    status: ThreadStatus::Running,
                    workspace: "/tmp/a".to_string(),
                    repository: "repo-a".to_string(),
                    branch: "main".to_string(),
                    created_at: "2026-03-21T09:00:00Z".to_string(),
                    updated_at: "2026-03-21T10:00:00Z".to_string(),
                    source: "cli".to_string(),
                    access_mode: AccessMode::ControlWithApprovals,
                    last_turn_summary: "initial".to_string(),
                    active_turn_id: None,
                },
                entries: vec![],
                approvals: vec![],
                git_status: None,
                pending_user_input: None,
            })
            .await;

        store
            .apply_live_event(&BridgeEventEnvelope {
                contract_version: CONTRACT_VERSION.to_string(),
                event_id: "evt-plan".to_string(),
                thread_id: "thread-1".to_string(),
                kind: BridgeEventKind::PlanDelta,
                occurred_at: "2026-03-21T10:01:00Z".to_string(),
                payload: json!({
                    "id": "plan-1",
                    "type": "plan",
                    "text": "1 out of 2 tasks completed\n1. Inspect bridge payload\n2. Add Flutter card",
                    "steps": [
                        {"step": "Inspect bridge payload", "status": "completed"},
                        {"step": "Add Flutter card", "status": "in_progress"}
                    ],
                    "completed_count": 1,
                    "total_count": 2,
                }),
                annotations: None,
                bridge_seq: None,
            })
            .await;

        let snapshot = store
            .snapshot("thread-1")
            .await
            .expect("snapshot should exist");
        assert_eq!(snapshot.entries.len(), 1);
        assert_eq!(snapshot.entries[0].payload["completed_count"], 1);
        assert_eq!(
            snapshot.entries[0].payload["steps"][1]["status"].as_str(),
            Some("in_progress")
        );
    }

    #[tokio::test]
    async fn terminal_live_thread_status_clears_active_turn_id() {
        let store = ProjectionStore::new();
        store
            .replace_summaries(vec![ThreadSummaryDto {
                contract_version: CONTRACT_VERSION.to_string(),
                thread_id: "thread-1".to_string(),
                native_thread_id: "thread-1".to_string(),
                provider: shared_contracts::ProviderKind::Codex,
                client: shared_contracts::ThreadClientKind::Cli,
                title: "Thread".to_string(),
                status: ThreadStatus::Running,
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
                    native_thread_id: "thread-1".to_string(),
                    provider: shared_contracts::ProviderKind::Codex,
                    client: shared_contracts::ThreadClientKind::Cli,
                    title: "Thread".to_string(),
                    status: ThreadStatus::Running,
                    workspace: "/tmp/a".to_string(),
                    repository: "repo-a".to_string(),
                    branch: "main".to_string(),
                    created_at: "2026-03-21T09:00:00Z".to_string(),
                    updated_at: "2026-03-21T10:00:00Z".to_string(),
                    source: "cli".to_string(),
                    access_mode: AccessMode::ControlWithApprovals,
                    last_turn_summary: "initial".to_string(),
                    active_turn_id: Some("turn-1".to_string()),
                },
                entries: vec![],
                approvals: vec![],
                git_status: None,
                pending_user_input: None,
            })
            .await;

        store
            .apply_live_event(&BridgeEventEnvelope {
                contract_version: CONTRACT_VERSION.to_string(),
                event_id: "evt-status".to_string(),
                thread_id: "thread-1".to_string(),
                kind: BridgeEventKind::ThreadStatusChanged,
                occurred_at: "2026-03-21T10:01:00Z".to_string(),
                payload: json!({
                    "status": "completed",
                    "reason": "upstream_notification",
                }),
                annotations: None,
                bridge_seq: None,
            })
            .await;

        let snapshot = store
            .snapshot("thread-1")
            .await
            .expect("snapshot should exist");
        assert_eq!(snapshot.thread.status, ThreadStatus::Completed);
        assert_eq!(snapshot.thread.active_turn_id, None);
    }

    #[tokio::test]
    async fn turn_started_status_event_keeps_last_turn_summary() {
        let store = ProjectionStore::new();
        store
            .replace_summaries(vec![ThreadSummaryDto {
                contract_version: CONTRACT_VERSION.to_string(),
                thread_id: "thread-1".to_string(),
                native_thread_id: "thread-1".to_string(),
                provider: shared_contracts::ProviderKind::Codex,
                client: shared_contracts::ThreadClientKind::Cli,
                title: "Thread".to_string(),
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
                    native_thread_id: "thread-1".to_string(),
                    provider: shared_contracts::ProviderKind::Codex,
                    client: shared_contracts::ThreadClientKind::Cli,
                    title: "Thread".to_string(),
                    status: ThreadStatus::Idle,
                    workspace: "/tmp/a".to_string(),
                    repository: "repo-a".to_string(),
                    branch: "main".to_string(),
                    created_at: "2026-03-21T09:00:00Z".to_string(),
                    updated_at: "2026-03-21T10:00:00Z".to_string(),
                    source: "cli".to_string(),
                    access_mode: AccessMode::ControlWithApprovals,
                    last_turn_summary: "previous assistant reply".to_string(),
                    active_turn_id: None,
                },
                entries: vec![],
                approvals: vec![],
                git_status: None,
                pending_user_input: None,
            })
            .await;

        store
            .apply_live_event(&BridgeEventEnvelope {
                contract_version: CONTRACT_VERSION.to_string(),
                event_id: "evt-turn-started".to_string(),
                thread_id: "thread-1".to_string(),
                kind: BridgeEventKind::ThreadStatusChanged,
                occurred_at: "2026-03-21T10:01:00Z".to_string(),
                payload: json!({
                    "status": "running",
                    "reason": "turn_started",
                    "model": "gpt-5-mini",
                    "reasoning_effort": "medium",
                    "turn_id": "turn-1",
                }),
                annotations: None,
                bridge_seq: None,
            })
            .await;

        let snapshot = store
            .snapshot("thread-1")
            .await
            .expect("snapshot should exist");
        assert_eq!(snapshot.thread.status, ThreadStatus::Running);
        assert_eq!(
            snapshot.thread.last_turn_summary,
            "previous assistant reply"
        );
        assert_eq!(snapshot.entries.len(), 1);
        assert_eq!(
            snapshot.entries[0].payload["model"].as_str(),
            Some("gpt-5-mini")
        );
    }

    #[tokio::test]
    async fn snapshot_repair_does_not_clobber_active_live_text() {
        let store = ProjectionStore::new();
        store
            .replace_summaries(vec![ThreadSummaryDto {
                contract_version: CONTRACT_VERSION.to_string(),
                thread_id: "thread-1".to_string(),
                native_thread_id: "thread-1".to_string(),
                provider: shared_contracts::ProviderKind::Codex,
                client: shared_contracts::ThreadClientKind::Cli,
                title: "Thread".to_string(),
                status: ThreadStatus::Running,
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
                    native_thread_id: "thread-1".to_string(),
                    provider: shared_contracts::ProviderKind::Codex,
                    client: shared_contracts::ThreadClientKind::Cli,
                    title: "Thread".to_string(),
                    status: ThreadStatus::Running,
                    workspace: "/tmp/a".to_string(),
                    repository: "repo-a".to_string(),
                    branch: "main".to_string(),
                    created_at: "2026-03-21T09:00:00Z".to_string(),
                    updated_at: "2026-03-21T10:00:00Z".to_string(),
                    source: "cli".to_string(),
                    access_mode: AccessMode::ControlWithApprovals,
                    last_turn_summary: String::new(),
                    active_turn_id: Some("turn-1".to_string()),
                },
                entries: vec![],
                approvals: vec![],
                git_status: None,
                pending_user_input: None,
            })
            .await;

        store
            .apply_live_event_with_phase(
                &BridgeEventEnvelope {
                    contract_version: CONTRACT_VERSION.to_string(),
                    event_id: "evt-1".to_string(),
                    thread_id: "thread-1".to_string(),
                    kind: BridgeEventKind::MessageDelta,
                    occurred_at: "2026-03-21T10:01:00Z".to_string(),
                    payload: json!({
                        "id": "msg-1",
                        "type": "message",
                        "role": "assistant",
                        "text": "hello world",
                    }),
                    annotations: None,
                    bridge_seq: None,
                },
                ProjectionItemPhase::Delta,
            )
            .await;

        store
            .merge_snapshot_repair(
                &ThreadSnapshotDto {
                    contract_version: CONTRACT_VERSION.to_string(),
                    thread: ThreadDetailDto {
                        contract_version: CONTRACT_VERSION.to_string(),
                        thread_id: "thread-1".to_string(),
                        native_thread_id: "thread-1".to_string(),
                        provider: shared_contracts::ProviderKind::Codex,
                        client: shared_contracts::ThreadClientKind::Cli,
                        title: "Thread".to_string(),
                        status: ThreadStatus::Running,
                        workspace: "/tmp/a".to_string(),
                        repository: "repo-a".to_string(),
                        branch: "main".to_string(),
                        created_at: "2026-03-21T09:00:00Z".to_string(),
                        updated_at: "2026-03-21T10:01:01Z".to_string(),
                        source: "desktop_ipc".to_string(),
                        access_mode: AccessMode::ControlWithApprovals,
                        last_turn_summary: String::new(),
                        active_turn_id: Some("turn-1".to_string()),
                    },
                    entries: vec![ThreadTimelineEntryDto {
                        event_id: "evt-1".to_string(),
                        kind: BridgeEventKind::MessageDelta,
                        occurred_at: "2026-03-21T10:01:01Z".to_string(),
                        summary: "hello".to_string(),
                        payload: json!({
                            "id": "msg-1",
                            "type": "message",
                            "role": "assistant",
                            "text": "hello",
                            "source": "desktop_ipc",
                        }),
                        annotations: None,
                    }],
                    approvals: vec![],
                    git_status: None,
                    pending_user_input: None,
                },
                Some(9),
            )
            .await;

        let snapshot = store
            .snapshot("thread-1")
            .await
            .expect("snapshot should exist");
        assert_eq!(snapshot.entries.len(), 1);
        assert_eq!(snapshot.entries[0].payload["text"], "hello world");
        assert_eq!(snapshot.entries[0].payload["source"], "desktop_ipc");

        let page = store
            .timeline_page("thread-1", None, 10)
            .await
            .expect("page should exist");
        assert_eq!(page.latest_bridge_seq, Some(9));
    }

    #[tokio::test]
    async fn snapshot_repair_backfills_settled_item_without_overwriting_final_text() {
        let store = ProjectionStore::new();
        store
            .replace_summaries(vec![ThreadSummaryDto {
                contract_version: CONTRACT_VERSION.to_string(),
                thread_id: "thread-1".to_string(),
                native_thread_id: "thread-1".to_string(),
                provider: shared_contracts::ProviderKind::Codex,
                client: shared_contracts::ThreadClientKind::Cli,
                title: "Thread".to_string(),
                status: ThreadStatus::Completed,
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
                    native_thread_id: "thread-1".to_string(),
                    provider: shared_contracts::ProviderKind::Codex,
                    client: shared_contracts::ThreadClientKind::Cli,
                    title: "Thread".to_string(),
                    status: ThreadStatus::Completed,
                    workspace: "/tmp/a".to_string(),
                    repository: "repo-a".to_string(),
                    branch: "main".to_string(),
                    created_at: "2026-03-21T09:00:00Z".to_string(),
                    updated_at: "2026-03-21T10:00:00Z".to_string(),
                    source: "cli".to_string(),
                    access_mode: AccessMode::ControlWithApprovals,
                    last_turn_summary: String::new(),
                    active_turn_id: None,
                },
                entries: vec![],
                approvals: vec![],
                git_status: None,
                pending_user_input: None,
            })
            .await;

        store
            .apply_live_event_with_phase(
                &BridgeEventEnvelope {
                    contract_version: CONTRACT_VERSION.to_string(),
                    event_id: "evt-1".to_string(),
                    thread_id: "thread-1".to_string(),
                    kind: BridgeEventKind::CommandDelta,
                    occurred_at: "2026-03-21T10:01:00Z".to_string(),
                    payload: json!({
                        "id": "cmd-1",
                        "type": "command",
                        "command": "ls",
                        "output": "done",
                    }),
                    annotations: None,
                    bridge_seq: None,
                },
                ProjectionItemPhase::Final,
            )
            .await;

        store
            .merge_snapshot_repair(
                &ThreadSnapshotDto {
                    contract_version: CONTRACT_VERSION.to_string(),
                    thread: ThreadDetailDto {
                        contract_version: CONTRACT_VERSION.to_string(),
                        thread_id: "thread-1".to_string(),
                        native_thread_id: "thread-1".to_string(),
                        provider: shared_contracts::ProviderKind::Codex,
                        client: shared_contracts::ThreadClientKind::Cli,
                        title: "Thread".to_string(),
                        status: ThreadStatus::Completed,
                        workspace: "/tmp/a".to_string(),
                        repository: "repo-a".to_string(),
                        branch: "main".to_string(),
                        created_at: "2026-03-21T09:00:00Z".to_string(),
                        updated_at: "2026-03-21T10:01:01Z".to_string(),
                        source: "archive".to_string(),
                        access_mode: AccessMode::ControlWithApprovals,
                        last_turn_summary: String::new(),
                        active_turn_id: None,
                    },
                    entries: vec![ThreadTimelineEntryDto {
                        event_id: "evt-1".to_string(),
                        kind: BridgeEventKind::CommandDelta,
                        occurred_at: "2026-03-21T10:01:01Z".to_string(),
                        summary: "done".to_string(),
                        payload: json!({
                            "id": "cmd-1",
                            "type": "command",
                            "command": "ls",
                            "output": "stale",
                            "exit_code": 0,
                        }),
                        annotations: None,
                    }],
                    approvals: vec![],
                    git_status: None,
                    pending_user_input: None,
                },
                None,
            )
            .await;

        let snapshot = store
            .snapshot("thread-1")
            .await
            .expect("snapshot should exist");
        assert_eq!(snapshot.entries[0].payload["output"], "done");
        assert_eq!(snapshot.entries[0].payload["exit_code"], 0);
    }
}
