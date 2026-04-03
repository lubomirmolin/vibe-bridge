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
    ThreadSummaryDto, ThreadTimelineEntryDto, ThreadTimelinePageDto, ThreadUsageDto, TrustStateDto,
    TurnMode, TurnMutationAcceptedDto, UserInputAnswerDto, UserInputOptionDto,
    UserInputQuestionDto,
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
use crate::thread_api::{
    GitStatusResponse, MutationResultResponse, RepositoryContextDto, is_provider_thread_id,
    provider_from_thread_id,
};

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
    active_turn_ids: RwLock<HashMap<String, String>>,
    active_turn_stream_threads: RwLock<HashSet<String>>,
    interrupted_threads: RwLock<HashSet<String>>,
    pending_bridge_owned_turns: RwLock<HashSet<String>>,
    awaiting_plan_question_prompts: RwLock<HashMap<String, String>>,
    pending_user_inputs: RwLock<HashMap<String, PendingUserInputSession>>,
    resumed_notification_threads: RwLock<HashSet<String>>,
    inflight_thread_title_generations: RwLock<HashSet<String>>,
    pending_user_message_images: RwLock<HashMap<String, Vec<String>>>,
    access_mode: RwLock<AccessMode>,
    security_events: RwLock<Vec<SecurityEventRecordDto>>,
    codex_usage_client: RwLock<CodexUsageClient>,
    gateway: CodexGateway,
    event_hub: EventHub,
    notification_control_tx: Mutex<Option<mpsc::Sender<NotificationControlMessage>>>,
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
    PlanQuestionnaire {
        questionnaire: PendingUserInputDto,
        original_prompt: String,
    },
    ProviderApproval(PendingProviderApprovalSession),
}

#[derive(Debug)]
struct PendingProviderApprovalSession {
    questionnaire: PendingUserInputDto,
    provider_request_id: String,
    context: ProviderApprovalContext,
    resolution_tx: oneshot::Sender<ProviderApprovalSelection>,
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
        git_status: crate::thread_api::GitStatusDto,
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

impl BridgeAppState {
    pub fn new(
        config: BridgeCodexConfig,
        pairing_sessions: PairingSessionService,
        pairing_route: PairingRouteState,
        speech: SpeechService,
    ) -> Self {
        Self {
            inner: Arc::new(BridgeAppStateInner {
                projections: ProjectionStore::new(),
                codex_health: RwLock::new(ServiceHealthDto {
                    status: ServiceHealthStatus::Degraded,
                    message: Some("codex bootstrap has not run yet".to_string()),
                }),
                available_models: RwLock::new(Vec::new()),
                bridge_turn_metadata: RwLock::new(HashMap::new()),
                active_turn_ids: RwLock::new(HashMap::new()),
                active_turn_stream_threads: RwLock::new(HashSet::new()),
                interrupted_threads: RwLock::new(HashSet::new()),
                pending_bridge_owned_turns: RwLock::new(HashSet::new()),
                awaiting_plan_question_prompts: RwLock::new(HashMap::new()),
                pending_user_inputs: RwLock::new(HashMap::new()),
                resumed_notification_threads: RwLock::new(HashSet::new()),
                inflight_thread_title_generations: RwLock::new(HashSet::new()),
                pending_user_message_images: RwLock::new(HashMap::new()),
                access_mode: RwLock::new(AccessMode::ControlWithApprovals),
                security_events: RwLock::new(Vec::new()),
                codex_usage_client: RwLock::new(CodexUsageClient::default()),
                gateway: CodexGateway::new(config),
                event_hub: EventHub::new(512),
                notification_control_tx: Mutex::new(None),
                desktop_ipc_control_tx: Mutex::new(None),
                pairing_sessions: Mutex::new(pairing_sessions),
                pairing_route,
                git_controls: Mutex::new(GitControlState::default()),
                speech,
            }),
        }
    }

    pub async fn from_config(config: BridgeConfig) -> Self {
        let pairing_sessions = PairingSessionService::new(
            config.host.as_str(),
            config.port,
            config.pairing_route.pairing_base_url().to_string(),
            config.state_directory.clone(),
        );
        let speech = SpeechService::from_config(&config).await;
        let state = Self::new(config.codex, pairing_sessions, config.pairing_route, speech);

        match state.inner.gateway.bootstrap().await {
            Ok(bootstrap) => {
                let preserved_summaries =
                    merge_reconciled_thread_summaries(Vec::new(), bootstrap.summaries);
                state
                    .projections()
                    .replace_summaries(preserved_summaries)
                    .await;
                state.set_available_models(bootstrap.models).await;
                state
                    .set_codex_health(ServiceHealthDto {
                        status: ServiceHealthStatus::Healthy,
                        message: bootstrap.message,
                    })
                    .await;
                state.schedule_recent_placeholder_title_backfill(3).await;
            }
            Err(error) => {
                state
                    .set_codex_health(ServiceHealthDto {
                        status: ServiceHealthStatus::Degraded,
                        message: Some(error),
                    })
                    .await;
            }
        }

        state
    }

    pub fn pairing_route_health(&self) -> PairingRouteInventoryDto {
        self.inner.pairing_route.health()
    }

    pub fn network_settings(&self) -> NetworkSettingsDto {
        self.inner.pairing_route.network_settings()
    }

    pub fn set_local_network_pairing_enabled(
        &self,
        enabled: bool,
    ) -> Result<NetworkSettingsDto, String> {
        self.inner
            .pairing_route
            .set_local_network_pairing_enabled(enabled)
    }

    pub fn desired_lan_listener_addr(&self) -> Option<SocketAddr> {
        self.inner.pairing_route.desired_lan_listener_addr()
    }

    pub fn record_lan_listener_active(&self, bind_addr: SocketAddr) {
        self.inner
            .pairing_route
            .record_lan_listener_active(bind_addr);
    }

    pub fn record_lan_listener_error(&self, error: impl Into<String>) {
        self.inner.pairing_route.record_lan_listener_error(error);
    }

    pub fn clear_lan_listener_runtime(&self) {
        self.inner.pairing_route.clear_lan_listener_runtime();
    }

    fn pairing_sessions_guard(&self) -> MutexGuard<'_, PairingSessionService> {
        match self.inner.pairing_sessions.lock() {
            Ok(guard) => guard,
            Err(poisoned) => {
                eprintln!(
                    "bridge pairing session state was poisoned; continuing with recovered state"
                );
                poisoned.into_inner()
            }
        }
    }

    pub fn trust_snapshot(&self) -> PairingTrustSnapshot {
        self.pairing_sessions_guard().trust_snapshot()
    }

    pub fn issue_pairing_session(&self) -> PairingSessionResponse {
        self.pairing_sessions_guard()
            .issue_session_with_routes(self.inner.pairing_route.pairing_routes())
    }

    pub fn finalize_trust(
        &self,
        request: PairingFinalizeRequest,
    ) -> Result<PairingFinalizeResponse, PairingFinalizeError> {
        self.pairing_sessions_guard()
            .finalize_trust_with_routes(request, self.inner.pairing_route.pairing_routes())
    }

    pub fn handshake(
        &self,
        request: PairingHandshakeRequest,
    ) -> Result<PairingHandshakeResponse, PairingHandshakeError> {
        self.pairing_sessions_guard()
            .handshake_with_routes(request, self.inner.pairing_route.pairing_routes())
    }

    pub fn authorize_trusted_session(
        &self,
        request: PairingHandshakeRequest,
    ) -> Result<(), PairingHandshakeError> {
        self.handshake(request).map(|_| ())
    }

    pub fn revoke_trust(&self, phone_id: Option<String>) -> Result<PairingRevokeResponse, String> {
        self.pairing_sessions_guard()
            .revoke_trust(PairingRevokeRequest { phone_id })
    }

    pub fn projections(&self) -> &ProjectionStore {
        &self.inner.projections
    }

    pub fn event_hub(&self) -> &EventHub {
        &self.inner.event_hub
    }

    pub async fn access_mode(&self) -> AccessMode {
        *self.inner.access_mode.read().await
    }

    pub async fn set_access_mode(&self, access_mode: AccessMode) {
        *self.inner.access_mode.write().await = access_mode;
        self.projections().set_access_mode(access_mode).await;
    }

    pub async fn decide_policy(&self, action: PolicyAction) -> PolicyDecision {
        PolicyEngine::new(self.access_mode().await).decide(action)
    }

    pub async fn security_events_snapshot(&self) -> Vec<SecurityEventRecordDto> {
        self.inner.security_events.read().await.clone()
    }

    pub async fn approval_records(&self) -> Vec<ApprovalRecordDto> {
        self.projections().list_approval_records().await
    }

    pub async fn record_security_audit(
        &self,
        severity: impl Into<String>,
        category: impl Into<String>,
        target: impl Into<String>,
        audit_event: SecurityAuditEventDto,
    ) {
        let occurred_at = Utc::now().to_rfc3339();
        let event = BridgeEventEnvelope {
            contract_version: shared_contracts::CONTRACT_VERSION.to_string(),
            event_id: format!(
                "security-{}",
                self.inner.security_events.read().await.len() + 1
            ),
            thread_id: target.into(),
            kind: BridgeEventKind::SecurityAudit,
            occurred_at,
            payload: serde_json::to_value(audit_event)
                .expect("security audit payload should serialize"),
            annotations: None,
        };
        let record = SecurityEventRecordDto {
            severity: severity.into(),
            category: category.into(),
            event,
        };
        self.inner.security_events.write().await.push(record);
    }

    pub async fn ensure_snapshot(&self, thread_id: &str) -> Result<ThreadSnapshotDto, String> {
        if let Some(snapshot) = self.projections().snapshot(thread_id).await {
            self.request_notification_thread_resume(thread_id).await;
            return Ok(snapshot);
        }

        let mut snapshot = self.inner.gateway.fetch_thread_snapshot(thread_id).await?;
        snapshot.thread.access_mode = self.access_mode().await;
        self.merge_bridge_turn_metadata(&mut snapshot).await;
        self.projections().put_snapshot(snapshot.clone()).await;
        self.request_notification_thread_resume(thread_id).await;
        Ok(snapshot)
    }

    pub async fn create_thread(
        &self,
        provider: ProviderKind,
        workspace: &str,
        model: Option<&str>,
    ) -> Result<ThreadSnapshotDto, String> {
        let mut snapshot = self
            .inner
            .gateway
            .create_thread(provider, workspace, model)
            .await?;
        snapshot.thread.access_mode = self.access_mode().await;
        self.merge_bridge_turn_metadata(&mut snapshot).await;
        let mut summaries = self.projections().list_summaries().await;
        let next_summary = thread_summary_from_snapshot(&snapshot);
        if let Some(index) = summaries
            .iter()
            .position(|summary| summary.thread_id == next_summary.thread_id)
        {
            summaries[index] = next_summary;
        } else {
            summaries.push(next_summary);
        }

        self.projections().put_snapshot(snapshot.clone()).await;
        self.projections().replace_summaries(summaries).await;
        Ok(snapshot)
    }

    pub async fn timeline_page(
        &self,
        thread_id: &str,
        before: Option<&str>,
        limit: usize,
    ) -> Result<ThreadTimelinePageDto, String> {
        if self.projections().snapshot(thread_id).await.is_none() {
            self.ensure_snapshot(thread_id).await?;
        }

        let mut page = self
            .projections()
            .timeline_page(thread_id, before, limit)
            .await
            .ok_or_else(|| format!("thread {thread_id} not found"))?;
        page.thread.access_mode = self.access_mode().await;
        Ok(page)
    }

    pub async fn git_status(&self, thread_id: &str) -> Result<GitStatusResponse, String> {
        let snapshot = self.ensure_snapshot(thread_id).await?;
        let git_state = read_git_state_for_status(&snapshot.thread.workspace, thread_id)?;
        self.projections()
            .update_git_state(
                thread_id,
                &git_state.response.repository,
                &git_state.response.status,
                None,
                None,
            )
            .await;
        Ok(git_state.response)
    }

    pub async fn git_diff(
        &self,
        thread_id: &str,
        mode: ThreadGitDiffMode,
        path: Option<&str>,
    ) -> Result<ThreadGitDiffDto, String> {
        let snapshot = self.ensure_snapshot(thread_id).await?;
        let repository = match mode {
            ThreadGitDiffMode::Workspace => read_git_state(&snapshot.thread.workspace, thread_id)
                .map(|state| state.snapshot_status)?,
            ThreadGitDiffMode::LatestThreadChange => {
                snapshot.git_status.clone().unwrap_or(SharedGitStatusDto {
                    workspace: snapshot.thread.workspace.clone(),
                    repository: snapshot.thread.repository.clone(),
                    branch: snapshot.thread.branch.clone(),
                    remote: None,
                    dirty: false,
                    ahead_by: 0,
                    behind_by: 0,
                })
            }
        };
        let (unified_diff, revision) = match mode {
            ThreadGitDiffMode::Workspace => {
                resolve_workspace_diff(&snapshot.thread.workspace, path)?
            }
            ThreadGitDiffMode::LatestThreadChange => (
                resolve_latest_thread_change_diff(&snapshot.entries, path),
                None,
            ),
        };

        Ok(ThreadGitDiffDto {
            contract_version: CONTRACT_VERSION.to_string(),
            thread: snapshot.thread,
            repository,
            mode,
            revision,
            files: parse_git_diff_file_summaries(&unified_diff),
            unified_diff,
            fetched_at: Utc::now().to_rfc3339(),
        })
    }

    pub async fn thread_usage(&self, thread_id: &str) -> Result<ThreadUsageDto, CodexUsageError> {
        let snapshot = self
            .ensure_snapshot(thread_id)
            .await
            .map_err(CodexUsageError::UpstreamUnavailable)?;

        if snapshot.thread.provider != ProviderKind::Codex {
            return Err(CodexUsageError::AuthUnavailable(
                "Usage bars are only available for Codex threads.".to_string(),
            ));
        }

        let usage = self
            .inner
            .codex_usage_client
            .read()
            .await
            .fetch_usage()
            .await?;
        Ok(ThreadUsageDto {
            contract_version: CONTRACT_VERSION.to_string(),
            thread_id: snapshot.thread.thread_id,
            provider: ProviderKind::Codex,
            plan_type: usage.plan_type,
            primary_window: usage.primary_window,
            secondary_window: usage.secondary_window,
        })
    }

    pub async fn queue_git_approval(
        &self,
        action: PendingApprovalAction,
        reason: &str,
    ) -> Result<ApprovalGateResponse, String> {
        let thread_id = action.thread_id().to_string();
        let snapshot = self.ensure_snapshot(&thread_id).await?;
        let git_state = read_git_state(&snapshot.thread.workspace, &thread_id)?;
        let occurred_at = Utc::now().to_rfc3339();
        let approval = {
            let mut git_controls = self
                .inner
                .git_controls
                .lock()
                .expect("git controls lock should not be poisoned");
            git_controls.queue_approval(
                action,
                reason,
                git_state.response.repository.clone(),
                git_state.response.status.clone(),
                &occurred_at,
            )
        };

        self.projections()
            .upsert_approval_record(approval.clone())
            .await;
        let event = BridgeEventEnvelope {
            contract_version: shared_contracts::CONTRACT_VERSION.to_string(),
            event_id: format!("evt-{}", approval.approval_id),
            thread_id: approval.thread_id.clone(),
            kind: BridgeEventKind::ApprovalRequested,
            occurred_at: approval.requested_at.clone(),
            payload: serde_json::to_value(&approval)
                .expect("approval event payload should serialize"),
            annotations: None,
        };
        self.projections().apply_live_event(&event).await;
        self.event_hub().publish(event);

        Ok(ApprovalGateResponse {
            contract_version: shared_contracts::CONTRACT_VERSION.to_string(),
            operation: approval.action.clone(),
            outcome: "approval_required".to_string(),
            message: "Dangerous action was gated pending explicit approval".to_string(),
            approval,
        })
    }

    pub async fn resolve_approval(
        &self,
        approval_id: &str,
        approved: bool,
    ) -> Result<ApprovalResolutionResponse, ResolveApprovalError> {
        let occurred_at = Utc::now().to_rfc3339();
        let record = {
            let mut git_controls = self
                .inner
                .git_controls
                .lock()
                .expect("git controls lock should not be poisoned");
            git_controls.resolve_approval(approval_id, approved, &occurred_at)?
        };

        if !approved {
            self.projections()
                .upsert_approval_record(record.approval.clone())
                .await;
            return Ok(ApprovalResolutionResponse {
                contract_version: shared_contracts::CONTRACT_VERSION.to_string(),
                approval: record.approval,
                mutation_result: None,
            });
        }

        let result = self
            .execute_pending_approval_action(&record, &occurred_at)
            .await;
        match result {
            Ok(mutation_result) => {
                self.projections()
                    .upsert_approval_record(record.approval.clone())
                    .await;
                Ok(ApprovalResolutionResponse {
                    contract_version: shared_contracts::CONTRACT_VERSION.to_string(),
                    approval: record.approval,
                    mutation_result: Some(mutation_result),
                })
            }
            Err(error) => {
                let restored_approval = {
                    let mut git_controls = self
                        .inner
                        .git_controls
                        .lock()
                        .expect("git controls lock should not be poisoned");
                    git_controls.restore_pending(approval_id);
                    git_controls
                        .approvals
                        .get(approval_id)
                        .expect("approval should exist after restore")
                        .approval
                        .clone()
                };
                self.projections()
                    .upsert_approval_record(restored_approval)
                    .await;
                Err(error)
            }
        }
    }

    pub async fn execute_git_branch_switch(
        &self,
        thread_id: &str,
        branch: &str,
    ) -> Result<MutationResultResponse, String> {
        self.execute_git_operation(thread_id, |workspace, status, occurred_at| {
            execute_branch_switch(workspace, thread_id, branch, status, occurred_at)
        })
        .await
    }

    pub async fn execute_git_pull(
        &self,
        thread_id: &str,
        remote: Option<&str>,
    ) -> Result<MutationResultResponse, String> {
        self.execute_git_operation(thread_id, |workspace, status, occurred_at| {
            execute_pull(workspace, thread_id, remote, status, occurred_at)
        })
        .await
    }

    pub async fn execute_git_push(
        &self,
        thread_id: &str,
        remote: Option<&str>,
    ) -> Result<MutationResultResponse, String> {
        self.execute_git_operation(thread_id, |workspace, status, occurred_at| {
            execute_push(workspace, thread_id, remote, status, occurred_at)
        })
        .await
    }

    async fn set_codex_health(&self, health: ServiceHealthDto) {
        *self.inner.codex_health.write().await = health;
    }

    async fn set_available_models(&self, models: Vec<ModelOptionDto>) {
        *self.inner.available_models.write().await = models;
    }

    async fn record_bridge_turn_metadata(&self, event: &BridgeEventEnvelope<Value>) {
        let mut metadata_by_thread = self.inner.bridge_turn_metadata.write().await;
        let entries = metadata_by_thread
            .entry(event.thread_id.clone())
            .or_insert_with(Vec::new);
        let next_entry = ThreadTimelineEntryDto {
            event_id: event.event_id.clone(),
            kind: event.kind,
            occurred_at: event.occurred_at.clone(),
            summary: String::new(),
            payload: event.payload.clone(),
            annotations: event.annotations.clone(),
        };
        if let Some(index) = entries
            .iter()
            .position(|existing| existing.event_id == next_entry.event_id)
        {
            entries[index] = next_entry;
        } else {
            entries.push(next_entry);
        }
        entries.sort_by(|left, right| {
            left.occurred_at
                .cmp(&right.occurred_at)
                .then_with(|| left.event_id.cmp(&right.event_id))
        });
    }

    async fn merge_bridge_turn_metadata(&self, snapshot: &mut ThreadSnapshotDto) {
        let metadata_entries = self
            .inner
            .bridge_turn_metadata
            .read()
            .await
            .get(&snapshot.thread.thread_id)
            .cloned()
            .unwrap_or_default();
        if metadata_entries.is_empty() {
            return;
        }

        for metadata_entry in metadata_entries {
            if snapshot
                .entries
                .iter()
                .any(|existing| existing.event_id == metadata_entry.event_id)
            {
                continue;
            }
            snapshot.entries.push(metadata_entry);
        }
        snapshot.entries.sort_by(|left, right| {
            left.occurred_at
                .cmp(&right.occurred_at)
                .then_with(|| left.event_id.cmp(&right.event_id))
        });
    }

    async fn apply_external_snapshot_update(
        &self,
        mut snapshot: ThreadSnapshotDto,
        events: Vec<BridgeEventEnvelope<Value>>,
    ) {
        self.merge_bridge_turn_metadata(&mut snapshot).await;
        if let Some(previous_snapshot) = self
            .projections()
            .snapshot(&snapshot.thread.thread_id)
            .await
        {
            preserve_generated_thread_title(&previous_snapshot, &mut snapshot);
        }
        let next_summary = thread_summary_from_snapshot(&snapshot);
        let mut summaries = self.projections().list_summaries().await;
        if let Some(index) = summaries
            .iter()
            .position(|summary| summary.thread_id == next_summary.thread_id)
        {
            summaries[index] = next_summary;
        } else {
            summaries.push(next_summary);
        }

        self.projections().put_snapshot(snapshot).await;
        self.projections().replace_summaries(summaries).await;

        for event in events {
            if should_clear_transient_thread_state(&event) {
                self.clear_transient_thread_state(&event.thread_id).await;
            }
            self.event_hub().publish(event);
        }
    }

    async fn schedule_recent_placeholder_title_backfill(&self, limit: usize) {
        let mut placeholder_threads = self.projections().list_summaries().await;
        placeholder_threads.retain(|summary| is_placeholder_thread_title(&summary.title));
        placeholder_threads.truncate(limit);

        for summary in placeholder_threads {
            self.schedule_thread_title_backfill_from_snapshot(&summary.thread_id, None)
                .await;
        }
    }

