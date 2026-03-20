use serde::{Deserialize, Serialize};

pub const CONTRACT_VERSION: &str = "2026-03-20";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ThreadStatus {
    Idle,
    Running,
    Completed,
    Interrupted,
    Failed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AccessMode {
    ReadOnly,
    ControlWithApprovals,
    FullControl,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BridgeEventKind {
    MessageDelta,
    PlanDelta,
    CommandDelta,
    FileChange,
    ApprovalRequested,
    ThreadStatusChanged,
    SecurityAudit,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ThreadTimelineGroupKind {
    Exploration,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ThreadTimelineExplorationKind {
    Read,
    Search,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ThreadTimelineAnnotationsDto {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub group_kind: Option<ThreadTimelineGroupKind>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub group_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exploration_kind: Option<ThreadTimelineExplorationKind>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub entry_label: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ThreadSummaryDto {
    pub contract_version: String,
    pub thread_id: String,
    pub title: String,
    pub status: ThreadStatus,
    pub workspace: String,
    pub repository: String,
    pub branch: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ThreadDetailDto {
    pub contract_version: String,
    pub thread_id: String,
    pub title: String,
    pub status: ThreadStatus,
    pub workspace: String,
    pub repository: String,
    pub branch: String,
    pub created_at: String,
    pub updated_at: String,
    pub source: String,
    pub access_mode: AccessMode,
    pub last_turn_summary: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ThreadTimelineEntryDto {
    pub event_id: String,
    pub kind: BridgeEventKind,
    pub occurred_at: String,
    pub summary: String,
    pub payload: serde_json::Value,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub annotations: Option<ThreadTimelineAnnotationsDto>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ThreadTimelinePageDto {
    pub contract_version: String,
    pub thread: ThreadDetailDto,
    pub entries: Vec<ThreadTimelineEntryDto>,
    pub next_before: Option<String>,
    pub has_more_before: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SecurityAuditEventDto {
    pub actor: String,
    pub action: String,
    pub target: String,
    pub outcome: String,
    pub reason: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BridgeEventEnvelope<TPayload> {
    pub contract_version: String,
    pub event_id: String,
    pub thread_id: String,
    pub kind: BridgeEventKind,
    pub occurred_at: String,
    pub payload: TPayload,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub annotations: Option<ThreadTimelineAnnotationsDto>,
}

impl<TPayload> BridgeEventEnvelope<TPayload> {
    pub fn new(
        event_id: impl Into<String>,
        thread_id: impl Into<String>,
        kind: BridgeEventKind,
        occurred_at: impl Into<String>,
        payload: TPayload,
    ) -> Self {
        Self {
            contract_version: CONTRACT_VERSION.to_string(),
            event_id: event_id.into(),
            thread_id: thread_id.into(),
            kind,
            occurred_at: occurred_at.into(),
            payload,
            annotations: None,
        }
    }

    pub fn with_annotations(mut self, annotations: Option<ThreadTimelineAnnotationsDto>) -> Self {
        self.annotations = annotations;
        self
    }
}

#[cfg(test)]
mod tests {
    use super::{
        BridgeEventEnvelope, BridgeEventKind, CONTRACT_VERSION, SecurityAuditEventDto,
        ThreadDetailDto, ThreadStatus, ThreadSummaryDto, ThreadTimelineExplorationKind,
        ThreadTimelineGroupKind, ThreadTimelinePageDto,
    };

    #[test]
    fn thread_summary_fixture_matches_contract() {
        let fixture = include_str!("../../../shared/contracts/fixtures/thread_summary.json");
        let summary: ThreadSummaryDto =
            serde_json::from_str(fixture).expect("thread fixture should decode");

        assert_eq!(summary.contract_version, CONTRACT_VERSION);
        assert_eq!(summary.status, ThreadStatus::Running);
        assert_eq!(summary.repository, "codex-mobile-companion");
    }

    #[test]
    fn message_event_fixture_matches_contract() {
        let fixture =
            include_str!("../../../shared/contracts/fixtures/bridge_event_message_delta.json");
        let event: BridgeEventEnvelope<serde_json::Value> =
            serde_json::from_str(fixture).expect("event fixture should decode");

        assert_eq!(event.contract_version, CONTRACT_VERSION);
        assert_eq!(event.kind, BridgeEventKind::MessageDelta);
        assert_eq!(event.payload["delta"], "Working on foundation contracts");
        assert!(event.annotations.is_none());
    }

    #[test]
    fn thread_detail_fixture_matches_contract() {
        let fixture = include_str!("../../../shared/contracts/fixtures/thread_detail.json");
        let detail: ThreadDetailDto =
            serde_json::from_str(fixture).expect("thread detail fixture should decode");

        assert_eq!(detail.contract_version, CONTRACT_VERSION);
        assert_eq!(detail.thread_id, "thread-123");
        assert_eq!(detail.last_turn_summary, "Summarized lifecycle behavior");
    }

    #[test]
    fn thread_timeline_page_fixture_matches_contract() {
        let fixture = include_str!("../../../shared/contracts/fixtures/thread_timeline_page.json");
        let timeline: ThreadTimelinePageDto =
            serde_json::from_str(fixture).expect("thread timeline page fixture should decode");

        assert_eq!(timeline.thread.thread_id, "thread-123");
        assert_eq!(timeline.entries.len(), 2);
        assert_eq!(timeline.entries[0].kind, BridgeEventKind::MessageDelta);
        assert_eq!(
            timeline.entries[1].payload["command"],
            "rg -n workspace crates/shared-contracts/src/lib.rs"
        );
        let annotations = timeline.entries[1]
            .annotations
            .as_ref()
            .expect("timeline entry should include annotations");
        assert_eq!(
            annotations.group_kind,
            Some(ThreadTimelineGroupKind::Exploration)
        );
        assert_eq!(
            annotations.exploration_kind,
            Some(ThreadTimelineExplorationKind::Search)
        );
        assert_eq!(annotations.entry_label.as_deref(), Some("Search"));
        assert_eq!(timeline.next_before.as_deref(), Some("evt-1"));
        assert!(timeline.has_more_before);
    }

    #[test]
    fn security_audit_fixture_matches_contract() {
        let fixture = include_str!("../../../shared/contracts/fixtures/security_audit_event.json");
        let event: SecurityAuditEventDto =
            serde_json::from_str(fixture).expect("security fixture should decode");

        assert_eq!(event.target, "git.push");
        assert_eq!(event.outcome, "allowed");
    }
}
