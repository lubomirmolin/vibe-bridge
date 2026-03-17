use std::collections::HashMap;

use serde::Serialize;
use serde_json::json;
use shared_contracts::{
    AccessMode, BridgeEventKind, CONTRACT_VERSION, ThreadDetailDto, ThreadStatus, ThreadSummaryDto,
    ThreadTimelineEntryDto,
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UpstreamThreadRecord {
    pub id: String,
    pub headline: String,
    pub lifecycle_state: String,
    pub workspace_path: String,
    pub repository_name: String,
    pub branch_name: String,
    pub created_at: String,
    pub updated_at: String,
    pub source: String,
    pub approval_mode: String,
    pub last_turn_summary: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UpstreamTimelineEvent {
    pub id: String,
    pub event_type: String,
    pub happened_at: String,
    pub summary_text: String,
    pub data: serde_json::Value,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ThreadApiService {
    thread_records: Vec<UpstreamThreadRecord>,
    timeline_by_thread_id: HashMap<String, Vec<UpstreamTimelineEvent>>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ThreadListResponse {
    pub contract_version: String,
    pub threads: Vec<ThreadSummaryDto>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ThreadDetailResponse {
    pub contract_version: String,
    pub thread: ThreadDetailDto,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ThreadTimelineResponse {
    pub contract_version: String,
    pub thread_id: String,
    pub events: Vec<ThreadTimelineEntryDto>,
}

impl ThreadApiService {
    pub fn with_seed_data(
        thread_records: Vec<UpstreamThreadRecord>,
        timeline_by_thread_id: HashMap<String, Vec<UpstreamTimelineEvent>>,
    ) -> Self {
        Self {
            thread_records,
            timeline_by_thread_id,
        }
    }

    pub fn sample() -> Self {
        let thread_records = vec![
            UpstreamThreadRecord {
                id: "thread-123".to_string(),
                headline: "Implement shared contracts".to_string(),
                lifecycle_state: "active".to_string(),
                workspace_path: "/workspace/codex-mobile-companion".to_string(),
                repository_name: "codex-mobile-companion".to_string(),
                branch_name: "master".to_string(),
                created_at: "2026-03-17T17:45:00Z".to_string(),
                updated_at: "2026-03-17T18:00:00Z".to_string(),
                source: "cli".to_string(),
                approval_mode: "control_with_approvals".to_string(),
                last_turn_summary: "Summarized lifecycle behavior".to_string(),
            },
            UpstreamThreadRecord {
                id: "thread-456".to_string(),
                headline: "Investigate reconnect dedup".to_string(),
                lifecycle_state: "done".to_string(),
                workspace_path: "/workspace/codex-mobile-companion".to_string(),
                repository_name: "codex-mobile-companion".to_string(),
                branch_name: "master".to_string(),
                created_at: "2026-03-17T16:30:00Z".to_string(),
                updated_at: "2026-03-17T17:30:00Z".to_string(),
                source: "vscode".to_string(),
                approval_mode: "full_control".to_string(),
                last_turn_summary: "Captured reconnect edge cases".to_string(),
            },
        ];

        let timeline_by_thread_id = HashMap::from([(
            "thread-123".to_string(),
            vec![
                UpstreamTimelineEvent {
                    id: "evt-1".to_string(),
                    event_type: "agent_message_delta".to_string(),
                    happened_at: "2026-03-17T18:01:00Z".to_string(),
                    summary_text: "Agent emitted message delta".to_string(),
                    data: json!({ "delta": "Working on foundation contracts" }),
                },
                UpstreamTimelineEvent {
                    id: "evt-2".to_string(),
                    event_type: "command_output_delta".to_string(),
                    happened_at: "2026-03-17T18:01:10Z".to_string(),
                    summary_text: "Command output streamed".to_string(),
                    data: json!({ "command": "cargo test --workspace", "delta": "running 12 tests" }),
                },
            ],
        )]);

        Self::with_seed_data(thread_records, timeline_by_thread_id)
    }

    pub fn list_response(&self) -> ThreadListResponse {
        ThreadListResponse {
            contract_version: CONTRACT_VERSION.to_string(),
            threads: self
                .thread_records
                .iter()
                .map(map_thread_summary)
                .collect::<Vec<_>>(),
        }
    }

    pub fn detail_response(&self, thread_id: &str) -> Option<ThreadDetailResponse> {
        self.thread_records
            .iter()
            .find(|thread| thread.id == thread_id)
            .map(|thread| ThreadDetailResponse {
                contract_version: CONTRACT_VERSION.to_string(),
                thread: map_thread_detail(thread),
            })
    }

    pub fn timeline_response(&self, thread_id: &str) -> Option<ThreadTimelineResponse> {
        self.timeline_by_thread_id
            .get(thread_id)
            .map(|events| ThreadTimelineResponse {
                contract_version: CONTRACT_VERSION.to_string(),
                thread_id: thread_id.to_string(),
                events: events.iter().map(map_timeline_entry).collect::<Vec<_>>(),
            })
    }
}

fn map_thread_summary(upstream: &UpstreamThreadRecord) -> ThreadSummaryDto {
    ThreadSummaryDto {
        contract_version: CONTRACT_VERSION.to_string(),
        thread_id: upstream.id.clone(),
        title: upstream.headline.clone(),
        status: map_thread_status(&upstream.lifecycle_state),
        workspace: upstream.workspace_path.clone(),
        repository: upstream.repository_name.clone(),
        branch: upstream.branch_name.clone(),
        updated_at: upstream.updated_at.clone(),
    }
}

fn map_thread_detail(upstream: &UpstreamThreadRecord) -> ThreadDetailDto {
    ThreadDetailDto {
        contract_version: CONTRACT_VERSION.to_string(),
        thread_id: upstream.id.clone(),
        title: upstream.headline.clone(),
        status: map_thread_status(&upstream.lifecycle_state),
        workspace: upstream.workspace_path.clone(),
        repository: upstream.repository_name.clone(),
        branch: upstream.branch_name.clone(),
        created_at: upstream.created_at.clone(),
        updated_at: upstream.updated_at.clone(),
        source: upstream.source.clone(),
        access_mode: map_access_mode(&upstream.approval_mode),
        last_turn_summary: upstream.last_turn_summary.clone(),
    }
}

fn map_timeline_entry(upstream: &UpstreamTimelineEvent) -> ThreadTimelineEntryDto {
    ThreadTimelineEntryDto {
        event_id: upstream.id.clone(),
        kind: map_event_kind(&upstream.event_type),
        occurred_at: upstream.happened_at.clone(),
        summary: upstream.summary_text.clone(),
        payload: upstream.data.clone(),
    }
}

fn map_thread_status(raw: &str) -> ThreadStatus {
    match raw {
        "active" => ThreadStatus::Running,
        "done" => ThreadStatus::Completed,
        "halted" => ThreadStatus::Interrupted,
        "error" => ThreadStatus::Failed,
        _ => ThreadStatus::Idle,
    }
}

fn map_access_mode(raw: &str) -> AccessMode {
    match raw {
        "read_only" => AccessMode::ReadOnly,
        "full_control" => AccessMode::FullControl,
        _ => AccessMode::ControlWithApprovals,
    }
}

fn map_event_kind(raw: &str) -> BridgeEventKind {
    match raw {
        "agent_message_delta" => BridgeEventKind::MessageDelta,
        "plan_delta" => BridgeEventKind::PlanDelta,
        "command_output_delta" => BridgeEventKind::CommandDelta,
        "file_change_delta" => BridgeEventKind::FileChange,
        "approval_requested" => BridgeEventKind::ApprovalRequested,
        "thread_status_changed" => BridgeEventKind::ThreadStatusChanged,
        _ => BridgeEventKind::MessageDelta,
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;

    use super::{ThreadApiService, UpstreamThreadRecord, UpstreamTimelineEvent};
    use shared_contracts::{AccessMode, BridgeEventKind, CONTRACT_VERSION, ThreadStatus};

    #[test]
    fn list_and_detail_responses_normalize_upstream_thread_shapes() {
        let service = ThreadApiService::with_seed_data(
            vec![UpstreamThreadRecord {
                id: "thread-abc".to_string(),
                headline: "Normalize thread payloads".to_string(),
                lifecycle_state: "active".to_string(),
                workspace_path: "/workspace/codex-mobile-companion".to_string(),
                repository_name: "codex-mobile-companion".to_string(),
                branch_name: "master".to_string(),
                created_at: "2026-03-17T10:00:00Z".to_string(),
                updated_at: "2026-03-17T10:05:00Z".to_string(),
                source: "cli".to_string(),
                approval_mode: "read_only".to_string(),
                last_turn_summary: "started normalization".to_string(),
            }],
            HashMap::new(),
        );

        let list = service.list_response();
        assert_eq!(list.contract_version, CONTRACT_VERSION);
        assert_eq!(list.threads[0].thread_id, "thread-abc");
        assert_eq!(list.threads[0].status, ThreadStatus::Running);

        let detail = service
            .detail_response("thread-abc")
            .expect("detail response should exist");
        assert_eq!(detail.thread.access_mode, AccessMode::ReadOnly);
        assert_eq!(detail.thread.last_turn_summary, "started normalization");
    }

    #[test]
    fn timeline_response_normalizes_event_kinds() {
        let service = ThreadApiService::with_seed_data(
            vec![UpstreamThreadRecord {
                id: "thread-abc".to_string(),
                headline: "Normalize stream payloads".to_string(),
                lifecycle_state: "active".to_string(),
                workspace_path: "/workspace/codex-mobile-companion".to_string(),
                repository_name: "codex-mobile-companion".to_string(),
                branch_name: "master".to_string(),
                created_at: "2026-03-17T10:00:00Z".to_string(),
                updated_at: "2026-03-17T10:05:00Z".to_string(),
                source: "cli".to_string(),
                approval_mode: "control_with_approvals".to_string(),
                last_turn_summary: "streaming".to_string(),
            }],
            HashMap::from([(
                "thread-abc".to_string(),
                vec![UpstreamTimelineEvent {
                    id: "evt-abc".to_string(),
                    event_type: "command_output_delta".to_string(),
                    happened_at: "2026-03-17T10:06:00Z".to_string(),
                    summary_text: "command output".to_string(),
                    data: serde_json::json!({ "delta": "line" }),
                }],
            )]),
        );

        let timeline = service
            .timeline_response("thread-abc")
            .expect("timeline response should exist");

        assert_eq!(timeline.contract_version, CONTRACT_VERSION);
        assert_eq!(timeline.events.len(), 1);
        assert_eq!(timeline.events[0].kind, BridgeEventKind::CommandDelta);
    }
}