    async fn schedule_thread_title_generation_from_prompt(
        &self,
        thread_id: &str,
        visible_prompt: &str,
        workspace: &str,
        model: Option<&str>,
    ) {
        let normalized_prompt = visible_prompt.trim();
        if normalized_prompt.is_empty() {
            return;
        }
        if let Some(fallback_title) =
            provisional_thread_title_from_prompt(thread_id, normalized_prompt)
        {
            let _ = self
                .persist_generated_thread_title(thread_id, &fallback_title)
                .await;
            return;
        }
        if !self
            .reserve_thread_title_generation_if_needed(thread_id)
            .await
        {
            return;
        }

        let state = self.clone();
        let thread_id = thread_id.to_string();
        let prompt = normalized_prompt.to_string();
        let workspace = workspace.to_string();
        let model = title_generation_model_for_thread(&thread_id, model).map(str::to_string);
        tokio::spawn(async move {
            let generation_result = state
                .inner
                .gateway
                .generate_thread_title_candidate(&workspace, &prompt, model.as_deref())
                .await;

            if let Ok(Some(title)) = generation_result {
                let _ = state
                    .persist_generated_thread_title(&thread_id, &title)
                    .await;
            }

            state.release_thread_title_generation(&thread_id).await;
        });
    }

    async fn schedule_thread_title_backfill_from_snapshot(
        &self,
        thread_id: &str,
        model: Option<&str>,
    ) {
        if !self
            .reserve_thread_title_generation_if_needed(thread_id)
            .await
        {
            return;
        }

        let state = self.clone();
        let thread_id = thread_id.to_string();
        let model = title_generation_model_for_thread(&thread_id, model).map(str::to_string);
        tokio::spawn(async move {
            let snapshot = state.ensure_snapshot(&thread_id).await.ok();
            let generated_title = snapshot
                .as_ref()
                .and_then(title_generation_source_from_snapshot)
                .and_then(|source| {
                    if source.prompt.trim().is_empty() {
                        None
                    } else {
                        Some(source)
                    }
                });

            if let Some(source) = generated_title {
                if let Some(title) =
                    provisional_thread_title_from_prompt(&thread_id, &source.prompt)
                {
                    let _ = state
                        .persist_generated_thread_title(&thread_id, &title)
                        .await;
                } else if let Ok(Some(title)) = state
                    .inner
                    .gateway
                    .generate_thread_title_candidate(
                        &source.workspace,
                        &source.prompt,
                        model.as_deref(),
                    )
                    .await
                {
                    let _ = state
                        .persist_generated_thread_title(&thread_id, &title)
                        .await;
                }
            }

            state.release_thread_title_generation(&thread_id).await;
        });
    }

    async fn reserve_thread_title_generation_if_needed(&self, thread_id: &str) -> bool {
        if !self.should_generate_thread_title(thread_id).await {
            return false;
        }

        self.inner
            .inflight_thread_title_generations
            .write()
            .await
            .insert(thread_id.to_string())
    }

    async fn release_thread_title_generation(&self, thread_id: &str) {
        self.inner
            .inflight_thread_title_generations
            .write()
            .await
            .remove(thread_id);
    }

    async fn should_generate_thread_title(&self, thread_id: &str) -> bool {
        if !matches!(
            provider_from_thread_id(thread_id),
            Some(
                shared_contracts::ProviderKind::Codex | shared_contracts::ProviderKind::ClaudeCode
            )
        ) {
            return false;
        }
        if self
            .inner
            .inflight_thread_title_generations
            .read()
            .await
            .contains(thread_id)
        {
            return false;
        }

        self.thread_title_still_needs_generation(thread_id).await
    }

    async fn thread_title_still_needs_generation(&self, thread_id: &str) -> bool {
        self.projections()
            .thread_title(thread_id)
            .await
            .map(|title| is_placeholder_thread_title(&title))
            .unwrap_or(true)
    }

    async fn persist_generated_thread_title(
        &self,
        thread_id: &str,
        title: &str,
    ) -> Result<(), String> {
        let normalized_title = title.trim();
        if normalized_title.is_empty() || !self.thread_title_still_needs_generation(thread_id).await
        {
            return Ok(());
        }

        if is_provider_thread_id(thread_id, ProviderKind::Codex) {
            self.inner
                .gateway
                .set_thread_name(thread_id, normalized_title)
                .await?;
        }
        let occurred_at = Utc::now().to_rfc3339();
        let status = self
            .projections()
            .update_thread_title(thread_id, normalized_title, &occurred_at)
            .await
            .unwrap_or(ThreadStatus::Idle);
        self.event_hub().publish(BridgeEventEnvelope {
            contract_version: shared_contracts::CONTRACT_VERSION.to_string(),
            event_id: format!("{thread_id}-title-{occurred_at}"),
            thread_id: thread_id.to_string(),
            kind: BridgeEventKind::ThreadStatusChanged,
            occurred_at,
            payload: json!({
                "status": thread_status_wire_value(status),
                "reason": "thread_title_generated",
                "title": normalized_title,
            }),
            annotations: None,
        });
        Ok(())
    }

    async fn request_notification_thread_resume(&self, thread_id: &str) {
        let normalized_thread_id = thread_id.trim();
        if normalized_thread_id.is_empty()
            || !is_provider_thread_id(normalized_thread_id, shared_contracts::ProviderKind::Codex)
        {
            return;
        }

        let next_thread_id = normalized_thread_id.to_string();
        let is_new = self
            .inner
            .resumed_notification_threads
            .write()
            .await
            .insert(next_thread_id.clone());
        if !is_new {
            return;
        }

        self.dispatch_notification_thread_resume(next_thread_id);
    }

    fn dispatch_notification_thread_resume(&self, thread_id: String) {
        let sender = self
            .inner
            .notification_control_tx
            .lock()
            .expect("notification control lock should not be poisoned")
            .clone();
        if let Some(sender) = sender {
            let _ = sender.send(NotificationControlMessage::ResumeThread(thread_id.clone()));
        }
        let desktop_sender = self
            .inner
            .desktop_ipc_control_tx
            .lock()
            .expect("desktop IPC control lock should not be poisoned")
            .clone();
        if let Some(sender) = desktop_sender {
            let _ = sender.send(NotificationControlMessage::ResumeThread(thread_id));
        }
    }

    async fn resumable_notification_threads(&self) -> HashSet<String> {
        self.inner.resumed_notification_threads.read().await.clone()
    }

    async fn forget_resumable_notification_thread(&self, thread_id: &str) {
        self.inner
            .resumed_notification_threads
            .write()
            .await
            .remove(thread_id);
    }

    async fn forget_resumable_notification_threads<I>(&self, thread_ids: I)
    where
        I: IntoIterator,
        I::Item: AsRef<str>,
    {
        let mut tracked = self.inner.resumed_notification_threads.write().await;
        for thread_id in thread_ids {
            tracked.remove(thread_id.as_ref());
        }
    }

    async fn clear_transient_thread_state(&self, thread_id: &str) {
        self.inner.active_turn_ids.write().await.remove(thread_id);
        self.inner
            .pending_bridge_owned_turns
            .write()
            .await
            .remove(thread_id);
        self.inner
            .pending_user_message_images
            .write()
            .await
            .remove(thread_id);
    }

    async fn clear_interrupted_thread_state(&self, thread_id: &str) {
        self.inner
            .interrupted_threads
            .write()
            .await
            .remove(thread_id);
    }

    async fn mark_thread_interrupt_requested(&self, thread_id: &str) {
        self.inner
            .interrupted_threads
            .write()
            .await
            .insert(thread_id.to_string());
    }

    async fn should_preserve_interrupted_thread_state(&self, thread_id: &str) -> bool {
        self.inner
            .interrupted_threads
            .read()
            .await
            .contains(thread_id)
    }

    async fn rewrite_interrupted_thread_status_event(
        &self,
        event: &mut BridgeEventEnvelope<Value>,
    ) {
        if event.kind != BridgeEventKind::ThreadStatusChanged {
            return;
        }

        let Some(status) = event.payload.get("status").and_then(Value::as_str) else {
            return;
        };

        if status == "running" {
            self.clear_interrupted_thread_state(&event.thread_id).await;
            return;
        }

        if !self
            .should_preserve_interrupted_thread_state(&event.thread_id)
            .await
        {
            return;
        }

        if let Some(payload) = event.payload.as_object_mut() {
            payload.insert(
                "status".to_string(),
                Value::String("interrupted".to_string()),
            );
            payload.insert(
                "reason".to_string(),
                Value::String("interrupt_requested".to_string()),
            );
        }
    }

    async fn finalize_bridge_owned_turn(&self, thread_id: &str) {
        self.clear_transient_thread_state(thread_id).await;
    }

    async fn mark_bridge_turn_stream_started(&self, thread_id: &str) {
        self.inner
            .active_turn_stream_threads
            .write()
            .await
            .insert(thread_id.to_string());
    }

    async fn mark_bridge_turn_stream_finished(&self, thread_id: &str) {
        self.inner
            .active_turn_stream_threads
            .write()
            .await
            .remove(thread_id);
    }

    async fn has_bridge_turn_stream_active(&self, thread_id: &str) -> bool {
        self.inner
            .active_turn_stream_threads
            .read()
            .await
            .contains(thread_id)
    }

    fn schedule_bridge_owned_turn_watchdog(&self, _thread_id: &str) {}

    async fn refresh_snapshot_after_bridge_turn_completion(&self, thread_id: &str) {
        let snapshot = match self.inner.gateway.fetch_thread_snapshot(thread_id).await {
            Ok(snapshot) => snapshot,
            Err(error) => {
                eprintln!(
                    "bridge thread snapshot refresh after turn completion failed for {thread_id}: {error}"
                );
                return;
            }
        };
        self.apply_bridge_turn_completion_snapshot(thread_id, snapshot)
            .await;
    }

    async fn apply_bridge_turn_completion_snapshot(
        &self,
        thread_id: &str,
        mut snapshot: ThreadSnapshotDto,
    ) {
        let previous_snapshot = self.projections().snapshot(thread_id).await;
        snapshot.thread.access_mode = self.access_mode().await;
        if self
            .should_preserve_interrupted_thread_state(thread_id)
            .await
            && snapshot.thread.status != ThreadStatus::Running
        {
            snapshot.thread.status = ThreadStatus::Interrupted;
            snapshot.thread.active_turn_id = None;
        }

        let mut compactor = LiveDeltaCompactor::default();
        let events = diff_thread_snapshots(previous_snapshot.as_ref(), &snapshot)
            .into_iter()
            .filter_map(|event| {
                let normalized = compactor.compact(event);
                (normalized.kind == BridgeEventKind::ThreadStatusChanged
                    && should_publish_compacted_event(&normalized)
                    && !should_suppress_live_event(&normalized))
                .then_some(normalized)
            })
            .collect::<Vec<_>>();

        self.apply_external_snapshot_update(snapshot, events).await;
    }

    async fn execute_pending_approval_action(
        &self,
        record: &PendingApprovalRecord,
        occurred_at: &str,
    ) -> Result<MutationResultResponse, ResolveApprovalError> {
        let snapshot = self.projections().snapshot(record.action.thread_id()).await;
        let snapshot = match snapshot {
            Some(snapshot) => snapshot,
            None => self
                .ensure_snapshot(record.action.thread_id())
                .await
                .map_err(|_| ResolveApprovalError::TargetNotFound)?,
        };

        let executed = match &record.action {
            PendingApprovalAction::BranchSwitch { branch, .. } => execute_branch_switch(
                &snapshot.thread.workspace,
                record.action.thread_id(),
                branch,
                snapshot.thread.status,
                occurred_at,
            ),
            PendingApprovalAction::Pull { remote, .. } => execute_pull(
                &snapshot.thread.workspace,
                record.action.thread_id(),
                remote.as_deref(),
                snapshot.thread.status,
                occurred_at,
            ),
            PendingApprovalAction::Push { remote, .. } => execute_push(
                &snapshot.thread.workspace,
                record.action.thread_id(),
                remote.as_deref(),
                snapshot.thread.status,
                occurred_at,
            ),
        }
        .map_err(ResolveApprovalError::MutationFailed)?;

        self.projections()
            .apply_live_event(&executed.command_event)
            .await;
        self.event_hub().publish(executed.command_event);
        self.projections()
            .update_git_state(
                record.action.thread_id(),
                &executed.mutation.repository,
                &executed.mutation.status,
                Some(occurred_at),
                Some(&executed.mutation.message),
            )
            .await;
        Ok(executed.mutation)
    }

    async fn execute_git_operation<F>(
        &self,
        thread_id: &str,
        operation: F,
    ) -> Result<MutationResultResponse, String>
    where
        F: FnOnce(&str, ThreadStatus, &str) -> Result<ExecutedGitMutation, String>,
    {
        let occurred_at = Utc::now().to_rfc3339();
        self.execute_git_operation_with_snapshot(thread_id, &occurred_at, operation)
            .await
    }

    async fn execute_git_operation_with_snapshot<F>(
        &self,
        thread_id: &str,
        occurred_at: &str,
        operation: F,
    ) -> Result<MutationResultResponse, String>
    where
        F: FnOnce(&str, ThreadStatus, &str) -> Result<ExecutedGitMutation, String>,
    {
        let snapshot = self.ensure_snapshot(thread_id).await?;
        let executed = operation(
            &snapshot.thread.workspace,
            snapshot.thread.status,
            occurred_at,
        )?;
        self.projections()
            .apply_live_event(&executed.command_event)
            .await;
        self.event_hub().publish(executed.command_event);
        self.projections()
            .update_git_state(
                thread_id,
                &executed.mutation.repository,
                &executed.mutation.status,
                Some(occurred_at),
                Some(&executed.mutation.message),
            )
            .await;
        Ok(executed.mutation)
    }

    pub fn start_notification_forwarder(&self) {
        let state = self.clone();
        let handle = tokio::runtime::Handle::current();
        let (control_tx, control_rx) = mpsc::channel();
        *self
            .inner
            .notification_control_tx
            .lock()
            .expect("notification control lock should not be poisoned") = Some(control_tx);
        std::thread::spawn(move || {
            let mut compactor = LiveDeltaCompactor::default();
            loop {
                let mut notifications = match state.inner.gateway.notification_stream() {
                    Ok(stream) => {
                        let state = state.clone();
                        handle.block_on(async move {
                            state
                                .set_codex_health(ServiceHealthDto {
                                    status: ServiceHealthStatus::Healthy,
                                    message: None,
                                })
                                .await;
                        });
                        stream
                    }
                    Err(error) => {
                        eprintln!("bridge notification stream failed to start: {error}");
                        let state = state.clone();
                        handle.block_on(async move {
                            state
                                .set_codex_health(ServiceHealthDto {
                                    status: ServiceHealthStatus::Degraded,
                                    message: Some(format!(
                                        "notification stream unavailable: {error}"
                                    )),
                                })
                                .await;
                        });
                        std::thread::sleep(std::time::Duration::from_secs(2));
                        continue;
                    }
                };

                let resumed_threads =
                    handle.block_on(async { state.resumable_notification_threads().await });
                let dropped_threads =
                    match resume_notification_threads(resumed_threads.iter(), |thread_id| {
                        notifications.resume_thread(thread_id)
                    }) {
                        Ok(dropped_threads) => dropped_threads,
                        Err(error) => {
                            eprintln!("bridge notification resume sync failed: {error}");
                            std::thread::sleep(std::time::Duration::from_secs(1));
                            continue;
                        }
                    };
                if !dropped_threads.is_empty() {
                    let state = state.clone();
                    handle.block_on(async move {
                        state
                            .forget_resumable_notification_threads(dropped_threads)
                            .await;
                    });
                }

                loop {
                    if let Err(error) =
                        drain_notification_control_messages(&control_rx, |message| match message {
                            NotificationControlMessage::ResumeThread(thread_id) => {
                                match resume_notification_thread_until_rollout_exists(
                                    &thread_id,
                                    |thread_id| notifications.resume_thread(thread_id),
                                ) {
                                    Ok(()) => Ok(()),
                                    Err(error) if is_stale_rollout_resume_error(&error) => {
                                        let state = state.clone();
                                        handle.block_on(async move {
                                            state
                                                .forget_resumable_notification_thread(&thread_id)
                                                .await;
                                        });
                                        Ok(())
                                    }
                                    Err(error) => Err(error),
                                }
                            }
                        })
                    {
                        eprintln!("bridge notification control failed: {error}");
                        break;
                    }

                    match notifications.next_event() {
                        Ok(Some(event)) => {
                            let mut normalized = compactor.compact(event);
                            if !should_publish_compacted_event(&normalized) {
                                continue;
                            }
                            let state = state.clone();
                            handle.block_on(async move {
                                let has_live_turn_stream = state
                                    .has_bridge_turn_stream_active(&normalized.thread_id)
                                    .await;
                                if has_live_turn_stream
                                    && should_skip_background_notification_event(&normalized)
                                {
                                    return;
                                }
                                let should_suppress_for_bridge_owned_turn =
                                    should_suppress_notification_event_for_bridge_active_turn(
                                        &normalized,
                                        state
                                            .has_bridge_owned_active_turn(&normalized.thread_id)
                                            .await,
                                    );
                                if should_suppress_for_bridge_owned_turn {
                                    return;
                                }
                                if should_clear_transient_thread_state(&normalized) {
                                    state
                                        .clear_transient_thread_state(&normalized.thread_id)
                                        .await;
                                }
                                if normalized.kind != BridgeEventKind::ThreadStatusChanged {
                                    state
                                        .merge_pending_user_message_images(&mut normalized)
                                        .await;
                                }
                                state.projections().apply_live_event(&normalized).await;
                                state.event_hub().publish(normalized);
                            });
                        }
                        Ok(None) => {
                            let state = state.clone();
                            handle.block_on(async move {
                                state
                                    .set_codex_health(ServiceHealthDto {
                                        status: ServiceHealthStatus::Degraded,
                                        message: Some(
                                            "notification stream closed; reconnecting".to_string(),
                                        ),
                                    })
                                    .await;
                            });
                            break;
                        }
                        Err(error) => {
                            eprintln!("bridge notification stream failed: {error}");
                            let state = state.clone();
                            handle.block_on(async move {
                                state
                                    .set_codex_health(ServiceHealthDto {
                                        status: ServiceHealthStatus::Degraded,
                                        message: Some(format!(
                                            "notification stream failed: {error}"
                                        )),
                                    })
                                    .await;
                            });
                            break;
                        }
                    }
                }

                std::thread::sleep(std::time::Duration::from_secs(1));
            }
        });
    }

