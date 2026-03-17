use serde::Serialize;
use std::process::{Child, Command, Stdio};

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
                let child = spawn_managed_process(&self.config.command, &self.config.args)?;
                let pid = child.id();
                self.state = RuntimeState::Managed { pid };
                self.managed_process = Some(child);
                Ok(())
            }
            CodexRuntimeMode::Auto => {
                if let Some(endpoint) = self.config.endpoint.clone() {
                    self.state = RuntimeState::Attached { endpoint };
                    return Ok(());
                }

                match spawn_managed_process(&self.config.command, &self.config.args) {
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

fn spawn_managed_process(command: &str, args: &[String]) -> Result<Child, String> {
    let mut cmd = Command::new(command);
    cmd.args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());

    cmd.spawn()
        .map_err(|error| format!("failed to spawn '{command} {}': {error}", args.join(" ")))
}

#[cfg(test)]
mod tests {
    use super::{CodexRuntimeConfig, CodexRuntimeMode, CodexRuntimeSupervisor};

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
}
