mod api;
mod config;
mod controls;
mod events;
mod gateway;
mod pairing_route;
mod projection;
mod speech;
mod state;

use std::fs;
use std::path::PathBuf;

use axum::serve;
use tokio::net::TcpListener;

pub use config::BridgeConfig;
use state::BridgeAppState;

fn pid_file_path(state_directory: &std::path::Path) -> PathBuf {
    state_directory.join("bridge-server.pid")
}

fn write_pid_file(state_directory: &std::path::Path) {
    let path = pid_file_path(state_directory);
    let pid = std::process::id();
    if let Err(error) = fs::write(&path, pid.to_string()) {
        eprintln!(
            "warning: failed to write PID file {}: {error}",
            path.display()
        );
    }
}

fn remove_pid_file(state_directory: &std::path::Path) {
    let path = pid_file_path(state_directory);
    if path.exists()
        && let Err(error) = fs::remove_file(&path)
    {
        eprintln!(
            "warning: failed to remove PID file {}: {error}",
            path.display()
        );
    }
}

pub async fn run_from_env() -> Result<(), String> {
    let config = BridgeConfig::from_env_and_args(std::env::args().skip(1))?;
    let state = BridgeAppState::from_config(config.clone()).await;
    state.start_notification_forwarder();
    state.start_summary_reconciler();
    let app = api::router(state);

    if let Err(error) = fs::create_dir_all(&config.state_directory) {
        return Err(format!(
            "failed to create state directory {}: {error}",
            config.state_directory.display()
        ));
    }
    write_pid_file(&config.state_directory);

    let listener = TcpListener::bind((config.host.as_str(), config.port))
        .await
        .map_err(|error| {
            format!(
                "failed to bind bridge listener on {}:{}: {error}",
                config.host, config.port
            )
        })?;

    let result = serve(listener, app)
        .await
        .map_err(|error| format!("bridge server failed: {error}"));

    remove_pid_file(&config.state_directory);
    result
}