    pub fn start_desktop_ipc_forwarder(&self) {
        let Some(desktop_ipc_config) =
            DesktopIpcConfig::detect(self.inner.gateway.desktop_ipc_socket_path())
        else {
            return;
        };

        let state = self.clone();
        let handle = tokio::runtime::Handle::current();
        let (control_tx, control_rx) = mpsc::channel();
        *self
            .inner
            .desktop_ipc_control_tx
            .lock()
            .expect("desktop IPC control lock should not be poisoned") = Some(control_tx);

        std::thread::spawn(move || {
            let mut compactor = LiveDeltaCompactor::default();
            let mut conversation_state_by_thread = HashMap::<String, Value>::new();

            loop {
                let mut client = match DesktopIpcClient::connect(&desktop_ipc_config) {
                    Ok(client) => client,
                    Err(error) => {
                        eprintln!("bridge desktop IPC failed to connect: {error}");
                        std::thread::sleep(std::time::Duration::from_secs(2));
                        continue;
                    }
                };

                let mut tracked_threads =
                    handle.block_on(async { state.resumable_notification_threads().await });
                let dropped_threads =
                    match resume_notification_threads(tracked_threads.iter(), |thread_id| {
                        match client.external_resume_thread(thread_id) {
                            Ok(()) => Ok(()),
                            Err(error) if error.contains("no-client-found") => Ok(()),
                            Err(error) => Err(error),
                        }
                    }) {
                        Ok(dropped_threads) => dropped_threads,
                        Err(error) => {
                            eprintln!("bridge desktop IPC resume sync failed: {error}");
                            Vec::new()
                        }
                    };
                if !dropped_threads.is_empty() {
                    for thread_id in &dropped_threads {
                        tracked_threads.remove(thread_id);
                    }
                    let state = state.clone();
                    handle.block_on(async move {
                        state
                            .forget_resumable_notification_threads(dropped_threads)
                            .await;
                    });
                }

                loop {
                    if let Err(error) =
                        drain_notification_control_messages(&control_rx, |message| match message {
                            NotificationControlMessage::ResumeThread(thread_id) => {
                                tracked_threads.insert(thread_id.to_string());
                                if let Some(conversation_state) =
                                    conversation_state_by_thread.get(&thread_id).cloned()
                                {
                                    let previous_snapshot = handle.block_on(async {
                                        state.projections().snapshot(&thread_id).await
                                    });
                                    if previous_snapshot.as_ref().is_some_and(|snapshot| {
                                        snapshot.thread.status == ThreadStatus::Running
                                    }) {
                                        match client.external_resume_thread(&thread_id) {
                                            Ok(()) => Ok(()),
                                            Err(error) if error.contains("no-client-found") => {
                                                Ok(())
                                            }
                                            Err(error) if is_stale_rollout_resume_error(&error) => {
                                                tracked_threads.remove(&thread_id);
                                                let state = state.clone();
                                                handle.block_on(async move {
                                                    state
                                                        .forget_resumable_notification_thread(
                                                            &thread_id,
                                                        )
                                                        .await;
                                                });
                                                Ok(())
                                            }
                                            Err(error) => Err(error),
                                        }?;
                                        return Ok(());
                                    }
                                    let previous_summary_status = handle.block_on(async {
                                        state.projections().summary_status(&thread_id).await
                                    });
                                    let access_mode =
                                        handle.block_on(async { state.access_mode().await });
                                    let latest_raw_turn_status = conversation_state
                                        .get("turns")
                                        .and_then(Value::as_array)
                                        .and_then(|turns| turns.last())
                                        .and_then(raw_turn_status)
                                        .map(ToString::to_string);
                                    if let Ok((next_snapshot, events)) =
                                        build_desktop_ipc_snapshot_update(
                                            previous_snapshot.as_ref(),
                                            previous_summary_status,
                                            &conversation_state,
                                            access_mode,
                                            &mut compactor,
                                            false,
                                            latest_raw_turn_status.as_deref(),
                                            handle.block_on(async {
                                                state.has_bridge_owned_active_turn(&thread_id).await
                                            }),
                                        )
                                    {
                                        let state = state.clone();
                                        handle.block_on(async move {
                                            state
                                                .apply_external_snapshot_update(
                                                    next_snapshot,
                                                    events,
                                                )
                                                .await;
                                        });
                                    }
                                }
                                match client.external_resume_thread(&thread_id) {
                                    Ok(()) => Ok(()),
                                    Err(error) if error.contains("no-client-found") => Ok(()),
                                    Err(error) if is_stale_rollout_resume_error(&error) => {
                                        tracked_threads.remove(&thread_id);
                                        let state = state.clone();
                                        handle.block_on(async move {
                                            state
                                                .forget_resumable_notification_thread(&thread_id)
                                                .await;
                                        });
                                        Ok(())
                                    }
                                    Err(error) => Err(error),
                                }
                            }
                        })
                    {
                        eprintln!("bridge desktop IPC control failed: {error}");
                        break;
                    }

                    let next_change = match client.next_thread_stream_state_changed() {
                        Ok(change) => change,
                        Err(error) => {
                            eprintln!("bridge desktop IPC stream failed: {error}");
                            break;
                        }
                    };
                    let Some(change) = next_change else {
                        continue;
                    };
                    let thread_id = change.conversation_id.clone();
                    let is_patch_update =
                        matches!(&change.change, DesktopStreamChange::Patches { .. });
                    let next_state = match change.change {
                        DesktopStreamChange::Snapshot { conversation_state } => {
                            Some(conversation_state)
                        }
                        DesktopStreamChange::Patches { patches } => {
                            let Some(mut conversation_state) =
                                conversation_state_by_thread.get(&thread_id).cloned()
                            else {
                                continue;
                            };
                            if let Err(error) = apply_patches(&mut conversation_state, &patches) {
                                eprintln!(
                                    "bridge desktop IPC patch apply failed for {thread_id}: {error}"
                                );
                                conversation_state_by_thread.remove(&thread_id);
                                continue;
                            }
                            Some(conversation_state)
                        }
                    };
                    let Some(conversation_state) = next_state else {
                        continue;
                    };
                    conversation_state_by_thread
                        .insert(thread_id.clone(), conversation_state.clone());
                    if !tracked_threads.contains(&thread_id) {
                        continue;
                    }

                    let previous_snapshot =
                        handle.block_on(async { state.projections().snapshot(&thread_id).await });
                    let previous_summary_status = handle
                        .block_on(async { state.projections().summary_status(&thread_id).await });
                    let access_mode = handle.block_on(async { state.access_mode().await });
                    let latest_raw_turn_status = conversation_state
                        .get("turns")
                        .and_then(Value::as_array)
                        .and_then(|turns| turns.last())
                        .and_then(raw_turn_status)
                        .map(ToString::to_string);
                    let (next_snapshot, events) = match build_desktop_ipc_snapshot_update(
                        previous_snapshot.as_ref(),
                        previous_summary_status,
                        &conversation_state,
                        access_mode,
                        &mut compactor,
                        is_patch_update,
                        latest_raw_turn_status.as_deref(),
                        handle.block_on(async {
                            state.has_bridge_owned_active_turn(&thread_id).await
                        }),
                    ) {
                        Ok(update) => update,
                        Err(error) => {
                            eprintln!(
                                "bridge desktop IPC snapshot mapping failed for {thread_id}: {error}"
                            );
                            continue;
                        }
                    };

                    let state = state.clone();
                    handle.block_on(async move {
                        state
                            .apply_external_snapshot_update(next_snapshot, events)
                            .await;
                    });
                }

                std::thread::sleep(std::time::Duration::from_secs(1));
            }
        });
    }

    pub fn start_summary_reconciler(&self) {
        let state = self.clone();
        tokio::spawn(async move {
            loop {
                sleep(Duration::from_secs(30)).await;
                match state.inner.gateway.bootstrap().await {
                    Ok(bootstrap) => {
                        let current_summaries = state.projections().list_summaries().await;
                        let preserved_summaries = merge_reconciled_thread_summaries(
                            current_summaries,
                            bootstrap.summaries,
                        );
                        state
                            .projections()
                            .replace_summaries(preserved_summaries)
                            .await;
                        state.set_available_models(bootstrap.models).await;
                        state
                            .set_codex_health(ServiceHealthDto {
                                status: ServiceHealthStatus::Healthy,
                                message: bootstrap.message,
                            })
                            .await;
                    }
                    Err(error) => {
                        state
                            .set_codex_health(ServiceHealthDto {
                                status: ServiceHealthStatus::Degraded,
                                message: Some(format!("summary reconcile failed: {error}")),
                            })
                            .await;
                    }
                }
            }
        });
    }

    pub async fn start_turn(
        &self,
        thread_id: &str,
        prompt: &str,
        images: &[String],
        model: Option<&str>,
        effort: Option<&str>,
        mode: TurnMode,
    ) -> Result<TurnMutationAcceptedDto, String> {
        let provider = provider_from_thread_id(thread_id).unwrap_or(ProviderKind::Codex);
        if provider == ProviderKind::ClaudeCode && mode == TurnMode::Plan {
            return Err("plan mode is not implemented for Claude Code threads yet".to_string());
        }
        match mode {
            TurnMode::Act => {
                self.clear_pending_user_input(thread_id).await;
                self.start_turn_with_visible_prompt(
                    thread_id, prompt, prompt, images, model, effort,
                )
                .await
            }
            TurnMode::Plan => {
                self.start_plan_turn(thread_id, prompt, images, model, effort)
                    .await
            }
        }
    }

    pub async fn start_commit_action(
        &self,
        thread_id: &str,
        model: Option<&str>,
        effort: Option<&str>,
    ) -> Result<TurnMutationAcceptedDto, String> {
        if !is_provider_thread_id(thread_id, shared_contracts::ProviderKind::Codex) {
            return Err(format!(
                "thread {thread_id} belongs to a read-only provider; commit actions are only implemented for codex threads"
            ));
        }
        self.start_turn_with_visible_prompt(
            thread_id,
            "Commit",
            &build_hidden_commit_prompt(),
            &[],
            model,
            effort,
        )
        .await
    }

    async fn start_turn_with_visible_prompt(
        &self,
        thread_id: &str,
        visible_prompt: &str,
        upstream_prompt: &str,
        images: &[String],
        model: Option<&str>,
        effort: Option<&str>,
    ) -> Result<TurnMutationAcceptedDto, String> {
        let normalized_images = images
            .iter()
            .map(|image| image.trim())
            .filter(|image| !image.is_empty())
            .map(ToString::to_string)
            .collect::<Vec<_>>();
        self.clear_interrupted_thread_state(thread_id).await;
        if !normalized_images.is_empty() {
            self.inner
                .pending_user_message_images
                .write()
                .await
                .insert(thread_id.to_string(), normalized_images.clone());
        }
        let visible_prompt = visible_prompt.trim();
        let state = self.clone();
        let handle = tokio::runtime::Handle::current();
        let completion_handle = handle.clone();
        let stream_finish_handle = completion_handle.clone();
        let compactor = Arc::new(std::sync::Mutex::new(LiveDeltaCompactor::default()));
        let completion_state = self.clone();
        let stream_finish_state = self.clone();
        let control_state = self.clone();
        let control_handle = handle.clone();
        let control_thread_id = thread_id.to_string();
        self.inner
            .pending_bridge_owned_turns
            .write()
            .await
            .insert(thread_id.to_string());
        self.mark_bridge_turn_stream_started(thread_id).await;
        let result = match self.inner.gateway.start_turn_streaming(
            thread_id,
            TurnStartRequest {
                prompt: upstream_prompt.to_string(),
                images: images.to_vec(),
                model: model.map(str::to_string),
                effort: effort.map(str::to_string),
                permission_mode: Some(claude_permission_mode_for_access_mode(
                    self.access_mode().await,
                )),
            },
            move |event| {
                let state = state.clone();
                if let Some(user_input_event) = handle.block_on(async {
                    state
                        .build_pending_user_input_event_from_live_message(&event)
                        .await
                }) {
                    let state = state.clone();
                    handle.block_on(async move {
                        state
                            .projections()
                            .apply_live_event(&user_input_event)
                            .await;
                        state.event_hub().publish(user_input_event);
                    });
                    return;
                }
                let mut normalized = compactor
                    .lock()
                    .expect("turn stream compactor lock should not be poisoned")
                    .compact(event);
                if !should_publish_compacted_event(&normalized) {
                    return;
                }
                if should_suppress_live_event(&normalized) {
                    return;
                }
                let state = state.clone();
                handle.block_on(async {
                    state
                        .rewrite_interrupted_thread_status_event(&mut normalized)
                        .await;
                });
                handle.block_on(async move {
                    if should_clear_transient_thread_state(&normalized) {
                        state
                            .clear_transient_thread_state(&normalized.thread_id)
                            .await;
                    }
                    if normalized.kind != BridgeEventKind::ThreadStatusChanged {
                        state
                            .merge_pending_user_message_images(&mut normalized)
                            .await;
                    }
                    state.projections().apply_live_event(&normalized).await;
                    state.event_hub().publish(normalized);
                });
            },
            move |control_request| {
                let state = control_state.clone();
                let thread_id = control_thread_id.clone();
                control_handle.block_on(async move {
                    state
                        .handle_turn_control_request(&thread_id, control_request)
                        .await
                })
            },
            move |completed_thread_id| {
                let state = completion_state.clone();
                completion_handle.block_on(async move {
                    state.finalize_bridge_owned_turn(&completed_thread_id).await;
                });
            },
            move |finished_thread_id| {
                let state = stream_finish_state.clone();
                stream_finish_handle.block_on(async move {
                    state
                        .mark_bridge_turn_stream_finished(&finished_thread_id)
                        .await;
                    state
                        .refresh_snapshot_after_bridge_turn_completion(&finished_thread_id)
                        .await;
                });
            },
        ) {
            Ok(result) => result,
            Err(error) => {
                self.mark_bridge_turn_stream_finished(thread_id).await;
                self.clear_transient_thread_state(thread_id).await;
                return Err(error);
            }
        };
        self.inner
            .pending_bridge_owned_turns
            .write()
            .await
            .remove(thread_id);
        if result.turn_id.is_none() {
            self.inner
                .pending_user_message_images
                .write()
                .await
                .remove(thread_id);
        }
        if let Some(turn_id) = result.turn_id {
            self.inner
                .active_turn_ids
                .write()
                .await
                .insert(thread_id.to_string(), turn_id);
            self.schedule_bridge_owned_turn_watchdog(thread_id);
        }
        let occurred_at = Utc::now().to_rfc3339();
        self.projections()
            .mark_thread_running(thread_id, &occurred_at, result.response.turn_id.as_deref())
            .await;
        let turn_started_event = build_turn_started_history_event(
            thread_id,
            &occurred_at,
            result.response.turn_id.as_deref(),
            model,
            effort,
        );
        self.record_bridge_turn_metadata(&turn_started_event).await;
        self.projections()
            .apply_live_event(&turn_started_event)
            .await;
        self.event_hub().publish(turn_started_event);
        if should_synthesize_visible_user_prompt(visible_prompt, upstream_prompt) {
            let mut visible_prompt_event = build_visible_user_message_event(
                thread_id,
                &occurred_at,
                result.response.turn_id.as_deref(),
                visible_prompt,
            );
            self.merge_pending_user_message_images(&mut visible_prompt_event)
                .await;
            self.record_bridge_turn_metadata(&visible_prompt_event)
                .await;
            self.projections()
                .apply_live_event(&visible_prompt_event)
                .await;
            self.event_hub().publish(visible_prompt_event);
        }
        if !visible_prompt.is_empty() {
            let workspace = self
                .projections()
                .snapshot(thread_id)
                .await
                .map(|snapshot| snapshot.thread.workspace)
                .unwrap_or_default();
            self.schedule_thread_title_generation_from_prompt(
                thread_id,
                visible_prompt,
                &workspace,
                model,
            )
            .await;
        }
        Ok(result.response)
    }

    async fn start_plan_turn(
        &self,
        thread_id: &str,
        prompt: &str,
        images: &[String],
        model: Option<&str>,
        effort: Option<&str>,
    ) -> Result<TurnMutationAcceptedDto, String> {
        self.clear_pending_user_input(thread_id).await;
        self.inner
            .awaiting_plan_question_prompts
            .write()
            .await
            .insert(thread_id.to_string(), prompt.trim().to_string());
        self.start_turn_with_visible_prompt(
            thread_id,
            prompt,
            &build_hidden_plan_question_prompt(prompt),
            images,
            model,
            effort,
        )
        .await
    }

    pub async fn respond_to_user_input(
        &self,
        thread_id: &str,
        request_id: &str,
        answers: &[UserInputAnswerDto],
        free_text: Option<&str>,
        model: Option<&str>,
        effort: Option<&str>,
    ) -> Result<TurnMutationAcceptedDto, String> {
        let free_text = free_text.map(str::trim).filter(|value| !value.is_empty());
        let session = {
            let mut pending = self.inner.pending_user_inputs.write().await;
            let Some(existing_request_id) = pending.get(thread_id).map(|session| match session {
                PendingUserInputSession::PlanQuestionnaire { questionnaire, .. } => {
                    questionnaire.request_id.as_str()
                }
                PendingUserInputSession::ProviderApproval(session) => {
                    session.questionnaire.request_id.as_str()
                }
            }) else {
                return Err("There is no pending user input for this thread.".to_string());
            };
            if existing_request_id != request_id {
                return Err(
                    "The pending question set is no longer current. Refresh and try again."
                        .to_string(),
                );
            }
            pending
                .remove(thread_id)
                .expect("pending user input should exist after id check")
        };

        match session {
            PendingUserInputSession::PlanQuestionnaire {
                questionnaire,
                original_prompt,
            } => {
                if answers.is_empty() && free_text.is_none() {
                    self.inner.pending_user_inputs.write().await.insert(
                        thread_id.to_string(),
                        PendingUserInputSession::PlanQuestionnaire {
                            questionnaire,
                            original_prompt,
                        },
                    );
                    return Err(
                        "Pick at least one answer or write your own clarification.".to_string()
                    );
                }

                self.projections()
                    .set_pending_user_input(thread_id, None)
                    .await;
                self.publish_user_input_resolution_event(thread_id, request_id)
                    .await;

                self.start_turn_with_visible_prompt(
                    thread_id,
                    &render_user_input_response_summary(&questionnaire, answers, free_text),
                    &build_hidden_plan_followup_prompt(
                        &original_prompt,
                        &questionnaire,
                        answers,
                        free_text,
                    ),
                    &[],
                    model,
                    effort,
                )
                .await
            }
            PendingUserInputSession::ProviderApproval(provider_session) => {
                let Some(selection) = parse_provider_approval_selection(answers) else {
                    self.inner.pending_user_inputs.write().await.insert(
                        thread_id.to_string(),
                        PendingUserInputSession::ProviderApproval(provider_session),
                    );
                    return Err("Choose Allow once, Allow for session, or Deny.".to_string());
                };

                self.projections()
                    .set_pending_user_input(thread_id, None)
                    .await;
                self.publish_user_input_resolution_event(thread_id, request_id)
                    .await;

                let should_interrupt_after_response = matches!(
                    provider_session.context,
                    ProviderApprovalContext::CodexPermissions { .. }
                ) && selection
                    == ProviderApprovalSelection::Deny;
                let interrupt_turn_id = match &provider_session.context {
                    ProviderApprovalContext::CodexPermissions { turn_id, .. } => Some(turn_id),
                    _ => None,
                };

                if provider_session.resolution_tx.send(selection).is_err() {
                    return Err("The provider approval request is no longer active.".to_string());
                }

                if should_interrupt_after_response && let Some(turn_id) = interrupt_turn_id {
                    let _ = self.inner.gateway.interrupt_turn(thread_id, turn_id).await;
                }

                let active_turn_id = self
                    .inner
                    .active_turn_ids
                    .read()
                    .await
                    .get(thread_id)
                    .cloned();
                Ok(TurnMutationAcceptedDto {
                    contract_version: CONTRACT_VERSION.to_string(),
                    thread_id: thread_id.to_string(),
                    thread_status: ThreadStatus::Running,
                    message: "approval response submitted".to_string(),
                    turn_id: active_turn_id,
                })
            }
        }
    }

    async fn handle_turn_control_request(
        &self,
        thread_id: &str,
        control_request: GatewayTurnControlRequest,
    ) -> Result<Option<Value>, String> {
        match control_request {
            GatewayTurnControlRequest::CodexApproval {
                request_id,
                method,
                params,
            } => {
                let Some(prompt) = build_pending_provider_approval_from_codex(
                    thread_id,
                    &request_id,
                    &method,
                    &params,
                )?
                else {
                    return Ok(None);
                };
                let selection = self
                    .register_provider_approval_session(thread_id, prompt)
                    .await?;
                Ok(Some(build_codex_approval_response(
                    &method, &params, selection,
                )?))
            }
            GatewayTurnControlRequest::ClaudeCanUseTool {
                request_id,
                request,
            } => {
                let request_copy = request.clone();
                let prompt =
                    build_pending_provider_approval_from_claude(thread_id, request_id, request)?;
                let selection = self
                    .register_provider_approval_session(thread_id, prompt)
                    .await?;
                Ok(Some(build_claude_tool_approval_response(
                    selection,
                    &request_copy,
                )))
            }
            GatewayTurnControlRequest::ClaudeControlCancel { request_id } => {
                self.cancel_provider_approval_request(thread_id, &request_id)
                    .await;
                Ok(None)
            }
        }
    }

    async fn register_provider_approval_session(
        &self,
        thread_id: &str,
        prompt: ProviderApprovalPrompt,
    ) -> Result<ProviderApprovalSelection, String> {
        let questionnaire = prompt.questionnaire.clone();
        let request_id = questionnaire.request_id.clone();
        let (resolution_tx, resolution_rx) = oneshot::channel();
        {
            let mut pending = self.inner.pending_user_inputs.write().await;
            if let Some(replaced) = pending.insert(
                thread_id.to_string(),
                PendingUserInputSession::ProviderApproval(PendingProviderApprovalSession {
                    questionnaire: questionnaire.clone(),
                    provider_request_id: prompt.provider_request_id,
                    context: prompt.context,
                    resolution_tx,
                }),
            ) {
                self.try_abort_pending_provider_approval(replaced);
            }
        }
        self.publish_user_input_pending_event(thread_id, &questionnaire)
            .await;
        resolution_rx
            .await
            .map_err(|_| format!("provider approval {request_id} was cancelled before completion"))
    }

    async fn cancel_provider_approval_request(&self, thread_id: &str, request_id: &str) {
        let removed = {
            let mut pending = self.inner.pending_user_inputs.write().await;
            let should_remove = pending.get(thread_id).is_some_and(|session| {
                matches!(
                    session,
                    PendingUserInputSession::ProviderApproval(provider_session)
                        if provider_session.provider_request_id == request_id
                )
            });
            if should_remove {
                pending.remove(thread_id)
            } else {
                None
            }
        };
        let Some(removed_session) = removed else {
            return;
        };
        let resolved_request_id = match &removed_session {
            PendingUserInputSession::ProviderApproval(provider_session) => {
                provider_session.questionnaire.request_id.clone()
            }
            PendingUserInputSession::PlanQuestionnaire { questionnaire, .. } => {
                questionnaire.request_id.clone()
            }
        };
        self.try_abort_pending_provider_approval(removed_session);
        self.projections()
            .set_pending_user_input(thread_id, None)
            .await;
        self.publish_user_input_resolution_event(thread_id, &resolved_request_id)
            .await;
    }

    fn try_abort_pending_provider_approval(&self, session: PendingUserInputSession) {
        if let PendingUserInputSession::ProviderApproval(provider_session) = session {
            let _ = provider_session
                .resolution_tx
                .send(ProviderApprovalSelection::Deny);
        }
    }

    async fn clear_pending_user_input(&self, thread_id: &str) {
        self.inner
            .awaiting_plan_question_prompts
            .write()
            .await
            .remove(thread_id);
        let removed = self
            .inner
            .pending_user_inputs
            .write()
            .await
            .remove(thread_id);
        if let Some(session) = removed {
            self.try_abort_pending_provider_approval(session);
        }
        self.projections()
            .set_pending_user_input(thread_id, None)
            .await;
    }

    async fn build_pending_user_input_event_from_live_message(
        &self,
        event: &BridgeEventEnvelope<Value>,
    ) -> Option<BridgeEventEnvelope<Value>> {
        if event.kind != BridgeEventKind::MessageDelta {
            return None;
        }
        if event.payload.get("role").and_then(Value::as_str) != Some("assistant") {
            return None;
        }

        let original_prompt = self
            .inner
            .awaiting_plan_question_prompts
            .write()
            .await
            .remove(&event.thread_id)?;
        let message_text = extract_text_from_payload(&event.payload)?;
        let questionnaire = parse_pending_user_input_payload(&message_text, &event.thread_id)?;
        let request_id = questionnaire.request_id.clone();

        if let Some(replaced) = self.inner.pending_user_inputs.write().await.insert(
            event.thread_id.clone(),
            PendingUserInputSession::PlanQuestionnaire {
                questionnaire: questionnaire.clone(),
                original_prompt,
            },
        ) {
            self.try_abort_pending_provider_approval(replaced);
        }

        Some(BridgeEventEnvelope {
            contract_version: CONTRACT_VERSION.to_string(),
            event_id: format!("{}-{}", event.thread_id, request_id),
            thread_id: event.thread_id.clone(),
            kind: BridgeEventKind::UserInputRequested,
            occurred_at: event.occurred_at.clone(),
            payload: json!({
                "request_id": questionnaire.request_id,
                "title": questionnaire.title,
                "detail": questionnaire.detail,
                "questions": questionnaire.questions,
                "state": "pending",
            }),
            annotations: None,
        })
    }

