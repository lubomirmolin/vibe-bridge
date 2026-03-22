use axum::extract::{Json as ExtractJson, Multipart, Path, Query, State, WebSocketUpgrade};
use axum::http::StatusCode;
use axum::response::Response;
use axum::routing::{get, post};
use axum::{Json, Router};
use serde::Deserialize;
use serde::Serialize;
use serde_json::json;
use shared_contracts::{
    AccessMode, BootstrapDto, ModelCatalogDto, SecurityAuditEventDto,
    SpeechModelMutationAcceptedDto, SpeechModelStatusDto, SpeechTranscriptionResultDto,
    ThreadSnapshotDto, ThreadSummaryDto, ThreadTimelinePageDto, TurnMutationAcceptedDto,
};

use crate::pairing::{
    PairingFinalizeError, PairingFinalizeRequest, PairingHandshakeError, PairingHandshakeRequest,
    PairingTrustSnapshot,
};
use crate::policy::{PolicyAction, PolicyDecision};
use crate::server::controls::{ApprovalRecordDto, ApprovalResolutionResponse};
use crate::server::events::{EventSubscriptionQuery, stream_events};
use crate::server::pairing_route::PairingRouteHealth;
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
            "/policy/access-mode",
            get(get_access_mode).post(set_access_mode),
        )
        .route("/threads", get(list_threads).post(create_thread))
        .route("/threads/:thread_id/snapshot", get(thread_snapshot))
        .route("/threads/:thread_id/history", get(thread_history))
        .route("/threads/:thread_id/git/status", get(thread_git_status))
        .route(
            "/threads/:thread_id/git/branch-switch",
            post(thread_git_branch_switch),
        )
        .route("/threads/:thread_id/git/pull", post(thread_git_pull))
        .route("/threads/:thread_id/git/push", post(thread_git_push))
        .route("/threads/:thread_id/turns", post(start_turn))
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
        .with_state(state)
}

async fn healthz() -> Json<serde_json::Value> {
    Json(json!({
        "status": "ok",
        "backend": "bridge-server",
        "contract_version": shared_contracts::CONTRACT_VERSION,
    }))
}

async fn bootstrap(State(state): State<BridgeAppState>) -> Json<BootstrapDto> {
    Json(state.bootstrap_payload().await)
}

async fn model_catalog(State(state): State<BridgeAppState>) -> Json<ModelCatalogDto> {
    Json(state.model_catalog_payload().await)
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

    while let Some(field) = multipart.next_field().await.map_err(|error| {
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
        break;
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

    let auth_request = PairingHandshakeRequest {
        phone_id: query.phone_id.clone(),
        bridge_id: query.bridge_id.clone(),
        session_token: query.session_token.clone(),
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
                reason: format!("mode={}", query.mode),
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
    phone_id: String,
    bridge_id: String,
    session_token: String,
    actor: Option<String>,
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

#[derive(Debug, Deserialize)]
struct StartTurnRequest {
    prompt: String,
    #[serde(default)]
    images: Vec<String>,
    #[serde(default)]
    model: Option<String>,
    #[serde(default, alias = "reasoning_effort")]
    effort: Option<String>,
}

#[derive(Debug, Deserialize)]
struct CreateThreadRequest {
    workspace: String,
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
    Json(state.trust_snapshot())
}

async fn pairing_route(State(state): State<BridgeAppState>) -> Json<PairingRouteHealth> {
    Json(state.pairing_route_health())
}

async fn start_turn(
    State(state): State<BridgeAppState>,
    Path(thread_id): Path<String>,
    ExtractJson(request): ExtractJson<StartTurnRequest>,
) -> Result<Json<TurnMutationAcceptedDto>, StatusCode> {
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
        )
        .await
    {
        Ok(response) => Ok(Json(response)),
        Err(error) => {
            eprintln!("bridge start_turn failed for {thread_id}: {error}");
            Err(StatusCode::BAD_GATEWAY)
        }
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
        .create_thread(&request.workspace, request.model.as_deref())
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
) -> Result<Json<TurnMutationAcceptedDto>, StatusCode> {
    let turn_id = request
        .as_ref()
        .and_then(|ExtractJson(request)| request.turn_id.as_deref());
    match state.interrupt_turn(&thread_id, turn_id).await {
        Ok(response) => Ok(Json(response)),
        Err(error) => {
            eprintln!("bridge interrupt_turn failed for {thread_id}: {error}");
            Err(StatusCode::BAD_GATEWAY)
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
    let scope = query.into_scope();
    ws.on_upgrade(move |socket| stream_events(socket, receiver, scope))
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

    use axum::body::Body;
    use axum::http::Request;
    use axum::http::StatusCode;
    use serde_json::Value;
    use serde_json::json;
    use tower::util::ServiceExt;

    use super::router;
    use crate::pairing::PairingFinalizeRequest;
    use crate::server::config::{BridgeCodexConfig, BridgeConfig};
    use crate::server::pairing_route::PairingRouteState;
    use crate::server::state::BridgeAppState;
    use shared_contracts::{AccessMode, ThreadSnapshotDto, ThreadSummaryDto};

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
        assert_eq!(events[0]["event"]["payload"]["reason"], "mode=full_control");
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
            state_directory: temp_state_directory,
            speech_helper_binary: None,
            pairing_route: PairingRouteState::new(
                "https://bridge.ts.net".to_string(),
                true,
                None,
                3110,
                false,
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
            crate::server::speech::SpeechService::new_for_tests(
                std::sync::Arc::new(crate::server::speech::UnsupportedSpeechBackend),
                config.state_directory.join("speech").join("tmp"),
                shared_contracts::SpeechModelStatusDto {
                    contract_version: shared_contracts::CONTRACT_VERSION.to_string(),
                    provider: "fluid_audio".to_string(),
                    model_id: "parakeet-tdt-0.6b-v3-coreml".to_string(),
                    state: shared_contracts::SpeechModelStateDto::Unsupported,
                    download_progress: None,
                    last_error: Some("tests use the unsupported speech backend".to_string()),
                    installed_bytes: None,
                },
            ),
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
        };
        state.projections().put_snapshot(snapshot.clone()).await;
        state
            .projections()
            .replace_summaries(vec![ThreadSummaryDto {
                contract_version: shared_contracts::CONTRACT_VERSION.to_string(),
                thread_id: thread_id.to_string(),
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
