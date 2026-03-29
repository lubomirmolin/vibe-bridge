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
    SecurityAuditEventDto, ServiceHealthDto, ServiceHealthStatus, ThreadGitDiffDto,
    ThreadGitDiffMode, ThreadSnapshotDto, ThreadStatus, ThreadSummaryDto, ThreadTimelineEntryDto,
    ThreadTimelinePageDto, TrustStateDto, TurnMutationAcceptedDto,
};
use tokio::sync::RwLock;
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
use crate::server::config::{BridgeCodexConfig, BridgeConfig};
use crate::server::controls::{
    ApprovalGateResponse, ApprovalRecordDto, ApprovalResolutionResponse, ApprovalStatus,
    ExecutedGitMutation, PendingApprovalAction, execute_branch_switch, execute_pull, execute_push,
    read_git_state, read_git_state_for_status,
};
use crate::server::events::EventHub;
use crate::server::gateway::CodexGateway;
use crate::server::pairing_route::PairingRouteState;
use crate::server::projection::ProjectionStore;
use crate::server::speech::{SpeechError, SpeechService};
use crate::thread_api::{GitStatusResponse, MutationResultResponse, RepositoryContextDto};

#[derive(Debug, Clone)]
pub struct BridgeAppState {
    inner: Arc<BridgeAppStateInner>,
}