    async fn publish_user_input_resolution_event(&self, thread_id: &str, request_id: &str) {
        let event = BridgeEventEnvelope {
            contract_version: CONTRACT_VERSION.to_string(),
            event_id: format!("{thread_id}-{request_id}-resolved"),
            thread_id: thread_id.to_string(),
            kind: BridgeEventKind::UserInputRequested,
            occurred_at: Utc::now().to_rfc3339(),
            payload: json!({
                "request_id": request_id,
                "state": "resolved",
            }),
            annotations: None,
        };
        self.projections().apply_live_event(&event).await;
        self.event_hub().publish(event);
    }

    async fn publish_user_input_pending_event(
        &self,
        thread_id: &str,
        pending_user_input: &PendingUserInputDto,
    ) {
        let event = BridgeEventEnvelope {
            contract_version: CONTRACT_VERSION.to_string(),
            event_id: format!("{thread_id}-{}", pending_user_input.request_id),
            thread_id: thread_id.to_string(),
            kind: BridgeEventKind::UserInputRequested,
            occurred_at: Utc::now().to_rfc3339(),
            payload: json!({
                "request_id": pending_user_input.request_id,
                "title": pending_user_input.title,
                "detail": pending_user_input.detail,
                "questions": pending_user_input.questions,
                "state": "pending",
            }),
            annotations: None,
        };
        self.projections().apply_live_event(&event).await;
        self.event_hub().publish(event);
    }

    async fn merge_pending_user_message_images(&self, event: &mut BridgeEventEnvelope<Value>) {
        if event.kind != BridgeEventKind::MessageDelta {
            return;
        }
        if event.payload.get("role").and_then(Value::as_str) != Some("user") {
            return;
        }

        let Some(pending_images) = self
            .inner
            .pending_user_message_images
            .write()
            .await
            .remove(&event.thread_id)
        else {
            return;
        };

        let has_images = event
            .payload
            .get("images")
            .and_then(Value::as_array)
            .is_some_and(|images| !images.is_empty());
        if has_images {
            return;
        }

        if let Some(object) = event.payload.as_object_mut() {
            object.insert(
                "images".to_string(),
                Value::Array(pending_images.into_iter().map(Value::String).collect()),
            );
        }
    }

    async fn has_bridge_owned_active_turn(&self, thread_id: &str) -> bool {
        if self
            .inner
            .active_turn_ids
            .read()
            .await
            .contains_key(thread_id)
        {
            return true;
        }

        self.inner
            .pending_bridge_owned_turns
            .read()
            .await
            .contains(thread_id)
    }

    pub async fn interrupt_turn(
        &self,
        thread_id: &str,
        turn_id: Option<&str>,
    ) -> Result<TurnMutationAcceptedDto, String> {
        let resolved_turn_id = if let Some(turn_id) = turn_id {
            turn_id.to_string()
        } else {
            if let Some(turn_id) = self
                .inner
                .active_turn_ids
                .read()
                .await
                .get(thread_id)
                .cloned()
            {
                turn_id
            } else {
                let turn_id = self.inner.gateway.resolve_active_turn_id(thread_id).await?;
                self.inner
                    .active_turn_ids
                    .write()
                    .await
                    .insert(thread_id.to_string(), turn_id.clone());
                turn_id
            }
        };
        let result = self
            .inner
            .gateway
            .interrupt_turn(thread_id, &resolved_turn_id)
            .await?;
        let occurred_at = Utc::now().to_rfc3339();
        self.mark_thread_interrupt_requested(thread_id).await;
        self.projections()
            .mark_thread_status(thread_id, ThreadStatus::Interrupted, &occurred_at)
            .await;
        self.inner.active_turn_ids.write().await.remove(thread_id);
        self.event_hub().publish(BridgeEventEnvelope {
            contract_version: shared_contracts::CONTRACT_VERSION.to_string(),
            event_id: format!("{thread_id}-status-{occurred_at}"),
            thread_id: thread_id.to_string(),
            kind: BridgeEventKind::ThreadStatusChanged,
            occurred_at,
            payload: json!({
                "status": "interrupted",
                "reason": "interrupt_requested",
            }),
            annotations: None,
        });
        Ok(result.response)
    }

    pub async fn bootstrap_payload(&self) -> BootstrapDto {
        let codex = self.inner.codex_health.read().await.clone();
        let models = self.inner.available_models.read().await.clone();
        let trust_snapshot = self.trust_snapshot();
        let access_mode = self.access_mode().await;

        BootstrapDto {
            contract_version: shared_contracts::CONTRACT_VERSION.to_string(),
            bridge: ServiceHealthDto {
                status: ServiceHealthStatus::Healthy,
                message: self.pairing_route_health().message,
            },
            codex,
            trust: TrustStateDto {
                trusted: trust_snapshot.trusted_phone.is_some(),
                access_mode,
            },
            threads: self.projections().list_summaries().await,
            models,
        }
    }

    #[cfg(test)]
    pub async fn set_codex_usage_client_for_tests(&self, client: CodexUsageClient) {
        *self.inner.codex_usage_client.write().await = client;
    }

    pub async fn model_catalog_payload(&self, provider: ProviderKind) -> ModelCatalogDto {
        let models = match provider {
            ProviderKind::Codex => self.inner.available_models.read().await.clone(),
            ProviderKind::ClaudeCode => self.inner.gateway.model_catalog(provider),
        };
        ModelCatalogDto {
            contract_version: shared_contracts::CONTRACT_VERSION.to_string(),
            models,
        }
    }

    pub async fn speech_status(&self) -> shared_contracts::SpeechModelStatusDto {
        self.inner.speech.status().await
    }

    pub async fn ensure_speech_model(
        &self,
    ) -> Result<shared_contracts::SpeechModelMutationAcceptedDto, SpeechError> {
        self.inner.speech.ensure_model().await
    }

    pub async fn remove_speech_model(
        &self,
    ) -> Result<shared_contracts::SpeechModelMutationAcceptedDto, SpeechError> {
        self.inner.speech.remove_model().await
    }

    pub async fn transcribe_audio_bytes(
        &self,
        file_name: Option<&str>,
        audio_bytes: &[u8],
    ) -> Result<shared_contracts::SpeechTranscriptionResultDto, SpeechError> {
        self.inner
            .speech
            .transcribe_bytes(file_name, audio_bytes)
            .await
    }
}

fn title_generation_model_for_thread<'a>(
    thread_id: &str,
    model: Option<&'a str>,
) -> Option<&'a str> {
    if is_provider_thread_id(thread_id, ProviderKind::Codex) {
        return model;
    }

    None
}

fn provisional_thread_title_from_prompt(thread_id: &str, prompt: &str) -> Option<String> {
    if !is_provider_thread_id(thread_id, ProviderKind::ClaudeCode) {
        return None;
    }

    let first_sentence = prompt
        .split(['.', '?', '!'])
        .find(|segment| !segment.trim().is_empty())
        .unwrap_or(prompt);
    normalize_prompt_fallback_thread_title(first_sentence)
}

fn normalize_prompt_fallback_thread_title(prompt: &str) -> Option<String> {
    let normalized_whitespace = prompt.split_whitespace().collect::<Vec<_>>().join(" ");
    let trimmed = normalized_whitespace
        .trim()
        .trim_matches(|ch| matches!(ch, '"' | '\'' | '`'));
    if trimmed.is_empty() || is_placeholder_thread_title(trimmed) {
        return None;
    }

    let mut title = trimmed.to_string();
    const MAX_THREAD_TITLE_CHARS: usize = 80;
    if title.chars().count() > MAX_THREAD_TITLE_CHARS {
        title = title
            .chars()
            .take(MAX_THREAD_TITLE_CHARS)
            .collect::<String>();
    }

    while title.ends_with('.') || title.ends_with(':') || title.ends_with(';') {
        title.pop();
    }

    let normalized = title.trim();
    if normalized.is_empty() || is_placeholder_thread_title(normalized) {
        return None;
    }

    Some(normalized.to_string())
}

fn preserve_generated_thread_title(
    previous_snapshot: &ThreadSnapshotDto,
    next_snapshot: &mut ThreadSnapshotDto,
) {
    if is_placeholder_thread_title(&next_snapshot.thread.title)
        && !is_placeholder_thread_title(&previous_snapshot.thread.title)
    {
        next_snapshot.thread.title = previous_snapshot.thread.title.clone();
    }
}

fn merge_reconciled_thread_summaries(
    current_summaries: Vec<ThreadSummaryDto>,
    mut reconciled_summaries: Vec<ThreadSummaryDto>,
) -> Vec<ThreadSummaryDto> {
    let current_by_thread_id = current_summaries
        .into_iter()
        .map(|summary| (summary.thread_id.clone(), summary))
        .collect::<HashMap<_, _>>();

    for summary in &mut reconciled_summaries {
        let Some(current_summary) = current_by_thread_id.get(&summary.thread_id) else {
            continue;
        };
        if is_placeholder_thread_title(&summary.title)
            && !is_placeholder_thread_title(&current_summary.title)
        {
            summary.title = current_summary.title.clone();
        }
    }

    reconciled_summaries
}

fn resolve_latest_thread_change_diff(
    entries: &[ThreadTimelineEntryDto],
    path: Option<&str>,
) -> String {
    let normalized_path = path.map(str::trim).filter(|path| !path.is_empty());
    for entry in entries.iter().rev() {
        let Some(diff) = entry
            .payload
            .get("resolved_unified_diff")
            .and_then(Value::as_str)
            .or_else(|| entry.payload.get("output").and_then(Value::as_str))
        else {
            continue;
        };
        let summaries = parse_git_diff_file_summaries(diff);
        if summaries.is_empty() {
            continue;
        }
        if let Some(path) = normalized_path
            && summaries.iter().all(|file| file.path != path)
        {
            continue;
        }
        return diff.to_string();
    }
    String::new()
}

fn resolve_workspace_diff(
    workspace: &str,
    path: Option<&str>,
) -> Result<(String, Option<String>), String> {
    let workspace = workspace.trim();
    if workspace.is_empty() {
        return Err("thread workspace is unavailable".to_string());
    }
    if !Path::new(workspace).exists() {
        return Err(format!("thread workspace does not exist: {workspace}"));
    }

    let revision = git_output(workspace, &["rev-parse", "HEAD"])
        .ok()
        .map(|value| value.trim().to_string());
    let mut unified_diff = git_output(
        workspace,
        &[
            "-c",
            "core.quotepath=false",
            "diff",
            "HEAD",
            "--find-renames",
            "--find-copies",
            "--binary",
            "--",
        ],
    )
    .or_else(|_| {
        git_output(
            workspace,
            &[
                "-c",
                "core.quotepath=false",
                "diff",
                "--cached",
                "--find-renames",
                "--find-copies",
                "--binary",
                "--",
            ],
        )
    })?;

    if let Some(path) = path.map(str::trim).filter(|path| !path.is_empty()) {
        unified_diff = git_output(
            workspace,
            &[
                "-c",
                "core.quotepath=false",
                "diff",
                "HEAD",
                "--find-renames",
                "--find-copies",
                "--binary",
                "--",
                path,
            ],
        )
        .or_else(|_| {
            git_output(
                workspace,
                &[
                    "-c",
                    "core.quotepath=false",
                    "diff",
                    "--cached",
                    "--find-renames",
                    "--find-copies",
                    "--binary",
                    "--",
                    path,
                ],
            )
        })?;
    }

    let mut untracked_files =
        git_output(workspace, &["ls-files", "--others", "--exclude-standard"])?
            .lines()
            .map(str::trim)
            .filter(|line| !line.is_empty())
            .filter(|line| {
                path.map(str::trim)
                    .filter(|value| !value.is_empty())
                    .is_none_or(|selected| *line == selected)
            })
            .map(ToOwned::to_owned)
            .collect::<Vec<_>>();
    untracked_files.sort();
    for untracked in untracked_files {
        if Path::new(workspace).join(&untracked).is_dir() {
            continue;
        }
        let diff = git_no_index_diff(workspace, "/dev/null", &untracked)?;
        if !unified_diff.is_empty() && !diff.is_empty() {
            unified_diff.push('\n');
        }
        unified_diff.push_str(diff.trim_end());
    }

    Ok((unified_diff.trim().to_string(), revision))
}

fn git_output(workspace: &str, args: &[&str]) -> Result<String, String> {
    let output = Command::new("git")
        .current_dir(workspace)
        .args(args)
        .output()
        .map_err(|error| format!("failed to execute git: {error}"))?;
    if output.status.success() {
        Ok(String::from_utf8_lossy(&output.stdout).to_string())
    } else {
        Err(String::from_utf8_lossy(&output.stderr).trim().to_string())
    }
}

fn git_no_index_diff(workspace: &str, left: &str, right: &str) -> Result<String, String> {
    let output = Command::new("git")
        .current_dir(workspace)
        .args([
            "-c",
            "core.quotepath=false",
            "diff",
            "--no-index",
            "--binary",
            "--find-renames",
            "--find-copies",
            left,
            right,
        ])
        .output()
        .map_err(|error| format!("failed to execute git diff --no-index: {error}"))?;

    if output.status.success() || output.status.code() == Some(1) {
        Ok(String::from_utf8_lossy(&output.stdout).to_string())
    } else {
        Err(String::from_utf8_lossy(&output.stderr).trim().to_string())
    }
}

fn parse_git_diff_file_summaries(diff: &str) -> Vec<GitDiffFileSummaryDto> {
    let mut files = Vec::new();
    let mut current: Option<ParsedGitDiffSummary> = None;

    for line in diff.lines() {
        if let Some(rest) = line.strip_prefix("diff --git ") {
            if let Some(file) = current.take() {
                files.push(file.finish());
            }
            current = Some(ParsedGitDiffSummary::from_diff_git(rest));
            continue;
        }

        let Some(file) = current.as_mut() else {
            continue;
        };

        if let Some(path) = line.strip_prefix("--- ") {
            file.apply_old_marker(path.trim());
            continue;
        }
        if let Some(path) = line.strip_prefix("+++ ") {
            file.apply_new_marker(path.trim());
            continue;
        }
        if let Some(path) = line.strip_prefix("rename from ") {
            file.old_path = Some(path.trim().to_string());
            file.change_type = GitDiffChangeTypeDto::Renamed;
            continue;
        }
        if let Some(path) = line.strip_prefix("rename to ") {
            file.new_path = Some(path.trim().to_string());
            file.path = path.trim().to_string();
            file.change_type = GitDiffChangeTypeDto::Renamed;
            continue;
        }
        if let Some(path) = line.strip_prefix("copy from ") {
            file.old_path = Some(path.trim().to_string());
            file.change_type = GitDiffChangeTypeDto::Copied;
            continue;
        }
        if let Some(path) = line.strip_prefix("copy to ") {
            file.new_path = Some(path.trim().to_string());
            file.path = path.trim().to_string();
            file.change_type = GitDiffChangeTypeDto::Copied;
            continue;
        }
        if line.starts_with("new file mode ") {
            file.change_type = GitDiffChangeTypeDto::Added;
            continue;
        }
        if line.starts_with("deleted file mode ") {
            file.change_type = GitDiffChangeTypeDto::Deleted;
            continue;
        }
        if line.starts_with("old mode ") || line.starts_with("new mode ") {
            if file.change_type == GitDiffChangeTypeDto::Modified {
                file.change_type = GitDiffChangeTypeDto::TypeChanged;
            }
            continue;
        }
        if line.starts_with("Binary files ") || line.starts_with("GIT binary patch") {
            file.is_binary = true;
            continue;
        }
        if line.starts_with("@@ ") || line == "@@" {
            continue;
        }
        if line.starts_with('+') && !line.starts_with("+++") {
            file.additions += 1;
            continue;
        }
        if line.starts_with('-') && !line.starts_with("---") {
            file.deletions += 1;
        }
    }

    if let Some(file) = current.take() {
        files.push(file.finish());
    }

    files
}

#[derive(Debug)]
struct ParsedGitDiffSummary {
    path: String,
    old_path: Option<String>,
    new_path: Option<String>,
    change_type: GitDiffChangeTypeDto,
    additions: u32,
    deletions: u32,
    is_binary: bool,
}

impl ParsedGitDiffSummary {
    fn from_diff_git(rest: &str) -> Self {
        let mut parts = rest.split_whitespace();
        let old_path = parts.next().map(normalize_diff_path);
        let new_path = parts.next().map(normalize_diff_path);
        let path = new_path
            .clone()
            .or_else(|| old_path.clone())
            .unwrap_or_default();

        Self {
            path,
            old_path,
            new_path,
            change_type: GitDiffChangeTypeDto::Modified,
            additions: 0,
            deletions: 0,
            is_binary: false,
        }
    }

    fn apply_old_marker(&mut self, path: &str) {
        if path == "/dev/null" {
            self.change_type = GitDiffChangeTypeDto::Added;
            self.old_path = None;
            return;
        }
        self.old_path = Some(normalize_diff_path(path));
    }

    fn apply_new_marker(&mut self, path: &str) {
        if path == "/dev/null" {
            self.change_type = GitDiffChangeTypeDto::Deleted;
            self.new_path = None;
            return;
        }
        let normalized = normalize_diff_path(path);
        self.path = normalized.clone();
        self.new_path = Some(normalized);
    }

    fn finish(self) -> GitDiffFileSummaryDto {
        GitDiffFileSummaryDto {
            path: self.path,
            old_path: self.old_path,
            new_path: self.new_path,
            change_type: self.change_type,
            additions: self.additions,
            deletions: self.deletions,
            is_binary: self.is_binary,
        }
    }
}

fn normalize_diff_path(path: &str) -> String {
    path.trim()
        .trim_matches('"')
        .strip_prefix("a/")
        .or_else(|| path.trim().trim_matches('"').strip_prefix("b/"))
        .unwrap_or(path.trim().trim_matches('"'))
        .to_string()
}

#[derive(Debug, Default)]
struct LiveDeltaCompactor {
    text_by_event_id: HashMap<String, String>,
    output_by_event_id: HashMap<String, String>,
    diff_by_event_id: HashMap<String, String>,
}

impl LiveDeltaCompactor {
    fn compact(&mut self, event: BridgeEventEnvelope<Value>) -> BridgeEventEnvelope<Value> {
        match event.kind {
            BridgeEventKind::MessageDelta => {
                if event.payload.get("text").is_none()
                    && event.payload.get("delta").and_then(Value::as_str).is_some()
                {
                    return event;
                }
                let role = match event.payload.get("type").and_then(Value::as_str) {
                    Some("userMessage") => "user",
                    _ => "assistant",
                };
                let current_text = event
                    .payload
                    .get("text")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                let (delta, replace) = compact_incremental_text(
                    &mut self.text_by_event_id,
                    &event.event_id,
                    current_text,
                );

                BridgeEventEnvelope {
                    payload: json!({
                        "id": event.payload.get("id").and_then(Value::as_str).unwrap_or_default(),
                        "type": "message",
                        "role": role,
                        "delta": delta,
                        "replace": replace,
                    }),
                    ..event
                }
            }
            BridgeEventKind::PlanDelta => {
                if event.payload.get("text").is_none()
                    && event.payload.get("delta").and_then(Value::as_str).is_some()
                {
                    return event;
                }
                let current_text = event
                    .payload
                    .get("text")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                let (delta, replace) = compact_incremental_text(
                    &mut self.text_by_event_id,
                    &event.event_id,
                    current_text,
                );

                let mut payload = json!({
                    "id": event.payload.get("id").and_then(Value::as_str).unwrap_or_default(),
                    "type": "plan",
                    "delta": delta,
                    "replace": replace,
                });
                if let Some(object) = payload.as_object_mut() {
                    if let Some(explanation) = event.payload.get("explanation") {
                        object.insert("explanation".to_string(), explanation.clone());
                    }
                    if let Some(steps) = event.payload.get("steps") {
                        object.insert("steps".to_string(), steps.clone());
                    }
                    if let Some(completed_count) = event.payload.get("completed_count") {
                        object.insert("completed_count".to_string(), completed_count.clone());
                    }
                    if let Some(total_count) = event.payload.get("total_count") {
                        object.insert("total_count".to_string(), total_count.clone());
                    }
                }

                BridgeEventEnvelope { payload, ..event }
            }
            BridgeEventKind::CommandDelta => {
                let current_output = event
                    .payload
                    .get("output")
                    .or_else(|| event.payload.get("aggregatedOutput"))
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                let (delta, replace) = compact_incremental_text(
                    &mut self.output_by_event_id,
                    &event.event_id,
                    current_output,
                );

                BridgeEventEnvelope {
                    payload: json!({
                        "id": event.payload.get("id").and_then(Value::as_str).unwrap_or_default(),
                        "type": "command",
                        "command": event.payload.get("command").and_then(Value::as_str).unwrap_or_default(),
                        "cmd": event.payload.get("cmd").and_then(Value::as_str),
                        "workdir": event.payload.get("cwd").and_then(Value::as_str),
                        "delta": delta,
                        "replace": replace,
                    }),
                    ..event
                }
            }
            BridgeEventKind::FileChange => {
                let current_diff = event
                    .payload
                    .get("resolved_unified_diff")
                    .or_else(|| event.payload.get("output"))
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                let (delta, replace) = compact_incremental_text(
                    &mut self.diff_by_event_id,
                    &event.event_id,
                    current_diff,
                );

                BridgeEventEnvelope {
                    payload: json!({
                        "id": event.payload.get("id").and_then(Value::as_str).unwrap_or_default(),
                        "type": "file_change",
                        "path": event.payload.get("path").or_else(|| event.payload.get("file")).and_then(Value::as_str).unwrap_or_default(),
                        "delta": delta,
                        "replace": replace,
                    }),
                    ..event
                }
            }
            _ => event,
        }
    }
}

