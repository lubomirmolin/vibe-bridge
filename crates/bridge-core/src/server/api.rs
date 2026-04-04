use axum::extract::{Json as ExtractJson, Multipart, Path, Query, State, WebSocketUpgrade};
use axum::http::header::{ACCEPT, CONTENT_TYPE, HOST};
use axum::http::{HeaderMap, HeaderValue, Method, StatusCode};
use axum::response::Response;
use axum::routing::{get, post};
use axum::{Json, Router};
use serde::Deserialize;
use serde::Serialize;
use serde_json::json;
use shared_contracts::{
    AccessMode, BootstrapDto, ModelCatalogDto, NetworkSettingsDto, PairingRouteInventoryDto,
    ProviderKind, SecurityAuditEventDto, SpeechModelMutationAcceptedDto, SpeechModelStatusDto,
    SpeechTranscriptionResultDto, ThreadGitDiffDto, ThreadGitDiffMode, ThreadSnapshotDto,
    ThreadSummaryDto, ThreadTimelinePageDto, ThreadUsageDto, TurnMode, TurnMutationAcceptedDto,
    UserInputAnswerDto,
};
use tower_http::cors::{AllowOrigin, CorsLayer};

use crate::pairing::{
    PairingFinalizeError, PairingFinalizeRequest, PairingHandshakeError, PairingHandshakeRequest,
    PairingTrustSnapshot,
};
use crate::policy::{PolicyAction, PolicyDecision};
use crate::server::codex_usage::CodexUsageError;
use crate::server::controls::{ApprovalRecordDto, ApprovalResolutionResponse};
use crate::server::events::{EventSubscriptionQuery, replay_events_for_scope, stream_events};
use crate::server::state::BridgeAppState;

pub fn router(state: BridgeAppState) -> Router {
    Router::new()
        .route("/healthz", get(healthz))
        .route("/bootstrap", get(bootstrap))
        .route("/models", get(model_catalog))
        .route(
            "/speech/models/parakeet",
            get(get_speech_model)
                .put(ensure_speech_model)
                .delete(remove_speech_model),
        )
        .route("/speech/transcriptions", post(transcribe_speech))
        .route(
            "/pairing/session",
            get(pairing_session).post(pairing_session),
        )
        .route("/pairing/finalize", post(pairing_finalize))
        .route("/pairing/handshake", post(pairing_handshake))
        .route("/pairing/trust/revoke", post(pairing_revoke))
        .route("/pairing/trust", get(pairing_trust))
        .route("/pairing/route", get(pairing_route))
        .route(
            "/settings/network",
            get(get_network_settings).post(set_network_settings),
        )
        .route(
            "/policy/access-mode",
            get(get_access_mode).post(set_access_mode),
        )
        .route("/threads", get(list_threads).post(create_thread))
        .route("/threads/:thread_id/snapshot", get(thread_snapshot))
        .route("/threads/:thread_id/history", get(thread_history))
        .route("/threads/:thread_id/usage", get(thread_usage))
        .route("/threads/:thread_id/git/status", get(thread_git_status))
        .route("/threads/:thread_id/git/diff", get(thread_git_diff))
        .route(
            "/threads/:thread_id/git/branch-switch",
            post(thread_git_branch_switch),
        )
        .route("/threads/:thread_id/git/pull", post(thread_git_pull))
        .route("/threads/:thread_id/git/push", post(thread_git_push))
        .route("/threads/:thread_id/turns", post(start_turn))
        .route(
            "/threads/:thread_id/user-input/respond",
            post(respond_to_user_input),
        )
        .route(
            "/threads/:thread_id/actions/commit",
            post(start_commit_action),
        )
        .route("/threads/:thread_id/interrupt", post(interrupt_turn))
        .route("/approvals", get(list_approvals))
        .route("/approvals/:approval_id/approve", post(approve_approval))
        .route("/approvals/:approval_id/reject", post(reject_approval))
        .route("/security/events", get(list_security_events))
        .route("/events", get(events))
        .layer(browser_localhost_cors_layer())
        .with_state(state)
}

fn browser_localhost_cors_layer() -> CorsLayer {
    CorsLayer::new()
        .allow_origin(AllowOrigin::predicate(
            |origin: &HeaderValue, _request_parts| is_loopback_browser_origin(origin),
        ))
        .allow_private_network(true)
        .allow_methods([
            Method::GET,
            Method::POST,
            Method::PUT,
            Method::DELETE,
            Method::OPTIONS,
        ])
        .allow_headers([ACCEPT, CONTENT_TYPE])
}

fn is_loopback_browser_origin(origin: &HeaderValue) -> bool {
    let Ok(origin_value) = origin.to_str() else {
        return false;
    };
    let Ok(parsed_origin) = origin_value.parse::<axum::http::Uri>() else {
        return false;
    };

    matches!(
        parsed_origin.host(),
        Some("localhost") | Some("127.0.0.1") | Some("[::1]") | Some("::1")
    )
}

async fn healthz() -> Json<serde_json::Value> {
    Json(json!({
        "status": "ok",
        "backend": "bridge-server",
        "contract_version": shared_contracts::CONTRACT_VERSION,
    }))
}

async fn bootstrap(State(state): State<BridgeAppState>) -> Json<BootstrapDto> {
    eprintln!("bridge api bootstrap start");
    let payload = state.bootstrap_payload().await;
    eprintln!(
        "bridge api bootstrap done threads={} trust_trusted={}",
        payload.threads.len(),
        payload.trust.trusted
    );
    Json(payload)
}

#[derive(Debug, Deserialize)]
struct ModelCatalogQuery {
    #[serde(default)]
    provider: Option<ProviderKind>,
}

async fn model_catalog(
    State(state): State<BridgeAppState>,
    Query(query): Query<ModelCatalogQuery>,
) -> Json<ModelCatalogDto> {
    Json(
        state
            .model_catalog_payload(query.provider.unwrap_or(ProviderKind::Codex))
            .await,
    )
}

async fn get_speech_model(State(state): State<BridgeAppState>) -> Json<SpeechModelStatusDto> {
    Json(state.speech_status().await)
}

async fn ensure_speech_model(
    State(state): State<BridgeAppState>,
) -> Result<Json<SpeechModelMutationAcceptedDto>, (StatusCode, Json<ErrorEnvelope>)> {
    state
        .ensure_speech_model()
        .await
        .map(Json)
        .map_err(speech_error_response)
}

async fn remove_speech_model(
    State(state): State<BridgeAppState>,
) -> Result<Json<SpeechModelMutationAcceptedDto>, (StatusCode, Json<ErrorEnvelope>)> {
    state
        .remove_speech_model()
        .await
        .map(Json)
        .map_err(speech_error_response)
}

async fn transcribe_speech(
    State(state): State<BridgeAppState>,
    mut multipart: Multipart,
) -> Result<Json<SpeechTranscriptionResultDto>, (StatusCode, Json<ErrorEnvelope>)> {
    let mut file_name: Option<String> = None;
    let mut audio_bytes: Option<Vec<u8>> = None;

    if let Some(field) = multipart.next_field().await.map_err(|error| {
        error_response(
            StatusCode::BAD_REQUEST,
            "speech_transcription_failed",
            "speech_invalid_audio",
            format!("Invalid multipart upload: {error}"),
        )
    })? {
        file_name = field.file_name().map(ToString::to_string);
        audio_bytes = Some(
            field
                .bytes()
                .await
                .map_err(|error| {
                    error_response(
                        StatusCode::BAD_REQUEST,
                        "speech_transcription_failed",
                        "speech_invalid_audio",
                        format!("Failed to read uploaded audio: {error}"),
                    )
                })?
                .to_vec(),
        );
    }

    let audio_bytes = audio_bytes.ok_or_else(|| {
        error_response(
            StatusCode::BAD_REQUEST,
            "speech_transcription_failed",
            "speech_invalid_audio",
            "Expected one uploaded WAV file.",
        )
    })?;

    state
        .transcribe_audio_bytes(file_name.as_deref(), &audio_bytes)
        .await
        .map(Json)
        .map_err(speech_error_response)
}

async fn pairing_session(
    State(state): State<BridgeAppState>,
) -> Result<Json<crate::pairing::PairingSessionResponse>, (StatusCode, Json<ErrorEnvelope>)> {
    let pairing_route = state.pairing_route_health();
    if !pairing_route.reachable {
        let message = pairing_route
            .message
            .unwrap_or_else(|| "Private pairing route is unavailable.".to_string());
        return Err(error_response(
            StatusCode::SERVICE_UNAVAILABLE,
            "pairing_session_unavailable",
            "private_pairing_route_unavailable",
            message,
        ));
    }

    Ok(Json(state.issue_pairing_session()))
}

async fn list_threads(State(state): State<BridgeAppState>) -> Json<Vec<ThreadSummaryDto>> {
    Json(state.projections().list_summaries().await)
}

async fn thread_snapshot(
    State(state): State<BridgeAppState>,
    Path(thread_id): Path<String>,
) -> Result<Json<ThreadSnapshotDto>, StatusCode> {
    match state.ensure_snapshot(&thread_id).await {
        Ok(snapshot) => Ok(Json(snapshot)),
        Err(_) => Err(StatusCode::NOT_FOUND),
    }
}

async fn get_access_mode(State(state): State<BridgeAppState>) -> Json<AccessModeResponse> {
    Json(AccessModeResponse {
        contract_version: shared_contracts::CONTRACT_VERSION.to_string(),
        access_mode: state.access_mode().await,
    })
}

async fn set_access_mode(
    State(state): State<BridgeAppState>,
    headers: HeaderMap,
    Query(query): Query<AccessModeMutationQuery>,
) -> Result<Json<AccessModeResponse>, (StatusCode, Json<ErrorEnvelope>)> {
    let Some(access_mode) = parse_access_mode(&query.mode) else {
        return Err(error_response(
            StatusCode::BAD_REQUEST,
            "policy_access_mode_invalid",
            "invalid_access_mode",
            "Unknown access mode.",
        ));
    };
    let actor = query
        .actor
        .clone()
        .unwrap_or_else(|| "mobile-device".to_string());

    if let Some(local_session_kind) = query.local_session.as_deref() {
        if !is_allowed_local_session_request(&headers, local_session_kind) {
            state
                .record_security_audit(
                    "warn",
                    "policy",
                    "policy",
                    SecurityAuditEventDto {
                        actor,
                        action: "set_access_mode".to_string(),
                        target: "policy.access_mode".to_string(),
                        outcome: "denied".to_string(),
                        reason: "local_session_not_allowed".to_string(),
                    },
                )
                .await;
            return Err(error_response(
                StatusCode::FORBIDDEN,
                "policy_access_mode_denied",
                "local_session_not_allowed",
                "Local session access-mode changes are only allowed over a loopback bridge connection.",
            ));
        }
    } else {
        let auth_request = PairingHandshakeRequest {
            phone_id: query.phone_id.clone().unwrap_or_default(),
            bridge_id: query.bridge_id.clone().unwrap_or_default(),
            session_token: query.session_token.clone().unwrap_or_default(),
        };

        if let Err(error) = state.authorize_trusted_session(auth_request) {
            state
                .record_security_audit(
                    "warn",
                    "policy",
                    "policy",
                    SecurityAuditEventDto {
                        actor,
                        action: "set_access_mode".to_string(),
                        target: "policy.access_mode".to_string(),
                        outcome: "denied".to_string(),
                        reason: error.code().to_string(),
                    },
                )
                .await;
            return Err(pairing_handshake_error_response(error));
        }
    }

    state.set_access_mode(access_mode).await;
    state
        .record_security_audit(
            "info",
            "policy",
            "policy",
            SecurityAuditEventDto {
                actor,
                action: "set_access_mode".to_string(),
                target: "policy.access_mode".to_string(),
                outcome: "allowed".to_string(),
                reason: if let Some(local_session_kind) = query.local_session.as_deref() {
                    format!("mode={};auth={local_session_kind}", query.mode)
                } else {
                    format!("mode={};auth=paired_session", query.mode)
                },
            },
        )
        .await;

    Ok(Json(AccessModeResponse {
        contract_version: shared_contracts::CONTRACT_VERSION.to_string(),
        access_mode,
    }))
}

