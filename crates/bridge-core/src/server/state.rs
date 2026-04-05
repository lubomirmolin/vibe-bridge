use std::collections::{HashMap, HashSet};
use std::net::SocketAddr;
use std::path::Path;
use std::process::Command;
use std::sync::Arc;
use std::sync::Mutex;
use std::sync::MutexGuard;
use std::sync::mpsc;

use chrono::Utc;
use serde_json::{Value, json};
use shared_contracts::{
    AccessMode, BootstrapDto, BridgeEventEnvelope, BridgeEventKind, CONTRACT_VERSION,
    GitDiffChangeTypeDto, GitDiffFileSummaryDto, GitStatusDto as SharedGitStatusDto,
    ModelCatalogDto, ModelOptionDto, NetworkSettingsDto, PairingRouteInventoryDto,
    PendingUserInputDto, ProviderKind, SecurityAuditEventDto, ServiceHealthDto,
    ServiceHealthStatus, ThreadGitDiffDto, ThreadGitDiffMode, ThreadSnapshotDto, ThreadStatus,
    ThreadSummaryDto, ThreadTimelineEntryDto, ThreadTimelinePageDto, ThreadUsageDto,
    ThreadWorkflowStateDto, TrustStateDto, TurnMode, TurnMutationAcceptedDto, UserInputAnswerDto,
    UserInputOptionDto, UserInputQuestionDto,
};
use tokio::sync::RwLock;
use tokio::sync::oneshot;
use tokio::time::{Duration, sleep};

use crate::codex_ipc::{
    DesktopIpcClient, DesktopIpcConfig, DesktopStreamChange, apply_patches, diff_thread_snapshots,
    raw_turn_status, snapshot_from_conversation_state,
};
use crate::incremental_text::compact_incremental_full_text;
use crate::pairing::{
    PairingFinalizeError, PairingFinalizeRequest, PairingFinalizeResponse, PairingHandshakeError,
    PairingHandshakeRequest, PairingHandshakeResponse, PairingRevokeRequest, PairingRevokeResponse,
    PairingSessionResponse, PairingSessionService, PairingTrustSnapshot,
};
use crate::policy::{PolicyAction, PolicyDecision, PolicyEngine};
use crate::server::codex_usage::{CodexUsageClient, CodexUsageError};
use crate::server::config::{BridgeCodexConfig, BridgeConfig};
use crate::server::contracts::{
    GitMutationStatusDto, GitStatusResponse, MutationResultResponse, RepositoryContextDto,
};
use crate::server::controls::{
    ApprovalGateResponse, ApprovalRecordDto, ApprovalResolutionResponse, ApprovalStatus,
    ExecutedGitMutation, PendingApprovalAction, execute_branch_switch, execute_pull, execute_push,
    read_git_state, read_git_state_for_status,
};
use crate::server::events::EventHub;
use crate::server::gateway::{CodexGateway, GatewayTurnControlRequest, TurnStartRequest};
use crate::server::pairing_route::PairingRouteState;
use crate::server::projection::ProjectionStore;
use crate::server::speech::{SpeechError, SpeechService};
use crate::thread_identity::{is_provider_thread_id, provider_from_thread_id};

mod approvals;
mod desktop_ipc;
mod git_diff;
mod lifecycle;
mod live;
mod snapshots;
mod streams;
mod thread_runtime;
mod titles;
mod turns;
pub(in crate::server) mod user_input;
mod workflow;

use self::git_diff::*;
use self::live::*;
use self::titles::*;
use self::user_input::*;
use self::workflow::*;

#[derive(Debug, Clone)]
pub struct BridgeAppState {
    inner: Arc<BridgeAppStateInner>,
}

