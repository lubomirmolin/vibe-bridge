use super::*;

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