async fn list_approvals(State(state): State<BridgeAppState>) -> Json<ApprovalListResponse> {
    Json(ApprovalListResponse {
        contract_version: shared_contracts::CONTRACT_VERSION.to_string(),
        approvals: state.approval_records().await,
    })
}

async fn list_security_events(State(state): State<BridgeAppState>) -> Json<SecurityEventsResponse> {
    Json(SecurityEventsResponse {
        contract_version: shared_contracts::CONTRACT_VERSION.to_string(),
        events: state.security_events_snapshot().await,
    })
}

#[derive(Debug, Deserialize)]
struct PairingFinalizeQuery {
    session_id: String,
    pairing_token: String,
    phone_id: String,
    phone_name: String,
    bridge_id: String,
}

#[derive(Debug, Deserialize)]
struct PairingHandshakeQuery {
    phone_id: String,
    bridge_id: String,
    session_token: String,
}

#[derive(Debug, Deserialize)]
struct PairingRevokeQuery {
    phone_id: Option<String>,
}

#[derive(Debug, Deserialize)]
struct AccessModeMutationQuery {
    mode: String,
    phone_id: Option<String>,
    bridge_id: Option<String>,
    session_token: Option<String>,
    local_session: Option<String>,
    actor: Option<String>,
}

fn is_allowed_local_session_request(headers: &HeaderMap, local_session_kind: &str) -> bool {
    matches!(local_session_kind, "browser_local" | "desktop_local")
        && is_loopback_host_header(headers)
}

fn is_loopback_host_header(headers: &HeaderMap) -> bool {
    let Some(host_header) = headers.get(HOST) else {
        return false;
    };
    let Ok(host_value) = host_header.to_str() else {
        return false;
    };
    let host = host_value.trim();

    if host.eq_ignore_ascii_case("localhost") || host.eq_ignore_ascii_case("127.0.0.1") {
        return true;
    }

    if host.starts_with("[::1]") {
        return true;
    }

    let without_port = host.split_once(':').map(|(value, _)| value).unwrap_or(host);
    matches!(without_port, "localhost" | "127.0.0.1" | "::1")
}

#[derive(Debug, Deserialize)]
struct NetworkSettingsMutationQuery {
    local_network_pairing_enabled: bool,
}

#[derive(Debug, Deserialize)]
struct ThreadHistoryQuery {
    before: Option<String>,
    limit: Option<usize>,
}

#[derive(Debug, Deserialize)]
struct GitBranchSwitchRequest {
    branch: String,
}

