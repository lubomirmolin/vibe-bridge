mod api;
mod config;
mod events;
mod gateway;
mod pairing_route;
mod projection;
mod state;

use axum::serve;
use tokio::net::TcpListener;

pub use config::BridgeConfig;
use state::BridgeAppState;

pub async fn run_from_env() -> Result<(), String> {
    let config = BridgeConfig::from_env_and_args(std::env::args().skip(1))?;
    let state = BridgeAppState::from_config(config.clone()).await;
    state.start_notification_forwarder();
    state.start_summary_reconciler();
    let app = api::router(state);
    let listener = TcpListener::bind((config.host.as_str(), config.port))
        .await
        .map_err(|error| {
            format!(
                "failed to bind bridge listener on {}:{}: {error}",
                config.host, config.port
            )
        })?;

    serve(listener, app)
        .await
        .map_err(|error| format!("bridge server failed: {error}"))
}
