use std::collections::HashMap;
use std::sync::Arc;

use serde_json::Value;
use shared_contracts::{
    AccessMode, ApprovalStatus, ApprovalSummaryDto, BridgeEventEnvelope, BridgeEventKind,
    PendingUserInputDto, ThreadDetailDto, ThreadSnapshotDto, ThreadStatus, ThreadSummaryDto,
    ThreadTimelineEntryDto, ThreadTimelinePageDto, ThreadWorkflowStateDto,
};
use tokio::sync::RwLock;

use crate::incremental_text::merge_incremental_text;
use crate::server::contracts::{GitMutationStatusDto, RepositoryContextDto};
use crate::server::controls::ApprovalRecordDto;
use crate::server::timeline_dedupe::dedupe_visible_user_prompt_representations;

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

    pub async fn summary(&self, thread_id: &str) -> Option<ThreadSummaryDto> {
        let state = self.inner.read().await;
        state.summaries.get(thread_id).cloned()
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

    pub async fn put_snapshot(&self, snapshot: ThreadSnapshotDto) {
        let mut state = self.inner.write().await;
        let mut snapshot = snapshot;
        if let Some(previous_snapshot) = state.snapshots.get(&snapshot.thread.thread_id) {
            snapshot.latest_bridge_seq = combine_latest_bridge_seq(
                previous_snapshot.latest_bridge_seq,
                snapshot.latest_bridge_seq,
            );
            snapshot.workflow_state = snapshot
                .workflow_state
                .clone()
                .or_else(|| previous_snapshot.workflow_state.clone());
        }
        dedupe_visible_user_prompt_representations(&mut snapshot.entries);
        for approval in &snapshot.approvals {
            state
                .approvals
                .insert(approval.approval_id.clone(), approval.clone());
        }
        state
            .snapshots
            .insert(snapshot.thread.thread_id.clone(), snapshot);
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
            latest_bridge_seq: snapshot.latest_bridge_seq,
            workflow_state: snapshot.workflow_state.clone(),
            pending_user_input: snapshot.pending_user_input.clone(),
            next_before,
            has_more_before,
        })
    }

    pub async fn apply_live_event(&self, event: &BridgeEventEnvelope<Value>) {
        let mut state = self.inner.write().await;
        ensure_snapshot_for_thread_from_summary_locked(
            &mut state,
            &event.thread_id,
            AccessMode::ControlWithApprovals,
        );
        apply_live_event_locked(&mut state, event);
    }

    pub async fn hydrate_from_events(
        &self,
        events: &[BridgeEventEnvelope<Value>],
        access_mode: AccessMode,
    ) {
        let mut ordered_events = events.to_vec();
        ordered_events.sort_by(|left, right| {
            let left_key = (
                left.bridge_seq.unwrap_or(u64::MAX),
                &left.occurred_at,
                &left.event_id,
            );
            let right_key = (
                right.bridge_seq.unwrap_or(u64::MAX),
                &right.occurred_at,
                &right.event_id,
            );
            left_key.cmp(&right_key)
        });

        let mut state = self.inner.write().await;
        for event in &ordered_events {
            ensure_snapshot_for_thread_from_summary_locked(
                &mut state,
                &event.thread_id,
                access_mode,
            );
            apply_live_event_locked(&mut state, event);
        }
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

    pub async fn list_pending_user_inputs(&self) -> Vec<(String, PendingUserInputDto)> {
        let state = self.inner.read().await;
        let mut pending = state
            .snapshots
            .iter()
            .filter_map(|(thread_id, snapshot)| {
                snapshot
                    .pending_user_input
                    .clone()
                    .map(|pending| (thread_id.clone(), pending))
            })
            .collect::<Vec<_>>();
        pending.sort_by(|left, right| left.0.cmp(&right.0));
        pending
    }

    pub async fn update_git_state(
        &self,
        thread_id: &str,
        repository: &RepositoryContextDto,
        status: &GitMutationStatusDto,
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

fn ensure_snapshot_for_thread_from_summary_locked(
    state: &mut ProjectionState,
    thread_id: &str,
    access_mode: AccessMode,
) {
    if state.snapshots.contains_key(thread_id) {
        return;
    }
    let Some(summary) = state.summaries.get(thread_id) else {
        return;
    };
    state.snapshots.insert(
        thread_id.to_string(),
        empty_snapshot_from_summary(summary, access_mode),
    );
}

fn empty_snapshot_from_summary(
    summary: &ThreadSummaryDto,
    access_mode: AccessMode,
) -> ThreadSnapshotDto {
    ThreadSnapshotDto {
        contract_version: summary.contract_version.clone(),
        thread: ThreadDetailDto {
            contract_version: summary.contract_version.clone(),
            thread_id: summary.thread_id.clone(),
            native_thread_id: summary.native_thread_id.clone(),
            provider: summary.provider,
            client: summary.client,
            title: summary.title.clone(),
            status: summary.status,
            workspace: summary.workspace.clone(),
            repository: summary.repository.clone(),
            branch: summary.branch.clone(),
            created_at: summary.updated_at.clone(),
            updated_at: summary.updated_at.clone(),
            source: "bridge_event_log".to_string(),
            access_mode,
            last_turn_summary: String::new(),
            active_turn_id: None,
        },
        latest_bridge_seq: None,
        entries: Vec::new(),
        approvals: Vec::new(),
        git_status: None,
        workflow_state: None,
        pending_user_input: None,
    }
}

fn apply_live_event_locked(state: &mut ProjectionState, event: &BridgeEventEnvelope<Value>) {
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
        snapshot.latest_bridge_seq =
            combine_latest_bridge_seq(snapshot.latest_bridge_seq, event.bridge_seq);
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
        } else if event.kind == BridgeEventKind::ThreadMetadataChanged {
            snapshot.workflow_state = workflow_state_from_payload(&event.payload);
        } else {
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
            dedupe_visible_user_prompt_representations(&mut snapshot.entries);
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

fn combine_latest_bridge_seq(current: Option<u64>, next: Option<u64>) -> Option<u64> {
    match (current, next) {
        (Some(current), Some(next)) => Some(current.max(next)),
        (Some(current), None) => Some(current),
        (None, Some(next)) => Some(next),
        (None, None) => None,
    }
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

fn pending_user_input_from_payload(payload: &Value) -> Option<PendingUserInputDto> {
    match payload.get("state").and_then(Value::as_str) {
        Some("resolved") => None,
        Some("pending") | None => serde_json::from_value(payload.clone()).ok(),
        Some(_) => None,
    }
}

fn workflow_state_from_payload(payload: &Value) -> Option<ThreadWorkflowStateDto> {
    payload
        .get("workflow_state")
        .cloned()
        .and_then(|value| serde_json::from_value(value).ok())
}

fn summarize_live_payload(kind: BridgeEventKind, payload: &Value) -> String {
    match kind {
        BridgeEventKind::MessageDelta | BridgeEventKind::PlanDelta => payload
            .get("text")
            .or_else(|| payload.get("delta"))
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
        BridgeEventKind::ThreadMetadataChanged => payload
            .get("workflow_state")
            .and_then(Value::as_object)
            .and_then(|workflow| workflow.get("state"))
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
            let mut payload = serde_json::json!({
                "id": incoming.get("id").and_then(Value::as_str).or_else(|| existing.and_then(|payload| payload.get("id")).and_then(Value::as_str)).unwrap_or_default(),
                "type": "message",
                "role": incoming.get("role").and_then(Value::as_str).or_else(|| existing.and_then(|payload| payload.get("role")).and_then(Value::as_str)).unwrap_or("assistant"),
                "text": next_text,
            });
            if let Some(images) = incoming
                .get("images")
                .cloned()
                .or_else(|| existing.and_then(|payload| payload.get("images")).cloned())
                && let Some(object) = payload.as_object_mut()
            {
                object.insert("images".to_string(), images);
            }
            if let Some(client_message_id) =
                incoming.get("client_message_id").cloned().or_else(|| {
                    existing
                        .and_then(|payload| payload.get("client_message_id"))
                        .cloned()
                })
                && let Some(object) = payload.as_object_mut()
            {
                object.insert("client_message_id".to_string(), client_message_id);
            }
            payload
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

            let mut payload = serde_json::json!({
                "id": incoming.get("id").and_then(Value::as_str).or_else(|| existing.and_then(|payload| payload.get("id")).and_then(Value::as_str)).unwrap_or_default(),
                "type": "plan",
                "text": next_text,
            });
            if let Some(object) = payload.as_object_mut() {
                if let Some(explanation) = incoming
                    .get("explanation")
                    .or_else(|| existing.and_then(|payload| payload.get("explanation")))
                {
                    object.insert("explanation".to_string(), explanation.clone());
                }
                if let Some(steps) = incoming
                    .get("steps")
                    .or_else(|| existing.and_then(|payload| payload.get("steps")))
                {
                    object.insert("steps".to_string(), steps.clone());
                }
                if let Some(completed_count) = incoming
                    .get("completed_count")
                    .or_else(|| existing.and_then(|payload| payload.get("completed_count")))
                {
                    object.insert("completed_count".to_string(), completed_count.clone());
                }
                if let Some(total_count) = incoming
                    .get("total_count")
                    .or_else(|| existing.and_then(|payload| payload.get("total_count")))
                {
                    object.insert("total_count".to_string(), total_count.clone());
                }
            }

            payload
        }
        BridgeEventKind::ThreadMetadataChanged => incoming.clone(),
        BridgeEventKind::UserInputRequested => incoming.clone(),
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

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::ProjectionStore;
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
                latest_bridge_seq: None,
                entries: vec![],
                approvals: vec![],
                git_status: None,
                workflow_state: None,
                pending_user_input: None,
            })
            .await;

        store
            .apply_live_event(&BridgeEventEnvelope {
                contract_version: CONTRACT_VERSION.to_string(),
                event_id: "evt-1".to_string(),
                bridge_seq: Some(7),
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
        assert_eq!(snapshot.latest_bridge_seq, Some(7));
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
    async fn put_snapshot_preserves_existing_latest_bridge_seq_when_refresh_lacks_cursor() {
        let store = ProjectionStore::new();
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
                latest_bridge_seq: Some(12),
                entries: vec![],
                approvals: vec![],
                git_status: None,
                workflow_state: None,
                pending_user_input: None,
            })
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
                    updated_at: "2026-03-21T10:01:00Z".to_string(),
                    source: "cli".to_string(),
                    access_mode: AccessMode::ControlWithApprovals,
                    last_turn_summary: "done".to_string(),
                    active_turn_id: None,
                },
                latest_bridge_seq: None,
                entries: vec![],
                approvals: vec![],
                git_status: None,
                workflow_state: None,
                pending_user_input: None,
            })
            .await;

        let snapshot = store
            .snapshot("thread-1")
            .await
            .expect("snapshot should exist");
        assert_eq!(snapshot.latest_bridge_seq, Some(12));
    }

    #[tokio::test]
    async fn put_snapshot_preserves_existing_workflow_state_when_refresh_lacks_it() {
        let store = ProjectionStore::new();
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
                latest_bridge_seq: Some(12),
                entries: vec![],
                approvals: vec![],
                git_status: None,
                workflow_state: Some(shared_contracts::ThreadWorkflowStateDto {
                    workflow_kind: "plan_questionnaire".to_string(),
                    state: "awaiting_questions".to_string(),
                    request_id: None,
                    original_prompt: Some("Investigate reconnect replay".to_string()),
                    provider_request_id: None,
                }),
                pending_user_input: None,
            })
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
                    updated_at: "2026-03-21T10:01:00Z".to_string(),
                    source: "cli".to_string(),
                    access_mode: AccessMode::ControlWithApprovals,
                    last_turn_summary: "done".to_string(),
                    active_turn_id: None,
                },
                latest_bridge_seq: None,
                entries: vec![],
                approvals: vec![],
                git_status: None,
                workflow_state: None,
                pending_user_input: None,
            })
            .await;

        let snapshot = store
            .snapshot("thread-1")
            .await
            .expect("snapshot should exist");
        assert_eq!(
            snapshot
                .workflow_state
                .as_ref()
                .map(|workflow| workflow.state.as_str()),
            Some("awaiting_questions")
        );
        let page = store
            .timeline_page("thread-1", None, 10)
            .await
            .expect("timeline page should exist");
        assert_eq!(
            page.workflow_state
                .as_ref()
                .and_then(|workflow| workflow.original_prompt.as_deref()),
            Some("Investigate reconnect replay")
        );
    }

    #[tokio::test]
    async fn hydrate_from_events_rebuilds_snapshots_from_bootstrap_summaries() {
        let store = ProjectionStore::new();
        store
            .replace_summaries(vec![ThreadSummaryDto {
                contract_version: CONTRACT_VERSION.to_string(),
                thread_id: "thread-1".to_string(),
                native_thread_id: "thread-1".to_string(),
                provider: shared_contracts::ProviderKind::Codex,
                client: shared_contracts::ThreadClientKind::Cli,
                title: "Recovered thread".to_string(),
                status: ThreadStatus::Idle,
                workspace: "/tmp/a".to_string(),
                repository: "repo-a".to_string(),
                branch: "main".to_string(),
                updated_at: "2026-03-21T10:00:00Z".to_string(),
            }])
            .await;

        store
            .hydrate_from_events(
                &[
                    BridgeEventEnvelope {
                        contract_version: CONTRACT_VERSION.to_string(),
                        event_id: "evt-msg".to_string(),
                        bridge_seq: Some(9),
                        thread_id: "thread-1".to_string(),
                        kind: BridgeEventKind::MessageDelta,
                        occurred_at: "2026-03-21T10:01:00Z".to_string(),
                        payload: json!({
                            "id": "msg-1",
                            "type": "message",
                            "role": "assistant",
                            "text": "Recovered output",
                        }),
                        annotations: None,
                    },
                    BridgeEventEnvelope {
                        contract_version: CONTRACT_VERSION.to_string(),
                        event_id: "evt-status".to_string(),
                        bridge_seq: Some(10),
                        thread_id: "thread-1".to_string(),
                        kind: BridgeEventKind::ThreadStatusChanged,
                        occurred_at: "2026-03-21T10:01:01Z".to_string(),
                        payload: json!({
                            "status": "completed",
                        }),
                        annotations: None,
                    },
                    BridgeEventEnvelope {
                        contract_version: CONTRACT_VERSION.to_string(),
                        event_id: "evt-input".to_string(),
                        bridge_seq: Some(11),
                        thread_id: "thread-1".to_string(),
                        kind: BridgeEventKind::UserInputRequested,
                        occurred_at: "2026-03-21T10:01:02Z".to_string(),
                        payload: json!({
                            "request_id": "req-1",
                            "title": "Clarify",
                            "questions": [],
                            "state": "pending",
                        }),
                        annotations: None,
                    },
                ],
                AccessMode::ControlWithApprovals,
            )
            .await;

        let snapshot = store
            .snapshot("thread-1")
            .await
            .expect("snapshot should be rebuilt from bootstrap summaries and persisted events");
        assert_eq!(snapshot.latest_bridge_seq, Some(11));
        assert_eq!(snapshot.thread.status, ThreadStatus::Completed);
        assert_eq!(snapshot.thread.last_turn_summary, "completed");
        assert_eq!(snapshot.entries.len(), 2);
        assert_eq!(snapshot.entries[0].summary, "Recovered output");
        assert_eq!(
            snapshot
                .pending_user_input
                .as_ref()
                .map(|value| value.request_id.as_str()),
            Some("req-1")
        );
    }

    #[tokio::test]
    async fn hydrate_from_events_restores_workflow_state_from_metadata_events() {
        let store = ProjectionStore::new();
        store
            .replace_summaries(vec![ThreadSummaryDto {
                contract_version: CONTRACT_VERSION.to_string(),
                thread_id: "thread-1".to_string(),
                native_thread_id: "thread-1".to_string(),
                provider: shared_contracts::ProviderKind::Codex,
                client: shared_contracts::ThreadClientKind::Cli,
                title: "Recovered thread".to_string(),
                status: ThreadStatus::Running,
                workspace: "/tmp/a".to_string(),
                repository: "repo-a".to_string(),
                branch: "main".to_string(),
                updated_at: "2026-03-21T10:00:00Z".to_string(),
            }])
            .await;

        store
            .hydrate_from_events(
                &[BridgeEventEnvelope {
                    contract_version: CONTRACT_VERSION.to_string(),
                    event_id: "evt-workflow".to_string(),
                    bridge_seq: Some(12),
                    thread_id: "thread-1".to_string(),
                    kind: BridgeEventKind::ThreadMetadataChanged,
                    occurred_at: "2026-03-21T10:01:03Z".to_string(),
                    payload: json!({
                        "workflow_state": {
                            "workflow_kind": "plan_questionnaire",
                            "state": "awaiting_questions",
                            "original_prompt": "Investigate replay resilience",
                        }
                    }),
                    annotations: None,
                }],
                AccessMode::ControlWithApprovals,
            )
            .await;

        let snapshot = store
            .snapshot("thread-1")
            .await
            .expect("snapshot should be rebuilt from metadata events");
        assert_eq!(snapshot.latest_bridge_seq, Some(12));
        assert_eq!(
            snapshot
                .workflow_state
                .as_ref()
                .map(|workflow| workflow.state.as_str()),
            Some("awaiting_questions")
        );
        let page = store
            .timeline_page("thread-1", None, 10)
            .await
            .expect("timeline page should exist");
        assert_eq!(
            page.workflow_state
                .as_ref()
                .and_then(|workflow| workflow.original_prompt.as_deref()),
            Some("Investigate replay resilience")
        );
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
                latest_bridge_seq: None,
                entries: vec![],
                approvals: vec![],
                git_status: None,
                workflow_state: None,
                pending_user_input: None,
            })
            .await;

        store
            .apply_live_event(&BridgeEventEnvelope {
                contract_version: CONTRACT_VERSION.to_string(),
                event_id: "evt-1".to_string(),
                bridge_seq: None,
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
                latest_bridge_seq: None,
                entries: vec![],
                approvals: vec![],
                git_status: None,
                workflow_state: None,
                pending_user_input: None,
            })
            .await;

        store
            .apply_live_event(&BridgeEventEnvelope {
                contract_version: CONTRACT_VERSION.to_string(),
                event_id: "evt-1".to_string(),
                bridge_seq: None,
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
            })
            .await;

        store
            .apply_live_event(&BridgeEventEnvelope {
                contract_version: CONTRACT_VERSION.to_string(),
                event_id: "evt-1".to_string(),
                bridge_seq: None,
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
            })
            .await;

        let snapshot = store
            .snapshot("thread-1")
            .await
            .expect("snapshot should exist");
        assert_eq!(snapshot.entries[0].payload["text"], "I'm checking");
    }

    #[tokio::test]
    async fn apply_live_user_message_replaces_matching_synthetic_visible_prompt() {
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
                    last_turn_summary: "Commit".to_string(),
                    active_turn_id: Some("turn-1".to_string()),
                },
                latest_bridge_seq: None,
                entries: vec![ThreadTimelineEntryDto {
                    event_id: "turn-1-visible-user-prompt".to_string(),
                    kind: BridgeEventKind::MessageDelta,
                    occurred_at: "2026-03-21T10:01:00Z".to_string(),
                    summary: "Commit".to_string(),
                    payload: json!({
                        "id": "",
                        "type": "userMessage",
                        "role": "user",
                        "text": "Commit",
                        "client_message_id": "client-1",
                    }),
                    annotations: None,
                }],
                approvals: vec![],
                git_status: None,
                workflow_state: None,
                pending_user_input: None,
            })
            .await;

        store
            .apply_live_event(&BridgeEventEnvelope {
                contract_version: CONTRACT_VERSION.to_string(),
                event_id: "turn-1-item-user-1".to_string(),
                bridge_seq: None,
                thread_id: "thread-1".to_string(),
                kind: BridgeEventKind::MessageDelta,
                occurred_at: "2026-03-21T10:01:01Z".to_string(),
                payload: json!({
                    "id": "item-user-1",
                    "type": "userMessage",
                    "role": "user",
                    "text": "Commit",
                    "client_message_id": "client-1",
                }),
                annotations: None,
            })
            .await;

        let snapshot = store
            .snapshot("thread-1")
            .await
            .expect("snapshot should exist");
        assert_eq!(snapshot.entries.len(), 1);
        assert_eq!(snapshot.entries[0].event_id, "turn-1-item-user-1");
    }

    #[tokio::test]
    async fn apply_live_user_message_dedupes_matching_archive_user_prompt() {
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
                    last_turn_summary: "Commit".to_string(),
                    active_turn_id: Some("turn-1".to_string()),
                },
                latest_bridge_seq: None,
                entries: vec![ThreadTimelineEntryDto {
                    event_id: "codex:thread-1-archive-2".to_string(),
                    kind: BridgeEventKind::MessageDelta,
                    occurred_at: "2026-03-21T10:01:00.000Z".to_string(),
                    summary: "Commit".to_string(),
                    payload: json!({
                        "type": "userMessage",
                        "role": "user",
                        "delta": "Commit",
                    }),
                    annotations: None,
                }],
                approvals: vec![],
                git_status: None,
                workflow_state: None,
                pending_user_input: None,
            })
            .await;

        store
            .apply_live_event(&BridgeEventEnvelope {
                contract_version: CONTRACT_VERSION.to_string(),
                event_id: "turn-1-item-user-1".to_string(),
                bridge_seq: None,
                thread_id: "thread-1".to_string(),
                kind: BridgeEventKind::MessageDelta,
                occurred_at: "2026-03-21T10:01:00.500Z".to_string(),
                payload: json!({
                    "id": "item-user-1",
                    "type": "message",
                    "role": "user",
                    "text": "Commit",
                }),
                annotations: None,
            })
            .await;

        let snapshot = store
            .snapshot("thread-1")
            .await
            .expect("snapshot should exist");
        assert_eq!(snapshot.entries.len(), 1);
        assert_eq!(snapshot.entries[0].event_id, "turn-1-item-user-1");
    }

    #[tokio::test]
    async fn apply_live_user_message_keeps_far_older_archive_user_prompt_with_same_text() {
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
                    last_turn_summary: "Commit".to_string(),
                    active_turn_id: Some("turn-2".to_string()),
                },
                latest_bridge_seq: None,
                entries: vec![ThreadTimelineEntryDto {
                    event_id: "codex:thread-1-archive-2".to_string(),
                    kind: BridgeEventKind::MessageDelta,
                    occurred_at: "2026-03-21T10:00:00.000Z".to_string(),
                    summary: "Commit".to_string(),
                    payload: json!({
                        "type": "userMessage",
                        "role": "user",
                        "delta": "Commit",
                    }),
                    annotations: None,
                }],
                approvals: vec![],
                git_status: None,
                workflow_state: None,
                pending_user_input: None,
            })
            .await;

        store
            .apply_live_event(&BridgeEventEnvelope {
                contract_version: CONTRACT_VERSION.to_string(),
                event_id: "turn-2-item-user-1".to_string(),
                bridge_seq: None,
                thread_id: "thread-1".to_string(),
                kind: BridgeEventKind::MessageDelta,
                occurred_at: "2026-03-21T10:05:00.000Z".to_string(),
                payload: json!({
                    "id": "item-user-1",
                    "type": "message",
                    "role": "user",
                    "text": "Commit",
                }),
                annotations: None,
            })
            .await;

        let snapshot = store
            .snapshot("thread-1")
            .await
            .expect("snapshot should exist");
        assert_eq!(snapshot.entries.len(), 2);
        assert_eq!(snapshot.entries[0].event_id, "codex:thread-1-archive-2");
        assert_eq!(snapshot.entries[1].event_id, "turn-2-item-user-1");
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
                latest_bridge_seq: None,
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
                workflow_state: None,
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
                latest_bridge_seq: None,
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
                workflow_state: None,
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
                latest_bridge_seq: None,
                entries: vec![],
                approvals: vec![],
                git_status: None,
                workflow_state: None,
                pending_user_input: None,
            })
            .await;

        store
            .apply_live_event(&BridgeEventEnvelope {
                contract_version: CONTRACT_VERSION.to_string(),
                event_id: "evt-plan".to_string(),
                bridge_seq: None,
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
                latest_bridge_seq: None,
                entries: vec![],
                approvals: vec![],
                git_status: None,
                workflow_state: None,
                pending_user_input: None,
            })
            .await;

        store
            .apply_live_event(&BridgeEventEnvelope {
                contract_version: CONTRACT_VERSION.to_string(),
                event_id: "evt-status".to_string(),
                bridge_seq: None,
                thread_id: "thread-1".to_string(),
                kind: BridgeEventKind::ThreadStatusChanged,
                occurred_at: "2026-03-21T10:01:00Z".to_string(),
                payload: json!({
                    "status": "completed",
                    "reason": "upstream_notification",
                }),
                annotations: None,
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
                latest_bridge_seq: None,
                entries: vec![],
                approvals: vec![],
                git_status: None,
                workflow_state: None,
                pending_user_input: None,
            })
            .await;

        store
            .apply_live_event(&BridgeEventEnvelope {
                contract_version: CONTRACT_VERSION.to_string(),
                event_id: "evt-turn-started".to_string(),
                bridge_seq: None,
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
}