#[derive(Debug, Default, Deserialize)]
struct GitRemoteRequest {
    #[serde(default)]
    remote: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
struct ThreadGitDiffQueryParams {
    mode: Option<String>,
    path: Option<String>,
}

#[derive(Debug, Deserialize)]
struct StartTurnRequest {
    prompt: String,
    #[serde(default)]
    images: Vec<String>,
    #[serde(default)]
    model: Option<String>,
    #[serde(default, alias = "reasoning_effort")]
    effort: Option<String>,
    #[serde(default)]
    mode: Option<TurnMode>,
}

#[derive(Debug, Deserialize)]
struct UserInputResponseRequest {
    request_id: String,
    #[serde(default)]
    answers: Vec<UserInputAnswerDto>,
    #[serde(default)]
    free_text: Option<String>,
    #[serde(default)]
    model: Option<String>,
    #[serde(default, alias = "reasoning_effort")]
    effort: Option<String>,
}

#[derive(Debug, Deserialize)]
struct CreateThreadRequest {
    workspace: String,
    #[serde(default)]
    provider: Option<ProviderKind>,
    #[serde(default)]
    model: Option<String>,
}

#[derive(Debug, Deserialize)]
struct CommitActionRequest {
    #[serde(default)]
    model: Option<String>,
    #[serde(default, alias = "reasoning_effort")]
    effort: Option<String>,
}

#[derive(Debug, Deserialize)]
struct InterruptTurnRequest {
    turn_id: Option<String>,
}

async fn pairing_finalize(
    State(state): State<BridgeAppState>,
    Query(query): Query<PairingFinalizeQuery>,
) -> Result<Json<crate::pairing::PairingFinalizeResponse>, (StatusCode, Json<ErrorEnvelope>)> {
    let request = PairingFinalizeRequest {
        session_id: query.session_id,
        pairing_token: query.pairing_token,
        phone_id: query.phone_id,
        phone_name: query.phone_name,
        bridge_id: query.bridge_id,
    };

    state
        .finalize_trust(request)
        .map(Json)
        .map_err(pairing_finalize_error_response)
}

async fn pairing_handshake(
    State(state): State<BridgeAppState>,
    Query(query): Query<PairingHandshakeQuery>,
) -> Result<Json<crate::pairing::PairingHandshakeResponse>, (StatusCode, Json<ErrorEnvelope>)> {
    let request = PairingHandshakeRequest {
        phone_id: query.phone_id,
        bridge_id: query.bridge_id,
        session_token: query.session_token,
    };

    state
        .handshake(request)
        .map(Json)
        .map_err(pairing_handshake_error_response)
}

async fn pairing_revoke(
    State(state): State<BridgeAppState>,
    Query(query): Query<PairingRevokeQuery>,
) -> Result<Json<crate::pairing::PairingRevokeResponse>, (StatusCode, Json<ErrorEnvelope>)> {
    state
        .revoke_trust(query.phone_id.and_then(normalize_optional_query))
        .map(Json)
        .map_err(|error| {
            error_response(
                StatusCode::INTERNAL_SERVER_ERROR,
                "pairing_revoke_failed",
                "storage_error",
                error,
            )
        })
}

async fn pairing_trust(State(state): State<BridgeAppState>) -> Json<PairingTrustSnapshot> {
    eprintln!("bridge api pairing_trust start");
    let snapshot = state.trust_snapshot();
    eprintln!(
        "bridge api pairing_trust done trusted_devices={} trusted_sessions={}",
        snapshot.trusted_devices.len(),
        snapshot.trusted_sessions.len()
    );
    Json(snapshot)
}

async fn pairing_route(State(state): State<BridgeAppState>) -> Json<PairingRouteInventoryDto> {
    Json(state.pairing_route_health())
}

async fn get_network_settings(State(state): State<BridgeAppState>) -> Json<NetworkSettingsDto> {
    Json(state.network_settings())
}

async fn set_network_settings(
    State(state): State<BridgeAppState>,
    Query(query): Query<NetworkSettingsMutationQuery>,
) -> Result<Json<NetworkSettingsDto>, (StatusCode, Json<ErrorEnvelope>)> {
    state
        .set_local_network_pairing_enabled(query.local_network_pairing_enabled)
        .map(Json)
        .map_err(|error| {
            error_response(
                StatusCode::INTERNAL_SERVER_ERROR,
                "network_settings_update_failed",
                "storage_error",
                error,
            )
        })
}

async fn start_turn(
    State(state): State<BridgeAppState>,
    Path(thread_id): Path<String>,
    ExtractJson(request): ExtractJson<StartTurnRequest>,
) -> Result<Json<TurnMutationAcceptedDto>, (StatusCode, Json<ErrorEnvelope>)> {
    match state
        .start_turn(
            &thread_id,
            &request.prompt,
            &request.images,
            request
                .model
                .as_deref()
                .map(str::trim)
                .filter(|value| !value.is_empty()),
            request
                .effort
                .as_deref()
                .map(str::trim)
                .filter(|value| !value.is_empty()),
            request.mode.unwrap_or(TurnMode::Act),
        )
        .await
    {
        Ok(response) => Ok(Json(response)),
        Err(error) => {
            eprintln!("bridge start_turn failed for {thread_id}: {error}");
            Err(turn_error_response(&thread_id, error, "turn_start_failed"))
        }
    }
}

async fn respond_to_user_input(
    State(state): State<BridgeAppState>,
    Path(thread_id): Path<String>,
    ExtractJson(request): ExtractJson<UserInputResponseRequest>,
) -> Result<Json<TurnMutationAcceptedDto>, (StatusCode, Json<ErrorEnvelope>)> {
    match state
        .respond_to_user_input(
            &thread_id,
            &request.request_id,
            &request.answers,
            request
                .free_text
                .as_deref()
                .map(str::trim)
                .filter(|value| !value.is_empty()),
            request
                .model
                .as_deref()
                .map(str::trim)
                .filter(|value| !value.is_empty()),
            request
                .effort
                .as_deref()
                .map(str::trim)
                .filter(|value| !value.is_empty()),
        )
        .await
    {
        Ok(response) => Ok(Json(response)),
        Err(error) => Err(error_response(
            StatusCode::BAD_REQUEST,
            "user_input_response_failed",
            "invalid_user_input_response",
            error,
        )),
    }
}

async fn start_commit_action(
    State(state): State<BridgeAppState>,
    Path(thread_id): Path<String>,
    request: Option<ExtractJson<CommitActionRequest>>,
) -> Result<Json<TurnMutationAcceptedDto>, (StatusCode, Json<ErrorEnvelope>)> {
    match state.decide_policy(PolicyAction::TurnCommit).await {
        PolicyDecision::Allow => {}
        PolicyDecision::Deny { reason } | PolicyDecision::RequireApproval { reason } => {
            state
                .record_security_audit(
                    "warn",
                    "turn",
                    thread_id.clone(),
                    SecurityAuditEventDto {
                        actor: "mobile-device".to_string(),
                        action: "turn_commit".to_string(),
                        target: "thread.commit".to_string(),
                        outcome: "denied".to_string(),
                        reason: reason.to_string(),
                    },
                )
                .await;
            return Err(error_response(
                StatusCode::FORBIDDEN,
                "turn_commit_failed",
                "policy_denied",
                reason,
            ));
        }
    }

    let request = request.map(|ExtractJson(request)| request);
    let model = request
        .as_ref()
        .and_then(|value| value.model.as_deref())
        .map(str::trim)
        .filter(|value| !value.is_empty());
    let effort = request
        .as_ref()
        .and_then(|value| value.effort.as_deref())
        .map(str::trim)
        .filter(|value| !value.is_empty());

    match state.start_commit_action(&thread_id, model, effort).await {
        Ok(response) => {
            state
                .record_security_audit(
                    "info",
                    "turn",
                    thread_id.clone(),
                    SecurityAuditEventDto {
                        actor: "mobile-device".to_string(),
                        action: "turn_commit".to_string(),
                        target: "thread.commit".to_string(),
                        outcome: "allowed".to_string(),
                        reason: "policy_allow".to_string(),
                    },
                )
                .await;
            Ok(Json(response))
        }
        Err(error) => Err(git_error_response(&thread_id, error, "turn_commit_failed")),
    }
}

async fn thread_git_status(
    State(state): State<BridgeAppState>,
    Path(thread_id): Path<String>,
) -> Result<Json<crate::thread_api::GitStatusResponse>, (StatusCode, Json<ErrorEnvelope>)> {
    state
        .git_status(&thread_id)
        .await
        .map(Json)
        .map_err(|error| git_error_response(&thread_id, error, "git_status_unavailable"))
}

async fn thread_usage(
    State(state): State<BridgeAppState>,
    Path(thread_id): Path<String>,
) -> Result<Json<ThreadUsageDto>, (StatusCode, Json<ErrorEnvelope>)> {
    state
        .thread_usage(&thread_id)
        .await
        .map(Json)
        .map_err(|error| thread_usage_error_response(&thread_id, error))
}

async fn thread_git_diff(
    State(state): State<BridgeAppState>,
    Path(thread_id): Path<String>,
    Query(query): Query<ThreadGitDiffQueryParams>,
) -> Result<Json<ThreadGitDiffDto>, (StatusCode, Json<ErrorEnvelope>)> {
    let Some(raw_mode) = query.mode.as_deref() else {
        return Err(error_response(
            StatusCode::BAD_REQUEST,
            "git_diff_unavailable",
            "missing_required_query_param",
            "missing_required_query_param: mode",
        ));
    };
    let mode = match raw_mode.trim() {
        "workspace" => ThreadGitDiffMode::Workspace,
        "latest_thread_change" => ThreadGitDiffMode::LatestThreadChange,
        _ => {
            return Err(error_response(
                StatusCode::BAD_REQUEST,
                "git_diff_unavailable",
                "invalid_git_diff_mode",
                "invalid_git_diff_mode",
            ));
        }
    };

    state
        .git_diff(&thread_id, mode, query.path.as_deref())
        .await
        .map(Json)
        .map_err(|error| git_diff_error_response(&thread_id, error))
}

async fn thread_git_branch_switch(
    State(state): State<BridgeAppState>,
    Path(thread_id): Path<String>,
    ExtractJson(request): ExtractJson<GitBranchSwitchRequest>,
) -> Result<(StatusCode, Json<serde_json::Value>), (StatusCode, Json<ErrorEnvelope>)> {
    let branch = request.branch.trim();
    if branch.is_empty() {
        return Err(error_response(
            StatusCode::BAD_REQUEST,
            "git_branch_switch_failed",
            "invalid_branch",
            "Branch name cannot be empty.",
        ));
    }

    match state.decide_policy(PolicyAction::GitBranchSwitch).await {
        PolicyDecision::Deny { reason } => {
            record_policy_denied(
                &state,
                &thread_id,
                "git_branch_switch",
                "git.branch_switch",
                reason,
            )
            .await;
            Err(error_response(
                StatusCode::FORBIDDEN,
                "git_branch_switch_failed",
                "policy_denied",
                reason,
            ))
        }
        PolicyDecision::RequireApproval { reason } => {
            let response = state
                .queue_git_approval(
                    crate::server::controls::PendingApprovalAction::BranchSwitch {
                        thread_id: thread_id.clone(),
                        branch: branch.to_string(),
                    },
                    reason,
                )
                .await
                .map_err(|error| {
                    git_error_response(&thread_id, error, "git_branch_switch_failed")
                })?;
            state
                .record_security_audit(
                    "warn",
                    "git",
                    thread_id.clone(),
                    SecurityAuditEventDto {
                        actor: "mobile-device".to_string(),
                        action: response.approval.action.clone(),
                        target: response.approval.target.clone(),
                        outcome: "gated".to_string(),
                        reason: reason.to_string(),
                    },
                )
                .await;
            Ok((
                StatusCode::ACCEPTED,
                Json(serde_json::to_value(response).expect("approval gate should serialize")),
            ))
        }
        PolicyDecision::Allow => {
            let response = state
                .execute_git_branch_switch(&thread_id, branch)
                .await
                .map_err(|error| {
                    git_error_response(&thread_id, error, "git_branch_switch_failed")
                })?;
            state
                .record_security_audit(
                    "info",
                    "git",
                    thread_id.clone(),
                    SecurityAuditEventDto {
                        actor: "mobile-device".to_string(),
                        action: "git_branch_switch".to_string(),
                        target: "git.branch_switch".to_string(),
                        outcome: "allowed".to_string(),
                        reason: "policy_allow".to_string(),
                    },
                )
                .await;
            Ok((
                StatusCode::OK,
                Json(serde_json::to_value(response).expect("mutation result should serialize")),
            ))
        }
    }
}

async fn thread_git_pull(
    State(state): State<BridgeAppState>,
    Path(thread_id): Path<String>,
    ExtractJson(request): ExtractJson<GitRemoteRequest>,
) -> Result<(StatusCode, Json<serde_json::Value>), (StatusCode, Json<ErrorEnvelope>)> {
    handle_git_remote_mutation(
        state,
        thread_id,
        request.remote,
        PolicyAction::GitPull,
        "git_pull",
        "git.pull",
    )
    .await
}

async fn thread_git_push(
    State(state): State<BridgeAppState>,
    Path(thread_id): Path<String>,
    ExtractJson(request): ExtractJson<GitRemoteRequest>,
) -> Result<(StatusCode, Json<serde_json::Value>), (StatusCode, Json<ErrorEnvelope>)> {
    handle_git_remote_mutation(
        state,
        thread_id,
        request.remote,
        PolicyAction::GitPush,
        "git_push",
        "git.push",
    )
    .await
}

async fn create_thread(
    State(state): State<BridgeAppState>,
    ExtractJson(request): ExtractJson<CreateThreadRequest>,
) -> Result<Json<ThreadSnapshotDto>, StatusCode> {
    match state
        .create_thread(
            request.provider.unwrap_or(ProviderKind::Codex),
            &request.workspace,
            request.model.as_deref(),
        )
        .await
    {
        Ok(snapshot) => Ok(Json(snapshot)),
        Err(error) => {
            eprintln!(
                "bridge create_thread failed for workspace {}: {error}",
                request.workspace
            );
            Err(StatusCode::BAD_GATEWAY)
        }
    }
}

async fn interrupt_turn(
    State(state): State<BridgeAppState>,
    Path(thread_id): Path<String>,
    request: Option<ExtractJson<InterruptTurnRequest>>,
) -> Result<Json<TurnMutationAcceptedDto>, (StatusCode, Json<ErrorEnvelope>)> {
    let turn_id = request
        .as_ref()
        .and_then(|ExtractJson(request)| request.turn_id.as_deref());
    match state.interrupt_turn(&thread_id, turn_id).await {
        Ok(response) => Ok(Json(response)),
        Err(error) => {
            eprintln!("bridge interrupt_turn failed for {thread_id}: {error}");
            Err(turn_error_response(
                &thread_id,
                error,
                "turn_interrupt_failed",
            ))
        }
    }
}

async fn thread_history(
    State(state): State<BridgeAppState>,
    Path(thread_id): Path<String>,
    Query(query): Query<ThreadHistoryQuery>,
) -> Result<Json<ThreadTimelinePageDto>, StatusCode> {
    let limit = query.limit.unwrap_or(50);
    match state
        .timeline_page(&thread_id, query.before.as_deref(), limit)
        .await
    {
        Ok(page) => Ok(Json(page)),
        Err(_) => Err(StatusCode::NOT_FOUND),
    }
}

async fn approve_approval(
    State(state): State<BridgeAppState>,
    Path(approval_id): Path<String>,
) -> Result<Json<ApprovalResolutionResponse>, (StatusCode, Json<ErrorEnvelope>)> {
    resolve_approval(state, approval_id, true).await
}

async fn reject_approval(
    State(state): State<BridgeAppState>,
    Path(approval_id): Path<String>,
) -> Result<Json<ApprovalResolutionResponse>, (StatusCode, Json<ErrorEnvelope>)> {
    resolve_approval(state, approval_id, false).await
}

async fn events(
    ws: WebSocketUpgrade,
    State(state): State<BridgeAppState>,
    Query(query): Query<EventSubscriptionQuery>,
) -> Response {
    let receiver = state.event_hub().subscribe();
    let after_event_id = query.after_event_id.clone();
    let scope = query.into_scope();
    let replay_snapshot = match &scope {
        crate::server::events::EventSubscriptionScope::Thread(thread_id) => {
            state.projections().snapshot(thread_id).await
        }
        crate::server::events::EventSubscriptionScope::List => None,
    };
    let replay_events =
        replay_events_for_scope(replay_snapshot.as_ref(), &scope, after_event_id.as_deref());
    ws.on_upgrade(move |socket| stream_events(socket, receiver, scope, replay_events))
}

#[derive(Debug, Serialize)]
struct ErrorEnvelope {
    error: String,
    code: String,
    message: String,
}

#[derive(Debug, Serialize)]
struct AccessModeResponse {
    contract_version: String,
    access_mode: AccessMode,
}

#[derive(Debug, Serialize)]
struct ApprovalListResponse {
    contract_version: String,
    approvals: Vec<ApprovalRecordDto>,
}

#[derive(Debug, Serialize)]
struct SecurityEventsResponse {
    contract_version: String,
    events: Vec<crate::server::state::SecurityEventRecordDto>,
}

async fn handle_git_remote_mutation(
    state: BridgeAppState,
    thread_id: String,
    remote: Option<String>,
    action: PolicyAction,
    action_name: &str,
    target: &str,
) -> Result<(StatusCode, Json<serde_json::Value>), (StatusCode, Json<ErrorEnvelope>)> {
    match state.decide_policy(action).await {
        PolicyDecision::Deny { reason } => {
            record_policy_denied(&state, &thread_id, action_name, target, reason).await;
            Err(error_response(
                StatusCode::FORBIDDEN,
                format!("{action_name}_failed"),
                "policy_denied",
                reason,
            ))
        }
        PolicyDecision::RequireApproval { reason } => {
            let response = state
                .queue_git_approval(
                    match action {
                        PolicyAction::GitPull => {
                            crate::server::controls::PendingApprovalAction::Pull {
                                thread_id: thread_id.clone(),
                                remote: remote
                                    .clone()
                                    .map(|value| value.trim().to_string())
                                    .filter(|value| !value.is_empty()),
                            }
                        }
                        PolicyAction::GitPush => {
                            crate::server::controls::PendingApprovalAction::Push {
                                thread_id: thread_id.clone(),
                                remote: remote
                                    .clone()
                                    .map(|value| value.trim().to_string())
                                    .filter(|value| !value.is_empty()),
                            }
                        }
                        _ => unreachable!("only pull and push use this helper"),
                    },
                    reason,
                )
                .await
                .map_err(|error| {
                    git_error_response(&thread_id, error, format!("{action_name}_failed"))
                })?;
            state
                .record_security_audit(
                    "warn",
                    "git",
                    thread_id.clone(),
                    SecurityAuditEventDto {
                        actor: "mobile-device".to_string(),
                        action: response.approval.action.clone(),
                        target: response.approval.target.clone(),
                        outcome: "gated".to_string(),
                        reason: reason.to_string(),
                    },
                )
                .await;
            Ok((
                StatusCode::ACCEPTED,
                Json(serde_json::to_value(response).expect("approval gate should serialize")),
            ))
        }
        PolicyDecision::Allow => {
            let response = match action {
                PolicyAction::GitPull => {
                    state.execute_git_pull(&thread_id, remote.as_deref()).await
                }
                PolicyAction::GitPush => {
                    state.execute_git_push(&thread_id, remote.as_deref()).await
                }
                _ => unreachable!("only pull and push use this helper"),
            }
            .map_err(|error| {
                git_error_response(&thread_id, error, format!("{action_name}_failed"))
            })?;
            state
                .record_security_audit(
                    "info",
                    "git",
                    thread_id.clone(),
                    SecurityAuditEventDto {
                        actor: "mobile-device".to_string(),
                        action: action_name.to_string(),
                        target: target.to_string(),
                        outcome: "allowed".to_string(),
                        reason: "policy_allow".to_string(),
                    },
                )
                .await;
            Ok((
                StatusCode::OK,
                Json(serde_json::to_value(response).expect("mutation result should serialize")),
            ))
        }
    }
}

async fn resolve_approval(
    state: BridgeAppState,
    approval_id: String,
    approved: bool,
) -> Result<Json<ApprovalResolutionResponse>, (StatusCode, Json<ErrorEnvelope>)> {
    match state.decide_policy(PolicyAction::ApprovalResolve).await {
        PolicyDecision::Allow => {}
        PolicyDecision::Deny { reason } | PolicyDecision::RequireApproval { reason } => {
            state
                .record_security_audit(
                    "warn",
                    "approval",
                    "approval",
                    SecurityAuditEventDto {
                        actor: "mobile-device".to_string(),
                        action: if approved {
                            "approval_approve".to_string()
                        } else {
                            "approval_reject".to_string()
                        },
                        target: "approval.resolve".to_string(),
                        outcome: "denied".to_string(),
                        reason: reason.to_string(),
                    },
                )
                .await;
            return Err(error_response(
                StatusCode::FORBIDDEN,
                "approval_resolution_failed",
                "policy_denied",
                reason,
            ));
        }
    }

    let response = state
        .resolve_approval(&approval_id, approved)
        .await
        .map_err(|error| match error {
            crate::server::state::ResolveApprovalError::NotFound => error_response(
                StatusCode::NOT_FOUND,
                "approval_resolution_failed",
                "approval_not_found",
                "Approval request was not found.",
            ),
            crate::server::state::ResolveApprovalError::NotPending => error_response(
                StatusCode::CONFLICT,
                "approval_resolution_failed",
                "approval_not_pending",
                "Approval is no longer actionable.",
            ),
            crate::server::state::ResolveApprovalError::TargetNotFound => error_response(
                StatusCode::NOT_FOUND,
                "approval_resolution_failed",
                "approval_target_not_found",
                "The target thread for this approval is no longer available.",
            ),
            crate::server::state::ResolveApprovalError::MutationFailed(message) => error_response(
                StatusCode::BAD_REQUEST,
                "approval_resolution_failed",
                "git_mutation_failed",
                message,
            ),
        })?;

    state
        .record_security_audit(
            if approved { "info" } else { "warn" },
            "approval",
            response.approval.thread_id.clone(),
            SecurityAuditEventDto {
                actor: "mobile-device".to_string(),
                action: if approved {
                    "approval_approve".to_string()
                } else {
                    "approval_reject".to_string()
                },
                target: response.approval.target.clone(),
                outcome: if approved {
                    "allowed".to_string()
                } else {
                    "rejected".to_string()
                },
                reason: if approved {
                    "approval_resolved".to_string()
                } else {
                    "approval_rejected".to_string()
                },
            },
        )
        .await;
    Ok(Json(response))
}

async fn record_policy_denied(
    state: &BridgeAppState,
    thread_id: &str,
    action: &str,
    target: &str,
    reason: &str,
) {
    state
        .record_security_audit(
            "warn",
            "git",
            thread_id,
            SecurityAuditEventDto {
                actor: "mobile-device".to_string(),
                action: action.to_string(),
                target: target.to_string(),
                outcome: "denied".to_string(),
                reason: reason.to_string(),
            },
        )
        .await;
}

fn git_error_response(
    thread_id: &str,
    message: String,
    error_name: impl Into<String>,
) -> (StatusCode, Json<ErrorEnvelope>) {
    if message.contains("thread ") && message.contains(" not found") {
        return error_response(
            StatusCode::NOT_FOUND,
            error_name,
            "thread_not_found",
            message,
        );
    }

    error_response(
        StatusCode::BAD_REQUEST,
        error_name,
        "git_operation_failed",
        format!("{thread_id}: {message}"),
    )
}

fn thread_usage_error_response(
    thread_id: &str,
    error: CodexUsageError,
) -> (StatusCode, Json<ErrorEnvelope>) {
    let status = match &error {
        CodexUsageError::AuthUnavailable(_) => StatusCode::SERVICE_UNAVAILABLE,
        CodexUsageError::UpstreamUnavailable(message)
            if message.contains("thread ") && message.contains(" not found") =>
        {
            StatusCode::NOT_FOUND
        }
        CodexUsageError::UpstreamUnavailable(_) => StatusCode::BAD_GATEWAY,
        CodexUsageError::InvalidResponse(_) => StatusCode::BAD_GATEWAY,
    };

    error_response(
        status,
        "thread_usage_unavailable",
        error.code(),
        format!("{thread_id}: {}", error.message()),
    )
}

fn turn_error_response(
    thread_id: &str,
    message: String,
    error_name: impl Into<String>,
) -> (StatusCode, Json<ErrorEnvelope>) {
    if message.contains("thread ") && message.contains(" not found") {
        return error_response(
            StatusCode::NOT_FOUND,
            error_name,
            "thread_not_found",
            message,
        );
    }

    if message.contains("plan mode is not implemented for Claude Code threads yet") {
        return error_response(
            StatusCode::BAD_REQUEST,
            error_name,
            "unsupported_turn_mode",
            message,
        );
    }

    if message.contains("no active Claude turn found")
        || message.contains("no active turn found for thread")
    {
        return error_response(StatusCode::CONFLICT, error_name, "no_active_turn", message);
    }

    error_response(
        StatusCode::BAD_GATEWAY,
        error_name,
        "upstream_mutation_failed",
        format!("{thread_id}: {message}"),
    )
}

fn git_diff_error_response(thread_id: &str, message: String) -> (StatusCode, Json<ErrorEnvelope>) {
    if message.contains("thread ") && message.contains(" not found") {
        return error_response(
            StatusCode::NOT_FOUND,
            "git_diff_unavailable",
            "thread_not_found",
            message,
        );
    }

    error_response(
        StatusCode::UNPROCESSABLE_ENTITY,
        "git_diff_unavailable",
        "git_diff_unavailable",
        format!("{thread_id}: {message}"),
    )
}

fn parse_access_mode(raw: &str) -> Option<AccessMode> {
    match raw {
        "read_only" => Some(AccessMode::ReadOnly),
        "control_with_approvals" => Some(AccessMode::ControlWithApprovals),
        "full_control" => Some(AccessMode::FullControl),
        _ => None,
    }
}

fn error_response(
    status: StatusCode,
    error: impl Into<String>,
    code: impl Into<String>,
    message: impl Into<String>,
) -> (StatusCode, Json<ErrorEnvelope>) {
    (
        status,
        Json(ErrorEnvelope {
            error: error.into(),
            code: code.into(),
            message: message.into(),
        }),
    )
}

fn pairing_finalize_error_response(
    error: PairingFinalizeError,
) -> (StatusCode, Json<ErrorEnvelope>) {
    let status = match error {
        PairingFinalizeError::UnknownPairingSession
        | PairingFinalizeError::InvalidPairingToken
        | PairingFinalizeError::PairingSessionExpired => StatusCode::BAD_REQUEST,
        PairingFinalizeError::SessionAlreadyConsumed
        | PairingFinalizeError::TrustedPhoneConflict => StatusCode::CONFLICT,
        PairingFinalizeError::BridgeIdentityMismatch
        | PairingFinalizeError::PrivateBridgePathRequired => StatusCode::FORBIDDEN,
        PairingFinalizeError::Storage(_) => StatusCode::INTERNAL_SERVER_ERROR,
    };

    error_response(
        status,
        "pairing_finalize_failed",
        error.code(),
        error.message(),
    )
}

fn pairing_handshake_error_response(
    error: PairingHandshakeError,
) -> (StatusCode, Json<ErrorEnvelope>) {
    error_response(
        StatusCode::FORBIDDEN,
        "pairing_handshake_failed",
        error.code(),
        error.message(),
    )
}

fn speech_error_response(
    error: crate::server::speech::SpeechError,
) -> (StatusCode, Json<ErrorEnvelope>) {
    error_response(
        error.status_code(),
        error.error(),
        error.code(),
        error.message(),
    )
}

fn normalize_optional_query(value: String) -> Option<String> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::path::{Path, PathBuf};
    use std::process::Command;
    use std::sync::Arc;

