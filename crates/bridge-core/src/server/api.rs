use axum::extract::{Json as ExtractJson, Path, Query, State, WebSocketUpgrade};
use axum::http::StatusCode;
use axum::response::Response;
use axum::routing::{get, post};
use axum::{Json, Router};
use serde::Deserialize;
use serde::Serialize;
use serde_json::json;
use shared_contracts::{
    AccessMode, ApprovalSummaryDto, BootstrapDto, ModelCatalogDto, SecurityAuditEventDto,
    ThreadSnapshotDto, ThreadSummaryDto, ThreadTimelinePageDto, TurnMutationAcceptedDto,
};

use crate::pairing::{
    PairingFinalizeError, PairingFinalizeRequest, PairingHandshakeError, PairingHandshakeRequest,
    PairingTrustSnapshot,
};
use crate::server::events::{EventSubscriptionQuery, stream_events};
use crate::server::pairing_route::PairingRouteHealth;
use crate::server::state::BridgeAppState;

pub fn router(state: BridgeAppState) -> Router {
    Router::new()
        .route("/healthz", get(healthz))
        .route("/bootstrap", get(bootstrap))
        .route("/models", get(model_catalog))
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
        .route("/threads/:thread_id/turns", post(start_turn))
        .route("/threads/:thread_id/interrupt", post(interrupt_turn))
        .route("/approvals", get(list_approvals))
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
        approvals: state.projections().list_approvals().await,
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
struct StartTurnRequest {
    prompt: String,
}

#[derive(Debug, Deserialize)]
struct CreateThreadRequest {
    workspace: String,
    #[serde(default)]
    model: Option<String>,
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
    match state.start_turn(&thread_id, &request.prompt).await {
        Ok(response) => Ok(Json(response)),
        Err(error) => {
            eprintln!("bridge start_turn failed for {thread_id}: {error}");
            Err(StatusCode::BAD_GATEWAY)
        }
    }
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
    approvals: Vec<ApprovalSummaryDto>,
}

#[derive(Debug, Serialize)]
struct SecurityEventsResponse {
    contract_version: String,
    events: Vec<crate::server::state::SecurityEventRecordDto>,
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
    use axum::body::Body;
    use axum::http::Request;
    use serde_json::Value;
    use tower::util::ServiceExt;

    use super::router;
    use crate::pairing::PairingFinalizeRequest;
    use crate::server::config::{BridgeCodexConfig, BridgeConfig};
    use crate::server::pairing_route::PairingRouteState;
    use crate::server::state::BridgeAppState;

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
                config.state_directory,
            ),
            config.pairing_route,
        )
    }
}
