use axum::extract::{Json as ExtractJson, Path, Query, State, WebSocketUpgrade};
use axum::http::StatusCode;
use axum::response::Response;
use axum::routing::{get, post};
use axum::{Json, Router};
use serde::Deserialize;
use serde::Serialize;
use serde_json::json;
use shared_contracts::{
    ApprovalSummaryDto, BootstrapDto, ThreadSnapshotDto, ThreadSummaryDto, ThreadTimelinePageDto,
    TurnMutationAcceptedDto,
};

use crate::pairing::{
    PairingFinalizeError, PairingFinalizeRequest, PairingHandshakeError, PairingHandshakeRequest,
    PairingTrustSnapshot,
};
use crate::rewrite::events::{EventSubscriptionQuery, stream_events};
use crate::rewrite::pairing_route::PairingRouteHealth;
use crate::rewrite::state::RewriteAppState;

pub fn router(state: RewriteAppState) -> Router {
    Router::new()
        .route("/healthz", get(healthz))
        .route("/bootstrap", get(bootstrap))
        .route("/pairing/session", get(pairing_session).post(pairing_session))
        .route("/pairing/finalize", post(pairing_finalize))
        .route("/pairing/handshake", post(pairing_handshake))
        .route("/pairing/trust/revoke", post(pairing_revoke))
        .route("/pairing/trust", get(pairing_trust))
        .route("/pairing/route", get(pairing_route))
        .route("/threads", get(list_threads).post(create_thread))
        .route("/threads/:thread_id/snapshot", get(thread_snapshot))
        .route("/threads/:thread_id/history", get(thread_history))
        .route("/threads/:thread_id/turns", post(start_turn))
        .route("/threads/:thread_id/interrupt", post(interrupt_turn))
        .route("/approvals", get(list_approvals))
        .route("/events", get(events))
        .with_state(state)
}

async fn healthz() -> Json<serde_json::Value> {
    Json(json!({
        "status": "ok",
        "backend": "rewrite",
        "contract_version": shared_contracts::CONTRACT_VERSION,
    }))
}

async fn bootstrap(State(state): State<RewriteAppState>) -> Json<BootstrapDto> {
    Json(state.bootstrap_payload().await)
}

async fn pairing_session(
    State(state): State<RewriteAppState>,
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

async fn list_threads(State(state): State<RewriteAppState>) -> Json<Vec<ThreadSummaryDto>> {
    Json(state.projections().list_summaries().await)
}

async fn thread_snapshot(
    State(state): State<RewriteAppState>,
    Path(thread_id): Path<String>,
) -> Result<Json<ThreadSnapshotDto>, StatusCode> {
    match state.ensure_snapshot(&thread_id).await {
        Ok(snapshot) => Ok(Json(snapshot)),
        Err(_) => Err(StatusCode::NOT_FOUND),
    }
}

async fn list_approvals(State(state): State<RewriteAppState>) -> Json<Vec<ApprovalSummaryDto>> {
    Json(state.projections().list_approvals().await)
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
    State(state): State<RewriteAppState>,
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
    State(state): State<RewriteAppState>,
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
    State(state): State<RewriteAppState>,
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

async fn pairing_trust(State(state): State<RewriteAppState>) -> Json<PairingTrustSnapshot> {
    Json(state.trust_snapshot())
}

async fn pairing_route(State(state): State<RewriteAppState>) -> Json<PairingRouteHealth> {
    Json(state.pairing_route_health())
}

async fn start_turn(
    State(state): State<RewriteAppState>,
    Path(thread_id): Path<String>,
    ExtractJson(request): ExtractJson<StartTurnRequest>,
) -> Result<Json<TurnMutationAcceptedDto>, StatusCode> {
    match state.start_turn(&thread_id, &request.prompt).await {
        Ok(response) => Ok(Json(response)),
        Err(error) => {
            eprintln!("rewrite start_turn failed for {thread_id}: {error}");
            Err(StatusCode::BAD_GATEWAY)
        }
    }
}

async fn create_thread(
    State(state): State<RewriteAppState>,
    ExtractJson(request): ExtractJson<CreateThreadRequest>,
) -> Result<Json<ThreadSnapshotDto>, StatusCode> {
    match state
        .create_thread(&request.workspace, request.model.as_deref())
        .await
    {
        Ok(snapshot) => Ok(Json(snapshot)),
        Err(error) => {
            eprintln!(
                "rewrite create_thread failed for workspace {}: {error}",
                request.workspace
            );
            Err(StatusCode::BAD_GATEWAY)
        }
    }
}

async fn interrupt_turn(
    State(state): State<RewriteAppState>,
    Path(thread_id): Path<String>,
    request: Option<ExtractJson<InterruptTurnRequest>>,
) -> Result<Json<TurnMutationAcceptedDto>, StatusCode> {
    let turn_id = request
        .as_ref()
        .and_then(|ExtractJson(request)| request.turn_id.as_deref());
    match state.interrupt_turn(&thread_id, turn_id).await {
        Ok(response) => Ok(Json(response)),
        Err(error) => {
            eprintln!("rewrite interrupt_turn failed for {thread_id}: {error}");
            Err(StatusCode::BAD_GATEWAY)
        }
    }
}

async fn thread_history(
    State(state): State<RewriteAppState>,
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
    State(state): State<RewriteAppState>,
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
    use crate::rewrite::config::{RewriteCodexConfig, RewriteConfig};
    use crate::rewrite::pairing_route::PairingRouteState;
    use crate::rewrite::state::RewriteAppState;

    #[tokio::test]
    async fn bootstrap_route_returns_rewrite_contract() {
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
        assert_eq!(decoded["bridge_identity"]["api_base_url"], "https://bridge.ts.net");
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

    fn test_state() -> RewriteAppState {
        let temp_state_directory = std::env::temp_dir().join(format!(
            "rewrite-pairing-test-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("clock should be monotonic enough")
                .as_nanos()
        ));

        let config = RewriteConfig {
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
            codex: RewriteCodexConfig::default(),
        };

        RewriteAppState::new(
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