    use async_trait::async_trait;
    use axum::Json as AxumJson;
    use axum::Router as AxumRouter;
    use axum::body::Body;
    use axum::http::Request;
    use axum::http::StatusCode;
    use axum::routing::get as axum_get;
    use serde_json::Value;
    use serde_json::json;
    use tokio::net::TcpListener;
    use tower::util::ServiceExt;

    use super::router;
    use crate::pairing::PairingFinalizeRequest;
    use crate::server::codex_usage::CodexUsageClient;
    use crate::server::config::{BridgeCodexConfig, BridgeConfig};
    use crate::server::pairing_route::PairingRouteState;
    use crate::server::speech::{SpeechBackend, SpeechError, SpeechService};
    use crate::server::state::BridgeAppState;
    use shared_contracts::{
        AccessMode, SpeechModelStateDto, SpeechModelStatusDto, SpeechTranscriptionResultDto,
        ThreadSnapshotDto, ThreadSummaryDto, ThreadUsageDto,
    };

    #[tokio::test]
    async fn bootstrap_route_returns_bridge_contract() {
        let app = router(test_state());
        let response = app
            .oneshot(
                Request::builder()
                    .uri("/bootstrap")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .expect("request should succeed");

        assert_eq!(response.status(), 200);
    }

    #[tokio::test]
    async fn model_catalog_route_returns_bridge_contract() {
        let app = router(test_state());
        let response = app
            .oneshot(
                Request::builder()
                    .uri("/models")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .expect("request should succeed");

        assert_eq!(response.status(), 200);
    }

    #[tokio::test]
    async fn thread_usage_route_returns_usage_payload() {
        let state = test_state();
        let repo_dir = unique_temp_dir("bridge-usage-route-repo");
        prime_thread(
            &state,
            "codex:thread-usage",
            &repo_dir,
            AccessMode::FullControl,
        )
        .await;

        let auth_path = unique_temp_dir("bridge-usage-auth").join("auth.json");
        std::fs::create_dir_all(
            auth_path
                .parent()
                .expect("auth path should have a parent directory"),
        )
        .expect("auth parent directory should create");
        std::fs::write(
            &auth_path,
            serde_json::to_vec(&json!({
                "tokens": {
                    "access_token": "route-test-token"
                }
            }))
            .expect("auth body should encode"),
        )
        .expect("auth body should write");

        let usage_listener = TcpListener::bind(("127.0.0.1", 0))
            .await
            .expect("usage listener should bind");
        let usage_addr = usage_listener
            .local_addr()
            .expect("usage listener addr should resolve");
        let usage_app = AxumRouter::new().route(
            "/backend-api/wham/usage",
            axum_get(|| async {
                AxumJson(json!({
                    "plan_type": "pro",
                    "rate_limit": {
                        "primary_window": {
                            "used_percent": 6,
                            "limit_window_seconds": 18000,
                            "reset_after_seconds": 12223,
                            "reset_at": 1774996694
                        },
                        "secondary_window": {
                            "used_percent": 42,
                            "limit_window_seconds": 604800,
                            "reset_after_seconds": 213053,
                            "reset_at": 1775197525
                        }
                    }
                }))
            }),
        );
        let usage_server = tokio::spawn(async move {
            axum::serve(usage_listener, usage_app)
                .await
                .expect("usage server should run");
        });

        state
            .set_codex_usage_client_for_tests(CodexUsageClient::new(
                auth_path,
                format!("http://{usage_addr}/backend-api/wham/usage"),
            ))
            .await;

        let app = router(state);
        let response = app
            .oneshot(
                Request::builder()
                    .uri("/threads/codex%3Athread-usage/usage")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .expect("request should succeed");

        assert_eq!(response.status(), StatusCode::OK);
        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .expect("body should read");
        let decoded: ThreadUsageDto = serde_json::from_slice(&body).expect("body should decode");
        assert_eq!(decoded.thread_id, "codex:thread-usage");
        assert_eq!(decoded.plan_type.as_deref(), Some("pro"));
        assert_eq!(decoded.primary_window.used_percent, 6);
        assert_eq!(
            decoded
                .secondary_window
                .as_ref()
                .expect("secondary window should exist")
                .used_percent,
            42
        );

        usage_server.abort();
    }

    #[tokio::test]
    async fn speech_model_route_returns_status_payload() {
        let app = router(test_state_with_speech_service(
            SpeechService::new_for_tests(
                Arc::new(StubSpeechBackend {
                    status: SpeechModelStatusDto {
                        contract_version: shared_contracts::CONTRACT_VERSION.to_string(),
                        provider: "fluid_audio".to_string(),
                        model_id: "parakeet-tdt-0.6b-v3-coreml".to_string(),
                        state: SpeechModelStateDto::Ready,
                        download_progress: None,
                        last_error: None,
                        installed_bytes: Some(123),
                    },
                    transcription: None,
                }),
                std::env::temp_dir().join("bridge-speech-test-tmp"),
                SpeechModelStatusDto {
                    contract_version: shared_contracts::CONTRACT_VERSION.to_string(),
                    provider: "fluid_audio".to_string(),
                    model_id: "parakeet-tdt-0.6b-v3-coreml".to_string(),
                    state: SpeechModelStateDto::Ready,
                    download_progress: None,
                    last_error: None,
                    installed_bytes: Some(123),
                },
            ),
        ));

        let response = app
            .oneshot(
                Request::builder()
                    .uri("/speech/models/parakeet")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .expect("request should succeed");

        assert_eq!(response.status(), StatusCode::OK);
        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .expect("body should read");
        let decoded: Value = serde_json::from_slice(&body).expect("body should decode");
        assert_eq!(decoded["state"], "ready");
        assert_eq!(decoded["installed_bytes"], 123);
    }

    #[tokio::test]
    async fn speech_transcription_route_rejects_non_wav_upload() {
        let app = router(test_state());
        let boundary = "speech-boundary";
        let body = format!(
            "--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"voice.txt\"\r\nContent-Type: text/plain\r\n\r\nnot wav\r\n--{boundary}--\r\n"
        );
        let response = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/speech/transcriptions")
                    .header(
                        "content-type",
                        format!("multipart/form-data; boundary={boundary}"),
                    )
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .expect("request should succeed");

        assert_eq!(response.status(), StatusCode::BAD_REQUEST);
        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .expect("body should read");
        let decoded: Value = serde_json::from_slice(&body).expect("body should decode");
        assert_eq!(decoded["code"], "speech_invalid_audio");
    }

    #[tokio::test]
    async fn speech_transcription_route_returns_transcript_for_wav_upload() {
        let app = router(test_state_with_speech_service(
            SpeechService::new_for_tests(
                Arc::new(StubSpeechBackend {
                    status: SpeechModelStatusDto {
                        contract_version: shared_contracts::CONTRACT_VERSION.to_string(),
                        provider: "fluid_audio".to_string(),
                        model_id: "parakeet-tdt-0.6b-v3-coreml".to_string(),
                        state: SpeechModelStateDto::Ready,
                        download_progress: None,
                        last_error: None,
                        installed_bytes: Some(456),
                    },
                    transcription: Some(SpeechTranscriptionResultDto {
                        contract_version: shared_contracts::CONTRACT_VERSION.to_string(),
                        provider: "fluid_audio".to_string(),
                        model_id: "parakeet-tdt-0.6b-v3-coreml".to_string(),
                        text: "transcribed text".to_string(),
                        duration_ms: 987,
                    }),
                }),
                std::env::temp_dir().join("bridge-speech-test-tmp-success"),
                SpeechModelStatusDto {
                    contract_version: shared_contracts::CONTRACT_VERSION.to_string(),
                    provider: "fluid_audio".to_string(),
                    model_id: "parakeet-tdt-0.6b-v3-coreml".to_string(),
                    state: SpeechModelStateDto::Ready,
                    download_progress: None,
                    last_error: None,
                    installed_bytes: Some(456),
                },
            ),
        ));
        let boundary = "speech-boundary";
        let mut wav_body = Vec::new();
        wav_body.extend_from_slice(
            format!(
                "--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"voice-message.wav\"\r\nContent-Type: audio/wav\r\n\r\n"
            )
            .as_bytes(),
        );
        wav_body.extend_from_slice(&fake_wav_bytes());
        wav_body.extend_from_slice(format!("\r\n--{boundary}--\r\n").as_bytes());

        let response = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/speech/transcriptions")
                    .header(
                        "content-type",
                        format!("multipart/form-data; boundary={boundary}"),
                    )
                    .body(Body::from(wav_body))
                    .unwrap(),
            )
            .await
            .expect("request should succeed");

        assert_eq!(response.status(), StatusCode::OK);
        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .expect("body should read");
        let decoded: Value = serde_json::from_slice(&body).expect("body should decode");
        assert_eq!(decoded["text"], "transcribed text");
        assert_eq!(decoded["duration_ms"], 987);
    }

    #[test]
    fn start_turn_request_accepts_model_and_effort_aliases() {
        let request: super::StartTurnRequest = serde_json::from_value(json!({
            "prompt": "Ship model propagation",
            "model": "gpt-5-mini",
            "reasoning_effort": "high",
        }))
        .expect("request should deserialize");

        assert_eq!(request.prompt, "Ship model propagation");
        assert!(request.images.is_empty());
        assert_eq!(request.model.as_deref(), Some("gpt-5-mini"));
        assert_eq!(request.effort.as_deref(), Some("high"));
    }

    #[test]
    fn start_turn_request_accepts_image_attachments() {
        let request: super::StartTurnRequest = serde_json::from_value(json!({
            "prompt": "",
            "images": ["data:image/png;base64,AAA"],
        }))
        .expect("request should deserialize");

        assert_eq!(request.prompt, "");
        assert_eq!(request.images, vec!["data:image/png;base64,AAA"]);
    }

    #[test]
    fn commit_action_request_accepts_effort_alias() {
        let request: super::CommitActionRequest = serde_json::from_value(json!({
            "model": "gpt-5-mini",
            "reasoning_effort": "high",
        }))
        .expect("request should deserialize");

        assert_eq!(request.model.as_deref(), Some("gpt-5-mini"));
        assert_eq!(request.effort.as_deref(), Some("high"));
    }

    #[tokio::test]
    async fn pairing_session_route_returns_qr_payload() {
        let app = router(test_state());
        let response = app
            .oneshot(
                Request::builder()
                    .uri("/pairing/session")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .expect("request should succeed");

        assert_eq!(response.status(), 200);
        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .expect("body should read");
        let decoded: Value = serde_json::from_slice(&body).expect("body should decode");
        assert!(
            decoded["bridge_identity"]["display_name"]
                .as_str()
                .is_some_and(|value| !value.trim().is_empty())
        );
        assert_eq!(
            decoded["bridge_identity"]["api_base_url"],
            "https://bridge.ts.net"
        );
        assert!(decoded["qr_payload"].as_str().is_some());
    }

    #[tokio::test]
    async fn pairing_finalize_and_handshake_round_trip() {
        let state = test_state();
        let issued = state.issue_pairing_session();
        let finalize = state
            .finalize_trust(PairingFinalizeRequest {
                session_id: issued.pairing_session.session_id.clone(),
                pairing_token: issued.pairing_session.pairing_token.clone(),
                phone_id: "phone-1".to_string(),
                phone_name: "iPhone".to_string(),
                bridge_id: issued.bridge_identity.bridge_id.clone(),
            })
            .expect("finalize should succeed");

        let app = router(state);
        let handshake_uri = format!(
            "/pairing/handshake?phone_id=phone-1&bridge_id={}&session_token={}",
            issued.bridge_identity.bridge_id, finalize.session_token
        );
        let response = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(handshake_uri)
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .expect("request should succeed");

        assert_eq!(response.status(), 200);
        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .expect("body should read");
        let decoded: Value = serde_json::from_slice(&body).expect("body should decode");
        assert_eq!(decoded["status"], "trusted");
        assert_eq!(
            decoded["bridge_identity"]["bridge_id"],
            issued.bridge_identity.bridge_id
        );
        assert!(
            decoded["bridge_identity"]["display_name"]
                .as_str()
                .is_some_and(|value| !value.trim().is_empty())
        );
    }

    #[tokio::test]
    async fn access_mode_routes_support_read_and_trusted_write() {
        let state = test_state();
        let issued = state.issue_pairing_session();
        let finalize = state
            .finalize_trust(PairingFinalizeRequest {
                session_id: issued.pairing_session.session_id.clone(),
                pairing_token: issued.pairing_session.pairing_token.clone(),
                phone_id: "phone-1".to_string(),
                phone_name: "iPhone".to_string(),
                bridge_id: issued.bridge_identity.bridge_id.clone(),
            })
            .expect("finalize should succeed");
        let app = router(state);

        let read_response = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri("/policy/access-mode")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .expect("read request should succeed");

        assert_eq!(read_response.status(), 200);
        let read_body = axum::body::to_bytes(read_response.into_body(), usize::MAX)
            .await
            .expect("body should read");
        let read_json: Value = serde_json::from_slice(&read_body).expect("body should decode");
        assert_eq!(read_json["access_mode"], "control_with_approvals");

        let write_uri = format!(
            "/policy/access-mode?mode=full_control&phone_id=phone-1&bridge_id={}&session_token={}&actor=mobile-settings",
            issued.bridge_identity.bridge_id, finalize.session_token
        );
        let write_response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(write_uri)
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .expect("write request should succeed");

        assert_eq!(write_response.status(), 200);
        let write_body = axum::body::to_bytes(write_response.into_body(), usize::MAX)
            .await
            .expect("body should read");
        let write_json: Value = serde_json::from_slice(&write_body).expect("body should decode");
        assert_eq!(write_json["access_mode"], "full_control");

        let security_response = app
            .oneshot(
                Request::builder()
                    .uri("/security/events")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .expect("security request should succeed");

        assert_eq!(security_response.status(), 200);
        let security_body = axum::body::to_bytes(security_response.into_body(), usize::MAX)
            .await
            .expect("body should read");
        let security_json: Value =
            serde_json::from_slice(&security_body).expect("body should decode");
        let events = security_json["events"]
            .as_array()
            .expect("events should be an array");
        assert_eq!(events.len(), 1);
        assert_eq!(events[0]["category"], "policy");
        assert_eq!(
            events[0]["event"]["payload"]["reason"],
            "mode=full_control;auth=paired_session"
        );
    }

    #[tokio::test]
    async fn git_status_route_returns_live_repo_state() {
        let sandbox = GitRepoSandbox::new("status-live");
        sandbox.commit_local("local ahead");
        sandbox.commit_remote("remote behind");
        run_git(&sandbox.repo_dir, ["fetch", "origin"]);
        fs::write(sandbox.repo_dir.join("dirty.txt"), "dirty change\n")
            .expect("dirty file should write");

        let state = test_state();
        prime_thread(
            &state,
            "thread-123",
            &sandbox.repo_dir,
            AccessMode::FullControl,
        )
        .await;
        let app = router(state);

        let response = app
            .oneshot(
                Request::builder()
                    .uri("/threads/thread-123/git/status")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .expect("request should succeed");

        assert_eq!(response.status(), 200);
        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .expect("body should read");
        let decoded: Value = serde_json::from_slice(&body).expect("body should decode");
        assert_eq!(decoded["repository"]["branch"], "main");
        assert_eq!(decoded["repository"]["remote"], "origin");
        assert_eq!(decoded["status"]["dirty"], true);
        assert_eq!(decoded["status"]["ahead_by"], 1);
        assert_eq!(decoded["status"]["behind_by"], 1);
    }

    #[tokio::test]
    async fn git_status_route_degrades_non_repo_workspace_into_unavailable_context() {
        let workspace = unique_temp_dir("status-non-repo");
        let state = test_state();
        prime_thread(&state, "thread-123", &workspace, AccessMode::FullControl).await;
        let app = router(state);

        let response = app
            .oneshot(
                Request::builder()
                    .uri("/threads/thread-123/git/status")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .expect("request should succeed");

        assert_eq!(response.status(), 200);
        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .expect("body should read");
        let decoded: Value = serde_json::from_slice(&body).expect("body should decode");
        assert_eq!(
            decoded["repository"]["workspace"].as_str(),
            Some(workspace.to_string_lossy().as_ref())
        );
        assert_eq!(decoded["repository"]["repository"], "unknown-repository");
        assert_eq!(decoded["repository"]["branch"], "unknown");
        assert_eq!(decoded["repository"]["remote"], "local");
        assert_eq!(decoded["status"]["dirty"], false);
        assert_eq!(decoded["status"]["ahead_by"], 0);
        assert_eq!(decoded["status"]["behind_by"], 0);
        let _ = fs::remove_dir_all(workspace);
    }

    #[tokio::test]
    async fn git_diff_route_returns_workspace_diff() {
        let sandbox = GitRepoSandbox::new("diff-live");
        fs::write(sandbox.repo_dir.join("dirty.txt"), "dirty change\n")
            .expect("dirty file should write");

        let state = test_state();
        prime_thread(
            &state,
            "thread-123",
            &sandbox.repo_dir,
            AccessMode::FullControl,
        )
        .await;
        let app = router(state);

        let response = app
            .oneshot(
                Request::builder()
                    .uri("/threads/thread-123/git/diff?mode=workspace")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .expect("request should succeed");

        assert_eq!(response.status(), 200);
        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .expect("body should read");
        let decoded: Value = serde_json::from_slice(&body).expect("body should decode");
        assert_eq!(decoded["mode"], "workspace");
        assert!(
            decoded["unified_diff"]
                .as_str()
                .unwrap_or_default()
                .contains("dirty.txt")
        );
        assert_eq!(decoded["files"][0]["path"], "dirty.txt");
    }

    #[tokio::test]
    async fn git_diff_route_returns_latest_thread_change_diff() {
        let state = test_state();
        let sandbox = GitRepoSandbox::new("diff-latest");
        prime_thread(
            &state,
            "019d174b-f678-7762-af1b-7c1f1910a056",
            &sandbox.repo_dir,
            AccessMode::FullControl,
        )
        .await;
        let mut snapshot = state
            .projections()
            .snapshot("019d174b-f678-7762-af1b-7c1f1910a056")
            .await
            .expect("snapshot should exist");
        snapshot.entries = vec![shared_contracts::ThreadTimelineEntryDto {
            event_id: "evt-diff".to_string(),
            kind: shared_contracts::BridgeEventKind::FileChange,
            occurred_at: "2026-03-21T09:01:00Z".to_string(),
            summary: "diff".to_string(),
            payload: json!({
                "resolved_unified_diff": "diff --git a/lib/main.dart b/lib/main.dart\n--- a/lib/main.dart\n+++ b/lib/main.dart\n@@ -1 +1 @@\n-old\n+new"
            }),
            annotations: None,
        }];
        state.projections().put_snapshot(snapshot.clone()).await;
        let app = router(state);

        let response = app
            .oneshot(
                Request::builder()
                    .uri(
                        "/threads/019d174b-f678-7762-af1b-7c1f1910a056/git/diff?mode=latest_thread_change",
                    )
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .expect("request should succeed");

        assert_eq!(response.status(), 200);
        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .expect("body should read");
        let decoded: Value = serde_json::from_slice(&body).expect("body should decode");
        assert_eq!(decoded["mode"], "latest_thread_change");
        assert!(
            decoded["unified_diff"]
                .as_str()
                .unwrap_or_default()
                .contains("lib/main.dart")
        );
        assert_eq!(decoded["files"][0]["path"], "lib/main.dart");
    }

    #[tokio::test]
    async fn full_control_branch_switch_route_returns_product_shape() {
        let sandbox = GitRepoSandbox::new("branch-switch");
        run_git(&sandbox.repo_dir, ["checkout", "-b", "release/2026"]);
        run_git(&sandbox.repo_dir, ["checkout", "main"]);

        let state = test_state();
        prime_thread(
            &state,
            "thread-123",
            &sandbox.repo_dir,
            AccessMode::FullControl,
        )
        .await;
        let app = router(state);

        let response = app
            .oneshot(json_request(
                "POST",
                "/threads/thread-123/git/branch-switch",
                json!({"branch":"release/2026"}),
            ))
            .await
            .expect("request should succeed");

        assert_eq!(response.status(), 200);
        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .expect("body should read");
        let decoded: Value = serde_json::from_slice(&body).expect("body should decode");
        assert_eq!(decoded["operation"], "git_branch_switch");
        assert_eq!(decoded["repository"]["branch"], "release/2026");
        assert_eq!(decoded["message"], "Switched branch to release/2026");
    }

    #[tokio::test]
    async fn control_with_approvals_gates_pull_until_approval_resolution() {
        let sandbox = GitRepoSandbox::new("pull-approval");
        sandbox.commit_remote("remote change");
        run_git(&sandbox.repo_dir, ["fetch", "origin"]);

        let state = test_state();
        prime_thread(
            &state,
            "thread-123",
            &sandbox.repo_dir,
            AccessMode::ControlWithApprovals,
        )
        .await;
        let app = router(state.clone());

        let gated = app
            .clone()
            .oneshot(json_request(
                "POST",
                "/threads/thread-123/git/pull",
                json!({}),
            ))
            .await
            .expect("request should succeed");

        assert_eq!(gated.status(), 202);
        let gated_body = axum::body::to_bytes(gated.into_body(), usize::MAX)
            .await
            .expect("body should read");
        let gated_json: Value = serde_json::from_slice(&gated_body).expect("body should decode");
        let approval_id = gated_json["approval"]["approval_id"]
            .as_str()
            .expect("approval id should exist")
            .to_string();
        assert_eq!(gated_json["outcome"], "approval_required");
        assert_eq!(gated_json["approval"]["git_status"]["behind_by"], 1);

        let approvals = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri("/approvals")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .expect("request should succeed");
        assert_eq!(approvals.status(), 200);
        let approvals_body = axum::body::to_bytes(approvals.into_body(), usize::MAX)
            .await
            .expect("body should read");
        let approvals_json: Value =
            serde_json::from_slice(&approvals_body).expect("body should decode");
        assert_eq!(
            approvals_json["approvals"][0]["repository"]["remote"],
            "origin"
        );

        state.set_access_mode(AccessMode::FullControl).await;
        let resolved = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(format!("/approvals/{approval_id}/approve"))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .expect("request should succeed");

        assert_eq!(resolved.status(), 200);
        let resolved_body = axum::body::to_bytes(resolved.into_body(), usize::MAX)
            .await
            .expect("body should read");
        let resolved_json: Value =
            serde_json::from_slice(&resolved_body).expect("body should decode");
        assert_eq!(resolved_json["mutation_result"]["operation"], "git_pull");

        let status_after = app
            .oneshot(
                Request::builder()
                    .uri("/threads/thread-123/git/status")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .expect("request should succeed");
        let status_body = axum::body::to_bytes(status_after.into_body(), usize::MAX)
            .await
            .expect("body should read");
        let status_json: Value = serde_json::from_slice(&status_body).expect("body should decode");
        assert_eq!(status_json["status"]["behind_by"], 0);
    }

    #[tokio::test]
    async fn read_only_commit_action_is_denied() {
        let sandbox = GitRepoSandbox::new("commit-read-only");
        let state = test_state();
        prime_thread(
            &state,
            "thread-123",
            &sandbox.repo_dir,
            AccessMode::ReadOnly,
        )
        .await;
        let app = router(state);

        let response = app
            .oneshot(json_request(
                "POST",
                "/threads/thread-123/actions/commit",
                json!({}),
            ))
            .await
            .expect("request should succeed");

        assert_eq!(response.status(), StatusCode::FORBIDDEN);
        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .expect("body should read");
        let decoded: Value = serde_json::from_slice(&body).expect("body should decode");
        assert_eq!(decoded["code"], "policy_denied");
    }

    #[tokio::test]
    async fn approval_reject_marks_request_rejected_without_running_git() {
        let sandbox = GitRepoSandbox::new("reject-approval");
        sandbox.commit_remote("remote change");
        run_git(&sandbox.repo_dir, ["fetch", "origin"]);

        let state = test_state();
        prime_thread(
            &state,
            "thread-123",
            &sandbox.repo_dir,
            AccessMode::ControlWithApprovals,
        )
        .await;
        let app = router(state.clone());

        let gated = app
            .clone()
            .oneshot(json_request(
                "POST",
                "/threads/thread-123/git/pull",
                json!({}),
            ))
            .await
            .expect("request should succeed");
        let gated_body = axum::body::to_bytes(gated.into_body(), usize::MAX)
            .await
            .expect("body should read");
        let gated_json: Value = serde_json::from_slice(&gated_body).expect("body should decode");
        let approval_id = gated_json["approval"]["approval_id"]
            .as_str()
            .expect("approval id should exist");

        state.set_access_mode(AccessMode::FullControl).await;
        let rejected = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(format!("/approvals/{approval_id}/reject"))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .expect("request should succeed");
        assert_eq!(rejected.status(), 200);
        let rejected_body = axum::body::to_bytes(rejected.into_body(), usize::MAX)
            .await
            .expect("body should read");
        let rejected_json: Value =
            serde_json::from_slice(&rejected_body).expect("body should decode");
        assert_eq!(rejected_json["approval"]["status"], "rejected");
        assert!(rejected_json["mutation_result"].is_null());

        let status_after = app
            .oneshot(
                Request::builder()
                    .uri("/threads/thread-123/git/status")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .expect("request should succeed");
        let status_body = axum::body::to_bytes(status_after.into_body(), usize::MAX)
            .await
            .expect("body should read");
        let status_json: Value = serde_json::from_slice(&status_body).expect("body should decode");
        assert_eq!(status_json["status"]["behind_by"], 1);
    }

    #[tokio::test]
    async fn read_only_blocks_git_mutations() {
        let sandbox = GitRepoSandbox::new("read-only");

        let state = test_state();
        prime_thread(
            &state,
            "thread-123",
            &sandbox.repo_dir,
            AccessMode::ReadOnly,
        )
        .await;
        let app = router(state);

        let response = app
            .oneshot(json_request(
                "POST",
                "/threads/thread-123/git/push",
                json!({}),
            ))
            .await
            .expect("request should succeed");

        assert_eq!(response.status(), 403);
        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .expect("body should read");
        let decoded: Value = serde_json::from_slice(&body).expect("body should decode");
        assert_eq!(decoded["code"], "policy_denied");
    }

    fn test_state() -> BridgeAppState {
        test_state_with_speech_service(SpeechService::new_for_tests(
            Arc::new(crate::server::speech::UnsupportedSpeechBackend),
            unique_temp_dir("bridge-speech-tmp"),
            SpeechModelStatusDto {
                contract_version: shared_contracts::CONTRACT_VERSION.to_string(),
                provider: "fluid_audio".to_string(),
                model_id: "parakeet-tdt-0.6b-v3-coreml".to_string(),
                state: SpeechModelStateDto::Unsupported,
                download_progress: None,
                last_error: Some("tests use the unsupported speech backend".to_string()),
                installed_bytes: None,
            },
        ))
    }

    fn test_state_with_speech_service(speech: SpeechService) -> BridgeAppState {
        let temp_state_directory = std::env::temp_dir().join(format!(
            "bridge-pairing-test-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("clock should be monotonic enough")
                .as_nanos()
        ));

        let config = BridgeConfig {
            host: "127.0.0.1".to_string(),
            port: 3110,
            state_directory: temp_state_directory.clone(),
            speech_helper_binary: None,
            pairing_route: PairingRouteState::new(
                "https://bridge.ts.net".to_string(),
                true,
                None,
                3110,
                false,
                temp_state_directory,
            ),
            codex: BridgeCodexConfig::default(),
        };

        BridgeAppState::new(
            config.codex,
            crate::pairing::PairingSessionService::new(
                config.host.as_str(),
                config.port,
                config.pairing_route.pairing_base_url().to_string(),
                config.state_directory.clone(),
            ),
            config.pairing_route,
            speech,
        )
    }

    fn test_state_with_codex_command(command: &Path) -> BridgeAppState {
        let temp_state_directory = unique_temp_dir("bridge-codex-test");
        let speech = SpeechService::new_for_tests(
            Arc::new(crate::server::speech::UnsupportedSpeechBackend),
            unique_temp_dir("bridge-codex-speech"),
            SpeechModelStatusDto {
                contract_version: shared_contracts::CONTRACT_VERSION.to_string(),
                provider: "fluid_audio".to_string(),
                model_id: "parakeet-tdt-0.6b-v3-coreml".to_string(),
                state: SpeechModelStateDto::Unsupported,
                download_progress: None,
                last_error: Some("tests use the unsupported speech backend".to_string()),
                installed_bytes: None,
            },
        );
        let config = BridgeConfig {
            host: "127.0.0.1".to_string(),
            port: 3110,
            state_directory: temp_state_directory.clone(),
            speech_helper_binary: None,
            pairing_route: PairingRouteState::new(
                "https://bridge.ts.net".to_string(),
                true,
                None,
                3110,
                false,
                temp_state_directory,
            ),
            codex: BridgeCodexConfig {
                mode: crate::codex_runtime::CodexRuntimeMode::Spawn,
                endpoint: None,
                command: command.to_string_lossy().to_string(),
                args: vec!["app-server".to_string()],
                desktop_ipc_socket_path: None,
            },
        };

        BridgeAppState::new(
            config.codex,
            crate::pairing::PairingSessionService::new(
                config.host.as_str(),
                config.port,
                config.pairing_route.pairing_base_url().to_string(),
                config.state_directory.clone(),
            ),
            config.pairing_route,
            speech,
        )
    }

    async fn prime_thread(
        state: &BridgeAppState,
        thread_id: &str,
        repo_dir: &Path,
        access_mode: AccessMode,
    ) {
        state.set_access_mode(access_mode).await;
        let workspace = repo_dir.to_string_lossy().to_string();
        let repository = repo_dir
            .file_name()
            .and_then(|value| value.to_str())
            .unwrap_or("repo")
            .to_string();
        let snapshot = ThreadSnapshotDto {
            contract_version: shared_contracts::CONTRACT_VERSION.to_string(),
            thread: shared_contracts::ThreadDetailDto {
                contract_version: shared_contracts::CONTRACT_VERSION.to_string(),
                thread_id: thread_id.to_string(),
                native_thread_id: thread_id.to_string(),
                provider: shared_contracts::ProviderKind::Codex,
                client: shared_contracts::ThreadClientKind::Cli,
                title: "Git thread".to_string(),
                status: shared_contracts::ThreadStatus::Idle,
                workspace: workspace.clone(),
                repository: repository.clone(),
                branch: "main".to_string(),
                created_at: "2026-03-21T09:00:00Z".to_string(),
                updated_at: "2026-03-21T09:00:00Z".to_string(),
                source: "cli".to_string(),
                access_mode,
                last_turn_summary: String::new(),
                active_turn_id: None,
            },
            entries: vec![],
            approvals: vec![],
            git_status: Some(shared_contracts::GitStatusDto {
                workspace: workspace.clone(),
                repository: repository.clone(),
                branch: "main".to_string(),
                remote: Some("origin".to_string()),
                dirty: false,
                ahead_by: 0,
                behind_by: 0,
            }),
            pending_user_input: None,
        };
        state.projections().put_snapshot(snapshot.clone()).await;
        state
            .projections()
            .replace_summaries(vec![ThreadSummaryDto {
                contract_version: shared_contracts::CONTRACT_VERSION.to_string(),
                thread_id: thread_id.to_string(),
                native_thread_id: thread_id.to_string(),
                provider: shared_contracts::ProviderKind::Codex,
                client: shared_contracts::ThreadClientKind::Cli,
                title: snapshot.thread.title,
                status: snapshot.thread.status,
                workspace,
                repository,
                branch: "main".to_string(),
                updated_at: "2026-03-21T09:00:00Z".to_string(),
            }])
            .await;
    }

    fn json_request(method: &str, uri: &str, body: Value) -> Request<Body> {
        Request::builder()
            .method(method)
            .uri(uri)
            .header("content-type", "application/json")
            .body(Body::from(body.to_string()))
            .unwrap()
    }

    fn fake_wav_bytes() -> Vec<u8> {
        vec![
            0x52, 0x49, 0x46, 0x46, 0x24, 0x00, 0x00, 0x00, 0x57, 0x41, 0x56, 0x45, 0x66, 0x6D,
            0x74, 0x20, 0x10, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x80, 0x3E, 0x00, 0x00,
            0x00, 0x7D, 0x00, 0x00, 0x02, 0x00, 0x10, 0x00, 0x64, 0x61, 0x74, 0x61, 0x04, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ]
    }

    fn write_fake_codex_script(label: &str, script_body: &str) -> PathBuf {
        let temp_dir = unique_temp_dir(label);
        let script_path = temp_dir.join("fake-codex.sh");
        fs::write(&script_path, script_body).expect("fake codex script should be written");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;

            fs::set_permissions(&script_path, fs::Permissions::from_mode(0o755))
                .expect("fake codex script should be executable");
        }
        script_path
    }

    #[tokio::test]
    async fn thread_history_route_hides_plan_protocol_messages_and_surfaces_pending_input() {
        let script_path = write_fake_codex_script(
            "plan-history",
            r#"#!/usr/bin/env python3
import json
import sys

for line in sys.stdin:
    request = json.loads(line)
    response = {"id": request.get("id")}
    method = request.get("method")

    if method == "initialize":
        response["result"] = {}
    elif method == "thread/read":
        response["result"] = {
            "thread": {
                "id": "thread-plan",
                "name": "Plan thread",
                "preview": "preview",
                "status": {"type": "idle"},
                "cwd": "/workspace/repo",
                "gitInfo": {
                    "branch": "main",
                    "originUrl": "git@github.com:example/repo.git",
                },
                "createdAt": 1710000000,
                "updatedAt": 1710000300,
                "source": "cli",
                "turns": [
                    {
                        "id": "turn-plan",
                        "items": [
                            {
                                "id": "msg-hidden-user",
                                "type": "userMessage",
                                "text": "You are running in mobile plan intake mode.\nDo not edit files, do not run commands, and do not produce the plan yet.",
                            },
                            {
                                "id": "msg-hidden-assistant",
                                "type": "agentMessage",
                                "text": "<codex-plan-questions>{\"title\":\"Clarify the implementation\",\"detail\":\"Pick the first test target.\",\"questions\":[{\"question_id\":\"scope\",\"prompt\":\"What should the test cover first?\",\"options\":[{\"option_id\":\"core\",\"label\":\"Core flows\",\"description\":\"Cover pairing and thread navigation.\",\"is_recommended\":true},{\"option_id\":\"plan\",\"label\":\"Plan mode\",\"description\":\"Cover plan mode only.\",\"is_recommended\":false},{\"option_id\":\"polish\",\"label\":\"Polish\",\"description\":\"Cover copy and layout polish.\",\"is_recommended\":false}]}]}</codex-plan-questions>",
                            },
                        ],
                    }
                ],
            }
        }
    else:
        response["result"] = {}

    sys.stdout.write(json.dumps(response) + "\n")
    sys.stdout.flush()
"#,
        );

        let app = router(test_state_with_codex_command(&script_path));
        let response = app
            .oneshot(
                Request::builder()
                    .uri("/threads/codex:thread-plan/history")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .expect("request should succeed");

        assert_eq!(response.status(), StatusCode::OK);
        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .expect("body should read");
        let decoded: Value = serde_json::from_slice(&body).expect("body should decode");

        assert_eq!(decoded["entries"], json!([]));
        assert_eq!(
            decoded["pending_user_input"]["title"],
            "Clarify the implementation"
        );
        assert_eq!(
            decoded["pending_user_input"]["questions"][0]["question_id"],
            "scope"
        );
        assert_eq!(decoded["thread"]["thread_id"], "codex:thread-plan");
        assert_eq!(decoded["thread"]["native_thread_id"], "thread-plan");

        let _ = fs::remove_file(&script_path);
        if let Some(parent) = script_path.parent() {
            let _ = fs::remove_dir_all(parent);
        }
    }

    #[tokio::test]
    async fn interrupt_route_resolves_active_turn_when_bridge_cache_is_empty() {
        let temp_dir = unique_temp_dir("interrupt-active-turn");
        let log_path = temp_dir.join("requests.log");
        let script_body = format!(
            r#"#!/usr/bin/env python3
import json
import sys

log_path = {log_path:?}

for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method")
    with open(log_path, "a", encoding="utf-8") as log_file:
        log_file.write(method + "\n")
    response = {{"id": request.get("id")}}

    if method == "initialize":
        response["result"] = {{}}
    elif method == "thread/read":
        response["result"] = {{
            "thread": {{
                "id": "thread-running",
                "name": "Running thread",
                "preview": "preview",
                "status": {{"type": "running"}},
                "cwd": "/workspace/repo",
                "gitInfo": {{
                    "branch": "main",
                    "originUrl": "git@github.com:example/repo.git",
                }},
                "createdAt": 1710000000,
                "updatedAt": 1710000300,
                "source": "cli",
                "turns": [
                    {{
                        "id": "turn-live",
                        "items": []
                    }}
                ],
            }}
        }}
    elif method == "turn/interrupt":
        response["result"] = {{}}
    else:
        response["result"] = {{}}

    sys.stdout.write(json.dumps(response) + "\n")
    sys.stdout.flush()
"#,
            log_path = log_path.to_string_lossy(),
        );
        let script_path = write_fake_codex_script("interrupt-active-turn", &script_body);

        let state = test_state_with_codex_command(&script_path);
        prime_thread(&state, "thread-running", &temp_dir, AccessMode::FullControl).await;
        state
            .projections()
            .mark_thread_running("thread-running", "2026-03-31T12:00:00Z", None)
            .await;
        let app = router(state);

        let response = app
            .oneshot(json_request(
                "POST",
                "/threads/thread-running/interrupt",
                json!({}),
            ))
            .await
            .expect("request should succeed");

        assert_eq!(response.status(), StatusCode::OK);
        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .expect("body should read");
        let decoded: Value = serde_json::from_slice(&body).expect("body should decode");
        assert_eq!(decoded["thread_status"], "interrupted");
        assert_eq!(decoded["message"], "interrupt requested");

        let request_log = fs::read_to_string(&log_path).expect("request log should exist");
        assert!(request_log.contains("thread/read"));
        assert!(request_log.contains("turn/interrupt"));

        let _ = fs::remove_file(&script_path);
        let _ = fs::remove_file(&log_path);
        let _ = fs::remove_dir_all(&temp_dir);
        if let Some(parent) = script_path.parent() {
            let _ = fs::remove_dir_all(parent);
        }
    }

    #[tokio::test]
    async fn start_turn_route_returns_structured_error_for_claude_plan_mode() {
        let app = router(test_state());
        let response = app
            .oneshot(json_request(
                "POST",
                "/threads/claude:test-thread/turns",
                json!({
                    "prompt": "Plan the change",
                    "mode": "plan",
                }),
            ))
            .await
            .expect("request should succeed");

        assert_eq!(response.status(), StatusCode::BAD_REQUEST);
        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .expect("body should read");
        let decoded: Value = serde_json::from_slice(&body).expect("body should decode");
        assert_eq!(decoded["error"], "turn_start_failed");
        assert_eq!(decoded["code"], "unsupported_turn_mode");
        assert_eq!(
            decoded["message"],
            "plan mode is not implemented for Claude Code threads yet"
        );
    }

    #[tokio::test]
    async fn interrupt_route_returns_structured_error_when_no_active_turn_exists() {
        let app = router(test_state());
        let response = app
            .oneshot(json_request(
                "POST",
                "/threads/claude:test-thread/interrupt",
                json!({}),
            ))
            .await
            .expect("request should succeed");

        assert_eq!(response.status(), StatusCode::CONFLICT);
        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .expect("body should read");
        let decoded: Value = serde_json::from_slice(&body).expect("body should decode");
        assert_eq!(decoded["error"], "turn_interrupt_failed");
        assert_eq!(decoded["code"], "no_active_turn");
        assert_eq!(
            decoded["message"],
            "no active Claude turn found for thread claude:test-thread"
        );
    }

    #[derive(Debug)]
    struct StubSpeechBackend {
        status: SpeechModelStatusDto,
        transcription: Option<SpeechTranscriptionResultDto>,
    }

    #[async_trait]
    impl SpeechBackend for StubSpeechBackend {
        async fn status(&self) -> Result<SpeechModelStatusDto, SpeechError> {
            Ok(self.status.clone())
        }

        async fn ensure_model(
            &self,
            _progress_callback: Option<crate::server::speech::ProgressCallback>,
        ) -> Result<SpeechModelStatusDto, SpeechError> {
            Ok(self.status.clone())
        }

        async fn remove_model(&self) -> Result<SpeechModelStatusDto, SpeechError> {
            Ok(self.status.clone())
        }

        async fn transcribe_file(
            &self,
            _audio_file: &Path,
        ) -> Result<SpeechTranscriptionResultDto, SpeechError> {
            self.transcription.clone().ok_or_else(|| {
                SpeechError::transcription_failed("missing test transcription result")
            })
        }
    }

    struct GitRepoSandbox {
        root_dir: PathBuf,
        repo_dir: PathBuf,
        remote_dir: PathBuf,
        clone_dir: PathBuf,
    }

    impl GitRepoSandbox {
        fn new(label: &str) -> Self {
            let root_dir = unique_temp_dir(label);
            let repo_dir = root_dir.join("repo");
            let remote_dir = root_dir.join("remote.git");
            let clone_dir = root_dir.join("clone");

            fs::create_dir_all(&repo_dir).expect("repo dir should exist");
            run_git(&repo_dir, ["init"]);
            run_git(&repo_dir, ["config", "user.name", "Codex"]);
            run_git(&repo_dir, ["config", "user.email", "codex@example.com"]);
            run_git(&repo_dir, ["branch", "-M", "main"]);
            fs::write(repo_dir.join("README.md"), "initial\n").expect("readme should write");
            run_git(&repo_dir, ["add", "."]);
            run_git(&repo_dir, ["commit", "-m", "initial"]);

            let bare_parent = unique_temp_dir("git-remote");
            run_git_in(
                bare_parent.as_path(),
                ["init", "--bare", remote_dir.to_string_lossy().as_ref()],
            );
            run_git(
                &repo_dir,
                [
                    "remote",
                    "add",
                    "origin",
                    remote_dir.to_string_lossy().as_ref(),
                ],
            );
            run_git(&repo_dir, ["push", "-u", "origin", "main"]);

            Self {
                root_dir,
                repo_dir,
                remote_dir,
                clone_dir,
            }
        }

        fn commit_local(&self, message: &str) {
            fs::write(self.repo_dir.join("local.txt"), format!("{message}\n"))
                .expect("local file should write");
            run_git(&self.repo_dir, ["add", "."]);
            run_git(&self.repo_dir, ["commit", "-m", message]);
        }

        fn commit_remote(&self, message: &str) {
            run_git_in(
                self.root_dir.as_path(),
                [
                    "clone",
                    self.remote_dir.to_string_lossy().as_ref(),
                    self.clone_dir.to_string_lossy().as_ref(),
                ],
            );
            run_git(&self.clone_dir, ["config", "user.name", "Codex"]);
            run_git(
                &self.clone_dir,
                ["config", "user.email", "codex@example.com"],
            );
            run_git(&self.clone_dir, ["checkout", "main"]);
            fs::write(self.clone_dir.join("remote.txt"), format!("{message}\n"))
                .expect("remote file should write");
            run_git(&self.clone_dir, ["add", "."]);
            run_git(&self.clone_dir, ["commit", "-m", message]);
            run_git(&self.clone_dir, ["push", "origin", "main"]);
            let _ = fs::remove_dir_all(&self.clone_dir);
        }
    }

    impl Drop for GitRepoSandbox {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root_dir);
            let _ = fs::remove_dir_all(&self.clone_dir);
        }
    }

    fn unique_temp_dir(label: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!(
            "bridge-core-{label}-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("clock should move forward")
                .as_nanos()
        ));
        fs::create_dir_all(&path).expect("temp dir should exist");
        path
    }

    fn run_git(cwd: &Path, args: impl IntoIterator<Item = impl AsRef<str>>) {
        let args = args
            .into_iter()
            .map(|value| value.as_ref().to_string())
            .collect::<Vec<_>>();
        let output = Command::new("git")
            .args(&args)
            .current_dir(cwd)
            .output()
            .expect("git command should run");
        assert!(
            output.status.success(),
            "git {:?} failed: {}",
            args,
            String::from_utf8_lossy(&output.stderr)
        );
    }

    fn run_git_in(cwd: &Path, args: impl IntoIterator<Item = impl AsRef<str>>) {
        run_git(cwd, args);
    }
}
