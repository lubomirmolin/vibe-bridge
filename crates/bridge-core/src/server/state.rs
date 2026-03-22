use std::collections::HashMap;
use std::sync::Arc;
use std::sync::Mutex;

use chrono::Utc;
use serde_json::{Value, json};
use shared_contracts::{
    AccessMode, BootstrapDto, BridgeEventEnvelope, BridgeEventKind, ModelCatalogDto,
    ModelOptionDto, SecurityAuditEventDto, ServiceHealthDto, ServiceHealthStatus,
    ThreadSnapshotDto, ThreadStatus, ThreadSummaryDto, ThreadTimelinePageDto, TrustStateDto,
    TurnMutationAcceptedDto,
};
use tokio::sync::RwLock;
use tokio::time::{Duration, sleep};

use crate::pairing::{
    PairingFinalizeError, PairingFinalizeRequest, PairingFinalizeResponse, PairingHandshakeError,
    PairingHandshakeRequest, PairingHandshakeResponse, PairingRevokeRequest, PairingRevokeResponse,
    PairingSessionResponse, PairingSessionService, PairingTrustSnapshot,
};
use crate::server::config::{BridgeCodexConfig, BridgeConfig};
use crate::server::events::EventHub;
use crate::server::gateway::CodexGateway;
use crate::server::pairing_route::{PairingRouteHealth, PairingRouteState};
use crate::server::projection::ProjectionStore;

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
    access_mode: RwLock<AccessMode>,
    security_events: RwLock<Vec<SecurityEventRecordDto>>,
    gateway: CodexGateway,
    event_hub: EventHub,
    pairing_sessions: Mutex<PairingSessionService>,
    pairing_route: PairingRouteState,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct SecurityEventRecordDto {
    pub severity: String,
    pub category: String,
    pub event: BridgeEventEnvelope<Value>,
}

impl BridgeAppState {
    pub fn new(
        config: BridgeCodexConfig,
        pairing_sessions: PairingSessionService,
        pairing_route: PairingRouteState,
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
                access_mode: RwLock::new(AccessMode::ControlWithApprovals),
                security_events: RwLock::new(Vec::new()),
                gateway: CodexGateway::new(config),
                event_hub: EventHub::new(512),
                pairing_sessions: Mutex::new(pairing_sessions),
                pairing_route,
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
        let state = Self::new(config.codex, pairing_sessions, config.pairing_route);

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
                        message: Some(error),
                    })
                    .await;
            }
        }

        state
    }

    pub fn pairing_route_health(&self) -> PairingRouteHealth {
        self.inner.pairing_route.health()
    }

    pub fn trust_snapshot(&self) -> PairingTrustSnapshot {
        self.inner
            .pairing_sessions
            .lock()
            .expect("pairing sessions lock should not be poisoned")
            .trust_snapshot()
    }

    pub fn issue_pairing_session(&self) -> PairingSessionResponse {
        self.inner
            .pairing_sessions
            .lock()
            .expect("pairing sessions lock should not be poisoned")
            .issue_session()
    }

    pub fn finalize_trust(
        &self,
        request: PairingFinalizeRequest,
    ) -> Result<PairingFinalizeResponse, PairingFinalizeError> {
        self.inner
            .pairing_sessions
            .lock()
            .expect("pairing sessions lock should not be poisoned")
            .finalize_trust(request)
    }

    pub fn handshake(
        &self,
        request: PairingHandshakeRequest,
    ) -> Result<PairingHandshakeResponse, PairingHandshakeError> {
        self.inner
            .pairing_sessions
            .lock()
            .expect("pairing sessions lock should not be poisoned")
            .handshake(request)
    }

    pub fn authorize_trusted_session(
        &self,
        request: PairingHandshakeRequest,
    ) -> Result<(), PairingHandshakeError> {
        self.handshake(request).map(|_| ())
    }

    pub fn revoke_trust(&self, phone_id: Option<String>) -> Result<PairingRevokeResponse, String> {
        self.inner
            .pairing_sessions
            .lock()
            .expect("pairing sessions lock should not be poisoned")
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

    pub async fn security_events_snapshot(&self) -> Vec<SecurityEventRecordDto> {
        self.inner.security_events.read().await.clone()
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
            return Ok(snapshot);
        }

        let mut snapshot = self.inner.gateway.fetch_thread_snapshot(thread_id).await?;
        snapshot.thread.access_mode = self.access_mode().await;
        self.projections().put_snapshot(snapshot.clone()).await;
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

    async fn set_codex_health(&self, health: ServiceHealthDto) {
        *self.inner.codex_health.write().await = health;
    }

    async fn set_available_models(&self, models: Vec<ModelOptionDto>) {
        *self.inner.available_models.write().await = models;
    }

    pub fn start_notification_forwarder(&self) {
        let state = self.clone();
        let handle = tokio::runtime::Handle::current();
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

                loop {
                    match notifications.next_event() {
                        Ok(Some(event)) => {
                            let normalized = compactor.compact(event);
                            if !should_publish_compacted_event(&normalized) {
                                continue;
                            }
                            let state = state.clone();
                            handle.block_on(async move {
                                if normalized.kind == BridgeEventKind::ThreadStatusChanged
                                    && normalized
                                        .payload
                                        .get("status")
                                        .and_then(Value::as_str)
                                        .is_some_and(|status| status != "running")
                                {
                                    state
                                        .inner
                                        .active_turn_ids
                                        .write()
                                        .await
                                        .remove(&normalized.thread_id);
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
    ) -> Result<TurnMutationAcceptedDto, String> {
        let state = self.clone();
        let handle = tokio::runtime::Handle::current();
        let compactor = Arc::new(std::sync::Mutex::new(LiveDeltaCompactor::default()));
        let result = self
            .inner
            .gateway
            .start_turn_streaming(thread_id, prompt, move |event| {
                let normalized = compactor
                    .lock()
                    .expect("turn stream compactor lock should not be poisoned")
                    .compact(event);
                if !should_publish_compacted_event(&normalized) {
                    return;
                }
                let state = state.clone();
                handle.block_on(async move {
                    if normalized.kind == BridgeEventKind::ThreadStatusChanged {
                        if normalized
                            .payload
                            .get("status")
                            .and_then(Value::as_str)
                            .is_some_and(|status| status != "running")
                        {
                            state
                                .inner
                                .active_turn_ids
                                .write()
                                .await
                                .remove(&normalized.thread_id);
                        }
                        return;
                    }
                    state.projections().apply_live_event(&normalized).await;
                    state.event_hub().publish(normalized);
                });
            })?;
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
        Ok(result.response)
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

                BridgeEventEnvelope {
                    payload: json!({
                        "id": event.payload.get("id").and_then(Value::as_str).unwrap_or_default(),
                        "type": "plan",
                        "delta": delta,
                        "replace": replace,
                    }),
                    ..event
                }
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
    match cache.get(event_id) {
        Some(previous_value) if current_value.starts_with(previous_value) => {
            let delta = current_value[previous_value.len()..].to_string();
            cache.insert(event_id.to_string(), current_value.to_string());
            (delta, false)
        }
        _ => {
            cache.insert(event_id.to_string(), current_value.to_string());
            (current_value.to_string(), true)
        }
    }
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