#[derive(Debug)]
struct BridgeAppStateInner {
    projections: ProjectionStore,
    codex_health: RwLock<ServiceHealthDto>,
    available_models: RwLock<Vec<ModelOptionDto>>,
    bridge_turn_metadata: RwLock<HashMap<String, Vec<ThreadTimelineEntryDto>>>,
    thread_runtimes: RwLock<HashMap<String, CodexThreadRuntime>>,
    inflight_thread_title_generations: RwLock<HashSet<String>>,
    access_mode: RwLock<AccessMode>,
    security_events: RwLock<Vec<SecurityEventRecordDto>>,
    codex_usage_client: RwLock<CodexUsageClient>,
    gateway: CodexGateway,
    event_hub: EventHub,
    desktop_ipc_control_tx: Mutex<Option<mpsc::Sender<NotificationControlMessage>>>,
    pairing_sessions: Mutex<PairingSessionService>,
    pairing_route: PairingRouteState,
    git_controls: Mutex<GitControlState>,
    speech: SpeechService,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum NotificationControlMessage {
    ResumeThread(String),
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct SecurityEventRecordDto {
    pub severity: String,
    pub category: String,
    pub event: BridgeEventEnvelope<Value>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct PendingApprovalRecord {
    approval: ApprovalRecordDto,
    action: PendingApprovalAction,
}

#[derive(Debug, Default)]
struct GitControlState {
    approvals: HashMap<String, PendingApprovalRecord>,
    next_approval_sequence: u64,
}

const USER_INPUT_OPTION_ALLOW_ONCE: &str = "allow_once";
const USER_INPUT_OPTION_ALLOW_SESSION: &str = "allow_for_session";
const USER_INPUT_OPTION_DENY: &str = "deny";

#[derive(Debug)]
enum PendingUserInputSession {
    NativeCodexRequestUserInput(PendingNativeUserInputSession),
    ProviderApproval(PendingProviderApprovalSession),
}

#[derive(Debug)]
struct PendingNativeUserInputSession {
    questionnaire: PendingUserInputDto,
    resolution_tx: oneshot::Sender<Value>,
}

#[derive(Debug)]
struct PendingProviderApprovalSession {
    questionnaire: PendingUserInputDto,
    provider_request_id: String,
    context: ProviderApprovalContext,
    resolution_tx: oneshot::Sender<ProviderApprovalSelection>,
}

#[derive(Debug, Clone)]
struct PendingTurnClientMessage {
    client_message_id: String,
    turn_id: Option<String>,
    prompt_text: String,
}

#[derive(Debug, Default)]
struct CodexThreadRuntime {
    active_turn_id: Option<String>,
    interrupted: bool,
    pending_client_message: Option<PendingTurnClientMessage>,
    pending_user_input: Option<PendingUserInputSession>,
    resumable_notifications: bool,
    pending_user_message_images: Vec<String>,
}

impl CodexThreadRuntime {
    fn is_empty(&self) -> bool {
        self.active_turn_id.is_none()
            && !self.interrupted
            && self.pending_client_message.is_none()
            && self.pending_user_input.is_none()
            && !self.resumable_notifications
            && self.pending_user_message_images.is_empty()
    }
}

#[derive(Debug, Clone)]
struct ProviderApprovalPrompt {
    questionnaire: PendingUserInputDto,
    provider_request_id: String,
    context: ProviderApprovalContext,
}

#[derive(Debug, Clone)]
enum ProviderApprovalContext {
    CodexCommandOrFile,
    CodexPermissions { turn_id: String },
    ClaudeCanUseTool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ProviderApprovalSelection {
    AllowOnce,
    AllowForSession,
    Deny,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ResolveApprovalError {
    NotFound,
    NotPending,
    TargetNotFound,
    MutationFailed(String),
}

impl GitControlState {
    fn queue_approval(
        &mut self,
        action: PendingApprovalAction,
        reason: &str,
        repository: RepositoryContextDto,
        git_status: GitMutationStatusDto,
        occurred_at: &str,
    ) -> ApprovalRecordDto {
        self.next_approval_sequence = self.next_approval_sequence.saturating_add(1);
        let approval = ApprovalRecordDto {
            contract_version: shared_contracts::CONTRACT_VERSION.to_string(),
            approval_id: format!("approval-{}", self.next_approval_sequence),
            thread_id: action.thread_id().to_string(),
            action: action.operation_name().to_string(),
            target: action.target_name(),
            reason: reason.to_string(),
            status: ApprovalStatus::Pending,
            requested_at: occurred_at.to_string(),
            resolved_at: None,
            repository,
            git_status,
        };
        self.approvals.insert(
            approval.approval_id.clone(),
            PendingApprovalRecord {
                approval: approval.clone(),
                action,
            },
        );
        approval
    }

    fn resolve_approval(
        &mut self,
        approval_id: &str,
        approved: bool,
        resolved_at: &str,
    ) -> Result<PendingApprovalRecord, ResolveApprovalError> {
        let Some(record) = self.approvals.get_mut(approval_id) else {
            return Err(ResolveApprovalError::NotFound);
        };
        if record.approval.status != ApprovalStatus::Pending {
            return Err(ResolveApprovalError::NotPending);
        }
        record.approval.status = if approved {
            ApprovalStatus::Approved
        } else {
            ApprovalStatus::Rejected
        };
        record.approval.resolved_at = Some(resolved_at.to_string());
        Ok(record.clone())
    }

    fn restore_pending(&mut self, approval_id: &str) {
        if let Some(record) = self.approvals.get_mut(approval_id) {
            record.approval.status = ApprovalStatus::Pending;
            record.approval.resolved_at = None;
        }
    }
}

#[cfg(test)]
mod tests;