fn compact_incremental_text(
    cache: &mut HashMap<String, String>,
    event_id: &str,
    current_value: &str,
) -> (String, bool) {
    compact_incremental_full_text(cache, event_id, current_value)
}

fn claude_permission_mode_for_access_mode(access_mode: AccessMode) -> String {
    match access_mode {
        AccessMode::ReadOnly => "plan".to_string(),
        AccessMode::ControlWithApprovals => "default".to_string(),
        AccessMode::FullControl => "acceptEdits".to_string(),
    }
}

fn thread_summary_from_snapshot(snapshot: &ThreadSnapshotDto) -> ThreadSummaryDto {
    ThreadSummaryDto {
        contract_version: snapshot.contract_version.clone(),
        thread_id: snapshot.thread.thread_id.clone(),
        native_thread_id: snapshot.thread.native_thread_id.clone(),
        provider: snapshot.thread.provider,
        client: snapshot.thread.client,
        title: snapshot.thread.title.clone(),
        status: snapshot.thread.status,
        workspace: snapshot.thread.workspace.clone(),
        repository: snapshot.thread.repository.clone(),
        branch: snapshot.thread.branch.clone(),
        updated_at: snapshot.thread.updated_at.clone(),
    }
}

#[derive(Debug, Clone)]
struct ThreadTitleGenerationSource {
    workspace: String,
    prompt: String,
}

fn title_generation_source_from_snapshot(
    snapshot: &ThreadSnapshotDto,
) -> Option<ThreadTitleGenerationSource> {
    let prompt = snapshot
        .entries
        .iter()
        .find_map(first_user_message_text_from_entry)
        .or_else(|| {
            let summary = snapshot.thread.last_turn_summary.trim();
            (!summary.is_empty() && !is_placeholder_thread_title(summary))
                .then(|| summary.to_string())
        })?;
    let workspace = snapshot.thread.workspace.trim();
    if workspace.is_empty() {
        return None;
    }

    Some(ThreadTitleGenerationSource {
        workspace: workspace.to_string(),
        prompt,
    })
}

fn first_user_message_text_from_entry(entry: &ThreadTimelineEntryDto) -> Option<String> {
    if entry.kind != BridgeEventKind::MessageDelta {
        return None;
    }
    if entry.payload.get("role").and_then(Value::as_str) != Some("user") {
        return None;
    }

    extract_text_from_payload(&entry.payload)
}

fn extract_text_from_payload(payload: &Value) -> Option<String> {
    for key in ["text", "delta", "message"] {
        if let Some(value) = payload.get(key).and_then(Value::as_str) {
            let trimmed = value.trim();
            if !trimmed.is_empty() {
                return Some(trimmed.to_string());
            }
        }
    }

    payload
        .get("content")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .find_map(|item| item.get("text").and_then(Value::as_str))
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToString::to_string)
}

fn build_hidden_plan_question_prompt(user_prompt: &str) -> String {
    format!(
        concat!(
            "You are running in mobile plan intake mode.\n",
            "Do not edit files, do not run commands, and do not produce the plan yet.\n",
            "Return only one XML-like block with no markdown fences and no extra prose.\n",
            "Use this exact wrapper: <codex-plan-questions>{{JSON}}</codex-plan-questions>\n",
            "The JSON must contain:\n",
            "- title: short string\n",
            "- detail: short string\n",
            "- questions: array of 1 to 3 questions\n",
            "Each question must contain question_id, prompt, and exactly 3 options.\n",
            "Each option must contain option_id, label, description, and is_recommended.\n",
            "Keep the choices mutually exclusive and concise.\n",
            "Original user request:\n{user_prompt}\n"
        ),
        user_prompt = user_prompt
    )
}

fn build_hidden_plan_followup_prompt(
    original_prompt: &str,
    questionnaire: &PendingUserInputDto,
    answers: &[UserInputAnswerDto],
    free_text: Option<&str>,
) -> String {
    format!(
        concat!(
            "You are continuing a mobile planning workflow.\n",
            "Do not edit files or run commands.\n",
            "Use the user's original request plus their selected answers to produce a concrete execution plan.\n",
            "If appropriate, emit update_plan with 3 to 7 actionable steps.\n",
            "After the plan, summarize the main tradeoffs briefly.\n\n",
            "Original request:\n{original_prompt}\n\n",
            "Questionnaire:\n{questionnaire_json}\n\n",
            "Selected answers:\n{answers_json}\n\n",
            "Additional free text:\n{free_text}\n"
        ),
        original_prompt = original_prompt,
        questionnaire_json =
            serde_json::to_string_pretty(questionnaire).unwrap_or_else(|_| "{}".to_string()),
        answers_json = serde_json::to_string_pretty(answers).unwrap_or_else(|_| "[]".to_string()),
        free_text = free_text.unwrap_or(""),
    )
}

fn render_user_input_response_summary(
    questionnaire: &PendingUserInputDto,
    answers: &[UserInputAnswerDto],
    free_text: Option<&str>,
) -> String {
    let mut lines = vec!["Plan clarification".to_string()];

    for answer in answers {
        let question_prompt = questionnaire
            .questions
            .iter()
            .find(|question| question.question_id == answer.question_id)
            .map(|question| question.prompt.as_str())
            .unwrap_or("Question");
        let option_label = questionnaire
            .questions
            .iter()
            .find(|question| question.question_id == answer.question_id)
            .and_then(|question| {
                question
                    .options
                    .iter()
                    .find(|option| option.option_id == answer.option_id)
            })
            .map(|option| option.label.as_str())
            .unwrap_or("Selected");
        lines.push(format!("- {question_prompt}: {option_label}"));
    }

    if let Some(free_text) = free_text {
        lines.push(format!("- Something else: {free_text}"));
    }

    lines.join("\n")
}

fn parse_provider_approval_selection(
    answers: &[UserInputAnswerDto],
) -> Option<ProviderApprovalSelection> {
    let selected_option_id = answers
        .iter()
        .find(|answer| answer.question_id == "approval_decision")
        .or_else(|| answers.first())
        .map(|answer| answer.option_id.as_str())?;
    match selected_option_id {
        USER_INPUT_OPTION_ALLOW_ONCE => Some(ProviderApprovalSelection::AllowOnce),
        USER_INPUT_OPTION_ALLOW_SESSION => Some(ProviderApprovalSelection::AllowForSession),
        USER_INPUT_OPTION_DENY => Some(ProviderApprovalSelection::Deny),
        _ => None,
    }
}

fn build_provider_approval_questionnaire(
    thread_id: &str,
    title: String,
    detail: Option<String>,
) -> PendingUserInputDto {
    PendingUserInputDto {
        request_id: format!(
            "provider-approval-{}-{}",
            thread_id,
            Utc::now().timestamp_millis()
        ),
        title,
        detail,
        questions: vec![UserInputQuestionDto {
            question_id: "approval_decision".to_string(),
            prompt: "Choose an action".to_string(),
            options: vec![
                UserInputOptionDto {
                    option_id: USER_INPUT_OPTION_ALLOW_ONCE.to_string(),
                    label: "Allow once".to_string(),
                    description: "Approve this action one time.".to_string(),
                    is_recommended: true,
                },
                UserInputOptionDto {
                    option_id: USER_INPUT_OPTION_ALLOW_SESSION.to_string(),
                    label: "Allow for session".to_string(),
                    description: "Approve now and remember for this session.".to_string(),
                    is_recommended: false,
                },
                UserInputOptionDto {
                    option_id: USER_INPUT_OPTION_DENY.to_string(),
                    label: "Deny".to_string(),
                    description: "Deny this action and interrupt the turn.".to_string(),
                    is_recommended: false,
                },
            ],
        }],
    }
}

fn stringify_provider_request_id(raw_request_id: &Value) -> String {
    if let Some(text) = raw_request_id.as_str() {
        return text.to_string();
    }
    if let Some(value) = raw_request_id.as_i64() {
        return value.to_string();
    }
    if let Some(value) = raw_request_id.as_u64() {
        return value.to_string();
    }
    raw_request_id.to_string()
}

fn join_optional_detail_lines(lines: impl IntoIterator<Item = Option<String>>) -> Option<String> {
    let lines = lines
        .into_iter()
        .flatten()
        .map(|line| line.trim().to_string())
        .filter(|line| !line.is_empty())
        .collect::<Vec<_>>();
    (!lines.is_empty()).then(|| lines.join("\n"))
}

fn build_pending_provider_approval_from_codex(
    fallback_thread_id: &str,
    raw_request_id: &Value,
    method: &str,
    params: &Value,
) -> Result<Option<ProviderApprovalPrompt>, String> {
    let thread_id = params
        .get("threadId")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or(fallback_thread_id);
    let reason = params
        .get("reason")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToString::to_string);
    let prompt = match method {
        "item/commandExecution/requestApproval" => {
            let command = params
                .get("command")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(|value| format!("Command: {value}"));
            let cwd = params
                .get("cwd")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(|value| format!("Working directory: {value}"));
            Some(ProviderApprovalPrompt {
                questionnaire: build_provider_approval_questionnaire(
                    thread_id,
                    "Approve command execution?".to_string(),
                    join_optional_detail_lines([reason, command, cwd]),
                ),
                provider_request_id: stringify_provider_request_id(raw_request_id),
                context: ProviderApprovalContext::CodexCommandOrFile,
            })
        }
        "item/fileChange/requestApproval" => {
            let grant_root = params
                .get("grantRoot")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(|value| format!("Requested write root: {value}"));
            Some(ProviderApprovalPrompt {
                questionnaire: build_provider_approval_questionnaire(
                    thread_id,
                    "Approve file changes?".to_string(),
                    join_optional_detail_lines([reason, grant_root]),
                ),
                provider_request_id: stringify_provider_request_id(raw_request_id),
                context: ProviderApprovalContext::CodexCommandOrFile,
            })
        }
        "item/permissions/requestApproval" => {
            let turn_id = params
                .get("turnId")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string();
            let requested_permissions = params
                .get("permissions")
                .cloned()
                .unwrap_or_else(|| json!({}));
            let permission_summary = summarize_codex_requested_permissions(&requested_permissions)
                .map(|summary| format!("Requested permissions: {summary}"));
            Some(ProviderApprovalPrompt {
                questionnaire: build_provider_approval_questionnaire(
                    thread_id,
                    "Approve additional permissions?".to_string(),
                    join_optional_detail_lines([reason, permission_summary]),
                ),
                provider_request_id: stringify_provider_request_id(raw_request_id),
                context: ProviderApprovalContext::CodexPermissions { turn_id },
            })
        }
        _ => None,
    };
    Ok(prompt)
}

fn summarize_codex_requested_permissions(permissions: &Value) -> Option<String> {
    let mut parts = Vec::new();
    let file_system = permissions.get("fileSystem");
    let read_paths = file_system
        .and_then(|profile| profile.get("read"))
        .and_then(Value::as_array)
        .map_or(0, Vec::len);
    let write_paths = file_system
        .and_then(|profile| profile.get("write"))
        .and_then(Value::as_array)
        .map_or(0, Vec::len);
    if read_paths > 0 {
        parts.push(format!("read paths: {read_paths}"));
    }
    if write_paths > 0 {
        parts.push(format!("write paths: {write_paths}"));
    }
    if permissions
        .get("network")
        .and_then(|profile| profile.get("enabled"))
        .and_then(Value::as_bool)
        .unwrap_or(false)
    {
        parts.push("network access".to_string());
    }
    (!parts.is_empty()).then(|| parts.join(", "))
}

fn build_codex_approval_response(
    method: &str,
    params: &Value,
    selection: ProviderApprovalSelection,
) -> Result<Value, String> {
    let response = match method {
        "item/commandExecution/requestApproval" | "item/fileChange/requestApproval" => {
            let decision = match selection {
                ProviderApprovalSelection::AllowOnce => "accept",
                ProviderApprovalSelection::AllowForSession => "acceptForSession",
                ProviderApprovalSelection::Deny => "cancel",
            };
            json!({ "decision": decision })
        }
        "item/permissions/requestApproval" => {
            let requested_permissions = params
                .get("permissions")
                .cloned()
                .unwrap_or_else(|| json!({}));
            match selection {
                ProviderApprovalSelection::AllowOnce => json!({
                    "permissions": requested_permissions,
                    "scope": "turn",
                }),
                ProviderApprovalSelection::AllowForSession => json!({
                    "permissions": requested_permissions,
                    "scope": "session",
                }),
                ProviderApprovalSelection::Deny => json!({
                    "permissions": {},
                    "scope": "turn",
                }),
            }
        }
        _ => return Err(format!("unsupported codex approval method: {method}")),
    };
    Ok(response)
}

fn build_pending_provider_approval_from_claude(
    thread_id: &str,
    request_id: String,
    request: Value,
) -> Result<ProviderApprovalPrompt, String> {
    if request.get("subtype").and_then(Value::as_str) != Some("can_use_tool") {
        return Err("unsupported Claude control request subtype".to_string());
    }
    let tool_name = request
        .get("display_name")
        .or_else(|| request.get("tool_name"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or("tool");
    let detail = join_optional_detail_lines([
        request
            .get("description")
            .and_then(Value::as_str)
            .map(ToString::to_string),
        summarize_claude_tool_input(request.get("input")),
    ]);
    let context = ProviderApprovalContext::ClaudeCanUseTool;
    Ok(ProviderApprovalPrompt {
        questionnaire: build_provider_approval_questionnaire(
            thread_id,
            format!("Approve {tool_name}?"),
            detail,
        ),
        provider_request_id: request_id,
        context,
    })
}

fn summarize_claude_tool_input(raw_input: Option<&Value>) -> Option<String> {
    let Some(input) = raw_input else {
        return None;
    };
    let Some(input_map) = input.as_object() else {
        return None;
    };
    let summary = input_map
        .iter()
        .take(3)
        .map(|(key, value)| {
            let formatted = value
                .as_str()
                .map(ToString::to_string)
                .unwrap_or_else(|| value.to_string());
            format!("{key}: {formatted}")
        })
        .collect::<Vec<_>>()
        .join(", ");
    (!summary.is_empty()).then(|| format!("Input: {summary}"))
}

fn build_claude_tool_approval_response(
    selection: ProviderApprovalSelection,
    request: &Value,
) -> Value {
    let mut response = match selection {
        ProviderApprovalSelection::AllowOnce | ProviderApprovalSelection::AllowForSession => {
            json!({
                "behavior": "allow",
                "updatedInput": request
                    .get("input")
                    .cloned()
                    .unwrap_or_else(|| Value::Object(serde_json::Map::new())),
            })
        }
        ProviderApprovalSelection::Deny => json!({
            "behavior": "deny",
            "message": "Permission denied by mobile approval.",
            "interrupt": true,
        }),
    };
    if let Some(object) = response.as_object_mut() {
        if let Some(tool_use_id) = request.get("tool_use_id").and_then(Value::as_str) {
            object.insert(
                "toolUseID".to_string(),
                Value::String(tool_use_id.to_string()),
            );
        }
        if selection == ProviderApprovalSelection::AllowForSession
            && let Some(suggestions) = request.get("permission_suggestions")
        {
            object.insert("updatedPermissions".to_string(), suggestions.clone());
        }
    }
    response
}

pub(super) fn parse_pending_user_input_payload(
    message_text: &str,
    thread_id: &str,
) -> Option<PendingUserInputDto> {
    let start = message_text.find("<codex-plan-questions>")?;
    let end = message_text.find("</codex-plan-questions>")?;
    if end <= start {
        return None;
    }

    let json_payload = message_text[start + "<codex-plan-questions>".len()..end].trim();
    let parsed = serde_json::from_str::<Value>(json_payload).ok()?;
    let title = parsed
        .get("title")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or("Clarify the plan")
        .to_string();
    let detail = parsed
        .get("detail")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string);

    let questions = parsed
        .get("questions")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|entry| {
            let prompt = entry
                .get("prompt")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|value| !value.is_empty())?;
            let question_id = entry
                .get("question_id")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(str::to_string)
                .unwrap_or_else(|| sanitize_user_input_id(prompt));
            let options = entry
                .get("options")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(|option| {
                    let label = option
                        .get("label")
                        .and_then(Value::as_str)
                        .map(str::trim)
                        .filter(|value| !value.is_empty())?;
                    Some(UserInputOptionDto {
                        option_id: option
                            .get("option_id")
                            .and_then(Value::as_str)
                            .map(str::trim)
                            .filter(|value| !value.is_empty())
                            .map(str::to_string)
                            .unwrap_or_else(|| sanitize_user_input_id(label)),
                        label: label.to_string(),
                        description: option
                            .get("description")
                            .and_then(Value::as_str)
                            .map(str::trim)
                            .unwrap_or_default()
                            .to_string(),
                        is_recommended: option
                            .get("is_recommended")
                            .and_then(Value::as_bool)
                            .unwrap_or(false),
                    })
                })
                .take(3)
                .collect::<Vec<_>>();

            if options.len() != 3 {
                return None;
            }

            Some(UserInputQuestionDto {
                question_id,
                prompt: prompt.to_string(),
                options,
            })
        })
        .take(3)
        .collect::<Vec<_>>();

    if questions.is_empty() {
        return None;
    }

    Some(PendingUserInputDto {
        request_id: format!("user-input-{}-{}", thread_id, Utc::now().timestamp_millis()),
        title,
        detail,
        questions,
    })
}

fn sanitize_user_input_id(value: &str) -> String {
    let mut identifier = value
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() {
                ch.to_ascii_lowercase()
            } else {
                '-'
            }
        })
        .collect::<String>();
    while identifier.contains("--") {
        identifier = identifier.replace("--", "-");
    }
    identifier.trim_matches('-').to_string()
}

fn is_placeholder_thread_title(title: &str) -> bool {
    let normalized = title.trim().to_lowercase();
    normalized.is_empty()
        || normalized == "untitled thread"
        || normalized == "new thread"
        || normalized == "fresh session"
}

fn thread_status_wire_value(status: ThreadStatus) -> &'static str {
    match status {
        ThreadStatus::Idle => "idle",
        ThreadStatus::Running => "running",
        ThreadStatus::Completed => "completed",
        ThreadStatus::Interrupted => "interrupted",
        ThreadStatus::Failed => "failed",
    }
}

fn build_turn_started_history_event(
    thread_id: &str,
    occurred_at: &str,
    turn_id: Option<&str>,
    model: Option<&str>,
    effort: Option<&str>,
) -> BridgeEventEnvelope<Value> {
    let mut payload = json!({
        "status": "running",
        "reason": "turn_started",
    });
    if let Some(turn_id) = turn_id.filter(|value| !value.trim().is_empty()) {
        payload["turn_id"] = Value::String(turn_id.to_string());
    }
    if let Some(model) = model.filter(|value| !value.trim().is_empty()) {
        payload["model"] = Value::String(model.to_string());
    }
    if let Some(effort) = effort.filter(|value| !value.trim().is_empty()) {
        payload["reasoning_effort"] = Value::String(effort.to_string());
    }

    BridgeEventEnvelope {
        contract_version: shared_contracts::CONTRACT_VERSION.to_string(),
        event_id: format!("{thread_id}-status-turn-started-{occurred_at}"),
        thread_id: thread_id.to_string(),
        kind: BridgeEventKind::ThreadStatusChanged,
        occurred_at: occurred_at.to_string(),
        payload,
        annotations: None,
    }
}

fn should_synthesize_visible_user_prompt(visible_prompt: &str, upstream_prompt: &str) -> bool {
    !visible_prompt.trim().is_empty() && is_hidden_message(upstream_prompt)
}

fn build_visible_user_message_event(
    thread_id: &str,
    occurred_at: &str,
    turn_id: Option<&str>,
    visible_prompt: &str,
) -> BridgeEventEnvelope<Value> {
    let prompt = visible_prompt.trim();
    let payload = json!({
        "type": "userMessage",
        "role": "user",
        "text": prompt,
        "content": [{
            "text": prompt,
        }],
    });

    let event_id = match turn_id.filter(|value| !value.trim().is_empty()) {
        Some(turn_id) => format!("{turn_id}-visible-user-prompt"),
        None => format!("{thread_id}-visible-user-prompt-{occurred_at}"),
    };

    BridgeEventEnvelope {
        contract_version: shared_contracts::CONTRACT_VERSION.to_string(),
        event_id,
        thread_id: thread_id.to_string(),
        kind: BridgeEventKind::MessageDelta,
        occurred_at: occurred_at.to_string(),
        payload,
        annotations: None,
    }
}

fn should_publish_compacted_event(event: &BridgeEventEnvelope<Value>) -> bool {
    match event.kind {
        BridgeEventKind::MessageDelta => {
            payload_has_visible_live_content(&event.payload, &["delta", "text", "message"], &[])
        }
        BridgeEventKind::PlanDelta => {
            payload_has_visible_live_content(&event.payload, &["delta", "text"], &["steps"])
        }
        BridgeEventKind::CommandDelta => payload_has_visible_live_content(
            &event.payload,
            &["delta", "output", "aggregatedOutput"],
            &["arguments", "input"],
        ),
        BridgeEventKind::FileChange => payload_has_visible_live_content(
            &event.payload,
            &["delta", "resolved_unified_diff", "output"],
            &[],
        ),
        _ => true,
    }
}

