use serde::{Deserialize, Serialize};

pub const CONTRACT_VERSION: &str = "2026-03-23";

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
pub enum BridgeApiRouteKind {
    Tailscale,
    LocalNetwork,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BridgeApiRouteDto {
    pub id: String,
    pub kind: BridgeApiRouteKind,
    pub base_url: String,
    pub reachable: bool,
    pub is_preferred: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PairingRouteInventoryDto {
    pub reachable: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub advertised_base_url: Option<String>,
    #[serde(default)]
    pub routes: Vec<BridgeApiRouteDto>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NetworkSettingsDto {
    pub contract_version: String,
    pub local_network_pairing_enabled: bool,
    #[serde(default)]
    pub routes: Vec<BridgeApiRouteDto>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
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
pub struct ReasoningEffortOptionDto {
    pub reasoning_effort: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ModelOptionDto {
    pub id: String,
    pub model: String,
    pub display_name: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub is_default: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub default_reasoning_effort: Option<String>,
    #[serde(default)]
    pub supported_reasoning_efforts: Vec<ReasoningEffortOptionDto>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ModelCatalogDto {
    pub contract_version: String,
    pub models: Vec<ModelOptionDto>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SpeechModelStateDto {
    Unsupported,
    NotInstalled,
    Installing,
    Ready,
    Busy,
    Failed,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SpeechModelStatusDto {
    pub contract_version: String,
    pub provider: String,
    pub model_id: String,
    pub state: SpeechModelStateDto,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub download_progress: Option<u8>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_error: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub installed_bytes: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SpeechModelMutationAcceptedDto {
    pub contract_version: String,
    pub provider: String,
    pub model_id: String,
    pub state: SpeechModelStateDto,
    pub message: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SpeechTranscriptionResultDto {
    pub contract_version: String,
    pub provider: String,
    pub model_id: String,
    pub text: String,
    pub duration_ms: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ServiceHealthStatus {
    Healthy,
    Degraded,
    Unavailable,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ServiceHealthDto {
    pub status: ServiceHealthStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TrustStateDto {
    pub trusted: bool,
    pub access_mode: AccessMode,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BootstrapDto {
    pub contract_version: String,
    pub bridge: ServiceHealthDto,
    pub codex: ServiceHealthDto,
    pub trust: TrustStateDto,
    #[serde(default)]
    pub threads: Vec<ThreadSummaryDto>,
    #[serde(default)]
    pub models: Vec<ModelOptionDto>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ApprovalStatus {
    Pending,
    Approved,
    Rejected,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ApprovalSummaryDto {
    pub approval_id: String,
    pub thread_id: String,
    pub action: String,
    pub status: ApprovalStatus,
    pub reason: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub target: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GitStatusDto {
    pub workspace: String,
    pub repository: String,
    pub branch: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub remote: Option<String>,
    pub dirty: bool,
    pub ahead_by: u32,
    pub behind_by: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ThreadGitDiffMode {
    Workspace,
    LatestThreadChange,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum GitDiffChangeTypeDto {
    Added,
    Modified,
    Deleted,
    Renamed,
    Copied,
    TypeChanged,
    Unmerged,
    Unknown,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GitDiffFileSummaryDto {
    pub path: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub old_path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub new_path: Option<String>,
    pub change_type: GitDiffChangeTypeDto,
    pub additions: u32,
    pub deletions: u32,
    #[serde(default)]
    pub is_binary: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ThreadGitDiffDto {
    pub contract_version: String,
    pub thread: ThreadDetailDto,
    pub repository: GitStatusDto,
    pub mode: ThreadGitDiffMode,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub revision: Option<String>,
    #[serde(default)]
    pub files: Vec<GitDiffFileSummaryDto>,
    #[serde(default)]
    pub unified_diff: String,
    pub fetched_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ThreadSnapshotDto {
    pub contract_version: String,
    pub thread: ThreadDetailDto,
    #[serde(default)]
    pub entries: Vec<ThreadTimelineEntryDto>,
    #[serde(default)]
    pub approvals: Vec<ApprovalSummaryDto>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub git_status: Option<GitStatusDto>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TurnMutationAcceptedDto {
    pub contract_version: String,
    pub thread_id: String,
    pub thread_status: ThreadStatus,
    pub message: String,
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
        BootstrapDto, BridgeEventEnvelope, BridgeEventKind, CONTRACT_VERSION,
        SecurityAuditEventDto, ServiceHealthDto, ServiceHealthStatus, ThreadDetailDto,
        ThreadStatus, ThreadSummaryDto, ThreadTimelineExplorationKind, ThreadTimelineGroupKind,
        ThreadTimelinePageDto, TrustStateDto, TurnMutationAcceptedDto,
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

    #[test]
    fn bootstrap_contract_serializes_expected_shape() {
        let bootstrap = BootstrapDto {
            contract_version: CONTRACT_VERSION.to_string(),
            bridge: ServiceHealthDto {
                status: ServiceHealthStatus::Healthy,
                message: None,
            },
            codex: ServiceHealthDto {
                status: ServiceHealthStatus::Degraded,
                message: Some("notification stream reconnecting".to_string()),
            },
            trust: TrustStateDto {
                trusted: false,
                access_mode: super::AccessMode::ControlWithApprovals,
            },
            threads: vec![],
            models: vec![],
        };

        let value = serde_json::to_value(bootstrap).expect("bootstrap should serialize");
        assert_eq!(value["contract_version"], CONTRACT_VERSION);
        assert_eq!(value["bridge"]["status"], "healthy");
        assert_eq!(value["codex"]["status"], "degraded");
        assert_eq!(value["trust"]["access_mode"], "control_with_approvals");
    }

    #[test]
    fn turn_mutation_contract_serializes_expected_shape() {
        let accepted = TurnMutationAcceptedDto {
            contract_version: CONTRACT_VERSION.to_string(),
            thread_id: "thread-123".to_string(),
            thread_status: ThreadStatus::Running,
            message: "turn accepted".to_string(),
        };

        let value = serde_json::to_value(accepted).expect("turn mutation should serialize");
        assert_eq!(value["contract_version"], CONTRACT_VERSION);
        assert_eq!(value["thread_id"], "thread-123");
        assert_eq!(value["thread_status"], "running");
        assert_eq!(value["message"], "turn accepted");
    }
}
