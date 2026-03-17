use serde::{Deserialize, Serialize};

pub const CONTRACT_VERSION: &str = "2026-03-17";

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
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{
        BridgeEventEnvelope, BridgeEventKind, CONTRACT_VERSION, SecurityAuditEventDto,
        ThreadDetailDto, ThreadStatus, ThreadSummaryDto, ThreadTimelineEntryDto,
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
    fn thread_timeline_fixture_matches_contract() {
        let fixture = include_str!("../../../shared/contracts/fixtures/thread_timeline.json");
        let timeline: Vec<ThreadTimelineEntryDto> =
            serde_json::from_str(fixture).expect("thread timeline fixture should decode");

        assert_eq!(timeline.len(), 2);
        assert_eq!(timeline[0].kind, BridgeEventKind::MessageDelta);
        assert_eq!(timeline[1].payload["command"], "cargo test --workspace");
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
