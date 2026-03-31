mod api;
mod codex_usage;
mod config;
mod controls;
mod events;
mod gateway;
mod pairing_route;
mod projection;
mod speech;
mod state;

use std::fs;
use std::net::SocketAddr;
use std::path::PathBuf;

use axum::Router;
use axum::serve;
use tokio::net::TcpListener;
use tokio::sync::oneshot;
use tokio::task::JoinHandle;
use tokio::time::{Duration, sleep};

use crate::codex_runtime::{
    CodexRuntimeConfig, CodexRuntimeMode, CodexRuntimeSupervisor, verify_endpoint_reachable,
};

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

    let mut runtime = CodexRuntimeSupervisor::new(CodexRuntimeConfig {
        mode: config.codex.mode,
        endpoint: config.codex.endpoint.clone(),
        command: config.codex.command.clone(),
        args: config.codex.args.clone(),
    });
    runtime.initialize()?;
    wait_for_codex_runtime(&config).await;

    let state = BridgeAppState::from_config(config.clone()).await;
    state.start_notification_forwarder();
    state.start_desktop_ipc_forwarder();
    state.start_summary_reconciler();
    let app = api::router(state.clone());

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

    let (lan_shutdown_tx, lan_shutdown_rx) = oneshot::channel();
    let lan_manager = tokio::spawn(run_lan_listener_manager(
        state,
        app.clone(),
        lan_shutdown_rx,
    ));

    let result = serve(listener, app)
        .await
        .map_err(|error| format!("bridge server failed: {error}"));

    let _ = lan_shutdown_tx.send(());
    let _ = lan_manager.await;
    remove_pid_file(&config.state_directory);
    drop(runtime);
    result
}

async fn wait_for_codex_runtime(config: &BridgeConfig) {
    if !matches!(
        config.codex.mode,
        CodexRuntimeMode::Auto | CodexRuntimeMode::Spawn
    ) {
        return;
    }

    let Some(endpoint) = config.codex.endpoint.as_deref() else {
        return;
    };

    for _ in 0..20 {
        if verify_endpoint_reachable(endpoint).is_ok() {
            return;
        }
        sleep(Duration::from_millis(250)).await;
    }
}

struct ManagedLanListener {
    bind_addr: SocketAddr,
    shutdown_tx: oneshot::Sender<()>,
    handle: JoinHandle<Result<(), String>>,
}

async fn run_lan_listener_manager(
    state: BridgeAppState,
    app: Router,
    mut shutdown_rx: oneshot::Receiver<()>,
) {
    let mut active_listener: Option<ManagedLanListener> = None;

    loop {
        if let Some(listener) = &active_listener
            && listener.handle.is_finished()
        {
            let listener = active_listener
                .take()
                .expect("active listener should exist");
            match listener.handle.await {
                Ok(Ok(())) => {
                    state.clear_lan_listener_runtime();
                }
                Ok(Err(error)) => state.record_lan_listener_error(error),
                Err(error) => state.record_lan_listener_error(format!(
                    "local network listener task failed: {error}"
                )),
            }
        }

        let desired_addr = state.desired_lan_listener_addr();
        let active_addr = active_listener.as_ref().map(|listener| listener.bind_addr);

        if desired_addr != active_addr {
            if let Some(listener) = active_listener.take() {
                let _ = listener.shutdown_tx.send(());
                let _ = listener.handle.await;
                state.clear_lan_listener_runtime();
            }

            if let Some(bind_addr) = desired_addr {
                match start_lan_listener(bind_addr, app.clone()).await {
                    Ok(listener) => {
                        state.record_lan_listener_active(bind_addr);
                        active_listener = Some(listener);
                    }
                    Err(error) => state.record_lan_listener_error(error),
                }
            } else {
                state.clear_lan_listener_runtime();
            }
        }

        tokio::select! {
            _ = &mut shutdown_rx => {
                if let Some(listener) = active_listener.take() {
                    let _ = listener.shutdown_tx.send(());
                    let _ = listener.handle.await;
                }
                state.clear_lan_listener_runtime();
                break;
            }
            _ = sleep(Duration::from_secs(2)) => {}
        }
    }
}

async fn start_lan_listener(
    bind_addr: SocketAddr,
    app: Router,
) -> Result<ManagedLanListener, String> {
    let listener = TcpListener::bind(bind_addr).await.map_err(|error| {
        format!("failed to bind local network listener on {bind_addr}: {error}")
    })?;
    let (shutdown_tx, shutdown_rx) = oneshot::channel();
    let handle = tokio::spawn(async move {
        serve(listener, app)
            .with_graceful_shutdown(async {
                let _ = shutdown_rx.await;
            })
            .await
            .map_err(|error| format!("local network listener failed on {bind_addr}: {error}"))
    });

    Ok(ManagedLanListener {
        bind_addr,
        shutdown_tx,
        handle,
    })
}
