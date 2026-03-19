use serde::Serialize;
use std::env;
use std::net::{TcpStream, ToSocketAddrs};
use std::process::{Child, Command, Stdio};
use std::time::Duration;
use tungstenite::http::Uri;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CodexRuntimeMode {
    Auto,
    Spawn,
    Attach,
}

impl CodexRuntimeMode {
    pub fn from_flag(flag: &str) -> Result<Self, String> {
        match flag {
            "auto" => Ok(Self::Auto),
            "spawn" => Ok(Self::Spawn),
            "attach" => Ok(Self::Attach),
            _ => Err(format!(
                "invalid --codex-mode value: {flag} (expected auto, spawn, or attach)"
            )),
        }
    }

    pub const fn as_wire(self) -> &'static str {
        match self {
            Self::Auto => "auto",
            Self::Spawn => "spawn",
            Self::Attach => "attach",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CodexRuntimeConfig {
    pub mode: CodexRuntimeMode,
    pub endpoint: Option<String>,
    pub command: String,
    pub args: Vec<String>,
}

impl Default for CodexRuntimeConfig {
    fn default() -> Self {
        Self {
            mode: CodexRuntimeMode::Auto,
            endpoint: Some("ws://127.0.0.1:4222".to_string()),
            command: "codex".to_string(),
            args: vec!["app-server".to_string()],
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct RuntimeSnapshot {
    pub mode: String,
    pub state: String,
    pub endpoint: Option<String>,
    pub pid: Option<u32>,
    pub detail: String,
}

#[derive(Debug)]
enum RuntimeState {
    Initializing,
    Attached { endpoint: String },
    Managed { pid: u32 },
    Degraded { reason: String },
}

#[derive(Debug)]
pub struct CodexRuntimeSupervisor {
    config: CodexRuntimeConfig,
    state: RuntimeState,
    managed_process: Option<Child>,
}

impl CodexRuntimeSupervisor {
    pub fn new(config: CodexRuntimeConfig) -> Self {
        Self {
            config,
            state: RuntimeState::Initializing,
            managed_process: None,
        }
    }

    pub fn initialize(&mut self) -> Result<(), String> {
        match self.config.mode {
            CodexRuntimeMode::Attach => {
                let endpoint = self.config.endpoint.clone().ok_or_else(|| {
                    String::from("--codex-endpoint is required when --codex-mode attach")
                })?;
                self.state = RuntimeState::Attached { endpoint };
                Ok(())
            }
            CodexRuntimeMode::Spawn => {
                let child = spawn_managed_process_with_endpoint(
                    &self.config.command,
                    &self.config.args,
                    self.config.endpoint.as_deref(),
                )?;
                let pid = child.id();
                self.state = RuntimeState::Managed { pid };
                self.managed_process = Some(child);
                Ok(())
            }
            CodexRuntimeMode::Auto => {
                if let Some(endpoint) = self.config.endpoint.clone() {
                    match verify_endpoint_reachable(&endpoint) {
                        Ok(()) => {
                            self.state = RuntimeState::Attached { endpoint };
                            return Ok(());
                        }
                        Err(attach_error) => {
                            match spawn_managed_process_with_endpoint(
                                &self.config.command,
                                &self.config.args,
                                self.config.endpoint.as_deref(),
                            ) {
                                Ok(child) => {
                                    let pid = child.id();
                                    self.state = RuntimeState::Managed { pid };
                                    self.managed_process = Some(child);
                                }
                                Err(spawn_error) => {
                                    self.state = RuntimeState::Degraded {
                                        reason: format!(
                                            "auto mode could not attach ({attach_error}) or start codex runtime ({spawn_error})"
                                        ),
                                    };
                                }
                            }
                            return Ok(());
                        }
                    }
                }

                match spawn_managed_process_with_endpoint(
                    &self.config.command,
                    &self.config.args,
                    self.config.endpoint.as_deref(),
                ) {
                    Ok(child) => {
                        let pid = child.id();
                        self.state = RuntimeState::Managed { pid };
                        self.managed_process = Some(child);
                    }
                    Err(error) => {
                        self.state = RuntimeState::Degraded {
                            reason: format!("auto mode could not start codex runtime: {error}"),
                        };
                    }
                }

                Ok(())
            }
        }
    }

    pub fn snapshot(&mut self) -> RuntimeSnapshot {
        if let Some(child) = self.managed_process.as_mut()
            && let Ok(Some(status)) = child.try_wait()
        {
            self.state = RuntimeState::Degraded {
                reason: format!("managed codex runtime exited unexpectedly with status {status}"),
            };
            self.managed_process = None;
        }

        match &self.state {
            RuntimeState::Initializing => RuntimeSnapshot {
                mode: self.config.mode.as_wire().to_string(),
                state: "initializing".to_string(),
                endpoint: None,
                pid: None,
                detail: "codex runtime has not been initialized yet".to_string(),
            },
            RuntimeState::Attached { endpoint } => RuntimeSnapshot {
                mode: self.config.mode.as_wire().to_string(),
                state: "attached".to_string(),
                endpoint: Some(endpoint.clone()),
                pid: None,
                detail: "bridge is attached to an existing local codex runtime".to_string(),
            },
            RuntimeState::Managed { pid } => RuntimeSnapshot {
                mode: self.config.mode.as_wire().to_string(),
                state: "managed".to_string(),
                endpoint: None,
                pid: Some(*pid),
                detail: "bridge started and supervises a local codex runtime process".to_string(),
            },
            RuntimeState::Degraded { reason } => RuntimeSnapshot {
                mode: self.config.mode.as_wire().to_string(),
                state: "degraded".to_string(),
                endpoint: self.config.endpoint.clone(),
                pid: None,
                detail: reason.clone(),
            },
        }
    }
}

impl Drop for CodexRuntimeSupervisor {
    fn drop(&mut self) {
        if let Some(mut child) = self.managed_process.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

fn spawn_managed_process_with_endpoint(
    command: &str,
    args: &[String],
    endpoint: Option<&str>,
) -> Result<Child, String> {
    let mut cmd = Command::new(command);
    let spawn_args = build_spawn_args(args, endpoint);
    if env::var_os("CODEX_MOBILE_COMPANION_DEBUG_RUNTIME_SPAWN").is_some() {
        eprintln!(
            "bridge-core runtime spawn: command={} endpoint={:?} args={:?}",
            command, endpoint, spawn_args
        );
    }
    cmd.args(&spawn_args)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null());

    cmd.spawn().map_err(|error| {
        format!(
            "failed to spawn '{command} {}': {error}",
            spawn_args.join(" ")
        )
    })
}

fn build_spawn_args(args: &[String], endpoint: Option<&str>) -> Vec<String> {
    let mut spawn_args = args.to_vec();

    if let Some(endpoint) = endpoint
        && spawn_args.first().map(String::as_str) == Some("app-server")
        && !spawn_args.iter().any(|arg| arg == "--listen")
    {
        spawn_args.push("--listen".to_string());
        spawn_args.push(endpoint.to_string());
    }

    spawn_args
}

fn verify_endpoint_reachable(endpoint: &str) -> Result<(), String> {
    let uri: Uri = endpoint
        .parse()
        .map_err(|error| format!("invalid codex endpoint '{endpoint}': {error}"))?;
    let host = uri
        .host()
        .ok_or_else(|| format!("codex endpoint '{endpoint}' is missing host"))?;
    let port = uri.port_u16().unwrap_or(match uri.scheme_str() {
        Some("wss") => 443,
        _ => 80,
    });

    let addresses = (host, port)
        .to_socket_addrs()
        .map_err(|error| format!("failed to resolve codex endpoint host '{host}:{port}': {error}"))?
        .collect::<Vec<_>>();

    if addresses.is_empty() {
        return Err(format!(
            "failed to resolve codex endpoint host '{host}:{port}'"
        ));
    }

    let mut last_error = None;
    for address in addresses {
        match TcpStream::connect_timeout(&address, Duration::from_millis(500)) {
            Ok(_) => return Ok(()),
            Err(error) => last_error = Some(format!("{address}: {error}")),
        }
    }

    Err(format!(
        "codex endpoint '{endpoint}' is unreachable ({})",
        last_error.unwrap_or_else(|| "unknown error".to_string())
    ))
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::net::TcpListener;
    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;
    use std::path::PathBuf;
    use std::thread;
    use std::time::Duration;

    use super::{CodexRuntimeConfig, CodexRuntimeMode, CodexRuntimeSupervisor, build_spawn_args};

    #[test]
    fn attach_mode_reports_attached_state() {
        let mut supervisor = CodexRuntimeSupervisor::new(CodexRuntimeConfig {
            mode: CodexRuntimeMode::Attach,
            endpoint: Some("ws://127.0.0.1:4222".to_string()),
            command: "codex".to_string(),
            args: vec!["app-server".to_string()],
        });

        supervisor
            .initialize()
            .expect("attach mode should initialize");
        let snapshot = supervisor.snapshot();

        assert_eq!(snapshot.state, "attached");
        assert_eq!(snapshot.endpoint.as_deref(), Some("ws://127.0.0.1:4222"));
        assert_eq!(snapshot.pid, None);
    }

    #[test]
    fn spawn_mode_starts_and_reports_managed_process() {
        let mut supervisor = CodexRuntimeSupervisor::new(CodexRuntimeConfig {
            mode: CodexRuntimeMode::Spawn,
            endpoint: None,
            command: "sleep".to_string(),
            args: vec!["30".to_string()],
        });

        supervisor
            .initialize()
            .expect("spawn mode should initialize");
        let snapshot = supervisor.snapshot();

        assert_eq!(snapshot.state, "managed");
        assert!(snapshot.pid.is_some());
    }

    #[test]
    fn auto_mode_only_reports_attached_when_endpoint_is_reachable() {
        let listener = TcpListener::bind("127.0.0.1:0")
            .expect("test should bind a local reachability probe listener");
        let endpoint = format!(
            "ws://127.0.0.1:{}",
            listener
                .local_addr()
                .expect("listener should have local addr")
                .port()
        );

        let mut supervisor = CodexRuntimeSupervisor::new(CodexRuntimeConfig {
            mode: CodexRuntimeMode::Auto,
            endpoint: Some(endpoint.clone()),
            command: "missing-command".to_string(),
            args: vec![],
        });

        supervisor
            .initialize()
            .expect("auto mode should initialize when endpoint is reachable");
        let snapshot = supervisor.snapshot();

        assert_eq!(snapshot.state, "attached");
        assert_eq!(snapshot.endpoint.as_deref(), Some(endpoint.as_str()));
        assert_eq!(snapshot.pid, None);
    }

    #[test]
    fn auto_mode_falls_back_to_managed_when_attach_is_unreachable() {
        let mut supervisor = CodexRuntimeSupervisor::new(CodexRuntimeConfig {
            mode: CodexRuntimeMode::Auto,
            endpoint: Some("ws://127.0.0.1:1".to_string()),
            command: "sleep".to_string(),
            args: vec!["30".to_string()],
        });

        supervisor
            .initialize()
            .expect("auto mode should initialize by spawning when attach is unreachable");
        let snapshot = supervisor.snapshot();

        assert_eq!(snapshot.state, "managed");
        assert!(snapshot.pid.is_some());
    }

    #[test]
    fn auto_mode_reports_degraded_when_attach_and_spawn_are_unavailable() {
        let mut supervisor = CodexRuntimeSupervisor::new(CodexRuntimeConfig {
            mode: CodexRuntimeMode::Auto,
            endpoint: Some("ws://127.0.0.1:1".to_string()),
            command: "nonexistent-codex-runtime-command".to_string(),
            args: vec![],
        });

        supervisor
            .initialize()
            .expect("auto mode should still initialize into degraded state");
        let snapshot = supervisor.snapshot();

        assert_eq!(snapshot.state, "degraded");
        assert!(snapshot.detail.contains("auto mode could not attach"));
        assert!(snapshot.detail.contains("or start codex runtime"));
    }

    #[test]
    fn build_spawn_args_adds_listen_endpoint_for_app_server() {
        let args = build_spawn_args(&["app-server".to_string()], Some("ws://127.0.0.1:4222"));

        assert_eq!(
            args,
            vec![
                "app-server".to_string(),
                "--listen".to_string(),
                "ws://127.0.0.1:4222".to_string(),
            ]
        );
    }

    #[test]
    fn build_spawn_args_keeps_explicit_listen_override() {
        let args = build_spawn_args(
            &[
                "app-server".to_string(),
                "--listen".to_string(),
                "ws://127.0.0.1:5000".to_string(),
            ],
            Some("ws://127.0.0.1:4222"),
        );

        assert_eq!(
            args,
            vec![
                "app-server".to_string(),
                "--listen".to_string(),
                "ws://127.0.0.1:5000".to_string(),
            ]
        );
    }

    #[test]
    fn build_spawn_args_does_not_modify_non_app_server_commands() {
        let args = build_spawn_args(&["30".to_string()], Some("ws://127.0.0.1:4222"));

        assert_eq!(args, vec!["30".to_string()]);
    }

    #[test]
    fn spawn_mode_keeps_stdin_open_for_managed_app_server_processes() {
        let script = make_stdin_blocking_test_script("codex-runtime-stdin");
        let mut supervisor = CodexRuntimeSupervisor::new(CodexRuntimeConfig {
            mode: CodexRuntimeMode::Spawn,
            endpoint: Some("ws://127.0.0.1:4222".to_string()),
            command: script.to_string_lossy().into_owned(),
            args: vec!["app-server".to_string()],
        });

        supervisor
            .initialize()
            .expect("spawn mode should initialize with stdin-blocking helper");
        thread::sleep(Duration::from_millis(100));

        let snapshot = supervisor.snapshot();
        assert_eq!(snapshot.state, "managed");
        assert!(snapshot.pid.is_some());

        let _ = fs::remove_file(script);
    }

    fn make_stdin_blocking_test_script(name: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!("{name}-{}", std::process::id()));
        fs::write(
            &path,
            "#!/bin/sh\nif [ \"$1\" = \"app-server\" ]; then\n  shift\nfi\ncat >/dev/null\n",
        )
        .expect("test script should be written");
        #[cfg(unix)]
        fs::set_permissions(&path, fs::Permissions::from_mode(0o755))
            .expect("test script should be executable");
        path
    }
}
