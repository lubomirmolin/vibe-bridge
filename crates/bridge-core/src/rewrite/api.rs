use axum::extract::{Json as ExtractJson, Path, Query, State, WebSocketUpgrade};
use axum::http::StatusCode;
use axum::response::Response;
use axum::routing::{get, post};
use axum::{Json, Router};
use serde::Deserialize;
use serde_json::json;
use shared_contracts::{
    ApprovalSummaryDto, BootstrapDto, ThreadSnapshotDto, ThreadSummaryDto, ThreadTimelinePageDto,
    TurnMutationAcceptedDto,
};

use crate::rewrite::events::{EventSubscriptionQuery, stream_events};
use crate::rewrite::state::RewriteAppState;

pub fn router(state: RewriteAppState) -> Router {
    Router::new()
        .route("/healthz", get(healthz))
        .route("/bootstrap", get(bootstrap))
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

#[cfg(test)]
mod tests {
    use axum::body::Body;
    use axum::http::Request;
    use tower::util::ServiceExt;

    use super::router;
    use crate::rewrite::state::RewriteAppState;

    #[tokio::test]
    async fn bootstrap_route_returns_rewrite_contract() {
        let app = router(RewriteAppState::new(
            crate::rewrite::config::RewriteCodexConfig::default(),
        ));
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
}