#[derive(Debug)]
struct BridgeAppStateInner {
    projections: ProjectionStore,
    codex_health: RwLock<ServiceHealthDto>,
    available_models: RwLock<Vec<ModelOptionDto>>,
    active_turn_ids: RwLock<HashMap<String, String>>,
    pending_bridge_owned_turns: RwLock<HashSet<String>>,
    resumed_notification_threads: RwLock<HashSet<String>>,
    inflight_thread_title_generations: RwLock<HashSet<String>>,
    pending_user_message_images: RwLock<HashMap<String, Vec<String>>>,
    pending_synthetic_user_messages: RwLock<HashMap<String, String>>,
    access_mode: RwLock<AccessMode>,
    security_events: RwLock<Vec<SecurityEventRecordDto>>,
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
                active_turn_ids: RwLock::new(HashMap::new()),
                pending_bridge_owned_turns: RwLock::new(HashSet::new()),
                resumed_notification_threads: RwLock::new(HashSet::new()),
                inflight_thread_title_generations: RwLock::new(HashSet::new()),
                pending_user_message_images: RwLock::new(HashMap::new()),
                pending_synthetic_user_messages: RwLock::new(HashMap::new()),
                access_mode: RwLock::new(AccessMode::ControlWithApprovals),
                security_events: RwLock::new(Vec::new()),
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
                state
                    .projections()
                    .replace_summaries(bootstrap.summaries)
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
        self.projections().put_snapshot(snapshot.clone()).await;
        self.request_notification_thread_resume(thread_id).await;
        Ok(snapshot)
    }

    pub async fn create_thread(
        &self,
        workspace: &str,
        model: Option<&str>,
    ) -> Result<ThreadSnapshotDto, String> {
        let mut snapshot = self.inner.gateway.create_thread(workspace, model).await?;
        snapshot.thread.access_mode = self.access_mode().await;
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

    async fn apply_external_snapshot_update(
        &self,
        snapshot: ThreadSnapshotDto,
        events: Vec<BridgeEventEnvelope<Value>>,
    ) {
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
        let model = model.map(str::to_string);
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
        let model = model.map(str::to_string);
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

            if let Some(source) = generated_title
                && let Ok(Some(title)) = state
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

        self.inner
            .gateway
            .set_thread_name(thread_id, normalized_title)
            .await?;
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
        if normalized_thread_id.is_empty() {
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

        let sender = self
            .inner
            .notification_control_tx
            .lock()
            .expect("notification control lock should not be poisoned")
            .clone();
        if let Some(sender) = sender {
            let _ = sender.send(NotificationControlMessage::ResumeThread(next_thread_id));
        }
        let desktop_sender = self
            .inner
            .desktop_ipc_control_tx
            .lock()
            .expect("desktop IPC control lock should not be poisoned")
            .clone();
        if let Some(sender) = desktop_sender {
            let _ = sender.send(NotificationControlMessage::ResumeThread(
                normalized_thread_id.to_string(),
            ));
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
        self.inner
            .pending_synthetic_user_messages
            .write()
            .await
            .remove(thread_id);
    }

    async fn finalize_bridge_owned_turn(&self, thread_id: &str) {
        self.clear_transient_thread_state(thread_id).await;
        self.refresh_snapshot_after_bridge_turn_completion(thread_id)
            .await;
    }

    async fn refresh_snapshot_after_bridge_turn_completion(&self, thread_id: &str) {
        let previous_snapshot = self.projections().snapshot(thread_id).await;
        let mut snapshot = match self.inner.gateway.fetch_thread_snapshot(thread_id).await {
            Ok(snapshot) => snapshot,
            Err(error) => {
                eprintln!(
                    "bridge thread snapshot refresh after turn completion failed for {thread_id}: {error}"
                );
                return;
            }
        };
        snapshot.thread.access_mode = self.access_mode().await;

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

                let resumed_threads = handle.block_on(async {
                    state
                        .inner
                        .resumed_notification_threads
                        .read()
                        .await
                        .clone()
                });
                if let Err(error) =
                    resume_notification_threads(resumed_threads.iter(), |thread_id| {
                        notifications.resume_thread(thread_id)
                    })
                {
                    eprintln!("bridge notification resume sync failed: {error}");
                    std::thread::sleep(std::time::Duration::from_secs(1));
                    continue;
                }

                loop {
                    if let Err(error) =
                        drain_notification_control_messages(&control_rx, |thread_id| {
                            notifications.resume_thread(thread_id)
                        })
                    {
                        eprintln!("bridge notification control failed: {error}");
                        break;
                    }

                    match notifications.next_event() {
                        Ok(Some(event)) => {
                            let normalized = compactor.compact(event);
                            if !should_publish_compacted_event(&normalized) {
                                continue;
                            }
                            let state = state.clone();
                            handle.block_on(async move {
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

                let mut tracked_threads = handle.block_on(async {
                    state
                        .inner
                        .resumed_notification_threads
                        .read()
                        .await
                        .clone()
                });
                if let Err(error) =
                    resume_notification_threads(tracked_threads.iter(), |thread_id| {
                        match client.external_resume_thread(thread_id) {
                            Ok(()) => Ok(()),
                            Err(error) if error.contains("no-client-found") => Ok(()),
                            Err(error) => Err(error),
                        }
                    })
                {
                    eprintln!("bridge desktop IPC resume sync failed: {error}");
                }

                loop {
                    if let Err(error) = drain_notification_control_messages(
                        &control_rx,
                        |thread_id| {
                            tracked_threads.insert(thread_id.to_string());
                            if let Some(conversation_state) =
                                conversation_state_by_thread.get(thread_id).cloned()
                            {
                                let previous_snapshot = handle.block_on(async {
                                    state.projections().snapshot(thread_id).await
                                });
                                if previous_snapshot.as_ref().is_some_and(|snapshot| {
                                    snapshot.thread.status == ThreadStatus::Running
                                }) {
                                    match client.external_resume_thread(thread_id) {
                                        Ok(()) => Ok(()),
                                        Err(error) if error.contains("no-client-found") => Ok(()),
                                        Err(error) => Err(error),
                                    }?;
                                    return Ok(());
                                }
                                let previous_summary_status = handle.block_on(async {
                                    state.projections().summary_status(thread_id).await
                                });
                                let access_mode =
                                    handle.block_on(async { state.access_mode().await });
                                if let Ok((next_snapshot, events)) =
                                    build_desktop_ipc_snapshot_update(
                                        previous_snapshot.as_ref(),
                                        previous_summary_status,
                                        &conversation_state,
                                        access_mode,
                                        &mut compactor,
                                        false,
                                        None,
                                    )
                                {
                                    let should_suppress_for_bridge_owned_turn =
                                        should_suppress_desktop_ipc_live_update_for_bridge_active_turn(
                                            handle.block_on(async {
                                                state.has_bridge_owned_active_turn(thread_id).await
                                            }),
                                        );
                                    if should_suppress_for_bridge_owned_turn {
                                        match client.external_resume_thread(thread_id) {
                                            Ok(()) => Ok(()),
                                            Err(error) if error.contains("no-client-found") => {
                                                Ok(())
                                            }
                                            Err(error) => Err(error),
                                        }?;
                                        return Ok(());
                                    }
                                    let state = state.clone();
                                    handle.block_on(async move {
                                        state
                                            .apply_external_snapshot_update(next_snapshot, events)
                                            .await;
                                    });
                                }
                            }
                            match client.external_resume_thread(thread_id) {
                                Ok(()) => Ok(()),
                                Err(error) if error.contains("no-client-found") => Ok(()),
                                Err(error) => Err(error),
                            }
                        },
                    ) {
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
                    ) {
                        Ok(update) => update,
                        Err(error) => {
                            eprintln!(
                                "bridge desktop IPC snapshot mapping failed for {thread_id}: {error}"
                            );
                            continue;
                        }
                    };
                    if should_suppress_desktop_ipc_live_update_for_bridge_active_turn(
                        handle.block_on(async {
                            state.has_bridge_owned_active_turn(&thread_id).await
                        }),
                    ) {
                        continue;
                    }

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
                        state
                            .projections()
                            .replace_summaries(bootstrap.summaries)
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
    ) -> Result<TurnMutationAcceptedDto, String> {
        self.start_turn_with_visible_prompt(thread_id, prompt, prompt, images, model, effort)
            .await
    }

    pub async fn start_commit_action(
        &self,
        thread_id: &str,
        model: Option<&str>,
        effort: Option<&str>,
    ) -> Result<TurnMutationAcceptedDto, String> {
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
        if !normalized_images.is_empty() {
            self.inner
                .pending_user_message_images
                .write()
                .await
                .insert(thread_id.to_string(), normalized_images.clone());
        }
        let visible_prompt = visible_prompt.trim();
        if !visible_prompt.is_empty() {
            self.publish_synthetic_user_message(thread_id, visible_prompt, &normalized_images)
                .await;
            self.inner
                .pending_synthetic_user_messages
                .write()
                .await
                .insert(thread_id.to_string(), visible_prompt.to_string());
            self.inner
                .pending_user_message_images
                .write()
                .await
                .remove(thread_id);
        }
        let state = self.clone();
        let handle = tokio::runtime::Handle::current();
        let completion_handle = handle.clone();
        let compactor = Arc::new(std::sync::Mutex::new(LiveDeltaCompactor::default()));
        let completion_state = self.clone();
        self.inner
            .pending_bridge_owned_turns
            .write()
            .await
            .insert(thread_id.to_string());
        let result = match self.inner.gateway.start_turn_streaming(
            thread_id,
            upstream_prompt,
            images,
            model,
            effort,
            move |event| {
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
                if handle.block_on(async {
                    state
                        .should_suppress_duplicate_synthetic_user_message(&normalized)
                        .await
                }) {
                    return;
                }
                let state = state.clone();
                let should_suppress_for_bridge_owned_turn = handle.block_on(async {
                    should_suppress_non_running_thread_status_for_bridge_active_turn(
                        &normalized,
                        state
                            .has_bridge_owned_active_turn(&normalized.thread_id)
                            .await,
                    )
                });
                if should_suppress_for_bridge_owned_turn {
                    return;
                }
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
            move |completed_thread_id| {
                let state = completion_state.clone();
                completion_handle.block_on(async move {
                    state.finalize_bridge_owned_turn(&completed_thread_id).await;
                });
            },
        ) {
            Ok(result) => result,
            Err(error) => {
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
            self.inner
                .pending_synthetic_user_messages
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
        }
        let occurred_at = Utc::now().to_rfc3339();
        self.projections()
            .mark_thread_running(thread_id, &occurred_at)
            .await;
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

    async fn publish_synthetic_user_message(
        &self,
        thread_id: &str,
        message: &str,
        images: &[String],
    ) {
        let image_payload = images
            .iter()
            .map(|image| image.trim())
            .filter(|image| !image.is_empty())
            .map(ToString::to_string)
            .collect::<Vec<_>>();
        let occurred_at = Utc::now().to_rfc3339();
        let event = BridgeEventEnvelope {
            contract_version: shared_contracts::CONTRACT_VERSION.to_string(),
            event_id: format!("{thread_id}-user-{}", occurred_at),
            thread_id: thread_id.to_string(),
            kind: BridgeEventKind::MessageDelta,
            occurred_at,
            payload: json!({
                "id": format!("{thread_id}-user-message"),
                "type": "message",
                "role": "user",
                "delta": message,
                "replace": true,
                "images": image_payload,
            }),
            annotations: None,
        };
        self.projections().apply_live_event(&event).await;
        self.event_hub().publish(event);
    }

    async fn should_suppress_duplicate_synthetic_user_message(
        &self,
        event: &BridgeEventEnvelope<Value>,
    ) -> bool {
        let mut pending = self.inner.pending_synthetic_user_messages.write().await;
        let Some(expected_text) = pending.get(&event.thread_id).map(String::as_str) else {
            return false;
        };

        if !is_duplicate_synthetic_user_message(expected_text, event) {
            return false;
        }

        pending.remove(&event.thread_id);
        drop(pending);

        self.inner
            .pending_user_message_images
            .write()
            .await
            .remove(&event.thread_id);
        true
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
            self.inner
                .active_turn_ids
                .read()
                .await
                .get(thread_id)
                .cloned()
                .ok_or_else(|| format!("no active turn tracked for thread {thread_id}"))?
        };
        let result = self
            .inner
            .gateway
            .interrupt_turn(thread_id, &resolved_turn_id)
            .await?;
        let occurred_at = Utc::now().to_rfc3339();
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

    pub async fn model_catalog_payload(&self) -> ModelCatalogDto {
        ModelCatalogDto {
            contract_version: shared_contracts::CONTRACT_VERSION.to_string(),
            models: self.inner.available_models.read().await.clone(),
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

fn thread_summary_from_snapshot(snapshot: &ThreadSnapshotDto) -> ThreadSummaryDto {
    ThreadSummaryDto {
        contract_version: snapshot.contract_version.clone(),
        thread_id: snapshot.thread.thread_id.clone(),
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

fn should_publish_compacted_event(event: &BridgeEventEnvelope<Value>) -> bool {
    match event.kind {
        BridgeEventKind::MessageDelta
        | BridgeEventKind::PlanDelta
        | BridgeEventKind::CommandDelta
        | BridgeEventKind::FileChange => {
            let replace = event
                .payload
                .get("replace")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            let delta = event
                .payload
                .get("delta")
                .and_then(Value::as_str)
                .unwrap_or_default();
            replace || !delta.is_empty()
        }
        _ => true,
    }
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

fn should_suppress_desktop_ipc_live_update_for_bridge_active_turn(
    has_bridge_owned_active_turn: bool,
) -> bool {
    has_bridge_owned_active_turn
}

fn should_suppress_notification_event_for_bridge_active_turn(
    event: &BridgeEventEnvelope<Value>,
    has_bridge_owned_active_turn: bool,
) -> bool {
    has_bridge_owned_active_turn
        && (event.kind != BridgeEventKind::ThreadStatusChanged
            || should_suppress_non_running_thread_status_for_bridge_active_turn(
                event,
                has_bridge_owned_active_turn,
            ))
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

fn build_desktop_ipc_snapshot_update(
    previous_snapshot: Option<&ThreadSnapshotDto>,
    previous_summary_status: Option<ThreadStatus>,
    conversation_state: &Value,
    access_mode: AccessMode,
    compactor: &mut LiveDeltaCompactor,
    is_patch_update: bool,
    latest_raw_turn_status: Option<&str>,
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

    let events = diff_thread_snapshots(previous_snapshot, &next_snapshot)
        .into_iter()
        .filter_map(|event| {
            let normalized = compactor.compact(event);
            (should_publish_compacted_event(&normalized)
                && !should_suppress_live_event(&normalized))
            .then_some(normalized)
        })
        .collect::<Vec<_>>();

    Ok((next_snapshot, events))
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
    latest_raw_turn_status: Option<&str>,
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
    if latest_raw_turn_status.is_some_and(|status| status.trim().eq_ignore_ascii_case("idle")) {
        return;
    }
    if next_snapshot.entries.is_empty() {
        return;
    }

    next_snapshot.thread.status = ThreadStatus::Running;
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

fn is_duplicate_synthetic_user_message(
    expected_text: &str,
    event: &BridgeEventEnvelope<Value>,
) -> bool {
    if event.kind != BridgeEventKind::MessageDelta {
        return false;
    }
    if event.payload.get("role").and_then(Value::as_str) != Some("user") {
        return false;
    }

    let Some(live_text) = payload_primary_text(&event.payload).map(str::trim) else {
        return false;
    };
    if live_text.is_empty() {
        return false;
    }

    expected_text.trim() == live_text
}

fn is_hidden_message(message: &str) -> bool {
    let trimmed = message.trim();
    trimmed.starts_with("# AGENTS.md instructions for ")
        || trimmed.starts_with("<permissions instructions>")
        || trimmed.starts_with("<app-context>")
        || trimmed.starts_with("<environment_context>")
        || trimmed.starts_with("<collaboration_mode>")
        || trimmed.starts_with("<turn_aborted>")
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

fn resume_notification_threads<'a, I, F>(thread_ids: I, mut resume_thread: F) -> Result<(), String>
where
    I: IntoIterator<Item = &'a String>,
    F: FnMut(&str) -> Result<(), String>,
{
    for thread_id in thread_ids {
        resume_thread(thread_id)?;
    }
    Ok(())
}

fn drain_notification_control_messages<F>(
    control_rx: &mpsc::Receiver<NotificationControlMessage>,
    mut resume_thread: F,
) -> Result<(), String>
where
    F: FnMut(&str) -> Result<(), String>,
{
    loop {
        match control_rx.try_recv() {
            Ok(NotificationControlMessage::ResumeThread(thread_id)) => {
                resume_thread(&thread_id)?;
            }
            Err(mpsc::TryRecvError::Empty) | Err(mpsc::TryRecvError::Disconnected) => {
                return Ok(());
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::sync::mpsc;
    use std::time::{SystemTime, UNIX_EPOCH};

    use serde_json::{Value, json};
    use shared_contracts::{
        BridgeEventEnvelope, BridgeEventKind, CONTRACT_VERSION, ThreadDetailDto, ThreadSnapshotDto,
        ThreadStatus, ThreadSummaryDto, ThreadTimelineEntryDto,
    };

    use crate::pairing::PairingSessionService;
    use crate::server::config::{BridgeCodexConfig, BridgeConfig};
    use crate::server::pairing_route::PairingRouteState;
    use crate::server::speech::SpeechService;

    use super::{
        BridgeAppState, LiveDeltaCompactor, NotificationControlMessage,
        build_desktop_ipc_snapshot_update, drain_notification_control_messages,
        ensure_running_status_for_desktop_patch_update, is_duplicate_synthetic_user_message,
        preserve_bootstrap_status_for_cached_desktop_snapshot, resume_notification_threads,
        should_clear_transient_thread_state,
        should_suppress_desktop_ipc_live_update_for_bridge_active_turn,
        should_suppress_non_running_thread_status_for_bridge_active_turn,
        should_suppress_notification_event_for_bridge_active_turn,
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
    fn duplicate_synthetic_user_message_matches_trimmed_user_delta() {
        let event = BridgeEventEnvelope {
            contract_version: CONTRACT_VERSION.to_string(),
            event_id: "evt-1".to_string(),
            thread_id: "thread-1".to_string(),
            kind: BridgeEventKind::MessageDelta,
            occurred_at: "2026-03-22T10:00:00Z".to_string(),
            payload: json!({
                "role": "user",
                "delta": "hello",
                "replace": true,
            }),
            annotations: None,
        };

        assert!(is_duplicate_synthetic_user_message(" hello ", &event));
    }

    #[test]
    fn duplicate_synthetic_user_message_rejects_non_user_or_mismatched_text() {
        let assistant_event = BridgeEventEnvelope {
            contract_version: CONTRACT_VERSION.to_string(),
            event_id: "evt-2".to_string(),
            thread_id: "thread-1".to_string(),
            kind: BridgeEventKind::MessageDelta,
            occurred_at: "2026-03-22T10:00:00Z".to_string(),
            payload: json!({
                "role": "assistant",
                "delta": "hello",
                "replace": true,
            }),
            annotations: None,
        };
        assert!(!is_duplicate_synthetic_user_message(
            "hello",
            &assistant_event
        ));

        let mismatched_text_event = BridgeEventEnvelope {
            contract_version: CONTRACT_VERSION.to_string(),
            event_id: "evt-3".to_string(),
            thread_id: "thread-1".to_string(),
            kind: BridgeEventKind::MessageDelta,
            occurred_at: "2026-03-22T10:00:00Z".to_string(),
            payload: json!({
                "role": "user",
                "delta": "hello world",
                "replace": true,
            }),
            annotations: None,
        };
        assert!(!is_duplicate_synthetic_user_message(
            "hello",
            &mismatched_text_event
        ));
    }

    #[test]
    fn resume_notification_threads_replays_all_requested_threads() {
        let requested = [
            "thread-from-mobile".to_string(),
            "thread-from-desktop".to_string(),
        ];
        let mut resumed = Vec::new();

        resume_notification_threads(requested.iter(), |thread_id| {
            resumed.push(thread_id.to_string());
            Ok(())
        })
        .expect("resume replay should succeed");

        assert_eq!(
            resumed,
            vec![
                "thread-from-mobile".to_string(),
                "thread-from-desktop".to_string(),
            ]
        );
    }

    #[test]
    fn drain_notification_control_messages_resumes_new_threads_until_queue_is_empty() {
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
        drain_notification_control_messages(&rx, |thread_id| {
            resumed.push(thread_id.to_string());
            Ok(())
        })
        .expect("draining control messages should succeed");

        assert_eq!(
            resumed,
            vec!["thread-123".to_string(), "thread-456".to_string()]
        );
    }

    #[tokio::test]
    async fn in_flight_title_generation_still_recognizes_placeholder_titles() {
        let state = test_bridge_app_state().await;
        let placeholder_snapshot = ThreadSnapshotDto {
            contract_version: CONTRACT_VERSION.to_string(),
            thread: ThreadDetailDto {
                contract_version: CONTRACT_VERSION.to_string(),
                thread_id: "thread-1".to_string(),
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
            },
            entries: Vec::new(),
            approvals: Vec::new(),
            git_status: None,
        };
        state.projections().put_snapshot(placeholder_snapshot).await;
        state
            .projections()
            .replace_summaries(vec![ThreadSummaryDto {
                contract_version: CONTRACT_VERSION.to_string(),
                thread_id: "thread-1".to_string(),
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

    #[test]
    fn desktop_patch_updates_mark_thread_running_until_explicit_completion_arrives() {
        let previous_snapshot = ThreadSnapshotDto {
            contract_version: CONTRACT_VERSION.to_string(),
            thread: ThreadDetailDto {
                contract_version: CONTRACT_VERSION.to_string(),
                thread_id: "thread-1".to_string(),
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
            },
            entries: Vec::new(),
            approvals: Vec::new(),
            git_status: None,
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
            },
            entries: Vec::new(),
            approvals: Vec::new(),
            git_status: None,
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
        )
        .expect("cached desktop snapshot should materialize");

        assert_eq!(snapshot.thread.thread_id, "thread-1");
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
    fn cached_desktop_snapshot_preserves_bootstrap_non_running_status() {
        let mut next_snapshot = ThreadSnapshotDto {
            contract_version: CONTRACT_VERSION.to_string(),
            thread: ThreadDetailDto {
                contract_version: CONTRACT_VERSION.to_string(),
                thread_id: "thread-1".to_string(),
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
    fn desktop_ipc_live_updates_are_suppressed_for_bridge_active_turns() {
        assert!(should_suppress_desktop_ipc_live_update_for_bridge_active_turn(true));
        assert!(!should_suppress_desktop_ipc_live_update_for_bridge_active_turn(false));
    }

    #[test]
    fn notification_events_are_suppressed_for_bridge_active_turns_except_status() {
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

        assert!(should_suppress_notification_event_for_bridge_active_turn(
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
}