fn payload_has_visible_live_content(
    payload: &Value,
    text_keys: &[&str],
    structured_keys: &[&str],
) -> bool {
    if payload
        .get("replace")
        .and_then(Value::as_bool)
        .unwrap_or(false)
    {
        return true;
    }
    if text_keys.iter().any(|key| {
        payload
            .get(*key)
            .and_then(Value::as_str)
            .is_some_and(|value| !value.is_empty())
    }) {
        return true;
    }
    structured_keys
        .iter()
        .any(|key| payload.get(*key).is_some_and(|value| !value.is_null()))
}

fn should_suppress_live_event(event: &BridgeEventEnvelope<Value>) -> bool {
    event.kind == BridgeEventKind::MessageDelta && payload_contains_hidden_message(&event.payload)
}

fn should_clear_transient_thread_state(event: &BridgeEventEnvelope<Value>) -> bool {
    event.kind == BridgeEventKind::ThreadStatusChanged
        && event
            .payload
            .get("status")
            .and_then(Value::as_str)
            .is_some_and(|status| status != "running")
}

fn should_suppress_notification_event_for_bridge_active_turn(
    event: &BridgeEventEnvelope<Value>,
    has_bridge_owned_active_turn: bool,
) -> bool {
    should_suppress_non_running_thread_status_for_bridge_active_turn(
        event,
        has_bridge_owned_active_turn,
    )
}

fn should_skip_background_notification_event(event: &BridgeEventEnvelope<Value>) -> bool {
    if event.kind != BridgeEventKind::ThreadStatusChanged {
        return true;
    }

    event
        .payload
        .get("status")
        .and_then(Value::as_str)
        .is_none_or(|status| status == "running")
}

fn should_suppress_non_running_thread_status_for_bridge_active_turn(
    event: &BridgeEventEnvelope<Value>,
    has_bridge_owned_active_turn: bool,
) -> bool {
    has_bridge_owned_active_turn
        && event.kind == BridgeEventKind::ThreadStatusChanged
        && event
            .payload
            .get("status")
            .and_then(Value::as_str)
            .is_some_and(|status| status != "running")
}

#[cfg(test)]
fn should_defer_bridge_owned_turn_finalization(status: ThreadStatus) -> bool {
    status == ThreadStatus::Running
}

#[cfg(test)]
fn watchdog_should_finalize_bridge_owned_turn(
    status: ThreadStatus,
    has_active_turn_stream: bool,
) -> bool {
    status != ThreadStatus::Running && !has_active_turn_stream
}

fn build_desktop_ipc_snapshot_update(
    previous_snapshot: Option<&ThreadSnapshotDto>,
    previous_summary_status: Option<ThreadStatus>,
    conversation_state: &Value,
    access_mode: AccessMode,
    compactor: &mut LiveDeltaCompactor,
    is_patch_update: bool,
    latest_raw_turn_status: Option<&str>,
    has_bridge_owned_active_turn: bool,
) -> Result<(ThreadSnapshotDto, Vec<BridgeEventEnvelope<Value>>), String> {
    let mut next_snapshot =
        snapshot_from_conversation_state(conversation_state, previous_snapshot, access_mode)?;
    preserve_bootstrap_status_for_cached_desktop_snapshot(
        previous_snapshot,
        previous_summary_status,
        &mut next_snapshot,
        is_patch_update,
    );
    ensure_running_status_for_desktop_patch_update(
        previous_snapshot,
        &mut next_snapshot,
        is_patch_update,
        latest_raw_turn_status,
    );
    preserve_running_status_for_bridge_owned_desktop_update(
        previous_snapshot,
        &mut next_snapshot,
        latest_raw_turn_status,
        has_bridge_owned_active_turn,
    );

    let events = diff_thread_snapshots(previous_snapshot, &next_snapshot)
        .into_iter()
        .filter_map(|event| {
            let normalized = compactor.compact(event);
            (should_publish_desktop_ipc_live_event(&normalized, has_bridge_owned_active_turn)
                && should_publish_compacted_event(&normalized)
                && !should_suppress_live_event(&normalized))
            .then_some(normalized)
        })
        .collect::<Vec<_>>();

    Ok((next_snapshot, events))
}

fn should_publish_desktop_ipc_live_event(
    _event: &BridgeEventEnvelope<Value>,
    has_bridge_owned_active_turn: bool,
) -> bool {
    !has_bridge_owned_active_turn
}

fn preserve_running_status_for_bridge_owned_desktop_update(
    previous_snapshot: Option<&ThreadSnapshotDto>,
    next_snapshot: &mut ThreadSnapshotDto,
    latest_raw_turn_status: Option<&str>,
    has_bridge_owned_active_turn: bool,
) {
    if !has_bridge_owned_active_turn {
        return;
    }
    if previous_snapshot
        .map(|snapshot| snapshot.thread.status != ThreadStatus::Running)
        .unwrap_or(true)
    {
        return;
    }
    if next_snapshot.thread.status == ThreadStatus::Running {
        return;
    }
    if desktop_raw_turn_status_is_terminal(latest_raw_turn_status) {
        return;
    }

    next_snapshot.thread.status = ThreadStatus::Running;
}

fn desktop_raw_turn_status_is_terminal(latest_raw_turn_status: Option<&str>) -> bool {
    matches!(
        latest_raw_turn_status.map(|status| status.trim().to_ascii_lowercase()),
        Some(status)
            if matches!(
                status.as_str(),
                "completed"
                    | "complete"
                    | "done"
                    | "success"
                    | "ok"
                    | "succeeded"
                    | "interrupted"
                    | "halted"
                    | "cancelled"
                    | "canceled"
                    | "failed"
                    | "fail"
                    | "error"
                    | "errored"
                    | "denied"
            )
    )
}

fn preserve_bootstrap_status_for_cached_desktop_snapshot(
    previous_snapshot: Option<&ThreadSnapshotDto>,
    previous_summary_status: Option<ThreadStatus>,
    next_snapshot: &mut ThreadSnapshotDto,
    is_patch_update: bool,
) {
    if is_patch_update || previous_snapshot.is_some() {
        return;
    }

    let Some(previous_summary_status) = previous_summary_status else {
        return;
    };

    if previous_summary_status == ThreadStatus::Running
        || next_snapshot.thread.status != ThreadStatus::Running
    {
        return;
    }

    next_snapshot.thread.status = previous_summary_status;
}

fn ensure_running_status_for_desktop_patch_update(
    previous_snapshot: Option<&ThreadSnapshotDto>,
    next_snapshot: &mut ThreadSnapshotDto,
    is_patch_update: bool,
    _latest_raw_turn_status: Option<&str>,
) {
    if !is_patch_update {
        return;
    }
    if previous_snapshot
        .map(|snapshot| snapshot.thread.status == ThreadStatus::Running)
        .unwrap_or(false)
    {
        return;
    }
    if next_snapshot.thread.status == ThreadStatus::Running {
        return;
    }
    if matches!(
        next_snapshot.thread.status,
        ThreadStatus::Completed | ThreadStatus::Interrupted | ThreadStatus::Failed
    ) {
        return;
    }
    if !desktop_patch_update_has_fresh_activity(previous_snapshot, next_snapshot) {
        return;
    }

    next_snapshot.thread.status = ThreadStatus::Running;
}

fn desktop_patch_update_has_fresh_activity(
    previous_snapshot: Option<&ThreadSnapshotDto>,
    next_snapshot: &ThreadSnapshotDto,
) -> bool {
    if next_snapshot.entries.is_empty() {
        return false;
    }

    let Some(previous_snapshot) = previous_snapshot else {
        return true;
    };

    previous_snapshot.entries != next_snapshot.entries
}

fn payload_contains_hidden_message(payload: &Value) -> bool {
    payload_primary_text(payload)
        .map(is_hidden_message)
        .unwrap_or(false)
}

fn payload_primary_text(payload: &Value) -> Option<&str> {
    for key in ["text", "delta", "message"] {
        if let Some(value) = payload.get(key).and_then(Value::as_str) {
            let trimmed = value.trim();
            if !trimmed.is_empty() {
                return Some(trimmed);
            }
        }
    }

    payload
        .get("content")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .find_map(|item| item.get("text").and_then(Value::as_str))
        .map(str::trim)
        .filter(|text| !text.is_empty())
}

fn is_hidden_message(message: &str) -> bool {
    let trimmed = message.trim();
    trimmed.starts_with("# AGENTS.md instructions for ")
        || trimmed.starts_with("<permissions instructions>")
        || trimmed.starts_with("<app-context>")
        || trimmed.starts_with("<environment_context>")
        || trimmed.starts_with("<collaboration_mode>")
        || trimmed.starts_with("<turn_aborted>")
        || trimmed.starts_with("You are running in mobile plan intake mode.")
        || trimmed.starts_with("You are continuing a mobile planning workflow.")
        || trimmed.contains("<codex-plan-questions>")
}

fn build_hidden_commit_prompt() -> String {
    r#"<app-context>
Mobile quick action: the user tapped Commit in the current session. In the visible thread transcript, the user message should appear as exactly:

Commit

Treat that visible message as the full user request.

Analyze the current workspace changes for this session.
Stage only files that belong to the current task or clear logical units.
Split commits logically when the changes should not land as one commit.
Use concise commit messages consistent with the repository style.
If there are unrelated, risky, or incomplete changes, leave them unstaged and explain why.
If there is nothing appropriate to commit, say that clearly and do not create an empty commit.
After you finish, respond with a short summary of the commit split you made, including commit messages and any skipped files.
</app-context>"#
        .to_string()
}

fn resume_notification_threads<'a, I, F>(
    thread_ids: I,
    mut resume_thread: F,
) -> Result<Vec<String>, String>
where
    I: IntoIterator<Item = &'a String>,
    F: FnMut(&str) -> Result<(), String>,
{
    let mut dropped_threads = Vec::new();
    for thread_id in thread_ids {
        match resume_notification_thread_until_rollout_exists(thread_id, &mut resume_thread) {
            Ok(()) => {}
            Err(error) if is_stale_rollout_resume_error(&error) => {
                dropped_threads.push(thread_id.to_string());
            }
            Err(error) => return Err(error),
        }
    }
    Ok(dropped_threads)
}

fn drain_notification_control_messages<F>(
    control_rx: &mpsc::Receiver<NotificationControlMessage>,
    mut handle_message: F,
) -> Result<(), String>
where
    F: FnMut(NotificationControlMessage) -> Result<(), String>,
{
    loop {
        match control_rx.try_recv() {
            Ok(message) => handle_message(message)?,
            Err(mpsc::TryRecvError::Empty) | Err(mpsc::TryRecvError::Disconnected) => {
                return Ok(());
            }
        }
    }
}

fn resume_notification_thread_until_rollout_exists<F>(
    thread_id: &str,
    mut resume_thread: F,
) -> Result<(), String>
where
    F: FnMut(&str) -> Result<(), String>,
{
    const MAX_ATTEMPTS: usize = 20;
    const RETRY_DELAY: Duration = Duration::from_millis(50);

    let mut last_stale_rollout_error: Option<String> = None;
    for attempt in 0..MAX_ATTEMPTS {
        match resume_thread(thread_id) {
            Ok(()) => return Ok(()),
            Err(error) if is_stale_rollout_resume_error(&error) => {
                last_stale_rollout_error = Some(error);
                if attempt + 1 < MAX_ATTEMPTS {
                    std::thread::sleep(RETRY_DELAY);
                    continue;
                }
            }
            Err(error) => return Err(error),
        }
    }

    Err(last_stale_rollout_error
        .unwrap_or_else(|| format!("codex rpc request 'thread/resume' failed for {thread_id}")))
}

fn is_stale_rollout_resume_error(error: &str) -> bool {
    error.contains("no rollout found") || error.contains("rollout at") && error.contains("is empty")
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::sync::mpsc;
    use std::time::{SystemTime, UNIX_EPOCH};

    use serde_json::{Value, json};
    use shared_contracts::{
        AccessMode, BridgeEventEnvelope, BridgeEventKind, CONTRACT_VERSION, ProviderKind,
        ThreadClientKind, ThreadDetailDto, ThreadSnapshotDto, ThreadStatus, ThreadSummaryDto,
        ThreadTimelineEntryDto,
    };

    use crate::pairing::PairingSessionService;
    use crate::server::config::{BridgeCodexConfig, BridgeConfig};
    use crate::server::pairing_route::PairingRouteState;
    use crate::server::speech::SpeechService;

    use super::{
        BridgeAppState, LiveDeltaCompactor, NotificationControlMessage,
        PendingProviderApprovalSession, PendingUserInputSession, ProviderApprovalContext,
        ProviderApprovalSelection, build_claude_tool_approval_response,
        build_codex_approval_response, build_desktop_ipc_snapshot_update,
        build_pending_provider_approval_from_codex, build_provider_approval_questionnaire,
        drain_notification_control_messages, ensure_running_status_for_desktop_patch_update,
        parse_provider_approval_selection, payload_contains_hidden_message,
        preserve_bootstrap_status_for_cached_desktop_snapshot,
        preserve_running_status_for_bridge_owned_desktop_update,
        resume_notification_thread_until_rollout_exists, resume_notification_threads,
        should_clear_transient_thread_state, should_defer_bridge_owned_turn_finalization,
        should_publish_compacted_event,
        should_suppress_non_running_thread_status_for_bridge_active_turn,
        should_suppress_notification_event_for_bridge_active_turn,
        watchdog_should_finalize_bridge_owned_turn,
    };

    async fn test_bridge_app_state() -> BridgeAppState {
        let state_directory = std::env::temp_dir().join(format!(
            "bridge-app-state-test-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .expect("system time should be after unix epoch")
                .as_nanos()
        ));
        fs::create_dir_all(&state_directory).expect("test state directory should exist");
        let pairing_route = PairingRouteState::new(
            "https://bridge.ts.net".to_string(),
            true,
            None,
            3210,
            false,
            state_directory.clone(),
        );
        let config = BridgeConfig {
            host: "127.0.0.1".to_string(),
            port: 3210,
            state_directory: state_directory.clone(),
            speech_helper_binary: None,
            pairing_route: pairing_route.clone(),
            codex: BridgeCodexConfig::default(),
        };
        let speech = SpeechService::from_config(&config).await;
        BridgeAppState::new(
            config.codex,
            PairingSessionService::new(
                &config.host,
                config.port,
                pairing_route.pairing_base_url(),
                state_directory,
            ),
            pairing_route,
            speech,
        )
    }

    #[test]
    fn hidden_payload_detection_marks_mobile_plan_protocol_messages() {
        assert!(payload_contains_hidden_message(&json!({
            "text": "You are running in mobile plan intake mode.\nReturn only one XML-like block."
        })));
        assert!(payload_contains_hidden_message(&json!({
            "text": "<codex-plan-questions>{\"title\":\"Plan\",\"questions\":[]}</codex-plan-questions>"
        })));
        assert!(!payload_contains_hidden_message(&json!({
            "text": "Plan how to cover the critical mobile flows."
        })));
    }

    #[test]
    fn hidden_upstream_prompts_synthesize_visible_user_messages() {
        assert!(super::should_synthesize_visible_user_prompt(
            "Commit",
            &super::build_hidden_commit_prompt(),
        ));
        assert!(!super::should_synthesize_visible_user_prompt(
            "Commit", "Commit",
        ));
        assert!(!super::should_synthesize_visible_user_prompt(
            "",
            &super::build_hidden_commit_prompt(),
        ));
    }

    #[test]
    fn visible_user_message_event_uses_user_message_payload() {
        let event = super::build_visible_user_message_event(
            "codex:thread-1",
            "2026-04-03T08:00:00Z",
            Some("turn-1"),
            "Commit",
        );

        assert_eq!(event.kind, BridgeEventKind::MessageDelta);
        assert_eq!(event.event_id, "turn-1-visible-user-prompt");
        assert_eq!(event.payload["type"], "userMessage");
        assert_eq!(event.payload["role"], "user");
        assert_eq!(event.payload["text"], "Commit");
        assert_eq!(event.payload["content"][0]["text"], "Commit");
    }

    #[tokio::test]
    async fn bridge_turn_metadata_merges_synthetic_visible_user_messages() {
        let state = test_bridge_app_state().await;
        let event = super::build_visible_user_message_event(
            "codex:thread-1",
            "2026-04-03T08:00:00Z",
            Some("turn-1"),
            "Commit",
        );

        state.record_bridge_turn_metadata(&event).await;

        let mut snapshot = ThreadSnapshotDto {
            contract_version: CONTRACT_VERSION.to_string(),
            thread: ThreadDetailDto {
                contract_version: CONTRACT_VERSION.to_string(),
                thread_id: "codex:thread-1".to_string(),
                native_thread_id: "thread-1".to_string(),
                provider: ProviderKind::Codex,
                client: ThreadClientKind::Cli,
                title: "Thread".to_string(),
                status: ThreadStatus::Idle,
                workspace: "/repo".to_string(),
                repository: "repo".to_string(),
                branch: "main".to_string(),
                created_at: "2026-04-03T08:00:00Z".to_string(),
                updated_at: "2026-04-03T08:00:00Z".to_string(),
                source: "cli".to_string(),
                access_mode: AccessMode::ControlWithApprovals,
                last_turn_summary: String::new(),
                active_turn_id: None,
            },
            entries: Vec::new(),
            approvals: Vec::new(),
            git_status: None,
            pending_user_input: None,
        };

        state.merge_bridge_turn_metadata(&mut snapshot).await;

        assert_eq!(snapshot.entries.len(), 1);
        assert_eq!(snapshot.entries[0].event_id, "turn-1-visible-user-prompt");
        assert_eq!(snapshot.entries[0].payload["text"], "Commit");
    }

    #[test]
    fn codex_command_approval_prompts_map_to_pending_user_input_shape() {
        let prompt = build_pending_provider_approval_from_codex(
            "codex:thread-fallback",
            &json!("req-1"),
            "item/commandExecution/requestApproval",
            &json!({
                "reason": "Need approval to inspect git state",
                "command": "git status",
                "cwd": "/repo",
            }),
        )
        .expect("command approval payload should parse")
        .expect("command approval prompt should be recognized");

        assert_eq!(prompt.provider_request_id, "req-1");
        assert_eq!(prompt.questionnaire.title, "Approve command execution?");
        assert_eq!(prompt.questionnaire.questions.len(), 1);
        assert_eq!(
            prompt.questionnaire.questions[0]
                .options
                .iter()
                .map(|option| option.option_id.as_str())
                .collect::<Vec<_>>(),
            vec!["allow_once", "allow_for_session", "deny"]
        );
        assert!(
            prompt
                .questionnaire
                .detail
                .expect("detail should be present")
                .contains("Command: git status")
        );
    }

    #[test]
    fn codex_permission_responses_map_allow_once_session_and_deny() {
        let params = json!({
            "permissions": {
                "fileSystem": { "read": ["/repo"], "write": ["/repo"] },
                "network": { "enabled": true }
            }
        });
        let allow_once = build_codex_approval_response(
            "item/permissions/requestApproval",
            &params,
            ProviderApprovalSelection::AllowOnce,
        )
        .expect("allow once should map");
        let allow_session = build_codex_approval_response(
            "item/permissions/requestApproval",
            &params,
            ProviderApprovalSelection::AllowForSession,
        )
        .expect("allow for session should map");
        let deny = build_codex_approval_response(
            "item/permissions/requestApproval",
            &params,
            ProviderApprovalSelection::Deny,
        )
        .expect("deny should map");

        assert_eq!(allow_once["scope"], "turn");
        assert_eq!(allow_once["permissions"], params["permissions"]);
        assert_eq!(allow_session["scope"], "session");
        assert_eq!(allow_session["permissions"], params["permissions"]);
        assert_eq!(deny["scope"], "turn");
        assert_eq!(deny["permissions"], json!({}));
    }

    #[test]
    fn codex_command_and_file_deny_map_to_cancel_decision() {
        let command_response = build_codex_approval_response(
            "item/commandExecution/requestApproval",
            &json!({}),
            ProviderApprovalSelection::Deny,
        )
        .expect("command deny should map");
        let file_response = build_codex_approval_response(
            "item/fileChange/requestApproval",
            &json!({}),
            ProviderApprovalSelection::Deny,
        )
        .expect("file deny should map");

        assert_eq!(command_response, json!({"decision":"cancel"}));
        assert_eq!(file_response, json!({"decision":"cancel"}));
    }

    #[test]
    fn claude_tool_approval_responses_preserve_schema() {
        let request = json!({
            "input": { "cmd": "ls -la" },
            "permission_suggestions": { "allow": ["ls"] },
            "tool_use_id": "tool-123",
        });
        let allow_session = build_claude_tool_approval_response(
            ProviderApprovalSelection::AllowForSession,
            &request,
        );
        let deny = build_claude_tool_approval_response(ProviderApprovalSelection::Deny, &request);

        assert_eq!(allow_session["behavior"], "allow");
        assert_eq!(allow_session["updatedInput"], json!({"cmd":"ls -la"}));
        assert_eq!(allow_session["updatedPermissions"], json!({"allow":["ls"]}));
        assert_eq!(allow_session["toolUseID"], "tool-123");

        assert_eq!(deny["behavior"], "deny");
        assert_eq!(deny["interrupt"], true);
    }

    #[test]
    fn provider_approval_selection_parser_accepts_allow_session_choice() {
        let selection =
            parse_provider_approval_selection(&[shared_contracts::UserInputAnswerDto {
                question_id: "approval_decision".to_string(),
                option_id: "allow_for_session".to_string(),
            }]);
        assert_eq!(selection, Some(ProviderApprovalSelection::AllowForSession));
    }

    #[tokio::test]
    async fn respond_to_provider_approval_returns_mutation_and_resolves_pending_request() {
        let state = test_bridge_app_state().await;
        let thread_id = "codex:thread-provider-approval";
        let questionnaire = build_provider_approval_questionnaire(
            "thread-provider-approval",
            "Approve command execution?".to_string(),
            None,
        );
        let request_id = questionnaire.request_id.clone();
        let (resolution_tx, resolution_rx) = tokio::sync::oneshot::channel();
        state.inner.pending_user_inputs.write().await.insert(
            thread_id.to_string(),
            PendingUserInputSession::ProviderApproval(PendingProviderApprovalSession {
                questionnaire,
                provider_request_id: "upstream-approval-1".to_string(),
                context: ProviderApprovalContext::CodexCommandOrFile,
                resolution_tx,
            }),
        );
        state
            .inner
            .active_turn_ids
            .write()
            .await
            .insert(thread_id.to_string(), "turn-approval-1".to_string());

        let result = state
            .respond_to_user_input(
                thread_id,
                &request_id,
                &[shared_contracts::UserInputAnswerDto {
                    question_id: "approval_decision".to_string(),
                    option_id: "allow_once".to_string(),
                }],
                None,
                None,
                None,
            )
            .await
            .expect("approval response should be accepted");

        assert_eq!(result.message, "approval response submitted");
        assert_eq!(result.turn_id.as_deref(), Some("turn-approval-1"));
        assert_eq!(
            resolution_rx
                .await
                .expect("provider selection should resolve"),
            ProviderApprovalSelection::AllowOnce
        );
    }

    #[test]
    fn resume_notification_threads_replays_all_requested_threads() {
        let requested = [
            "thread-from-mobile".to_string(),
            "thread-from-desktop".to_string(),
        ];
        let mut resumed = Vec::new();

        let dropped_threads = resume_notification_threads(requested.iter(), |thread_id| {
            resumed.push(thread_id.to_string());
            Ok(())
        })
        .expect("resume replay should succeed");
        assert!(dropped_threads.is_empty());

        assert_eq!(
            resumed,
            vec![
                "thread-from-mobile".to_string(),
                "thread-from-desktop".to_string(),
            ]
        );
    }

    #[test]
    fn drain_notification_control_messages_resumes_threads_until_queue_is_empty() {
        let (tx, rx) = mpsc::channel();
        tx.send(NotificationControlMessage::ResumeThread(
            "thread-123".to_string(),
        ))
        .expect("control message should enqueue");
        tx.send(NotificationControlMessage::ResumeThread(
            "thread-456".to_string(),
        ))
        .expect("control message should enqueue");
        drop(tx);

        let mut resumed = Vec::new();
        drain_notification_control_messages(&rx, |message| {
            let NotificationControlMessage::ResumeThread(thread_id) = message;
            resumed.push(thread_id);
            Ok(())
        })
        .expect("draining control messages should succeed");

        assert_eq!(
            resumed,
            vec!["thread-123".to_string(), "thread-456".to_string()]
        );
    }

    #[test]
    fn duplicate_resume_notification_requests_are_de_deduplicated() {
        let (tx, rx) = mpsc::channel();
        tx.send(NotificationControlMessage::ResumeThread(
            "thread-123".to_string(),
        ))
        .expect("control message should enqueue");
        tx.send(NotificationControlMessage::ResumeThread(
            "thread-123".to_string(),
        ))
        .expect("control message should enqueue");
        drop(tx);

        let mut resumed = Vec::new();
        drain_notification_control_messages(&rx, |message| {
            let NotificationControlMessage::ResumeThread(thread_id) = message;
            resumed.push(thread_id);
            Ok(())
        })
        .expect("draining control messages should succeed");

        assert_eq!(
            resumed,
            vec!["thread-123".to_string(), "thread-123".to_string()]
        );
    }

    #[test]
    fn request_notification_thread_resume_dispatches_once_per_thread() {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("runtime should build");
        runtime.block_on(async {
            let state = test_bridge_app_state().await;
            let (tx, rx) = mpsc::channel();
            *state
                .inner
                .notification_control_tx
                .lock()
                .expect("notification control lock should not be poisoned") = Some(tx);

            state
                .request_notification_thread_resume("codex:thread-123")
                .await;
            state
                .request_notification_thread_resume("codex:thread-123")
                .await;

            assert_eq!(
                rx.recv().expect("resume message should be sent"),
                NotificationControlMessage::ResumeThread("codex:thread-123".to_string())
            );
            assert!(rx.try_recv().is_err());
        });
    }

    #[test]
    fn request_notification_thread_resume_ignores_non_codex_threads() {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("runtime should build");
        runtime.block_on(async {
            let state = test_bridge_app_state().await;
            let (tx, rx) = mpsc::channel();
            *state
                .inner
                .notification_control_tx
                .lock()
                .expect("notification control lock should not be poisoned") = Some(tx);

            state
                .request_notification_thread_resume("claude:thread-123")
                .await;

            assert!(rx.try_recv().is_err());
        });
    }

    #[test]
    fn resume_notification_thread_retries_missing_rollout_until_success() {
        let mut attempts = 0usize;
        let result = resume_notification_thread_until_rollout_exists("thread-123", |_| {
            attempts += 1;
            if attempts < 3 {
                return Err(
                    "codex rpc request 'thread/resume' failed: no rollout found".to_string()
                );
            }
            Ok(())
        });

        assert!(result.is_ok());
        assert_eq!(attempts, 3);
    }

    #[test]
    fn resume_notification_thread_treats_empty_rollout_as_stale() {
        let mut attempts = 0usize;
        let result = resume_notification_thread_until_rollout_exists("thread-123", |_| {
            attempts += 1;
            Err(
                "codex rpc request 'thread/resume' failed: failed to load rollout `/tmp/rollout.jsonl`: rollout at /tmp/rollout.jsonl is empty"
                    .to_string(),
            )
        });

        assert_eq!(
            result,
            Err(
                "codex rpc request 'thread/resume' failed: failed to load rollout `/tmp/rollout.jsonl`: rollout at /tmp/rollout.jsonl is empty"
                    .to_string(),
            )
        );
        assert_eq!(attempts, 20);
    }

    #[test]
    fn resume_notification_thread_returns_non_rollout_errors_immediately() {
        let mut attempts = 0usize;
        let result = resume_notification_thread_until_rollout_exists("thread-123", |_| {
            attempts += 1;
            Err("codex rpc request 'thread/resume' failed: invalid thread id".to_string())
        });

        assert_eq!(
            result,
            Err("codex rpc request 'thread/resume' failed: invalid thread id".to_string())
        );
        assert_eq!(attempts, 1);
    }

    #[tokio::test]
    async fn in_flight_title_generation_still_recognizes_placeholder_titles() {
        let state = test_bridge_app_state().await;
        let placeholder_snapshot = ThreadSnapshotDto {
            contract_version: CONTRACT_VERSION.to_string(),
            thread: ThreadDetailDto {
                contract_version: CONTRACT_VERSION.to_string(),
                thread_id: "thread-1".to_string(),
                native_thread_id: "thread-1".to_string(),
                provider: shared_contracts::ProviderKind::Codex,
                client: shared_contracts::ThreadClientKind::Cli,
                title: "Untitled thread".to_string(),
                status: ThreadStatus::Idle,
                workspace: "/repo".to_string(),
                repository: "repo".to_string(),
                branch: "main".to_string(),
                created_at: "2026-03-29T10:00:00Z".to_string(),
                updated_at: "2026-03-29T10:00:00Z".to_string(),
                source: "bridge".to_string(),
                access_mode: shared_contracts::AccessMode::ControlWithApprovals,
                last_turn_summary: String::new(),
                active_turn_id: None,
            },
            entries: Vec::new(),
            approvals: Vec::new(),
            git_status: None,
            pending_user_input: None,
        };
        state.projections().put_snapshot(placeholder_snapshot).await;
        state
            .projections()
            .replace_summaries(vec![ThreadSummaryDto {
                contract_version: CONTRACT_VERSION.to_string(),
                thread_id: "thread-1".to_string(),
                native_thread_id: "thread-1".to_string(),
                provider: shared_contracts::ProviderKind::Codex,
                client: shared_contracts::ThreadClientKind::Cli,
                title: "Untitled thread".to_string(),
                status: ThreadStatus::Idle,
                workspace: "/repo".to_string(),
                repository: "repo".to_string(),
                branch: "main".to_string(),
                updated_at: "2026-03-29T10:00:00Z".to_string(),
            }])
            .await;

        state
            .inner
            .inflight_thread_title_generations
            .write()
            .await
            .insert("thread-1".to_string());

        assert!(state.thread_title_still_needs_generation("thread-1").await);
        assert!(!state.should_generate_thread_title("thread-1").await);
    }

    #[tokio::test]
    async fn claude_placeholder_titles_still_generate_and_persist_locally() {
        let state = test_bridge_app_state().await;
        let placeholder_snapshot = ThreadSnapshotDto {
            contract_version: CONTRACT_VERSION.to_string(),
            thread: ThreadDetailDto {
                contract_version: CONTRACT_VERSION.to_string(),
                thread_id: "claude:thread-1".to_string(),
                native_thread_id: "thread-1".to_string(),
                provider: shared_contracts::ProviderKind::ClaudeCode,
                client: shared_contracts::ThreadClientKind::Bridge,
                title: "Untitled thread".to_string(),
                status: ThreadStatus::Idle,
                workspace: "/repo".to_string(),
                repository: "repo".to_string(),
                branch: "main".to_string(),
                created_at: "2026-03-29T10:00:00Z".to_string(),
                updated_at: "2026-03-29T10:00:00Z".to_string(),
                source: "bridge".to_string(),
                access_mode: shared_contracts::AccessMode::ControlWithApprovals,
                last_turn_summary: String::new(),
                active_turn_id: None,
            },
            entries: Vec::new(),
            approvals: Vec::new(),
            git_status: None,
            pending_user_input: None,
        };
        state.projections().put_snapshot(placeholder_snapshot).await;
        state
            .projections()
            .replace_summaries(vec![ThreadSummaryDto {
                contract_version: CONTRACT_VERSION.to_string(),
                thread_id: "claude:thread-1".to_string(),
                native_thread_id: "thread-1".to_string(),
                provider: shared_contracts::ProviderKind::ClaudeCode,
                client: shared_contracts::ThreadClientKind::Bridge,
                title: "Untitled thread".to_string(),
                status: ThreadStatus::Idle,
                workspace: "/repo".to_string(),
                repository: "repo".to_string(),
                branch: "main".to_string(),
                updated_at: "2026-03-29T10:00:00Z".to_string(),
            }])
            .await;

        assert!(state.should_generate_thread_title("claude:thread-1").await);

        state
            .persist_generated_thread_title(
                "claude:thread-1",
                "Investigate Claude thread title generation",
            )
            .await
            .expect("Claude titles should persist without an upstream rename");

        let snapshot = state
            .projections()
            .snapshot("claude:thread-1")
            .await
            .expect("Claude snapshot should exist");
        assert_eq!(
            snapshot.thread.title,
            "Investigate Claude thread title generation"
        );

        let summary_title = state
            .projections()
            .thread_title("claude:thread-1")
            .await
            .expect("Claude summary title should exist");
        assert_eq!(summary_title, "Investigate Claude thread title generation");
    }

    #[test]
    fn title_generation_model_uses_requested_model_only_for_codex_threads() {
        assert_eq!(
            super::title_generation_model_for_thread("codex:thread-1", Some("gpt-5-mini")),
            Some("gpt-5-mini")
        );
        assert_eq!(
            super::title_generation_model_for_thread("claude:thread-1", Some("claude-sonnet-4-6"),),
            None
        );
    }

    #[test]
    fn claude_prompt_title_fallback_uses_first_sentence() {
        assert_eq!(
            super::provisional_thread_title_from_prompt(
                "claude:thread-1",
                "Explain why thread titles help mobile triage. Do not use tools.",
            ),
            Some("Explain why thread titles help mobile triage".to_string())
        );
        assert_eq!(
            super::provisional_thread_title_from_prompt(
                "codex:thread-1",
                "Explain why thread titles help mobile triage.",
            ),
            None
        );
    }

    #[test]
    fn external_snapshot_refresh_preserves_non_placeholder_generated_title() {
        let previous_snapshot = ThreadSnapshotDto {
            contract_version: CONTRACT_VERSION.to_string(),
            thread: ThreadDetailDto {
                contract_version: CONTRACT_VERSION.to_string(),
                thread_id: "claude:thread-1".to_string(),
                native_thread_id: "thread-1".to_string(),
                provider: shared_contracts::ProviderKind::ClaudeCode,
                client: shared_contracts::ThreadClientKind::Bridge,
                title: "Investigate Claude thread titles".to_string(),
                status: ThreadStatus::Running,
                workspace: "/repo".to_string(),
                repository: "repo".to_string(),
                branch: "main".to_string(),
                created_at: "2026-03-29T10:00:00Z".to_string(),
                updated_at: "2026-03-29T10:00:00Z".to_string(),
                source: "bridge".to_string(),
                access_mode: shared_contracts::AccessMode::ControlWithApprovals,
                last_turn_summary: String::new(),
                active_turn_id: None,
            },
            entries: Vec::new(),
            approvals: Vec::new(),
            git_status: None,
            pending_user_input: None,
        };
        let mut refreshed_snapshot = ThreadSnapshotDto {
            contract_version: CONTRACT_VERSION.to_string(),
            thread: ThreadDetailDto {
                contract_version: CONTRACT_VERSION.to_string(),
                thread_id: "claude:thread-1".to_string(),
                native_thread_id: "thread-1".to_string(),
                provider: shared_contracts::ProviderKind::ClaudeCode,
                client: shared_contracts::ThreadClientKind::Bridge,
                title: "Untitled thread".to_string(),
                status: ThreadStatus::Completed,
                workspace: "/repo".to_string(),
                repository: "repo".to_string(),
                branch: "main".to_string(),
                created_at: "2026-03-29T10:00:00Z".to_string(),
                updated_at: "2026-03-29T10:00:10Z".to_string(),
                source: "bridge".to_string(),
                access_mode: shared_contracts::AccessMode::ControlWithApprovals,
                last_turn_summary: String::new(),
                active_turn_id: None,
            },
            entries: Vec::new(),
            approvals: Vec::new(),
            git_status: None,
            pending_user_input: None,
        };

        super::preserve_generated_thread_title(&previous_snapshot, &mut refreshed_snapshot);

        assert_eq!(
            refreshed_snapshot.thread.title,
            "Investigate Claude thread titles"
        );
    }

    #[test]
    fn summary_reconcile_preserves_existing_non_placeholder_title() {
        let reconciled = super::merge_reconciled_thread_summaries(
            vec![ThreadSummaryDto {
                contract_version: CONTRACT_VERSION.to_string(),
                thread_id: "claude:thread-1".to_string(),
                native_thread_id: "thread-1".to_string(),
                provider: shared_contracts::ProviderKind::ClaudeCode,
                client: shared_contracts::ThreadClientKind::Bridge,
                title: "Explain why thread titles help mobile triage".to_string(),
                status: ThreadStatus::Running,
                workspace: "/repo".to_string(),
                repository: "repo".to_string(),
                branch: "main".to_string(),
                updated_at: "2026-03-29T10:00:05Z".to_string(),
            }],
            vec![ThreadSummaryDto {
                contract_version: CONTRACT_VERSION.to_string(),
                thread_id: "claude:thread-1".to_string(),
                native_thread_id: "thread-1".to_string(),
                provider: shared_contracts::ProviderKind::ClaudeCode,
                client: shared_contracts::ThreadClientKind::Bridge,
                title: "Untitled thread".to_string(),
                status: ThreadStatus::Completed,
                workspace: "/repo".to_string(),
                repository: "repo".to_string(),
                branch: "main".to_string(),
                updated_at: "2026-03-29T10:00:10Z".to_string(),
            }],
        );

        assert_eq!(
            reconciled[0].title,
            "Explain why thread titles help mobile triage"
        );
        assert_eq!(reconciled[0].status, ThreadStatus::Completed);
    }

    #[test]
    fn desktop_patch_updates_mark_thread_running_until_explicit_completion_arrives() {
        let previous_snapshot = ThreadSnapshotDto {
            contract_version: CONTRACT_VERSION.to_string(),
            thread: ThreadDetailDto {
                contract_version: CONTRACT_VERSION.to_string(),
                thread_id: "thread-1".to_string(),
                native_thread_id: "thread-1".to_string(),
                provider: shared_contracts::ProviderKind::Codex,
                client: shared_contracts::ThreadClientKind::Cli,
                title: "Thread".to_string(),
                status: ThreadStatus::Idle,
                workspace: "/repo".to_string(),
                repository: "repo".to_string(),
                branch: "main".to_string(),
                created_at: "2026-03-27T20:00:00Z".to_string(),
                updated_at: "2026-03-27T20:00:00Z".to_string(),
                source: "codex_app_ipc".to_string(),
                access_mode: shared_contracts::AccessMode::ControlWithApprovals,
                last_turn_summary: String::new(),
                active_turn_id: None,
            },
            entries: Vec::new(),
            approvals: Vec::new(),
            git_status: None,
            pending_user_input: None,
        };
        let mut next_snapshot = ThreadSnapshotDto {
            contract_version: CONTRACT_VERSION.to_string(),
            thread: ThreadDetailDto {
                status: ThreadStatus::Idle,
                updated_at: "2026-03-27T20:00:10Z".to_string(),
                ..previous_snapshot.thread.clone()
            },
            entries: vec![ThreadTimelineEntryDto {
                event_id: "evt-1".to_string(),
                kind: BridgeEventKind::CommandDelta,
                occurred_at: "2026-03-27T20:00:10Z".to_string(),
                summary: "working".to_string(),
                payload: json!({"delta":"working","replace":false}),
                annotations: None,
            }],
            approvals: Vec::new(),
            git_status: None,
            pending_user_input: None,
        };

        ensure_running_status_for_desktop_patch_update(
            Some(&previous_snapshot),
            &mut next_snapshot,
            true,
            Some("in_progress"),
        );

        assert_eq!(next_snapshot.thread.status, ThreadStatus::Running);
    }

    #[test]
    fn desktop_patch_updates_do_not_override_explicit_terminal_status() {
        let previous_snapshot = ThreadSnapshotDto {
            contract_version: CONTRACT_VERSION.to_string(),
            thread: ThreadDetailDto {
                contract_version: CONTRACT_VERSION.to_string(),
                thread_id: "thread-1".to_string(),
                native_thread_id: "thread-1".to_string(),
                provider: shared_contracts::ProviderKind::Codex,
                client: shared_contracts::ThreadClientKind::Cli,
                title: "Thread".to_string(),
                status: ThreadStatus::Running,
                workspace: "/repo".to_string(),
                repository: "repo".to_string(),
                branch: "main".to_string(),
                created_at: "2026-03-27T20:00:00Z".to_string(),
                updated_at: "2026-03-27T20:00:00Z".to_string(),
                source: "codex_app_ipc".to_string(),
                access_mode: shared_contracts::AccessMode::ControlWithApprovals,
                last_turn_summary: String::new(),
                active_turn_id: None,
            },
            entries: Vec::new(),
            approvals: Vec::new(),
            git_status: None,
            pending_user_input: None,
        };
        let mut next_snapshot = ThreadSnapshotDto {
            contract_version: CONTRACT_VERSION.to_string(),
            thread: ThreadDetailDto {
                status: ThreadStatus::Completed,
                updated_at: "2026-03-27T20:00:10Z".to_string(),
                ..previous_snapshot.thread.clone()
            },
            entries: vec![ThreadTimelineEntryDto {
                event_id: "evt-1".to_string(),
                kind: BridgeEventKind::MessageDelta,
                occurred_at: "2026-03-27T20:00:10Z".to_string(),
                summary: "done".to_string(),
                payload: json!({"delta":"done","replace":false}),
                annotations: None,
            }],
            approvals: Vec::new(),
            git_status: None,
            pending_user_input: None,
        };

        ensure_running_status_for_desktop_patch_update(
            Some(&previous_snapshot),
            &mut next_snapshot,
            true,
            Some("completed"),
        );

        assert_eq!(next_snapshot.thread.status, ThreadStatus::Completed);
    }

    #[test]
    fn desktop_patch_updates_with_fresh_activity_override_idle_raw_turn_status() {
        let previous_snapshot = ThreadSnapshotDto {
            contract_version: CONTRACT_VERSION.to_string(),
            thread: ThreadDetailDto {
                contract_version: CONTRACT_VERSION.to_string(),
                thread_id: "thread-1".to_string(),
                native_thread_id: "thread-1".to_string(),
                provider: shared_contracts::ProviderKind::Codex,
                client: shared_contracts::ThreadClientKind::Cli,
                title: "Thread".to_string(),
                status: ThreadStatus::Idle,
                workspace: "/repo".to_string(),
                repository: "repo".to_string(),
                branch: "main".to_string(),
                created_at: "2026-03-27T20:00:00Z".to_string(),
                updated_at: "2026-03-27T20:00:00Z".to_string(),
                source: "codex_app_ipc".to_string(),
                access_mode: shared_contracts::AccessMode::ControlWithApprovals,
                last_turn_summary: "thinking".to_string(),
                active_turn_id: None,
            },
            entries: vec![ThreadTimelineEntryDto {
                event_id: "evt-1".to_string(),
                kind: BridgeEventKind::MessageDelta,
                occurred_at: "2026-03-27T20:00:00Z".to_string(),
                summary: "thinking".to_string(),
                payload: json!({"delta":"thinking","replace":true}),
                annotations: None,
            }],
            approvals: Vec::new(),
            git_status: None,
            pending_user_input: None,
        };
        let mut next_snapshot = ThreadSnapshotDto {
            contract_version: CONTRACT_VERSION.to_string(),
            thread: ThreadDetailDto {
                status: ThreadStatus::Idle,
                updated_at: "2026-03-27T20:00:10Z".to_string(),
                ..previous_snapshot.thread.clone()
            },
            entries: vec![ThreadTimelineEntryDto {
                event_id: "evt-1".to_string(),
                kind: BridgeEventKind::MessageDelta,
                occurred_at: "2026-03-27T20:00:10Z".to_string(),
                summary: "thinking harder".to_string(),
                payload: json!({"delta":"thinking harder","replace":true}),
                annotations: None,
            }],
            approvals: Vec::new(),
            git_status: None,
            pending_user_input: None,
        };

        ensure_running_status_for_desktop_patch_update(
            Some(&previous_snapshot),
            &mut next_snapshot,
            true,
            Some("idle"),
        );

        assert_eq!(next_snapshot.thread.status, ThreadStatus::Running);
    }

    #[test]
    fn desktop_patch_updates_without_fresh_activity_preserve_idle_raw_turn_status() {
        let previous_snapshot = ThreadSnapshotDto {
            contract_version: CONTRACT_VERSION.to_string(),
            thread: ThreadDetailDto {
                contract_version: CONTRACT_VERSION.to_string(),
                thread_id: "thread-1".to_string(),
                native_thread_id: "thread-1".to_string(),
                provider: shared_contracts::ProviderKind::Codex,
                client: shared_contracts::ThreadClientKind::Cli,
                title: "Thread".to_string(),
                status: ThreadStatus::Idle,
                workspace: "/repo".to_string(),
                repository: "repo".to_string(),
                branch: "main".to_string(),
                created_at: "2026-03-27T20:00:00Z".to_string(),
                updated_at: "2026-03-27T20:00:00Z".to_string(),
                source: "codex_app_ipc".to_string(),
                access_mode: shared_contracts::AccessMode::ControlWithApprovals,
                last_turn_summary: "thinking".to_string(),
                active_turn_id: None,
            },
            entries: vec![ThreadTimelineEntryDto {
                event_id: "evt-1".to_string(),
                kind: BridgeEventKind::MessageDelta,
                occurred_at: "2026-03-27T20:00:00Z".to_string(),
                summary: "thinking".to_string(),
                payload: json!({"delta":"thinking","replace":true}),
                annotations: None,
            }],
            approvals: Vec::new(),
            git_status: None,
            pending_user_input: None,
        };
        let mut next_snapshot = previous_snapshot.clone();

        ensure_running_status_for_desktop_patch_update(
            Some(&previous_snapshot),
            &mut next_snapshot,
            true,
            Some("idle"),
        );

        assert_eq!(next_snapshot.thread.status, ThreadStatus::Idle);
    }

    #[test]
    fn cached_desktop_snapshot_is_materialized_when_thread_starts_being_tracked() {
        let conversation_state = json!({
            "id": "thread-1",
            "hostId": "local",
            "title": "Thread",
            "cwd": "/repo",
            "lastModifiedAt": "2026-03-27T20:00:10Z",
            "turns": [
                {
                    "turnId": "019d2918-919e-7420-b23f-7568c5771389",
                    "status": "in_progress",
                    "turnStartedAtMs": 1774592758217_i64,
                    "params": {
                        "threadId": "thread-1",
                        "cwd": "/repo",
                        "input": [{ "type": "text", "text": "hello" }]
                    },
                    "items": [
                        {
                            "id": "msg-user-1",
                            "type": "userMessage",
                            "content": [{ "type": "text", "text": "hello" }]
                        },
                        {
                            "id": "msg-assistant-1",
                            "type": "agentMessage",
                            "text": "working"
                        }
                    ]
                }
            ]
        });

        let mut compactor = LiveDeltaCompactor::default();
        let (snapshot, events) = build_desktop_ipc_snapshot_update(
            None,
            None,
            &conversation_state,
            shared_contracts::AccessMode::ControlWithApprovals,
            &mut compactor,
            false,
            None,
            false,
        )
        .expect("cached desktop snapshot should materialize");

        assert_eq!(snapshot.thread.thread_id, "codex:thread-1");
        assert_eq!(snapshot.thread.native_thread_id, "thread-1");
        assert_eq!(snapshot.thread.status, ThreadStatus::Running);
        assert_eq!(snapshot.entries.len(), 2);
        assert!(events.iter().any(|event| {
            event.kind == BridgeEventKind::ThreadStatusChanged
                && event.payload.get("status").and_then(Value::as_str) == Some("running")
        }));
        assert!(events.iter().any(|event| {
            event.kind == BridgeEventKind::MessageDelta
                && event.payload.get("role").and_then(Value::as_str) == Some("assistant")
                && event.payload.get("replace").and_then(Value::as_bool) == Some(true)
        }));
    }

    #[test]
    fn bridge_owned_desktop_snapshot_updates_do_not_publish_live_events() {
        let conversation_state = json!({
            "id": "thread-1",
            "hostId": "local",
            "title": "Thread",
            "cwd": "/repo",
            "lastModifiedAt": "2026-03-27T20:00:10Z",
            "turns": [
                {
                    "turnId": "019d2918-919e-7420-b23f-7568c5771389",
                    "status": "in_progress",
                    "turnStartedAtMs": 1774592758217_i64,
                    "params": {
                        "threadId": "thread-1",
                        "cwd": "/repo",
                        "input": [{ "type": "text", "text": "hello" }]
                    },
                    "items": [
                        {
                            "id": "msg-assistant-1",
                            "type": "agentMessage",
                            "text": "working"
                        }
                    ]
                }
            ]
        });

        let mut compactor = LiveDeltaCompactor::default();
        let (snapshot, events) = build_desktop_ipc_snapshot_update(
            None,
            None,
            &conversation_state,
            shared_contracts::AccessMode::ControlWithApprovals,
            &mut compactor,
            false,
            None,
            true,
        )
        .expect("bridge-owned desktop snapshot should still materialize");

        assert_eq!(snapshot.entries.len(), 1);
        assert!(events.is_empty());
    }

    #[test]
    fn cached_desktop_snapshot_preserves_bootstrap_non_running_status() {
        let mut next_snapshot = ThreadSnapshotDto {
            contract_version: CONTRACT_VERSION.to_string(),
            thread: ThreadDetailDto {
                contract_version: CONTRACT_VERSION.to_string(),
                thread_id: "thread-1".to_string(),
                native_thread_id: "thread-1".to_string(),
                provider: shared_contracts::ProviderKind::Codex,
                client: shared_contracts::ThreadClientKind::Cli,
                title: "Thread".to_string(),
                status: ThreadStatus::Running,
                workspace: "/repo".to_string(),
                repository: "repo".to_string(),
                branch: "main".to_string(),
                created_at: "2026-03-27T20:00:00Z".to_string(),
                updated_at: "2026-03-27T20:00:10Z".to_string(),
                source: "codex_app_ipc".to_string(),
                access_mode: shared_contracts::AccessMode::ControlWithApprovals,
                last_turn_summary: "working".to_string(),
                active_turn_id: None,
            },
            entries: vec![ThreadTimelineEntryDto {
                event_id: "evt-1".to_string(),
                kind: BridgeEventKind::MessageDelta,
                occurred_at: "2026-03-27T20:00:10Z".to_string(),
                summary: "working".to_string(),
                payload: json!({"delta":"working","replace":true}),
                annotations: None,
            }],
            approvals: Vec::new(),
            git_status: None,
            pending_user_input: None,
        };

        preserve_bootstrap_status_for_cached_desktop_snapshot(
            None,
            Some(ThreadStatus::Idle),
            &mut next_snapshot,
            false,
        );

        assert_eq!(next_snapshot.thread.status, ThreadStatus::Idle);
    }

    #[test]
    fn terminal_thread_status_events_clear_transient_thread_state() {
        let event = BridgeEventEnvelope {
            contract_version: CONTRACT_VERSION.to_string(),
            event_id: "evt-status".to_string(),
            thread_id: "thread-1".to_string(),
            kind: BridgeEventKind::ThreadStatusChanged,
            occurred_at: "2026-03-27T20:00:10Z".to_string(),
            payload: json!({
                "status": "completed",
                "reason": "upstream_notification",
            }),
            annotations: None,
        };

        assert!(should_clear_transient_thread_state(&event));
    }

    #[test]
    fn live_delta_compactor_keeps_plan_steps_on_compacted_events() {
        let mut compactor = LiveDeltaCompactor::default();
        let compacted = compactor.compact(BridgeEventEnvelope {
            contract_version: CONTRACT_VERSION.to_string(),
            event_id: "evt-plan".to_string(),
            thread_id: "thread-1".to_string(),
            kind: BridgeEventKind::PlanDelta,
            occurred_at: "2026-03-27T20:00:10Z".to_string(),
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
        });

        assert_eq!(compacted.payload["type"], "plan");
        assert_eq!(
            compacted.payload["delta"],
            "1 out of 2 tasks completed\n1. Inspect bridge payload\n2. Add Flutter card"
        );
        assert_eq!(compacted.payload["completed_count"], 1);
        assert_eq!(
            compacted.payload["steps"][1]["status"].as_str(),
            Some("in_progress")
        );
    }

    #[test]
    fn live_delta_compactor_preserves_raw_codex_message_deltas() {
        let mut compactor = LiveDeltaCompactor::default();
        let compacted = compactor.compact(BridgeEventEnvelope {
            contract_version: CONTRACT_VERSION.to_string(),
            event_id: "evt-message".to_string(),
            thread_id: "thread-1".to_string(),
            kind: BridgeEventKind::MessageDelta,
            occurred_at: "2026-03-27T20:00:10Z".to_string(),
            payload: json!({
                "id": "msg-1",
                "type": "agentMessage",
                "role": "assistant",
                "delta": "**Overall**",
                "replace": false,
            }),
            annotations: None,
        });

        assert_eq!(compacted.payload["delta"], "**Overall**");
        assert_eq!(compacted.payload["replace"].as_bool(), Some(false));
    }

    #[test]
    fn message_events_with_text_but_no_delta_still_publish() {
        let event = BridgeEventEnvelope {
            contract_version: CONTRACT_VERSION.to_string(),
            event_id: "evt-message".to_string(),
            thread_id: "thread-1".to_string(),
            kind: BridgeEventKind::MessageDelta,
            occurred_at: "2026-03-27T20:00:10Z".to_string(),
            payload: json!({
                "role": "assistant",
                "text": "Streaming now",
            }),
            annotations: None,
        };

        assert!(should_publish_compacted_event(&event));
    }

    #[test]
    fn whitespace_only_message_deltas_still_publish() {
        let mut compactor = LiveDeltaCompactor::default();
        let initial = compactor.compact(BridgeEventEnvelope {
            contract_version: CONTRACT_VERSION.to_string(),
            event_id: "evt-message".to_string(),
            thread_id: "thread-1".to_string(),
            kind: BridgeEventKind::MessageDelta,
            occurred_at: "2026-03-27T20:00:10Z".to_string(),
            payload: json!({
                "id": "msg-1",
                "type": "agentMessage",
                "role": "assistant",
                "text": "GIF",
            }),
            annotations: None,
        });
        let whitespace = compactor.compact(BridgeEventEnvelope {
            contract_version: CONTRACT_VERSION.to_string(),
            event_id: "evt-message".to_string(),
            thread_id: "thread-1".to_string(),
            kind: BridgeEventKind::MessageDelta,
            occurred_at: "2026-03-27T20:00:11Z".to_string(),
            payload: json!({
                "id": "msg-1",
                "type": "agentMessage",
                "role": "assistant",
                "text": "GIF\n",
            }),
            annotations: None,
        });

        assert_eq!(initial.payload["delta"], "GIF");
        assert_eq!(whitespace.payload["delta"], "\n");
        assert!(should_publish_compacted_event(&whitespace));
    }

    #[test]
    fn running_thread_status_events_do_not_clear_transient_thread_state() {
        let event = BridgeEventEnvelope {
            contract_version: CONTRACT_VERSION.to_string(),
            event_id: "evt-status".to_string(),
            thread_id: "thread-1".to_string(),
            kind: BridgeEventKind::ThreadStatusChanged,
            occurred_at: "2026-03-27T20:00:10Z".to_string(),
            payload: json!({
                "status": "running",
                "reason": "upstream_notification",
            }),
            annotations: None,
        };

        assert!(!should_clear_transient_thread_state(&event));
    }

    #[test]
    fn bridge_owned_desktop_updates_preserve_running_until_terminal_raw_status() {
        let previous_snapshot = ThreadSnapshotDto {
            contract_version: CONTRACT_VERSION.to_string(),
            thread: ThreadDetailDto {
                contract_version: CONTRACT_VERSION.to_string(),
                thread_id: "thread-1".to_string(),
                native_thread_id: "thread-1".to_string(),
                provider: shared_contracts::ProviderKind::Codex,
                client: shared_contracts::ThreadClientKind::Cli,
                title: "Thread".to_string(),
                status: ThreadStatus::Running,
                workspace: "/repo".to_string(),
                repository: "repo".to_string(),
                branch: "main".to_string(),
                created_at: "2026-03-27T20:00:00Z".to_string(),
                updated_at: "2026-03-27T20:00:00Z".to_string(),
                source: "codex_app_ipc".to_string(),
                access_mode: shared_contracts::AccessMode::ControlWithApprovals,
                last_turn_summary: "working".to_string(),
                active_turn_id: None,
            },
            entries: vec![ThreadTimelineEntryDto {
                event_id: "evt-1".to_string(),
                kind: BridgeEventKind::MessageDelta,
                occurred_at: "2026-03-27T20:00:00Z".to_string(),
                summary: "working".to_string(),
                payload: json!({"delta":"working","replace":true}),
                annotations: None,
            }],
            approvals: Vec::new(),
            git_status: None,
            pending_user_input: None,
        };
        let mut next_snapshot = ThreadSnapshotDto {
            contract_version: CONTRACT_VERSION.to_string(),
            thread: ThreadDetailDto {
                status: ThreadStatus::Idle,
                updated_at: "2026-03-27T20:00:10Z".to_string(),
                ..previous_snapshot.thread.clone()
            },
            entries: vec![ThreadTimelineEntryDto {
                event_id: "evt-2".to_string(),
                kind: BridgeEventKind::MessageDelta,
                occurred_at: "2026-03-27T20:00:10Z".to_string(),
                summary: "still working".to_string(),
                payload: json!({"delta":"still working","replace":true}),
                annotations: None,
            }],
            approvals: Vec::new(),
            git_status: None,
            pending_user_input: None,
        };

        preserve_running_status_for_bridge_owned_desktop_update(
            Some(&previous_snapshot),
            &mut next_snapshot,
            Some("idle"),
            true,
        );

        assert_eq!(next_snapshot.thread.status, ThreadStatus::Running);
    }

    #[test]
    fn bridge_owned_desktop_updates_allow_terminal_raw_status() {
        let previous_snapshot = ThreadSnapshotDto {
            contract_version: CONTRACT_VERSION.to_string(),
            thread: ThreadDetailDto {
                contract_version: CONTRACT_VERSION.to_string(),
                thread_id: "thread-1".to_string(),
                native_thread_id: "thread-1".to_string(),
                provider: shared_contracts::ProviderKind::Codex,
                client: shared_contracts::ThreadClientKind::Cli,
                title: "Thread".to_string(),
                status: ThreadStatus::Running,
                workspace: "/repo".to_string(),
                repository: "repo".to_string(),
                branch: "main".to_string(),
                created_at: "2026-03-27T20:00:00Z".to_string(),
                updated_at: "2026-03-27T20:00:00Z".to_string(),
                source: "codex_app_ipc".to_string(),
                access_mode: shared_contracts::AccessMode::ControlWithApprovals,
                last_turn_summary: "working".to_string(),
                active_turn_id: None,
            },
            entries: vec![],
            approvals: Vec::new(),
            git_status: None,
            pending_user_input: None,
        };
        let mut next_snapshot = ThreadSnapshotDto {
            contract_version: CONTRACT_VERSION.to_string(),
            thread: ThreadDetailDto {
                status: ThreadStatus::Completed,
                updated_at: "2026-03-27T20:00:10Z".to_string(),
                ..previous_snapshot.thread.clone()
            },
            entries: vec![],
            approvals: Vec::new(),
            git_status: None,
            pending_user_input: None,
        };

        preserve_running_status_for_bridge_owned_desktop_update(
            Some(&previous_snapshot),
            &mut next_snapshot,
            Some("completed"),
            true,
        );

        assert_eq!(next_snapshot.thread.status, ThreadStatus::Completed);
    }

    #[test]
    fn notification_events_continue_streaming_for_bridge_active_turns() {
        let message = BridgeEventEnvelope {
            contract_version: CONTRACT_VERSION.to_string(),
            event_id: "evt-message".to_string(),
            thread_id: "thread-1".to_string(),
            kind: BridgeEventKind::MessageDelta,
            occurred_at: "2026-03-29T09:00:00Z".to_string(),
            payload: json!({"delta":"hello","replace":true}),
            annotations: None,
        };
        let status = BridgeEventEnvelope {
            contract_version: CONTRACT_VERSION.to_string(),
            event_id: "evt-status".to_string(),
            thread_id: "thread-1".to_string(),
            kind: BridgeEventKind::ThreadStatusChanged,
            occurred_at: "2026-03-29T09:00:01Z".to_string(),
            payload: json!({"status":"running"}),
            annotations: None,
        };

        assert!(!should_suppress_notification_event_for_bridge_active_turn(
            &message, true
        ));
        assert!(!should_suppress_notification_event_for_bridge_active_turn(
            &status, true
        ));
        assert!(!should_suppress_notification_event_for_bridge_active_turn(
            &message, false
        ));
    }

    #[test]
    fn non_running_thread_status_events_are_suppressed_for_bridge_active_turns() {
        let idle_status = BridgeEventEnvelope {
            contract_version: CONTRACT_VERSION.to_string(),
            event_id: "evt-status".to_string(),
            thread_id: "thread-1".to_string(),
            kind: BridgeEventKind::ThreadStatusChanged,
            occurred_at: "2026-03-29T09:00:01Z".to_string(),
            payload: json!({"status":"idle"}),
            annotations: None,
        };
        let running_status = BridgeEventEnvelope {
            payload: json!({"status":"running"}),
            ..idle_status.clone()
        };

        assert!(
            should_suppress_non_running_thread_status_for_bridge_active_turn(&idle_status, true)
        );
        assert!(
            !should_suppress_non_running_thread_status_for_bridge_active_turn(
                &running_status,
                true
            )
        );
        assert!(
            !should_suppress_non_running_thread_status_for_bridge_active_turn(&idle_status, false)
        );
        assert!(should_suppress_notification_event_for_bridge_active_turn(
            &idle_status,
            true
        ));
    }

    #[tokio::test]
    async fn interrupt_requested_threads_rewrite_upstream_idle_status_to_interrupted() {
        let state = test_bridge_app_state().await;
        state
            .mark_thread_interrupt_requested("codex:thread-1")
            .await;

        let mut idle_status = BridgeEventEnvelope {
            contract_version: CONTRACT_VERSION.to_string(),
            event_id: "evt-status".to_string(),
            thread_id: "codex:thread-1".to_string(),
            kind: BridgeEventKind::ThreadStatusChanged,
            occurred_at: "2026-03-29T09:00:01Z".to_string(),
            payload: json!({
                "status": "idle",
                "reason": "upstream_notification",
            }),
            annotations: None,
        };

        state
            .rewrite_interrupted_thread_status_event(&mut idle_status)
            .await;

        assert_eq!(idle_status.payload["status"], "interrupted");
        assert_eq!(idle_status.payload["reason"], "interrupt_requested");
    }

    #[tokio::test]
    async fn interrupt_requested_threads_preserve_interrupted_status_in_completion_snapshot() {
        let state = test_bridge_app_state().await;
        let thread_id = "codex:thread-1";
        state.mark_thread_interrupt_requested(thread_id).await;

        let snapshot = ThreadSnapshotDto {
            contract_version: CONTRACT_VERSION.to_string(),
            thread: ThreadDetailDto {
                contract_version: CONTRACT_VERSION.to_string(),
                thread_id: thread_id.to_string(),
                native_thread_id: "thread-1".to_string(),
                provider: shared_contracts::ProviderKind::Codex,
                client: shared_contracts::ThreadClientKind::Cli,
                title: "Thread".to_string(),
                status: ThreadStatus::Idle,
                workspace: "/repo".to_string(),
                repository: "repo".to_string(),
                branch: "main".to_string(),
                created_at: "2026-03-27T20:00:00Z".to_string(),
                updated_at: "2026-03-27T20:00:10Z".to_string(),
                source: "codex_app_ipc".to_string(),
                access_mode: shared_contracts::AccessMode::ControlWithApprovals,
                last_turn_summary: "idle".to_string(),
                active_turn_id: None,
            },
            entries: vec![],
            approvals: Vec::new(),
            git_status: None,
            pending_user_input: None,
        };

        state
            .apply_bridge_turn_completion_snapshot(thread_id, snapshot)
            .await;

        let stored = state
            .projections()
            .snapshot(thread_id)
            .await
            .expect("snapshot should be stored");
        assert_eq!(stored.thread.status, ThreadStatus::Interrupted);
    }

    #[test]
    fn bridge_owned_turn_finalization_waits_for_non_running_snapshot() {
        assert!(should_defer_bridge_owned_turn_finalization(
            ThreadStatus::Running
        ));
        assert!(!should_defer_bridge_owned_turn_finalization(
            ThreadStatus::Idle
        ));
        assert!(!should_defer_bridge_owned_turn_finalization(
            ThreadStatus::Completed
        ));
    }

    #[test]
    fn watchdog_does_not_finalize_while_turn_stream_is_active() {
        assert!(!watchdog_should_finalize_bridge_owned_turn(
            ThreadStatus::Completed,
            true
        ));
        assert!(!watchdog_should_finalize_bridge_owned_turn(
            ThreadStatus::Running,
            false
        ));
        assert!(watchdog_should_finalize_bridge_owned_turn(
            ThreadStatus::Completed,
            false
        ));
    }
}
