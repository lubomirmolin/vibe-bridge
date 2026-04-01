use std::collections::{HashMap, HashSet};
use std::env;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::PathBuf;
#[cfg(not(test))]
use std::process::Command;
use std::sync::mpsc::RecvTimeoutError;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use serde::Serialize;
use serde_json::{Value, json};
use shared_contracts::{
    AccessMode, BridgeEventEnvelope, BridgeEventKind, CONTRACT_VERSION, SecurityAuditEventDto,
    ThreadGitDiffMode,
};
use tungstenite::{Message, accept};

use codex_runtime::{
    CodexRuntimeConfig, CodexRuntimeMode, CodexRuntimeSupervisor, RuntimeSnapshot,
};
use logging::{InMemoryLogSink, LogSeverity, LogSink, StructuredLogger};
use pairing::{
    PairingFinalizeError, PairingFinalizeRequest, PairingHandshakeError, PairingHandshakeRequest,
    PairingRevokeRequest, PairingSessionService, PairingTrustSnapshot,
};
use persistence::PersistenceBoundary;
use policy::{PolicyAction, PolicyDecision, PolicyEngine};
use runtime_sync::{forward_upstream_notifications_loop, reconcile_upstream_loop};
use secure_storage::InMemorySecureStore;
use stream_router::StreamRouter;
use thread_api::{
    GitStatusResponse, MutationDispatch, MutationResultResponse, RepositoryContextDto,
    ThreadApiService, ThreadGitDiffQuery,
};

pub mod codex_ipc;
pub mod codex_runtime;
pub mod codex_transport;
pub(crate) mod incremental_text;
pub mod logging;
pub mod pairing;
pub mod persistence;
pub mod policy;
pub mod runtime_sync;
pub mod secure_storage;
pub mod server;
pub mod stream_router;
#[cfg(test)]
pub(crate) mod test_support;
pub mod thread_api;

#[derive(Debug, Clone, PartialEq, Eq)]
struct Config {
    host: String,
    port: u16,
    admin_port: u16,
    state_directory: PathBuf,
    pairing_base_url: String,
    pairing_route_reachable: bool,
    pairing_route_message: Option<String>,
    pairing_route_requires_runtime_serve_check: bool,
    codex_runtime: CodexRuntimeConfig,
}

const FALLBACK_PRIVATE_PAIRING_BASE_URL: &str = "https://bridge.ts.net";
const TAILSCALE_BIN_OVERRIDE_ENV: &str = "CODEX_MOBILE_COMPANION_TAILSCALE_BIN";

#[derive(Debug, Clone, PartialEq, Eq)]
struct PairingRouteContract {
    pairing_base_url: String,
    reachable: bool,
    message: Option<String>,
    requires_runtime_serve_check: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct PairingRouteState {
    pairing_base_url: String,
    reachable: bool,
    message: Option<String>,
    bridge_port: u16,
    requires_runtime_serve_check: bool,
}

impl PairingRouteState {
    fn health(&self) -> PairingRouteHealth {
        self.health_with(discover_verified_tailscale_pairing_base_url)
    }

    fn health_with<F>(&self, discover_route: F) -> PairingRouteHealth
    where
        F: FnOnce(u16) -> Option<String>,
    {
        if self.requires_runtime_serve_check {
            if let Some(pairing_base_url) = discover_route(self.bridge_port) {
                return PairingRouteHealth {
                    reachable: true,
                    advertised_base_url: Some(pairing_base_url),
                    message: None,
                };
            }

            if self.reachable {
                return PairingRouteHealth {
                    reachable: false,
                    advertised_base_url: None,
                    message: Some(format!(
                        "Private pairing route is unavailable: verified tailscale serve mapping for localhost port {} is no longer active.",
                        self.bridge_port
                    )),
                };
            }
        }

        PairingRouteHealth {
            reachable: self.reachable,
            advertised_base_url: self.reachable.then(|| self.pairing_base_url.clone()),
            message: self.message.clone(),
        }
    }
}

impl PairingRouteContract {
    fn verified(pairing_base_url: String) -> Self {
        Self {
            pairing_base_url,
            reachable: true,
            message: None,
            requires_runtime_serve_check: true,
        }
    }

    fn explicit(pairing_base_url: String) -> Self {
        Self {
            pairing_base_url,
            reachable: true,
            message: None,
            requires_runtime_serve_check: false,
        }
    }

    fn degraded(message: String) -> Self {
        Self {
            pairing_base_url: FALLBACK_PRIVATE_PAIRING_BASE_URL.to_string(),
            reachable: false,
            message: Some(message),
            requires_runtime_serve_check: true,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BridgeFoundations {
    pub persistence: PersistenceBoundary,
    pub secure_store: InMemorySecureStore,
    pub logger: StructuredLogger<InMemoryLogSink>,
}

pub fn build_foundations(base_directory: impl Into<PathBuf>) -> BridgeFoundations {
    BridgeFoundations {
        persistence: PersistenceBoundary::new(base_directory),
        secure_store: InMemorySecureStore::new(),
        logger: StructuredLogger::new(InMemoryLogSink::default()),
    }
}

pub fn run_from_env() -> Result<(), String> {
    run(std::env::args().skip(1))
}

fn run<I>(args: I) -> Result<(), String>
where
    I: IntoIterator<Item = String>,
{
    let config = parse_args(args)?;
    let foundations = build_foundations(config.state_directory.clone());

    let mut runtime = CodexRuntimeSupervisor::new(config.codex_runtime.clone());
    runtime.initialize()?;

    let thread_api = ThreadApiService::from_codex_app_server(
        &config.codex_runtime.command,
        &config.codex_runtime.args,
        config.codex_runtime.endpoint.as_deref(),
    )
    .unwrap_or_else(|error| {
        eprintln!("failed to load codex-backed thread data: {error}");
        ThreadApiService::empty()
    });

    let app = Arc::new(BridgeApplication::new(
        thread_api,
        runtime,
        StreamRouter::new(),
        PairingSessionService::new(
            config.host.as_str(),
            config.port,
            config.pairing_base_url.clone(),
            foundations.persistence.state_directory(),
        ),
        PairingRouteState {
            pairing_base_url: config.pairing_base_url,
            reachable: config.pairing_route_reachable,
            message: config.pairing_route_message,
            bridge_port: config.port,
            requires_runtime_serve_check: config.pairing_route_requires_runtime_serve_check,
        },
        foundations.logger,
    ));

    let api_listener = TcpListener::bind((config.host.as_str(), config.port)).map_err(|error| {
        format!(
            "failed to bind API listener on {}:{}: {error}",
            config.host, config.port
        )
    })?;
    let admin_listener =
        TcpListener::bind((config.host.as_str(), config.admin_port)).map_err(|error| {
            format!(
                "failed to bind admin listener on {}:{}: {error}",
                config.host, config.admin_port
            )
        })?;

    let api_app = Arc::clone(&app);
    let api_server = thread::spawn(move || serve_listener(api_listener, api_app));

    let admin_app = Arc::clone(&app);
    let admin_server = thread::spawn(move || serve_listener(admin_listener, admin_app));

    let reconciler_app = Arc::clone(&app);
    let _reconciler = thread::spawn(move || reconcile_upstream_loop(reconciler_app));

    let notifications_app = Arc::clone(&app);
    let notification_command = config.codex_runtime.command.clone();
    let notification_args = config.codex_runtime.args.clone();
    let notification_endpoint = config.codex_runtime.endpoint.clone();
    let _notifications = thread::spawn(move || {
        forward_upstream_notifications_loop(
            notifications_app,
            notification_command,
            notification_args,
            notification_endpoint,
        )
    });

    api_server
        .join()
        .map_err(|_| "API server thread panicked".to_string())?;
    admin_server
        .join()
        .map_err(|_| "admin server thread panicked".to_string())?;

    Ok(())
}

fn parse_args<I>(args: I) -> Result<Config, String>
where
    I: IntoIterator<Item = String>,
{
    parse_args_with_pairing_route_resolver(args, resolve_default_pairing_route_contract)
}

fn parse_args_with_pairing_route_resolver<I, F>(
    args: I,
    default_pairing_route_resolver: F,
) -> Result<Config, String>
where
    I: IntoIterator<Item = String>,
    F: Fn(u16) -> PairingRouteContract,
{
    let mut host = String::from("127.0.0.1");
    let mut port = 3110_u16;
    let mut admin_port = 3111_u16;
    let mut state_directory = PathBuf::from(".");

    let mut codex_mode = CodexRuntimeMode::Auto;
    let mut codex_endpoint = Some("ws://127.0.0.1:4222".to_string());
    let mut codex_command = String::from("codex");
    let mut codex_args = vec!["app-server".to_string()];
    let mut codex_args_overridden = false;
    let mut pairing_base_url: Option<String> = None;

    let mut args_iter = args.into_iter();
    while let Some(argument) = args_iter.next() {
        match argument.as_str() {
            "--host" => {
                host = args_iter
                    .next()
                    .ok_or_else(|| String::from("missing value for --host"))?;
            }
            "--port" => {
                let value = args_iter
                    .next()
                    .ok_or_else(|| String::from("missing value for --port"))?;
                port = value
                    .parse()
                    .map_err(|_| format!("invalid --port value: {value}"))?;
            }
            "--admin-port" => {
                let value = args_iter
                    .next()
                    .ok_or_else(|| String::from("missing value for --admin-port"))?;
                admin_port = value
                    .parse()
                    .map_err(|_| format!("invalid --admin-port value: {value}"))?;
            }
            "--state-directory" => {
                let value = args_iter
                    .next()
                    .ok_or_else(|| String::from("missing value for --state-directory"))?;
                let trimmed = value.trim();
                if trimmed.is_empty() {
                    return Err(String::from(
                        "invalid --state-directory value: path is empty",
                    ));
                }
                state_directory = PathBuf::from(trimmed);
            }
            "--codex-mode" => {
                let value = args_iter
                    .next()
                    .ok_or_else(|| String::from("missing value for --codex-mode"))?;
                codex_mode = CodexRuntimeMode::from_flag(&value)?;
            }
            "--codex-endpoint" => {
                codex_endpoint = Some(
                    args_iter
                        .next()
                        .ok_or_else(|| String::from("missing value for --codex-endpoint"))?,
                );
            }
            "--codex-command" => {
                codex_command = args_iter
                    .next()
                    .ok_or_else(|| String::from("missing value for --codex-command"))?;
            }
            "--codex-arg" => {
                let value = args_iter
                    .next()
                    .ok_or_else(|| String::from("missing value for --codex-arg"))?;
                if !codex_args_overridden {
                    codex_args.clear();
                    codex_args_overridden = true;
                }
                codex_args.push(value);
            }
            "--pairing-base-url" => {
                let value = args_iter
                    .next()
                    .ok_or_else(|| String::from("missing value for --pairing-base-url"))?;
                pairing_base_url = Some(value.trim().to_string());
            }
            "--help" | "-h" => {
                return Err(String::from(
                    "usage: bridge-server [--host <ip-or-hostname>] [--port <u16>] [--admin-port <u16>] [--state-directory <path>] [--pairing-base-url <https://bridge.ts.net>] [--codex-mode <auto|spawn|attach>] [--codex-endpoint <ws-url>] [--codex-command <binary>] [--codex-arg <arg>]",
                ));
            }
            _ => {
                return Err(format!("unknown argument: {argument}"));
            }
        }
    }

    if codex_mode == CodexRuntimeMode::Attach && codex_endpoint.is_none() {
        return Err(String::from(
            "--codex-endpoint is required when --codex-mode attach",
        ));
    }

    let pairing_route = if let Some(explicit_pairing_base_url) = pairing_base_url {
        if !crate::pairing::is_private_bridge_api_base_url(&explicit_pairing_base_url) {
            return Err(String::from(
                "--pairing-base-url must be a private https Tailscale hostname",
            ));
        }

        PairingRouteContract::explicit(explicit_pairing_base_url)
    } else {
        default_pairing_route_resolver(port)
    };

    Ok(Config {
        host,
        port,
        admin_port,
        state_directory,
        pairing_base_url: pairing_route.pairing_base_url,
        pairing_route_reachable: pairing_route.reachable,
        pairing_route_message: pairing_route.message,
        pairing_route_requires_runtime_serve_check: pairing_route.requires_runtime_serve_check,
        codex_runtime: CodexRuntimeConfig {
            mode: codex_mode,
            endpoint: codex_endpoint,
            command: codex_command,
            args: codex_args,
        },
    })
}

fn resolve_default_pairing_route_contract(port: u16) -> PairingRouteContract {
    resolve_default_pairing_route_contract_with(
        port,
        discover_verified_tailscale_pairing_base_url,
        ensure_tailscale_serve_mapping,
    )
}

fn resolve_default_pairing_route_contract_with<FDiscover, FEnsure>(
    port: u16,
    mut discover_route: FDiscover,
    mut ensure_route: FEnsure,
) -> PairingRouteContract
where
    FDiscover: FnMut(u16) -> Option<String>,
    FEnsure: FnMut(u16) -> Result<(), String>,
{
    if let Some(pairing_base_url) = discover_route(port) {
        return PairingRouteContract::verified(pairing_base_url);
    }

    if let Err(error) = ensure_route(port) {
        return PairingRouteContract::degraded(format!(
            "Private pairing route is unavailable: failed to launch `tailscale serve --bg {port}`: {error}"
        ));
    }

    match discover_route(port) {
        Some(pairing_base_url) => PairingRouteContract::verified(pairing_base_url),
        None => PairingRouteContract::degraded(format!(
            "Private pairing route is unavailable: `tailscale serve --bg {port}` ran, but no verified mapping to localhost:{port} was found in `tailscale serve status --json`."
        )),
    }
}

fn discover_verified_tailscale_pairing_base_url(port: u16) -> Option<String> {
    let status = read_tailscale_json(["status", "--json"])?;
    let serve_status = read_tailscale_json(["serve", "status", "--json"])?;
    pairing_base_url_from_tailscale_status(&status, &serve_status, port)
}

fn ensure_tailscale_serve_mapping(port: u16) -> Result<(), String> {
    let port_value = port.to_string();
    let tailscale_bin = resolve_tailscale_binary()?;
    let output = std::process::Command::new(&tailscale_bin)
        .args(["serve", "--bg", port_value.as_str()])
        .output()
        .map_err(|error| {
            format!(
                "tailscale CLI unavailable at {}: {error}",
                tailscale_bin.display()
            )
        })?;

    if output.status.success() {
        return Ok(());
    }

    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
    let details = if !stderr.is_empty() {
        stderr
    } else if !stdout.is_empty() {
        stdout
    } else {
        format!("exit status {}", output.status)
    };

    Err(details)
}

fn read_tailscale_json<const N: usize>(args: [&str; N]) -> Option<Value> {
    let tailscale_bin = resolve_tailscale_binary().ok()?;
    let output = std::process::Command::new(tailscale_bin)
        .args(args)
        .output()
        .ok()?;

    if !output.status.success() {
        return None;
    }

    serde_json::from_slice(&output.stdout).ok()
}

fn resolve_tailscale_binary() -> Result<PathBuf, String> {
    resolve_cli_binary(
        TAILSCALE_BIN_OVERRIDE_ENV,
        "tailscale",
        &[
            "/opt/homebrew/bin/tailscale",
            "/usr/local/bin/tailscale",
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        ],
    )
}

fn resolve_cli_binary(
    override_env_var: &str,
    command_name: &str,
    candidate_paths: &[&str],
) -> Result<PathBuf, String> {
    if let Some(path) = env::var_os(override_env_var) {
        let candidate = PathBuf::from(path);
        if candidate.is_file() {
            return Ok(candidate);
        }
    }

    if let Some(path_var) = env::var_os("PATH") {
        for entry in env::split_paths(&path_var) {
            let candidate = entry.join(command_name);
            if candidate.is_file() {
                return Ok(candidate);
            }
        }
    }

    for path in candidate_paths {
        let candidate = PathBuf::from(path);
        if candidate.is_file() {
            return Ok(candidate);
        }
    }

    Err(format!(
        "{command_name} CLI unavailable: checked {override_env_var}, PATH, and {}",
        candidate_paths.join(", ")
    ))
}

fn pairing_base_url_from_tailscale_status(
    status: &Value,
    serve_status: &Value,
    port: u16,
) -> Option<String> {
    let dns_name = status
        .get("Self")
        .and_then(|self_node| self_node.get("DNSName"))
        .and_then(Value::as_str)?
        .trim()
        .trim_end_matches('.');

    if dns_name.is_empty()
        || !serve_status_has_exact_https_bridge_proxy(serve_status, dns_name, port)
    {
        return None;
    }

    let candidate = format!("https://{dns_name}");
    if crate::pairing::is_private_bridge_api_base_url(&candidate) {
        Some(candidate)
    } else {
        None
    }
}

fn serve_status_has_exact_https_bridge_proxy(
    serve_status: &Value,
    dns_name: &str,
    port: u16,
) -> bool {
    if !serve_status
        .get("TCP")
        .and_then(|tcp| tcp.get("443"))
        .and_then(|https_route| https_route.get("HTTPS"))
        .and_then(Value::as_bool)
        .unwrap_or(false)
    {
        return false;
    }

    let expected_web_key = format!("{}:443", dns_name.to_ascii_lowercase());
    let web_entry = serve_status
        .get("Web")
        .and_then(Value::as_object)
        .and_then(|web_routes| {
            web_routes.iter().find_map(|(key, route)| {
                (key.trim().trim_end_matches('.').to_ascii_lowercase() == expected_web_key)
                    .then_some(route)
            })
        });

    let root_handler = web_entry
        .and_then(|route| route.get("Handlers"))
        .and_then(|handlers| handlers.get("/"));

    match root_handler {
        Some(Value::String(proxy)) => proxy_targets_bridge_loopback(proxy, port),
        Some(Value::Object(handler)) => handler
            .get("Proxy")
            .and_then(Value::as_str)
            .map(|proxy| proxy_targets_bridge_loopback(proxy, port))
            .unwrap_or(false),
        _ => false,
    }
}

fn proxy_targets_bridge_loopback(raw: &str, port: u16) -> bool {
    let normalized = raw.trim().trim_end_matches('/').to_ascii_lowercase();

    normalized == format!("http://127.0.0.1:{port}")
        || normalized == format!("http://localhost:{port}")
        || normalized == format!("http://[::1]:{port}")
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
struct AccessModeResponse {
    contract_version: String,
    access_mode: AccessMode,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
struct ApprovalListResponse {
    contract_version: String,
    approvals: Vec<ApprovalRecordDto>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
struct ApprovalGateResponse {
    contract_version: String,
    operation: String,
    outcome: String,
    message: String,
    approval: ApprovalRecordDto,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
struct ApprovalResolutionResponse {
    contract_version: String,
    approval: ApprovalRecordDto,
    mutation_result: Option<MutationResultResponse>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
struct SecurityEventsResponse {
    contract_version: String,
    events: Vec<SecurityEventRecordDto>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
struct SecurityEventRecordDto {
    severity: String,
    category: String,
    event: BridgeEventEnvelope<Value>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
enum ApprovalStatus {
    Pending,
    Approved,
    Rejected,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum PendingApprovalAction {
    BranchSwitch {
        thread_id: String,
        branch: String,
    },
    Pull {
        thread_id: String,
        remote: Option<String>,
    },
    Push {
        thread_id: String,
        remote: Option<String>,
    },
}

impl PendingApprovalAction {
    fn thread_id(&self) -> &str {
        match self {
            Self::BranchSwitch { thread_id, .. }
            | Self::Pull { thread_id, .. }
            | Self::Push { thread_id, .. } => thread_id,
        }
    }

    fn operation_name(&self) -> &'static str {
        match self {
            Self::BranchSwitch { .. } => "git_branch_switch",
            Self::Pull { .. } => "git_pull",
            Self::Push { .. } => "git_push",
        }
    }

    fn target_name(&self) -> String {
        match self {
            Self::BranchSwitch { branch, .. } => branch.clone(),
            Self::Pull { .. } => "git.pull".to_string(),
            Self::Push { .. } => "git.push".to_string(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
struct ApprovalRecordDto {
    contract_version: String,
    approval_id: String,
    thread_id: String,
    action: String,
    target: String,
    reason: String,
    status: ApprovalStatus,
    requested_at: String,
    resolved_at: Option<String>,
    repository: RepositoryContextDto,
    git_status: thread_api::GitStatusDto,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct PendingApprovalRecord {
    approval: ApprovalRecordDto,
    action: PendingApprovalAction,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum ResolveApprovalError {
    NotFound,
    NotPending,
}

#[derive(Debug)]
struct SecurityState {
    policy_engine: PolicyEngine,
    approvals: Vec<PendingApprovalRecord>,
    next_approval_sequence: u64,
    next_security_event_sequence: u64,
    logger: StructuredLogger<InMemoryLogSink>,
}

impl SecurityState {
    fn new(logger: StructuredLogger<InMemoryLogSink>) -> Self {
        Self {
            policy_engine: PolicyEngine::default(),
            approvals: Vec::new(),
            next_approval_sequence: 1,
            next_security_event_sequence: 1,
            logger,
        }
    }

    fn access_mode(&self) -> AccessMode {
        self.policy_engine.access_mode()
    }

    fn set_access_mode(&mut self, access_mode: AccessMode) {
        self.policy_engine.set_access_mode(access_mode);
    }

    fn decide(&self, action: PolicyAction) -> PolicyDecision {
        self.policy_engine.decide(action)
    }

    fn queue_approval(
        &mut self,
        action: PendingApprovalAction,
        reason: &str,
        repository: RepositoryContextDto,
        git_status: thread_api::GitStatusDto,
    ) -> ApprovalRecordDto {
        let sequence = self.next_approval_sequence;
        self.next_approval_sequence = self.next_approval_sequence.saturating_add(1);

        let approval = ApprovalRecordDto {
            contract_version: CONTRACT_VERSION.to_string(),
            approval_id: format!("approval-{sequence}"),
            thread_id: action.thread_id().to_string(),
            action: action.operation_name().to_string(),
            target: action.target_name(),
            reason: reason.to_string(),
            status: ApprovalStatus::Pending,
            requested_at: timestamp_from_sequence(sequence),
            resolved_at: None,
            repository,
            git_status,
        };

        self.approvals.push(PendingApprovalRecord {
            approval: approval.clone(),
            action,
        });

        approval
    }

    fn approvals_snapshot(&self) -> Vec<ApprovalRecordDto> {
        self.approvals
            .iter()
            .map(|record| record.approval.clone())
            .collect::<Vec<_>>()
    }

    fn resolve_approval(
        &mut self,
        approval_id: &str,
        approved: bool,
    ) -> Result<PendingApprovalRecord, ResolveApprovalError> {
        let sequence = self.next_approval_sequence;
        self.next_approval_sequence = self.next_approval_sequence.saturating_add(1);

        let record = self
            .approvals
            .iter_mut()
            .find(|record| record.approval.approval_id == approval_id)
            .ok_or(ResolveApprovalError::NotFound)?;

        if record.approval.status != ApprovalStatus::Pending {
            return Err(ResolveApprovalError::NotPending);
        }

        record.approval.status = if approved {
            ApprovalStatus::Approved
        } else {
            ApprovalStatus::Rejected
        };
        record.approval.resolved_at = Some(timestamp_from_sequence(sequence));

        Ok(record.clone())
    }

    fn rollback_approval_resolution(
        &mut self,
        approval_id: &str,
    ) -> Result<PendingApprovalRecord, ResolveApprovalError> {
        let record = self
            .approvals
            .iter_mut()
            .find(|record| record.approval.approval_id == approval_id)
            .ok_or(ResolveApprovalError::NotFound)?;

        if record.approval.status == ApprovalStatus::Pending {
            return Ok(record.clone());
        }

        record.approval.status = ApprovalStatus::Pending;
        record.approval.resolved_at = None;

        Ok(record.clone())
    }

    fn log_security_audit(
        &mut self,
        severity: LogSeverity,
        thread_id: impl Into<String>,
        audit_event: SecurityAuditEventDto,
    ) -> BridgeEventEnvelope<Value> {
        let sequence = self.next_security_event_sequence;
        self.next_security_event_sequence = self.next_security_event_sequence.saturating_add(1);
        let event_id = format!("evt-security-{sequence}");
        let occurred_at = timestamp_from_sequence(sequence);
        let payload = serde_json::to_value(&audit_event)
            .expect("security audit event serialization should never fail");
        let event = BridgeEventEnvelope::new(
            event_id,
            thread_id,
            BridgeEventKind::SecurityAudit,
            occurred_at,
            payload,
        );

        self.logger.log_security_audit(
            severity,
            event.event_id.clone(),
            event.thread_id.clone(),
            event.occurred_at.clone(),
            audit_event,
        );

        event
    }

    fn security_events_snapshot(&self) -> Vec<SecurityEventRecordDto> {
        self.logger
            .sink()
            .records()
            .iter()
            .map(|record| SecurityEventRecordDto {
                severity: log_severity_wire(record.severity).to_string(),
                category: record.category.to_string(),
                event: record.event.clone(),
            })
            .collect::<Vec<_>>()
    }
}

fn log_severity_wire(severity: LogSeverity) -> &'static str {
    match severity {
        LogSeverity::Debug => "debug",
        LogSeverity::Info => "info",
        LogSeverity::Warn => "warn",
        LogSeverity::Error => "error",
    }
}

fn timestamp_from_sequence(sequence: u64) -> String {
    let minute = (sequence / 60) % 60;
    let second = sequence % 60;
    format!("2026-03-17T23:{minute:02}:{second:02}Z")
}

fn parse_access_mode(raw: &str) -> Option<AccessMode> {
    match raw.trim() {
        "read_only" => Some(AccessMode::ReadOnly),
        "control_with_approvals" => Some(AccessMode::ControlWithApprovals),
        "full_control" => Some(AccessMode::FullControl),
        _ => None,
    }
}

#[derive(Debug)]
pub(crate) struct BridgeApplication {
    thread_api: Mutex<ThreadApiService>,
    runtime: Mutex<CodexRuntimeSupervisor>,
    stream_router: StreamRouter,
    pairing_sessions: Mutex<PairingSessionService>,
    pairing_route: PairingRouteState,
    security_state: Mutex<SecurityState>,
}

impl BridgeApplication {
    fn new(
        thread_api: ThreadApiService,
        runtime: CodexRuntimeSupervisor,
        stream_router: StreamRouter,
        pairing_sessions: PairingSessionService,
        pairing_route: PairingRouteState,
        logger: StructuredLogger<InMemoryLogSink>,
    ) -> Self {
        Self {
            thread_api: Mutex::new(thread_api),
            runtime: Mutex::new(runtime),
            stream_router,
            pairing_sessions: Mutex::new(pairing_sessions),
            pairing_route,
            security_state: Mutex::new(SecurityState::new(logger)),
        }
    }

    fn pairing_route_health(&self) -> PairingRouteHealth {
        self.pairing_route.health()
    }

    fn trust_snapshot(&self) -> PairingTrustSnapshot {
        self.pairing_sessions
            .lock()
            .expect("pairing sessions mutex should not be poisoned")
            .trust_snapshot()
    }

    fn runtime_snapshot(&self) -> RuntimeSnapshot {
        self.runtime
            .lock()
            .expect("runtime mutex should not be poisoned")
            .snapshot()
    }

    fn access_mode(&self) -> AccessMode {
        self.security_state
            .lock()
            .expect("security state mutex should not be poisoned")
            .access_mode()
    }

    fn set_access_mode(&self, access_mode: AccessMode) {
        self.security_state
            .lock()
            .expect("security state mutex should not be poisoned")
            .set_access_mode(access_mode);
    }

    fn decide_policy(&self, action: PolicyAction) -> PolicyDecision {
        self.security_state
            .lock()
            .expect("security state mutex should not be poisoned")
            .decide(action)
    }

    fn queue_approval(
        &self,
        action: PendingApprovalAction,
        reason: &str,
        repository: RepositoryContextDto,
        git_status: thread_api::GitStatusDto,
    ) -> ApprovalRecordDto {
        self.security_state
            .lock()
            .expect("security state mutex should not be poisoned")
            .queue_approval(action, reason, repository, git_status)
    }

    fn approvals_snapshot(&self) -> Vec<ApprovalRecordDto> {
        self.security_state
            .lock()
            .expect("security state mutex should not be poisoned")
            .approvals_snapshot()
    }

    fn resolve_approval(
        &self,
        approval_id: &str,
        approved: bool,
    ) -> Result<PendingApprovalRecord, ResolveApprovalError> {
        self.security_state
            .lock()
            .expect("security state mutex should not be poisoned")
            .resolve_approval(approval_id, approved)
    }

    fn rollback_approval_resolution(
        &self,
        approval_id: &str,
    ) -> Result<PendingApprovalRecord, ResolveApprovalError> {
        self.security_state
            .lock()
            .expect("security state mutex should not be poisoned")
            .rollback_approval_resolution(approval_id)
    }

    fn authorize_trusted_session(
        &self,
        request: PairingHandshakeRequest,
    ) -> Result<(), PairingHandshakeError> {
        self.pairing_sessions
            .lock()
            .expect("pairing sessions mutex should not be poisoned")
            .handshake(request)
            .map(|_| ())
    }

    fn security_events_snapshot(&self) -> Vec<SecurityEventRecordDto> {
        self.security_state
            .lock()
            .expect("security state mutex should not be poisoned")
            .security_events_snapshot()
    }

    fn record_security_audit(
        &self,
        severity: LogSeverity,
        thread_id: impl Into<String>,
        audit_event: SecurityAuditEventDto,
    ) {
        let event = self
            .security_state
            .lock()
            .expect("security state mutex should not be poisoned")
            .log_security_audit(severity, thread_id, audit_event);
        self.stream_router.publish(event);
    }

    pub(crate) fn reconcile_upstream_activity(
        &self,
    ) -> Result<Vec<BridgeEventEnvelope<Value>>, String> {
        self.thread_api
            .lock()
            .expect("thread API mutex should not be poisoned")
            .reconcile_from_upstream()
    }

    pub(crate) fn subscriber_count(&self) -> usize {
        self.stream_router.subscriber_count()
    }

    pub(crate) fn publish_stream_event(&self, event: BridgeEventEnvelope<Value>) {
        self.stream_router.publish(event);
    }

    pub(crate) fn apply_live_upstream_event(&self, event: BridgeEventEnvelope<Value>) {
        self.thread_api
            .lock()
            .expect("thread API mutex should not be poisoned")
            .apply_live_event(event.clone());
        self.stream_router.publish(event);
    }
}

fn serve_listener(listener: TcpListener, app: Arc<BridgeApplication>) {
    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                let app = Arc::clone(&app);
                thread::spawn(move || {
                    if let Err(error) = handle_connection(stream, &app) {
                        eprintln!("connection error: {error}");
                    }
                });
            }
            Err(error) => {
                eprintln!("listener error: {error}");
                break;
            }
        }
    }
}

fn handle_connection(mut stream: TcpStream, app: &Arc<BridgeApplication>) -> Result<(), String> {
    let mut preview_buffer = [0_u8; 4096];
    let preview_bytes = stream
        .peek(&mut preview_buffer)
        .map_err(|error| format!("failed to peek request: {error}"))?;

    let preview_text = String::from_utf8_lossy(&preview_buffer[..preview_bytes]);
    let request_line = preview_text.lines().next().unwrap_or_default();
    let mut request_parts = request_line.split_whitespace();
    let method = request_parts.next().unwrap_or_default();
    let target = request_parts.next().unwrap_or_default();

    if method == "GET"
        && target.starts_with("/stream")
        && is_websocket_upgrade_request(&preview_text)
    {
        return handle_websocket_connection(stream, app, target);
    }

    let mut request_buffer = [0_u8; 8192];
    let bytes_read = stream
        .read(&mut request_buffer)
        .map_err(|error| format!("failed to read request: {error}"))?;
    let request_text = String::from_utf8_lossy(&request_buffer[..bytes_read]);
    let request_line = request_text.lines().next().unwrap_or_default();

    let response = route_request(request_line, app);
    stream
        .write_all(response.as_bytes())
        .map_err(|error| format!("failed to write response: {error}"))
}

fn handle_websocket_connection(
    stream: TcpStream,
    app: &BridgeApplication,
    target: &str,
) -> Result<(), String> {
    let mut websocket =
        accept(stream).map_err(|error| format!("websocket accept failed: {error}"))?;

    let mut thread_ids = parse_stream_thread_ids(target);
    if thread_ids.is_empty() {
        let mut thread_api = app
            .thread_api
            .lock()
            .expect("thread API mutex should not be poisoned");
        log_thread_sync_error(thread_api.sync_from_upstream());
        thread_ids = thread_api
            .list_response()
            .threads
            .into_iter()
            .map(|thread| thread.thread_id)
            .collect::<Vec<_>>();
    }

    let subscription = app.stream_router.subscribe(thread_ids.clone());
    let subscribed = json!({
        "contract_version": shared_contracts::CONTRACT_VERSION,
        "event": "subscribed",
        "thread_ids": thread_ids,
    });

    websocket
        .send(Message::Text(subscribed.to_string()))
        .map_err(|error| format!("failed to send websocket subscription ack: {error}"))?;

    let result = loop {
        match subscription.receiver.recv_timeout(Duration::from_secs(15)) {
            Ok(event) => {
                let frame = serde_json::to_string(&event)
                    .expect("websocket event serialization should not fail");
                if let Err(error) = websocket.send(Message::Text(frame)) {
                    break Err(format!("failed to send websocket event: {error}"));
                }
            }
            Err(RecvTimeoutError::Timeout) => {
                if websocket.send(Message::Ping(Vec::new())).is_err() {
                    break Ok(());
                }
            }
            Err(RecvTimeoutError::Disconnected) => break Ok(()),
        }
    };

    app.stream_router.unsubscribe(subscription.id);
    result
}

fn is_websocket_upgrade_request(request_preview: &str) -> bool {
    let mut has_upgrade_header = false;
    let mut has_connection_upgrade = false;

    for line in request_preview.lines() {
        let normalized = line.trim().to_ascii_lowercase();
        if normalized.starts_with("upgrade:") && normalized.contains("websocket") {
            has_upgrade_header = true;
        }
        if normalized.starts_with("connection:") && normalized.contains("upgrade") {
            has_connection_upgrade = true;
        }
    }

    has_upgrade_header && has_connection_upgrade
}

fn parse_stream_thread_ids(target: &str) -> Vec<String> {
    let query = target
        .split_once('?')
        .map(|(_, query)| query)
        .unwrap_or_default();

    let mut thread_ids = HashSet::new();
    for pair in query.split('&').filter(|pair| !pair.is_empty()) {
        let (raw_key, raw_value) = pair.split_once('=').unwrap_or((pair, ""));
        let key = decode_component(raw_key);
        if key != "thread_id" && key != "thread_ids" {
            continue;
        }

        let value = decode_component(raw_value);
        for thread_id in value.split(',') {
            let thread_id = thread_id.trim();
            if !thread_id.is_empty() {
                thread_ids.insert(thread_id.to_string());
            }
        }
    }

    thread_ids.into_iter().collect::<Vec<_>>()
}

fn log_thread_sync_error(result: Result<(), String>) {
    if let Err(error) = result {
        eprintln!("failed to refresh Codex thread snapshot: {error}");
    }
}

fn route_request(request_line: &str, app: &BridgeApplication) -> String {
    let mut parts = request_line.split_whitespace();
    let method = parts.next().unwrap_or_default();
    let target = parts.next().unwrap_or_default();

    if method != "GET" && method != "POST" {
        return method_not_allowed_response();
    }

    let (path, query) = split_target(target);
    eprintln!("debug route_request method={method} target={target} path={path}");

    match (method, path) {
        ("GET", "/health") => {
            let seeded_thread_count = app
                .thread_api
                .lock()
                .expect("thread API mutex should not be poisoned")
                .list_response()
                .threads
                .len();
            let payload = HealthResponse {
                status: "ok",
                runtime: app.runtime_snapshot(),
                pairing_route: app.pairing_route_health(),
                trust: app.trust_snapshot(),
                api: ApiSurface {
                    endpoints: vec![
                        "POST /pairing/session",
                        "POST /pairing/finalize",
                        "POST /pairing/handshake",
                        "POST /pairing/trust/revoke",
                        "GET /policy/access-mode",
                        "POST /policy/access-mode?mode=<read_only|control_with_approvals|full_control>",
                        "GET /models",
                        "GET /threads",
                        "GET /threads/:id",
                        "GET /threads/:id/timeline?before=<event_id>&limit=<n>",
                        "POST /threads/:id/open-on-mac",
                        "GET /threads/:id/git/status",
                        "GET /threads/:id/git/diff?mode=<workspace|latest_thread_change>&path=<repo_path>",
                        "POST /threads/:id/turns/start",
                        "POST /threads/:id/turns/steer",
                        "POST /threads/:id/turns/interrupt",
                        "POST /threads/:id/git/branch-switch",
                        "POST /threads/:id/git/pull",
                        "POST /threads/:id/git/push",
                        "GET /approvals",
                        "POST /approvals/:id/approve",
                        "POST /approvals/:id/reject",
                        "GET /security/events",
                        "WS /stream?thread_id=<id>",
                    ],
                    seeded_thread_count,
                },
            };
            json_response("200 OK", &payload)
        }
        ("GET", "/policy/access-mode") => {
            let payload = AccessModeResponse {
                contract_version: CONTRACT_VERSION.to_string(),
                access_mode: app.access_mode(),
            };
            json_response("200 OK", &payload)
        }
        ("POST", "/policy/access-mode") => {
            let Some(raw_mode) = query_required(&query, "mode") else {
                return bad_request_response("missing_required_query_param: mode");
            };
            let Some(access_mode) = parse_access_mode(&raw_mode) else {
                return bad_request_response("invalid_access_mode");
            };

            let actor = query
                .get("actor")
                .cloned()
                .unwrap_or_else(|| "mobile-device".to_string());

            let trusted_session = match trusted_session_request_from_query(&query) {
                Ok(request) => request,
                Err((code, message)) => {
                    app.record_security_audit(
                        LogSeverity::Warn,
                        "policy",
                        SecurityAuditEventDto {
                            actor: actor.clone(),
                            action: "set_access_mode".to_string(),
                            target: "policy.access_mode".to_string(),
                            outcome: "denied".to_string(),
                            reason: code.to_string(),
                        },
                    );
                    return json_error_response(
                        "403 Forbidden",
                        "policy_access_mode_denied",
                        code,
                        message,
                    );
                }
            };

            if let Err(error) = app.authorize_trusted_session(trusted_session) {
                app.record_security_audit(
                    LogSeverity::Warn,
                    "policy",
                    SecurityAuditEventDto {
                        actor: actor.clone(),
                        action: "set_access_mode".to_string(),
                        target: "policy.access_mode".to_string(),
                        outcome: "denied".to_string(),
                        reason: error.code().to_string(),
                    },
                );

                return json_error_response(
                    "403 Forbidden",
                    "policy_access_mode_denied",
                    error.code(),
                    error.message(),
                );
            }

            app.set_access_mode(access_mode);
            app.record_security_audit(
                LogSeverity::Info,
                "policy",
                SecurityAuditEventDto {
                    actor,
                    action: "set_access_mode".to_string(),
                    target: "policy.access_mode".to_string(),
                    outcome: "allowed".to_string(),
                    reason: format!("mode={raw_mode}"),
                },
            );

            let payload = AccessModeResponse {
                contract_version: CONTRACT_VERSION.to_string(),
                access_mode,
            };
            json_response("200 OK", &payload)
        }
        ("GET", "/approvals") => {
            let payload = ApprovalListResponse {
                contract_version: CONTRACT_VERSION.to_string(),
                approvals: app.approvals_snapshot(),
            };
            json_response("200 OK", &payload)
        }
        ("GET", "/security/events") => {
            let payload = SecurityEventsResponse {
                contract_version: CONTRACT_VERSION.to_string(),
                events: app.security_events_snapshot(),
            };
            json_response("200 OK", &payload)
        }
        ("GET", "/models") => {
            let thread_api = app
                .thread_api
                .lock()
                .expect("thread API mutex should not be poisoned");
            let payload = thread_api.model_catalog_response();
            json_response("200 OK", &payload)
        }
        ("GET", "/threads") => {
            let mut thread_api = app
                .thread_api
                .lock()
                .expect("thread API mutex should not be poisoned");
            log_thread_sync_error(thread_api.sync_from_upstream());
            let response = thread_api.list_response();
            json_response("200 OK", &response)
        }
        (_, "/stream") => upgrade_required_response(),
        _ => route_pairing_request(method, path, &query, app)
            .or_else(|| route_approval_request(method, path, &query, app))
            .or_else(|| route_thread_request(method, path, &query, app))
            .unwrap_or_else(not_found_response),
    }
}

fn route_pairing_request(
    method: &str,
    path: &str,
    query: &HashMap<String, String>,
    app: &BridgeApplication,
) -> Option<String> {
    match (method, path) {
        ("POST", "/pairing/session") | ("GET", "/pairing/session") => {
            let pairing_route = app.pairing_route_health();
            if !pairing_route.reachable {
                let message = pairing_route
                    .message
                    .as_deref()
                    .unwrap_or("Private pairing route is unavailable.");
                return Some(json_error_response(
                    "503 Service Unavailable",
                    "pairing_session_unavailable",
                    "private_pairing_route_unavailable",
                    message,
                ));
            }

            let session = app
                .pairing_sessions
                .lock()
                .expect("pairing sessions mutex should not be poisoned")
                .issue_session();
            Some(json_response("200 OK", &session))
        }
        ("POST", "/pairing/finalize") => {
            let Some(session_id) = query_required(query, "session_id") else {
                return Some(bad_request_response(
                    "missing_required_query_param: session_id",
                ));
            };
            let Some(pairing_token) = query_required(query, "pairing_token") else {
                return Some(bad_request_response(
                    "missing_required_query_param: pairing_token",
                ));
            };
            let Some(phone_id) = query_required(query, "phone_id") else {
                return Some(bad_request_response(
                    "missing_required_query_param: phone_id",
                ));
            };
            let Some(phone_name) = query_required(query, "phone_name") else {
                return Some(bad_request_response(
                    "missing_required_query_param: phone_name",
                ));
            };
            let Some(bridge_id) = query_required(query, "bridge_id") else {
                return Some(bad_request_response(
                    "missing_required_query_param: bridge_id",
                ));
            };

            let request = PairingFinalizeRequest {
                session_id,
                pairing_token,
                phone_id,
                phone_name,
                bridge_id,
            };

            let result = app
                .pairing_sessions
                .lock()
                .expect("pairing sessions mutex should not be poisoned")
                .finalize_trust(request);

            Some(match result {
                Ok(response) => json_response("200 OK", &response),
                Err(error) => pairing_finalize_error_response(error),
            })
        }
        ("POST", "/pairing/handshake") => {
            let Some(phone_id) = query_required(query, "phone_id") else {
                return Some(bad_request_response(
                    "missing_required_query_param: phone_id",
                ));
            };
            let Some(bridge_id) = query_required(query, "bridge_id") else {
                return Some(bad_request_response(
                    "missing_required_query_param: bridge_id",
                ));
            };
            let Some(session_token) = query_required(query, "session_token") else {
                return Some(bad_request_response(
                    "missing_required_query_param: session_token",
                ));
            };

            let request = PairingHandshakeRequest {
                phone_id,
                bridge_id,
                session_token,
            };

            let result = app
                .pairing_sessions
                .lock()
                .expect("pairing sessions mutex should not be poisoned")
                .handshake(request);

            Some(match result {
                Ok(response) => json_response("200 OK", &response),
                Err(error) => pairing_handshake_error_response(error),
            })
        }
        ("POST", "/pairing/trust/revoke") => {
            let phone_id = query
                .get("phone_id")
                .map(|value| value.trim())
                .and_then(|value| {
                    if value.is_empty() {
                        None
                    } else {
                        Some(value.to_string())
                    }
                });
            let actor = query.get("actor").cloned().unwrap_or_else(|| {
                if phone_id.is_some() {
                    "mobile-device".to_string()
                } else {
                    "desktop-shell".to_string()
                }
            });

            let result = app
                .pairing_sessions
                .lock()
                .expect("pairing sessions mutex should not be poisoned")
                .revoke_trust(PairingRevokeRequest { phone_id });

            Some(match result {
                Ok(response) => {
                    app.record_security_audit(
                        if response.revoked {
                            LogSeverity::Info
                        } else {
                            LogSeverity::Warn
                        },
                        "pairing",
                        SecurityAuditEventDto {
                            actor,
                            action: "revoke_trust".to_string(),
                            target: "pairing.trust".to_string(),
                            outcome: if response.revoked {
                                "allowed".to_string()
                            } else {
                                "denied".to_string()
                            },
                            reason: if response.revoked {
                                "trust_revoked".to_string()
                            } else {
                                "no_matching_trusted_phone_or_session".to_string()
                            },
                        },
                    );
                    json_response("200 OK", &response)
                }
                Err(error) => {
                    app.record_security_audit(
                        LogSeverity::Warn,
                        "pairing",
                        SecurityAuditEventDto {
                            actor,
                            action: "revoke_trust".to_string(),
                            target: "pairing.trust".to_string(),
                            outcome: "denied".to_string(),
                            reason: "storage_error".to_string(),
                        },
                    );
                    json_error_response(
                        "500 Internal Server Error",
                        "pairing_revoke_failed",
                        "storage_error",
                        &error,
                    )
                }
            })
        }
        _ => None,
    }
}

fn query_required(query: &HashMap<String, String>, key: &str) -> Option<String> {
    query
        .get(key)
        .map(String::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToString::to_string)
}

fn trusted_session_request_from_query(
    query: &HashMap<String, String>,
) -> Result<PairingHandshakeRequest, (&'static str, &'static str)> {
    let Some(phone_id) = query_required(query, "phone_id") else {
        return Err((
            "trusted_session_required",
            "Trusted session authorization is required for access mode changes.",
        ));
    };
    let Some(bridge_id) = query_required(query, "bridge_id") else {
        return Err((
            "trusted_session_required",
            "Trusted session authorization is required for access mode changes.",
        ));
    };
    let Some(session_token) = query_required(query, "session_token") else {
        return Err((
            "trusted_session_required",
            "Trusted session authorization is required for access mode changes.",
        ));
    };

    Ok(PairingHandshakeRequest {
        phone_id,
        bridge_id,
        session_token,
    })
}

fn route_thread_request(
    method: &str,
    path: &str,
    query: &HashMap<String, String>,
    app: &BridgeApplication,
) -> Option<String> {
    let thread_path = path.strip_prefix("/threads/")?;
    let segments = thread_path
        .split('/')
        .filter(|segment| !segment.is_empty())
        .collect::<Vec<_>>();
    let thread_id = *segments.first()?;

    match (method, segments.as_slice()) {
        ("GET", [_]) => {
            let mut thread_api = app
                .thread_api
                .lock()
                .expect("thread API mutex should not be poisoned");
            log_thread_sync_error(thread_api.sync_thread_from_upstream(thread_id));
            let mut detail = thread_api.detail_response(thread_id)?;
            detail.thread.access_mode = app.access_mode();
            Some(json_response("200 OK", &detail))
        }
        ("GET", [_, "timeline"]) => {
            let mut thread_api = app
                .thread_api
                .lock()
                .expect("thread API mutex should not be poisoned");
            log_thread_sync_error(thread_api.sync_thread_from_upstream(thread_id));
            let thread_exists = thread_api.detail_response(thread_id).is_some();
            if !thread_exists {
                return None;
            }
            let before = if let Some(raw_before) = query.get("before") {
                let trimmed = raw_before.trim();
                if trimmed.is_empty() {
                    return Some(bad_request_response(
                        "The timeline before cursor query parameter must not be empty.",
                    ));
                }
                Some(trimmed.to_string())
            } else {
                None
            };
            let limit = if let Some(raw_limit) = query.get("limit") {
                let trimmed = raw_limit.trim();
                if trimmed.is_empty() {
                    return Some(bad_request_response(
                        "The timeline limit query parameter must not be empty.",
                    ));
                }

                match trimmed.parse::<usize>() {
                    Ok(value) => value.clamp(1, 200),
                    Err(_) => {
                        return Some(bad_request_response(
                            "The timeline limit query parameter must be a positive integer.",
                        ));
                    }
                }
            } else {
                50
            };
            if let Some(before_cursor) = before.as_deref()
                && !thread_api
                    .timeline_cursor_exists(thread_id, before_cursor)
                    .unwrap_or(false)
            {
                return Some(bad_request_response(
                    "The provided timeline cursor does not exist for this thread.",
                ));
            }
            let timeline =
                thread_api.timeline_page_response(thread_id, before.as_deref(), limit)?;
            Some(json_response("200 OK", &timeline))
        }
        ("POST", [_, "open-on-mac"]) => {
            let thread_api = app
                .thread_api
                .lock()
                .expect("thread API mutex should not be poisoned");
            let thread_exists = thread_api.detail_response(thread_id).is_some();
            if !thread_exists {
                return None;
            }

            Some(match open_thread_in_codex_app(thread_id) {
                Ok(response) => json_response("200 OK", &response),
                Err(message) => json_error_response(
                    "503 Service Unavailable",
                    "open_on_mac_failed",
                    "codex_app_unavailable",
                    &message,
                ),
            })
        }
        ("GET", [_, "git", "status"]) => {
            let thread_api = app
                .thread_api
                .lock()
                .expect("thread API mutex should not be poisoned");
            let status = thread_api.git_status_response(thread_id)?;
            Some(json_response("200 OK", &status))
        }
        ("GET", [_, "git", "diff"]) => {
            let Some(raw_mode) = query.get("mode").map(String::as_str) else {
                return Some(bad_request_response("missing_required_query_param: mode"));
            };
            let mode = match raw_mode.trim() {
                "workspace" => ThreadGitDiffMode::Workspace,
                "latest_thread_change" => ThreadGitDiffMode::LatestThreadChange,
                _ => return Some(bad_request_response("invalid_git_diff_mode")),
            };
            let path = query
                .get("path")
                .map(String::as_str)
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(ToString::to_string);

            let mut thread_api = app
                .thread_api
                .lock()
                .expect("thread API mutex should not be poisoned");
            log_thread_sync_error(thread_api.sync_thread_from_upstream(thread_id));
            match thread_api.git_diff_response(thread_id, &ThreadGitDiffQuery { mode, path }) {
                Some(diff) => Some(json_response("200 OK", &diff)),
                None => {
                    if thread_api.detail_response(thread_id).is_none() {
                        None
                    } else {
                        Some(json_error_response(
                            "422 Unprocessable Entity",
                            "git_diff_unavailable",
                            "git_diff_unavailable",
                            "Git diff is unavailable for this thread workspace.",
                        ))
                    }
                }
            }
        }
        ("POST", [_, "turns", "start"]) => {
            let actor = query
                .get("actor")
                .map(String::as_str)
                .unwrap_or("mobile-device");
            let decision = app.decide_policy(PolicyAction::TurnStart);
            if let PolicyDecision::Deny { reason } = decision {
                return Some(policy_denied_response_with_audit(
                    app,
                    thread_id,
                    actor,
                    "turn_start",
                    "turn.start",
                    reason,
                ));
            }

            let prompt = query.get("prompt").map(String::as_str);
            let dispatch = match app
                .thread_api
                .lock()
                .expect("thread API mutex should not be poisoned")
                .start_turn(thread_id, prompt)
            {
                Ok(Some(dispatch)) => dispatch,
                Ok(None) => return None,
                Err(message) => {
                    return Some(json_error_response(
                        "502 Bad Gateway",
                        "turn_start_failed",
                        "upstream_mutation_failed",
                        &message,
                    ));
                }
            };
            app.record_security_audit(
                LogSeverity::Info,
                thread_id,
                SecurityAuditEventDto {
                    actor: actor.to_string(),
                    action: "turn_start".to_string(),
                    target: "turn.start".to_string(),
                    outcome: "allowed".to_string(),
                    reason: "policy_allow".to_string(),
                },
            );
            Some(dispatch_response(app, dispatch))
        }
        ("POST", [_, "turns", "steer"]) => {
            let actor = query
                .get("actor")
                .map(String::as_str)
                .unwrap_or("mobile-device");
            let decision = app.decide_policy(PolicyAction::TurnSteer);
            if let PolicyDecision::Deny { reason } = decision {
                return Some(policy_denied_response_with_audit(
                    app,
                    thread_id,
                    actor,
                    "turn_steer",
                    "turn.steer",
                    reason,
                ));
            }

            let instruction = query.get("instruction").map(String::as_str);
            let dispatch = match app
                .thread_api
                .lock()
                .expect("thread API mutex should not be poisoned")
                .steer_turn(thread_id, instruction)
            {
                Ok(Some(dispatch)) => dispatch,
                Ok(None) => return None,
                Err(message) => {
                    return Some(json_error_response(
                        "502 Bad Gateway",
                        "turn_steer_failed",
                        "upstream_mutation_failed",
                        &message,
                    ));
                }
            };
            app.record_security_audit(
                LogSeverity::Info,
                thread_id,
                SecurityAuditEventDto {
                    actor: actor.to_string(),
                    action: "turn_steer".to_string(),
                    target: "turn.steer".to_string(),
                    outcome: "allowed".to_string(),
                    reason: "policy_allow".to_string(),
                },
            );
            Some(dispatch_response(app, dispatch))
        }
        ("POST", [_, "turns", "interrupt"]) => {
            let actor = query
                .get("actor")
                .map(String::as_str)
                .unwrap_or("mobile-device");
            let decision = app.decide_policy(PolicyAction::TurnInterrupt);
            if let PolicyDecision::Deny { reason } = decision {
                return Some(policy_denied_response_with_audit(
                    app,
                    thread_id,
                    actor,
                    "turn_interrupt",
                    "turn.interrupt",
                    reason,
                ));
            }

            let dispatch = match app
                .thread_api
                .lock()
                .expect("thread API mutex should not be poisoned")
                .interrupt_turn(thread_id)
            {
                Ok(Some(dispatch)) => dispatch,
                Ok(None) => return None,
                Err(message) => {
                    return Some(json_error_response(
                        "502 Bad Gateway",
                        "turn_interrupt_failed",
                        "upstream_mutation_failed",
                        &message,
                    ));
                }
            };
            app.record_security_audit(
                LogSeverity::Info,
                thread_id,
                SecurityAuditEventDto {
                    actor: actor.to_string(),
                    action: "turn_interrupt".to_string(),
                    target: "turn.interrupt".to_string(),
                    outcome: "allowed".to_string(),
                    reason: "policy_allow".to_string(),
                },
            );
            Some(dispatch_response(app, dispatch))
        }
        ("POST", [_, "git", "branch-switch"]) => {
            let Some(branch) = query.get("branch") else {
                return Some(bad_request_response("missing_required_query_param: branch"));
            };

            if branch.trim().is_empty() {
                return Some(bad_request_response("invalid_branch"));
            }

            let actor = query
                .get("actor")
                .map(String::as_str)
                .unwrap_or("mobile-device");
            let decision = app.decide_policy(PolicyAction::GitBranchSwitch);

            if let PolicyDecision::Deny { reason } = decision {
                return Some(policy_denied_response_with_audit(
                    app,
                    thread_id,
                    actor,
                    "git_branch_switch",
                    "git.branch_switch",
                    reason,
                ));
            }

            if let PolicyDecision::RequireApproval { reason } = decision {
                let git_status = app
                    .thread_api
                    .lock()
                    .expect("thread API mutex should not be poisoned")
                    .git_status_response(thread_id)?;
                return Some(queue_approval_response(
                    app,
                    actor,
                    PendingApprovalAction::BranchSwitch {
                        thread_id: thread_id.to_string(),
                        branch: branch.trim().to_string(),
                    },
                    reason,
                    git_status,
                ));
            }

            let dispatch = app
                .thread_api
                .lock()
                .expect("thread API mutex should not be poisoned")
                .switch_branch(thread_id, branch)?;
            app.record_security_audit(
                LogSeverity::Info,
                thread_id,
                SecurityAuditEventDto {
                    actor: actor.to_string(),
                    action: "git_branch_switch".to_string(),
                    target: "git.branch_switch".to_string(),
                    outcome: "allowed".to_string(),
                    reason: "policy_allow".to_string(),
                },
            );
            Some(dispatch_response(app, dispatch))
        }
        ("POST", [_, "git", "pull"]) => {
            let remote = query.get("remote").map(String::as_str);

            let actor = query
                .get("actor")
                .map(String::as_str)
                .unwrap_or("mobile-device");
            let decision = app.decide_policy(PolicyAction::GitPull);

            if let PolicyDecision::Deny { reason } = decision {
                return Some(policy_denied_response_with_audit(
                    app, thread_id, actor, "git_pull", "git.pull", reason,
                ));
            }

            if let PolicyDecision::RequireApproval { reason } = decision {
                let git_status = app
                    .thread_api
                    .lock()
                    .expect("thread API mutex should not be poisoned")
                    .git_status_response(thread_id)?;
                return Some(queue_approval_response(
                    app,
                    actor,
                    PendingApprovalAction::Pull {
                        thread_id: thread_id.to_string(),
                        remote: remote.map(str::to_string),
                    },
                    reason,
                    git_status,
                ));
            }

            let dispatch = app
                .thread_api
                .lock()
                .expect("thread API mutex should not be poisoned")
                .pull_repo(thread_id, remote)?;
            app.record_security_audit(
                LogSeverity::Info,
                thread_id,
                SecurityAuditEventDto {
                    actor: actor.to_string(),
                    action: "git_pull".to_string(),
                    target: "git.pull".to_string(),
                    outcome: "allowed".to_string(),
                    reason: "policy_allow".to_string(),
                },
            );
            Some(dispatch_response(app, dispatch))
        }
        ("POST", [_, "git", "push"]) => {
            let remote = query.get("remote").map(String::as_str);

            let actor = query
                .get("actor")
                .map(String::as_str)
                .unwrap_or("mobile-device");
            let decision = app.decide_policy(PolicyAction::GitPush);

            if let PolicyDecision::Deny { reason } = decision {
                return Some(policy_denied_response_with_audit(
                    app, thread_id, actor, "git_push", "git.push", reason,
                ));
            }

            if let PolicyDecision::RequireApproval { reason } = decision {
                let git_status = app
                    .thread_api
                    .lock()
                    .expect("thread API mutex should not be poisoned")
                    .git_status_response(thread_id)?;
                return Some(queue_approval_response(
                    app,
                    actor,
                    PendingApprovalAction::Push {
                        thread_id: thread_id.to_string(),
                        remote: remote.map(str::to_string),
                    },
                    reason,
                    git_status,
                ));
            }

            let dispatch = app
                .thread_api
                .lock()
                .expect("thread API mutex should not be poisoned")
                .push_repo(thread_id, remote)?;
            app.record_security_audit(
                LogSeverity::Info,
                thread_id,
                SecurityAuditEventDto {
                    actor: actor.to_string(),
                    action: "git_push".to_string(),
                    target: "git.push".to_string(),
                    outcome: "allowed".to_string(),
                    reason: "policy_allow".to_string(),
                },
            );
            Some(dispatch_response(app, dispatch))
        }
        _ => Some(method_not_allowed_response()),
    }
}

fn route_approval_request(
    method: &str,
    path: &str,
    query: &HashMap<String, String>,
    app: &BridgeApplication,
) -> Option<String> {
    let approval_path = path.strip_prefix("/approvals/")?;
    let segments = approval_path
        .split('/')
        .filter(|segment| !segment.is_empty())
        .collect::<Vec<_>>();

    match (method, segments.as_slice()) {
        ("POST", [approval_id, "approve"]) => {
            Some(resolve_approval_request(app, query, approval_id, true))
        }
        ("POST", [approval_id, "reject"]) => {
            Some(resolve_approval_request(app, query, approval_id, false))
        }
        _ => Some(method_not_allowed_response()),
    }
}

fn resolve_approval_request(
    app: &BridgeApplication,
    query: &HashMap<String, String>,
    approval_id: &str,
    approved: bool,
) -> String {
    let actor = query
        .get("actor")
        .map(String::as_str)
        .unwrap_or("mobile-device");
    let action_name = if approved {
        "approval_approve"
    } else {
        "approval_reject"
    };

    match app.decide_policy(PolicyAction::ApprovalResolve) {
        PolicyDecision::Allow => {}
        PolicyDecision::Deny { reason } | PolicyDecision::RequireApproval { reason } => {
            return policy_denied_response_with_audit(
                app,
                "approval",
                actor,
                action_name,
                "approval.resolve",
                reason,
            );
        }
    }

    let record = match app.resolve_approval(approval_id, approved) {
        Ok(record) => record,
        Err(ResolveApprovalError::NotFound) => {
            return json_error_response(
                "404 Not Found",
                "approval_resolution_failed",
                "approval_not_found",
                "Approval request was not found.",
            );
        }
        Err(ResolveApprovalError::NotPending) => {
            return json_error_response(
                "409 Conflict",
                "approval_resolution_failed",
                "approval_not_pending",
                "Approval is no longer actionable.",
            );
        }
    };

    if !approved {
        app.record_security_audit(
            LogSeverity::Warn,
            record.approval.thread_id.clone(),
            SecurityAuditEventDto {
                actor: actor.to_string(),
                action: action_name.to_string(),
                target: record.approval.target.clone(),
                outcome: "rejected".to_string(),
                reason: "approval_rejected".to_string(),
            },
        );

        return json_response(
            "200 OK",
            &ApprovalResolutionResponse {
                contract_version: CONTRACT_VERSION.to_string(),
                approval: record.approval,
                mutation_result: None,
            },
        );
    }

    let dispatch = execute_pending_approval_action(app, &record.action);
    let Some(dispatch) = dispatch else {
        let _ = app.rollback_approval_resolution(approval_id);
        app.record_security_audit(
            LogSeverity::Warn,
            record.approval.thread_id.clone(),
            SecurityAuditEventDto {
                actor: actor.to_string(),
                action: action_name.to_string(),
                target: record.approval.target.clone(),
                outcome: "denied".to_string(),
                reason: "approval_target_not_found".to_string(),
            },
        );

        return json_error_response(
            "404 Not Found",
            "approval_resolution_failed",
            "approval_target_not_found",
            "The target thread for this approval is no longer available.",
        );
    };

    let mutation_result = dispatch.response.clone();
    for event in dispatch.events {
        app.stream_router.publish(event);
    }

    app.record_security_audit(
        LogSeverity::Info,
        record.approval.thread_id.clone(),
        SecurityAuditEventDto {
            actor: actor.to_string(),
            action: action_name.to_string(),
            target: record.approval.target.clone(),
            outcome: "allowed".to_string(),
            reason: "approval_resolved".to_string(),
        },
    );

    json_response(
        "200 OK",
        &ApprovalResolutionResponse {
            contract_version: CONTRACT_VERSION.to_string(),
            approval: record.approval,
            mutation_result: Some(mutation_result),
        },
    )
}

fn execute_pending_approval_action(
    app: &BridgeApplication,
    action: &PendingApprovalAction,
) -> Option<MutationDispatch> {
    let mut thread_api = app
        .thread_api
        .lock()
        .expect("thread API mutex should not be poisoned");

    match action {
        PendingApprovalAction::BranchSwitch { thread_id, branch } => {
            thread_api.switch_branch(thread_id, branch)
        }
        PendingApprovalAction::Pull { thread_id, remote } => {
            thread_api.pull_repo(thread_id, remote.as_deref())
        }
        PendingApprovalAction::Push { thread_id, remote } => {
            thread_api.push_repo(thread_id, remote.as_deref())
        }
    }
}

fn queue_approval_response(
    app: &BridgeApplication,
    actor: &str,
    action: PendingApprovalAction,
    reason: &str,
    git_status: GitStatusResponse,
) -> String {
    let approval = app.queue_approval(
        action,
        reason,
        git_status.repository.clone(),
        git_status.status.clone(),
    );

    let payload = serde_json::to_value(&approval).expect("approval payload should serialize");
    let approval_event = BridgeEventEnvelope::new(
        format!("evt-{}", approval.approval_id),
        approval.thread_id.clone(),
        BridgeEventKind::ApprovalRequested,
        approval.requested_at.clone(),
        payload,
    );
    app.stream_router.publish(approval_event);

    app.record_security_audit(
        LogSeverity::Warn,
        approval.thread_id.clone(),
        SecurityAuditEventDto {
            actor: actor.to_string(),
            action: approval.action.clone(),
            target: approval.target.clone(),
            outcome: "gated".to_string(),
            reason: reason.to_string(),
        },
    );

    json_response(
        "202 Accepted",
        &ApprovalGateResponse {
            contract_version: CONTRACT_VERSION.to_string(),
            operation: approval.action.clone(),
            outcome: "approval_required".to_string(),
            message: "Dangerous action was gated pending explicit approval".to_string(),
            approval,
        },
    )
}

fn policy_denied_response_with_audit(
    app: &BridgeApplication,
    thread_id: &str,
    actor: &str,
    action: &str,
    target: &str,
    reason: &str,
) -> String {
    app.record_security_audit(
        LogSeverity::Warn,
        thread_id,
        SecurityAuditEventDto {
            actor: actor.to_string(),
            action: action.to_string(),
            target: target.to_string(),
            outcome: "denied".to_string(),
            reason: reason.to_string(),
        },
    );

    json_error_response(
        "403 Forbidden",
        "policy_denied",
        "policy_denied",
        &format!("{action} denied by current access mode: {reason}"),
    )
}

fn dispatch_response(app: &BridgeApplication, dispatch: MutationDispatch) -> String {
    for event in dispatch.events {
        app.stream_router.publish(event);
    }
    json_response("200 OK", &dispatch.response)
}

fn split_target(target: &str) -> (&str, HashMap<String, String>) {
    let (path, query) = target.split_once('?').unwrap_or((target, ""));
    (path, parse_query_params(query))
}

fn parse_query_params(query: &str) -> HashMap<String, String> {
    let mut params = HashMap::new();

    for pair in query.split('&').filter(|pair| !pair.is_empty()) {
        let (raw_key, raw_value) = pair.split_once('=').unwrap_or((pair, ""));
        params.insert(decode_component(raw_key), decode_component(raw_value));
    }

    params
}

fn decode_component(component: &str) -> String {
    let bytes = component.as_bytes();
    let mut decoded = Vec::with_capacity(bytes.len());
    let mut index = 0;

    while index < bytes.len() {
        match bytes[index] {
            b'+' => {
                decoded.push(b' ');
                index += 1;
            }
            b'%' if index + 2 < bytes.len() => {
                let maybe_hex = std::str::from_utf8(&bytes[index + 1..index + 3]).ok();
                if let Some(hex) = maybe_hex
                    && let Ok(value) = u8::from_str_radix(hex, 16)
                {
                    decoded.push(value);
                    index += 3;
                    continue;
                }
                decoded.push(bytes[index]);
                index += 1;
            }
            byte => {
                decoded.push(byte);
                index += 1;
            }
        }
    }

    String::from_utf8_lossy(&decoded).to_string()
}

fn not_found_response() -> String {
    json_response("404 Not Found", &json!({ "error": "not_found" }))
}

fn method_not_allowed_response() -> String {
    json_response(
        "405 Method Not Allowed",
        &json!({ "error": "method_not_allowed" }),
    )
}

fn bad_request_response(message: &str) -> String {
    json_error_response("400 Bad Request", "bad_request", "bad_request", message)
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
struct OpenOnMacResponse {
    contract_version: String,
    thread_id: String,
    attempted_url: String,
    message: String,
    best_effort: bool,
}

fn open_thread_in_codex_app(thread_id: &str) -> Result<OpenOnMacResponse, String> {
    open_thread_in_codex_app_with(thread_id, open_codex_deep_link)
}

fn open_thread_in_codex_app_with<F>(
    thread_id: &str,
    mut open_deep_link: F,
) -> Result<OpenOnMacResponse, String>
where
    F: FnMut(&str) -> Result<(), String>,
{
    let attempted_urls = candidate_codex_deep_links(thread_id);
    let mut errors = Vec::new();

    for attempted_url in attempted_urls {
        match open_deep_link(&attempted_url) {
            Ok(()) => {
                return Ok(OpenOnMacResponse {
                    contract_version: CONTRACT_VERSION.to_string(),
                    thread_id: thread_id.to_string(),
                    attempted_url,
                    message: "Requested Codex.app to open the matching shared thread. Desktop refresh is best effort; mobile remains fully usable.".to_string(),
                    best_effort: true,
                });
            }
            Err(error) => errors.push(error),
        }
    }

    let detail = if errors.is_empty() {
        "Codex.app is unavailable or could not be opened.".to_string()
    } else {
        format!(
            "Codex.app is unavailable or could not be opened ({}).",
            errors.join(" | ")
        )
    };

    Err(format!(
        "{detail} Mobile remains usable and open-on-Mac is best effort."
    ))
}

fn candidate_codex_deep_links(thread_id: &str) -> Vec<String> {
    vec![
        format!("codex://thread/{thread_id}"),
        format!("codex://threads/{thread_id}"),
        format!("codex://open?thread_id={thread_id}"),
    ]
}

fn open_codex_deep_link(url: &str) -> Result<(), String> {
    #[cfg(test)]
    {
        let _ = url;
        Ok(())
    }

    #[cfg(not(test))]
    {
        let primary = Command::new("open")
            .arg("-a")
            .arg("Codex")
            .arg(url)
            .status()
            .map_err(|error| format!("failed to invoke `open -a Codex`: {error}"))?;

        if primary.success() {
            return Ok(());
        }

        let fallback = Command::new("open")
            .arg(url)
            .status()
            .map_err(|error| format!("failed to invoke `open`: {error}"))?;

        if fallback.success() {
            return Ok(());
        }

        Err(format!(
            "`open -a Codex` exited with {primary}, and fallback `open` exited with {fallback}"
        ))
    }
}

fn pairing_finalize_error_response(error: PairingFinalizeError) -> String {
    let status = match error {
        PairingFinalizeError::UnknownPairingSession
        | PairingFinalizeError::InvalidPairingToken
        | PairingFinalizeError::PairingSessionExpired => "400 Bad Request",
        PairingFinalizeError::SessionAlreadyConsumed
        | PairingFinalizeError::TrustedPhoneConflict => "409 Conflict",
        PairingFinalizeError::BridgeIdentityMismatch
        | PairingFinalizeError::PrivateBridgePathRequired => "403 Forbidden",
        PairingFinalizeError::Storage(_) => "500 Internal Server Error",
    };

    json_error_response(
        status,
        "pairing_finalize_failed",
        error.code(),
        &error.message(),
    )
}

fn pairing_handshake_error_response(error: PairingHandshakeError) -> String {
    json_error_response(
        "403 Forbidden",
        "pairing_handshake_failed",
        error.code(),
        error.message(),
    )
}

fn json_error_response(status: &str, error: &str, code: &str, message: &str) -> String {
    json_response(
        status,
        &json!({
            "error": error,
            "code": code,
            "message": message,
        }),
    )
}

fn upgrade_required_response() -> String {
    json_response(
        "426 Upgrade Required",
        &json!({ "error": "upgrade_required", "upgrade": "websocket" }),
    )
}

fn json_response<TPayload>(status: &str, payload: &TPayload) -> String
where
    TPayload: Serialize,
{
    let body = serde_json::to_string(payload).expect("JSON serialization should not fail");
    format!(
        "HTTP/1.1 {status}\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
        body.len(),
        body
    )
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
struct HealthResponse {
    status: &'static str,
    runtime: RuntimeSnapshot,
    pairing_route: PairingRouteHealth,
    trust: PairingTrustSnapshot,
    api: ApiSurface,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
struct PairingRouteHealth {
    reachable: bool,
    advertised_base_url: Option<String>,
    message: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
struct ApiSurface {
    endpoints: Vec<&'static str>,
    seeded_thread_count: usize,
}

#[cfg(test)]
mod tests {
    use std::fs;
    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;
    use std::path::PathBuf;
    use std::sync::mpsc::RecvTimeoutError;
    use std::time::Duration;

    use serde_json::Value;

    use super::{
        BridgeApplication, CodexRuntimeConfig, CodexRuntimeMode, CodexRuntimeSupervisor, Config,
        InMemoryLogSink, PairingRouteContract, PairingRouteState, PairingSessionService,
        PendingApprovalAction, RepositoryContextDto, StreamRouter, StructuredLogger,
        build_foundations, pairing_base_url_from_tailscale_status, parse_args,
        parse_args_with_pairing_route_resolver, resolve_cli_binary,
        resolve_default_pairing_route_contract_with, route_request,
    };
    use crate::thread_api::ThreadApiService;

    #[test]
    fn parse_args_uses_verified_default_pairing_route_when_available() {
        let config = parse_args_with_pairing_route_resolver(Vec::<String>::new(), |_port| {
            PairingRouteContract::verified("https://verified.taild54ede.ts.net".to_string())
        })
        .expect("defaults should parse");

        assert_eq!(config.host, "127.0.0.1");
        assert_eq!(config.port, 3110);
        assert_eq!(config.admin_port, 3111);
        assert_eq!(
            config.pairing_base_url,
            "https://verified.taild54ede.ts.net"
        );
        assert!(config.pairing_route_reachable);
        assert!(config.pairing_route_message.is_none());
        assert!(config.pairing_route_requires_runtime_serve_check);
        assert_eq!(
            config.codex_runtime,
            CodexRuntimeConfig {
                mode: CodexRuntimeMode::Auto,
                endpoint: Some("ws://127.0.0.1:4222".to_string()),
                command: "codex".to_string(),
                args: vec!["app-server".to_string()],
            }
        );
    }

    #[test]
    fn parse_args_marks_default_pairing_route_unavailable_when_not_verified() {
        let config = parse_args_with_pairing_route_resolver(Vec::<String>::new(), |port| {
            PairingRouteContract::degraded(format!("route for {port} is unavailable"))
        })
        .expect("defaults should parse");

        assert_eq!(config.pairing_base_url, "https://bridge.ts.net");
        assert!(!config.pairing_route_reachable);
        assert_eq!(
            config.pairing_route_message.as_deref(),
            Some("route for 3110 is unavailable")
        );
        assert!(config.pairing_route_requires_runtime_serve_check);
    }

    #[test]
    fn parse_args_reads_explicit_values() {
        let config = parse_args_with_pairing_route_resolver(
            vec![
                "--host".to_string(),
                "0.0.0.0".to_string(),
                "--port".to_string(),
                "9999".to_string(),
                "--admin-port".to_string(),
                "9998".to_string(),
                "--state-directory".to_string(),
                "/tmp/bridge-state".to_string(),
                "--codex-mode".to_string(),
                "spawn".to_string(),
                "--codex-command".to_string(),
                "sleep".to_string(),
                "--codex-arg".to_string(),
                "10".to_string(),
                "--pairing-base-url".to_string(),
                "https://bridge.ts.net".to_string(),
            ],
            |_port| panic!("default pairing route resolver should not be used"),
        )
        .expect("explicit values should parse");

        assert_eq!(
            config,
            Config {
                host: "0.0.0.0".to_string(),
                port: 9999,
                admin_port: 9998,
                state_directory: PathBuf::from("/tmp/bridge-state"),
                pairing_base_url: "https://bridge.ts.net".to_string(),
                pairing_route_reachable: true,
                pairing_route_message: None,
                pairing_route_requires_runtime_serve_check: false,
                codex_runtime: CodexRuntimeConfig {
                    mode: CodexRuntimeMode::Spawn,
                    endpoint: Some("ws://127.0.0.1:4222".to_string()),
                    command: "sleep".to_string(),
                    args: vec!["10".to_string()],
                },
            }
        );
    }

    #[test]
    fn parse_args_rejects_non_private_explicit_pairing_base_url() {
        let error = parse_args(vec![
            "--pairing-base-url".to_string(),
            "http://127.0.0.1:3110".to_string(),
        ])
        .expect_err("non-private explicit route should be rejected");

        assert!(error.contains("--pairing-base-url must be a private https Tailscale hostname"));
    }

    #[test]
    fn parse_args_rejects_unknown_flag() {
        let error =
            parse_args(vec!["--unknown".to_string()]).expect_err("unknown flag should fail");

        assert!(error.contains("unknown argument"));
    }

    #[test]
    fn foundation_bootstrap_builds_consistent_paths() {
        let foundations = build_foundations("/tmp/bridge-core");
        let threads_path = foundations
            .persistence
            .sqlite_path_for(crate::persistence::PersistenceScope::ThreadsCache);

        assert_eq!(
            threads_path,
            std::path::PathBuf::from("/tmp/bridge-core/state/threads-cache.sqlite")
        );
    }

    #[test]
    fn parse_args_supports_codex_runtime_modes() {
        let config = parse_args_with_pairing_route_resolver(
            vec![
                "--codex-mode".to_string(),
                "attach".to_string(),
                "--codex-endpoint".to_string(),
                "ws://127.0.0.1:4222".to_string(),
            ],
            |_port| PairingRouteContract::verified("https://bridge.ts.net".to_string()),
        )
        .expect("codex runtime flags should parse");

        assert_eq!(config.codex_runtime.mode, CodexRuntimeMode::Attach);
        assert_eq!(
            config.codex_runtime.endpoint.as_deref(),
            Some("ws://127.0.0.1:4222")
        );
    }

    #[test]
    fn pairing_base_url_requires_matching_serve_route_for_bridge_port() {
        let status = serde_json::json!({
            "Self": {
                "DNSName": "macbook-pro.taild54ede.ts.net."
            }
        });

        let missing_route = serde_json::json!({});
        assert!(pairing_base_url_from_tailscale_status(&status, &missing_route, 3110).is_none());

        let verified_route = serde_json::json!({
            "TCP": {
                "443": {
                    "HTTPS": true
                }
            },
            "Web": {
                "macbook-pro.taild54ede.ts.net:443": {
                    "Handlers": {
                        "/": {
                            "Proxy": "http://127.0.0.1:3110"
                        }
                    }
                }
            }
        });

        assert_eq!(
            pairing_base_url_from_tailscale_status(&status, &verified_route, 3110),
            Some("https://macbook-pro.taild54ede.ts.net".to_string())
        );
    }

    #[test]
    fn pairing_base_url_rejects_unrelated_serve_entries_that_only_mention_port() {
        let status = serde_json::json!({
            "Self": {
                "DNSName": "macbook-pro.taild54ede.ts.net."
            }
        });

        let stale_port_reference = serde_json::json!({
            "stale": "3110"
        });

        assert!(
            pairing_base_url_from_tailscale_status(&status, &stale_port_reference, 3110).is_none()
        );

        let wrong_host_https_proxy = serde_json::json!({
            "TCP": {
                "443": {
                    "HTTPS": true
                }
            },
            "Web": {
                "other-mac.taild54ede.ts.net:443": {
                    "Handlers": {
                        "/": {
                            "Proxy": "http://127.0.0.1:3110"
                        }
                    }
                }
            }
        });

        assert!(
            pairing_base_url_from_tailscale_status(&status, &wrong_host_https_proxy, 3110)
                .is_none()
        );
    }

    #[test]
    fn pairing_base_url_rejects_https_loopback_proxy_targets() {
        let status = serde_json::json!({
            "Self": {
                "DNSName": "macbook-pro.taild54ede.ts.net."
            }
        });

        for https_loopback_target in [
            "https://127.0.0.1:3110",
            "https://localhost:3110",
            "https://[::1]:3110",
        ] {
            let serve_status = serde_json::json!({
                "TCP": {
                    "443": {
                        "HTTPS": true
                    }
                },
                "Web": {
                    "macbook-pro.taild54ede.ts.net:443": {
                        "Handlers": {
                            "/": {
                                "Proxy": https_loopback_target
                            }
                        }
                    }
                }
            });

            assert!(
                pairing_base_url_from_tailscale_status(&status, &serve_status, 3110).is_none(),
                "expected https loopback target {https_loopback_target} to be rejected"
            );
        }
    }

    #[test]
    fn pairing_base_url_rejects_non_root_handler_proxy_for_bridge_port() {
        let status = serde_json::json!({
            "Self": {
                "DNSName": "macbook-pro.taild54ede.ts.net."
            }
        });

        let non_root_handler = serde_json::json!({
            "TCP": {
                "443": {
                    "HTTPS": true
                }
            },
            "Web": {
                "macbook-pro.taild54ede.ts.net:443": {
                    "Handlers": {
                        "/stale": {
                            "Proxy": "http://127.0.0.1:3110"
                        }
                    }
                }
            }
        });

        assert!(pairing_base_url_from_tailscale_status(&status, &non_root_handler, 3110).is_none());
    }

    #[test]
    fn resolve_default_route_provisions_serve_when_mapping_is_missing() {
        let mut discover_attempts = 0;
        let mut provision_calls = 0;

        let contract = resolve_default_pairing_route_contract_with(
            3110,
            |_port| {
                discover_attempts += 1;
                if discover_attempts == 2 {
                    Some("https://macbook-pro.taild54ede.ts.net".to_string())
                } else {
                    None
                }
            },
            |_port| {
                provision_calls += 1;
                Ok(())
            },
        );

        assert!(contract.reachable);
        assert_eq!(
            contract.pairing_base_url,
            "https://macbook-pro.taild54ede.ts.net"
        );
        assert_eq!(provision_calls, 1);
    }

    #[test]
    fn resolve_default_route_degrades_when_serve_launch_fails() {
        let contract = resolve_default_pairing_route_contract_with(
            3110,
            |_port| None,
            |_port| Err("permission denied".to_string()),
        );

        assert!(!contract.reachable);
        assert_eq!(contract.pairing_base_url, "https://bridge.ts.net");
        assert_eq!(
            contract.message.as_deref(),
            Some(
                "Private pairing route is unavailable: failed to launch `tailscale serve --bg 3110`: permission denied"
            )
        );
    }

    #[test]
    fn resolve_default_route_degrades_when_mapping_still_unverified_after_launch() {
        let contract =
            resolve_default_pairing_route_contract_with(3110, |_port| None, |_port| Ok(()));

        assert!(!contract.reachable);
        assert_eq!(contract.pairing_base_url, "https://bridge.ts.net");
        assert_eq!(
            contract.message.as_deref(),
            Some(
                "Private pairing route is unavailable: `tailscale serve --bg 3110` ran, but no verified mapping to localhost:3110 was found in `tailscale serve status --json`."
            )
        );
    }

    #[test]
    fn pairing_route_health_recovers_when_verified_mapping_appears_later() {
        let state = PairingRouteState {
            pairing_base_url: "https://bridge.ts.net".to_string(),
            reachable: false,
            message: Some("stale startup error".to_string()),
            bridge_port: 3110,
            requires_runtime_serve_check: true,
        };

        let health = state.health_with(|_port| Some("https://lubo.taild54ede.ts.net".to_string()));

        assert!(health.reachable);
        assert_eq!(
            health.advertised_base_url.as_deref(),
            Some("https://lubo.taild54ede.ts.net")
        );
        assert_eq!(health.message, None);
    }

    #[test]
    fn resolve_cli_binary_uses_fallback_candidates_for_custom_command() {
        let binary = make_test_executable("codex-test-cli-explicit");
        let resolved = resolve_cli_binary(
            "CODEX_TEST_CLI_OVERRIDE",
            "codex-test-cli-explicit",
            &[binary.to_string_lossy().as_ref()],
        )
        .expect("fallback candidate should resolve");

        assert_eq!(resolved, binary);
        let _ = fs::remove_file(binary);
    }

    #[test]
    fn resolve_cli_binary_reports_missing_command_with_checked_locations() {
        let error = resolve_cli_binary(
            "CODEX_TEST_MISSING_OVERRIDE",
            "codex-test-cli-missing",
            &["/tmp/does-not-exist/codex-test-cli-missing"],
        )
        .expect_err("missing command should return an error");

        assert!(error.contains("codex-test-cli-missing CLI unavailable"));
        assert!(error.contains("CODEX_TEST_MISSING_OVERRIDE"));
    }

    #[test]
    fn pairing_session_route_fails_closed_when_private_route_is_unavailable() {
        let app = test_application_with_pairing_route(
            false,
            Some("Private pairing route is unavailable for port 3110"),
        );

        let response = route_request("POST /pairing/session HTTP/1.1", &app);
        assert!(response.starts_with("HTTP/1.1 503 Service Unavailable"));

        let body = parse_json_body(&response);
        assert_eq!(body["error"], "pairing_session_unavailable");
        assert_eq!(body["code"], "private_pairing_route_unavailable");
        assert_eq!(
            body["message"],
            "Private pairing route is unavailable for port 3110"
        );
    }

    #[test]
    fn thread_routes_are_available() {
        let app = test_application();

        let models_response = route_request("GET /models HTTP/1.1", &app);
        assert!(models_response.starts_with("HTTP/1.1 200 OK"));
        assert!(models_response.contains("\"models\""));
        assert!(models_response.contains("\"display_name\":\"GPT-5\""));

        let list_response = route_request("GET /threads HTTP/1.1", &app);
        assert!(list_response.starts_with("HTTP/1.1 200 OK"));
        assert!(list_response.contains("\"threads\""));
        assert!(!list_response.contains("lifecycle_state"));

        let detail_response = route_request("GET /threads/thread-123 HTTP/1.1", &app);
        assert!(detail_response.starts_with("HTTP/1.1 200 OK"));
        assert!(detail_response.contains("\"thread_id\":\"thread-123\""));
        assert!(detail_response.contains("\"last_turn_summary\""));

        let timeline_response = route_request("GET /threads/thread-123/timeline HTTP/1.1", &app);
        assert!(timeline_response.starts_with("HTTP/1.1 200 OK"));
        assert!(timeline_response.contains("\"thread\""));
        assert!(timeline_response.contains("\"entries\""));
        assert!(timeline_response.contains("\"kind\":\"message_delta\""));
    }

    #[test]
    fn thread_timeline_route_supports_before_and_limit_query() {
        let app = test_application();

        let timeline_response =
            route_request("GET /threads/thread-123/timeline?limit=1 HTTP/1.1", &app);
        assert!(timeline_response.starts_with("HTTP/1.1 200 OK"));
        let body = parse_json_body(&timeline_response);
        let entries = body["entries"]
            .as_array()
            .expect("timeline entries should be present");
        assert_eq!(entries.len(), 1);
        assert_eq!(body["has_more_before"], true);

        let before = body["next_before"]
            .as_str()
            .expect("next_before cursor should be present");
        let older_response = route_request(
            &format!("GET /threads/thread-123/timeline?before={before}&limit=1 HTTP/1.1"),
            &app,
        );
        let older_body = parse_json_body(&older_response);
        let older_entries = older_body["entries"]
            .as_array()
            .expect("older timeline entries should be present");
        assert_eq!(older_entries.len(), 1);
    }

    #[test]
    fn thread_timeline_route_rejects_invalid_limit_query() {
        let app = test_application();

        let invalid_limit =
            route_request("GET /threads/thread-123/timeline?limit=abc HTTP/1.1", &app);
        assert!(invalid_limit.starts_with("HTTP/1.1 400 Bad Request"));
        let invalid_body = parse_json_body(&invalid_limit);
        assert_eq!(
            invalid_body["message"],
            "The timeline limit query parameter must be a positive integer."
        );

        let empty_limit = route_request("GET /threads/thread-123/timeline?limit= HTTP/1.1", &app);
        assert!(empty_limit.starts_with("HTTP/1.1 400 Bad Request"));
        let empty_body = parse_json_body(&empty_limit);
        assert_eq!(
            empty_body["message"],
            "The timeline limit query parameter must not be empty."
        );
    }

    #[test]
    fn thread_timeline_route_rejects_unknown_before_cursor() {
        let app = test_application();

        let response = route_request(
            "GET /threads/thread-123/timeline?before=missing-event HTTP/1.1",
            &app,
        );
        assert!(response.starts_with("HTTP/1.1 400 Bad Request"));
        let body = parse_json_body(&response);
        assert_eq!(
            body["message"],
            "The provided timeline cursor does not exist for this thread."
        );
    }

    #[test]
    fn thread_timeline_route_rejects_empty_before_cursor() {
        let app = test_application();

        let response = route_request("GET /threads/thread-123/timeline?before= HTTP/1.1", &app);
        assert!(response.starts_with("HTTP/1.1 400 Bad Request"));
        let body = parse_json_body(&response);
        assert_eq!(
            body["message"],
            "The timeline before cursor query parameter must not be empty."
        );
    }

    #[test]
    fn thread_timeline_route_keeps_unknown_threads_as_not_found() {
        let app = test_application();

        let response = route_request(
            "GET /threads/missing-thread/timeline?before=missing-event HTTP/1.1",
            &app,
        );
        assert!(response.starts_with("HTTP/1.1 404 Not Found"));
    }

    #[test]
    fn open_on_mac_route_returns_best_effort_response_for_known_thread() {
        let app = test_application();

        let response = route_request("POST /threads/thread-123/open-on-mac HTTP/1.1", &app);
        assert!(response.starts_with("HTTP/1.1 200 OK"));

        let body = parse_json_body(&response);
        assert_eq!(body["thread_id"], "thread-123");
        assert_eq!(body["best_effort"], true);
        assert_eq!(body["contract_version"], shared_contracts::CONTRACT_VERSION);

        let attempted_url = body["attempted_url"]
            .as_str()
            .expect("attempted URL should be present");
        assert!(attempted_url.contains("thread-123"));
    }

    #[test]
    fn open_on_mac_route_returns_not_found_for_unknown_thread() {
        let app = test_application();

        let response = route_request("POST /threads/thread-missing/open-on-mac HTTP/1.1", &app);
        assert!(response.starts_with("HTTP/1.1 404 Not Found"));
    }

    #[test]
    fn open_on_mac_reports_graceful_failure_when_all_links_fail() {
        let error = super::open_thread_in_codex_app_with("thread-123", |_url| {
            Err("Codex.app is not installed".to_string())
        })
        .expect_err("open-on-mac should fail when opener fails");

        assert!(error.contains("Codex.app is unavailable or could not be opened"));
        assert!(error.contains("Mobile remains usable"));
    }

    #[test]
    fn turn_and_git_mutation_routes_return_product_shaped_results() {
        let app = test_application();
        let trusted_session_query = trusted_session_query(&app);

        let mode = route_request(
            &format!("POST /policy/access-mode?mode=full_control&{trusted_session_query} HTTP/1.1"),
            &app,
        );
        assert!(mode.starts_with("HTTP/1.1 200 OK"));

        let turn_start = route_request(
            "POST /threads/thread-123/turns/start?prompt=Ship+threaded+streaming HTTP/1.1",
            &app,
        );
        assert!(turn_start.starts_with("HTTP/1.1 200 OK"));
        assert!(turn_start.contains("\"operation\":\"turn_start\""));
        assert!(turn_start.contains("\"thread_status\":\"running\""));

        let branch_switch = route_request(
            "POST /threads/thread-456/git/branch-switch?branch=release%2F2026 HTTP/1.1",
            &app,
        );
        assert!(branch_switch.starts_with("HTTP/1.1 200 OK"));
        assert!(branch_switch.contains("\"operation\":\"git_branch_switch\""));
        assert!(branch_switch.contains("\"repository\":\"codex-runtime-tools\""));
        assert!(branch_switch.contains("\"branch\":\"release/2026\""));

        let git_status = route_request("GET /threads/thread-456/git/status HTTP/1.1", &app);
        assert!(git_status.starts_with("HTTP/1.1 200 OK"));
        assert!(git_status.contains("\"remote\":\"upstream\""));
    }

    #[test]
    fn git_diff_route_returns_latest_thread_change_payload() {
        let app = test_application();

        let response = route_request(
            "GET /threads/thread-123/git/diff?mode=latest_thread_change HTTP/1.1",
            &app,
        );

        assert!(response.starts_with("HTTP/1.1 200 OK"));
        assert!(response.contains("\"mode\":\"latest_thread_change\""));
        assert!(response.contains("\"files\":"));
    }

    #[test]
    fn git_diff_route_rejects_invalid_mode() {
        let app = test_application();

        let response = route_request("GET /threads/thread-123/git/diff?mode=nope HTTP/1.1", &app);

        assert!(response.starts_with("HTTP/1.1 400 Bad Request"));
        assert!(response.contains("\"message\":\"invalid_git_diff_mode\""));
    }

    #[test]
    fn read_only_mode_blocks_turn_and_git_mutations() {
        let app = test_application();
        let trusted_session_query = trusted_session_query(&app);

        let mode = route_request(
            &format!("POST /policy/access-mode?mode=read_only&{trusted_session_query} HTTP/1.1"),
            &app,
        );
        assert!(mode.starts_with("HTTP/1.1 200 OK"));

        let turn_start = route_request(
            "POST /threads/thread-123/turns/start?prompt=Blocked HTTP/1.1",
            &app,
        );
        assert!(turn_start.starts_with("HTTP/1.1 403 Forbidden"));
        assert!(turn_start.contains("\"error\":\"policy_denied\""));

        let git_push = route_request("POST /threads/thread-123/git/push HTTP/1.1", &app);
        assert!(git_push.starts_with("HTTP/1.1 403 Forbidden"));
        assert!(git_push.contains("\"error\":\"policy_denied\""));
    }

    #[test]
    fn control_with_approvals_gates_git_mutations_until_full_control_resolution() {
        let app = test_application();
        let trusted_session_query = trusted_session_query(&app);

        let mode = route_request(
            &format!(
                "POST /policy/access-mode?mode=control_with_approvals&{trusted_session_query} HTTP/1.1"
            ),
            &app,
        );
        assert!(mode.starts_with("HTTP/1.1 200 OK"));

        let status_before = parse_json_body(&route_request(
            "GET /threads/thread-123/git/status HTTP/1.1",
            &app,
        ));
        assert_eq!(status_before["status"]["behind_by"], 1);

        let gated = route_request(
            "POST /threads/thread-123/git/pull?remote=origin HTTP/1.1",
            &app,
        );
        assert!(gated.starts_with("HTTP/1.1 202 Accepted"));
        let gated_body = parse_json_body(&gated);
        assert_eq!(gated_body["outcome"], "approval_required");
        let approval_id = gated_body["approval"]["approval_id"]
            .as_str()
            .expect("approval id should be present")
            .to_string();

        let status_after_gate = parse_json_body(&route_request(
            "GET /threads/thread-123/git/status HTTP/1.1",
            &app,
        ));
        assert_eq!(status_after_gate["status"]["behind_by"], 1);

        let blocked_resolution = route_request(
            &format!("POST /approvals/{approval_id}/approve HTTP/1.1"),
            &app,
        );
        assert!(blocked_resolution.starts_with("HTTP/1.1 403 Forbidden"));

        let elevate = route_request(
            &format!("POST /policy/access-mode?mode=full_control&{trusted_session_query} HTTP/1.1"),
            &app,
        );
        assert!(elevate.starts_with("HTTP/1.1 200 OK"));

        let resolved = route_request(
            &format!("POST /approvals/{approval_id}/approve HTTP/1.1"),
            &app,
        );
        assert!(resolved.starts_with("HTTP/1.1 200 OK"));
        let resolved_body = parse_json_body(&resolved);
        assert_eq!(resolved_body["mutation_result"]["operation"], "git_pull");

        let status_after_resolve = parse_json_body(&route_request(
            "GET /threads/thread-123/git/status HTTP/1.1",
            &app,
        ));
        assert_eq!(status_after_resolve["status"]["behind_by"], 0);
    }

    #[test]
    fn control_with_approvals_branch_switch_approval_carries_exact_target_branch() {
        let app = test_application();
        let trusted_session_query = trusted_session_query(&app);

        let mode = route_request(
            &format!(
                "POST /policy/access-mode?mode=control_with_approvals&{trusted_session_query} HTTP/1.1"
            ),
            &app,
        );
        assert!(mode.starts_with("HTTP/1.1 200 OK"));

        let gated = route_request(
            "POST /threads/thread-456/git/branch-switch?branch=release%2F2026 HTTP/1.1",
            &app,
        );
        assert!(gated.starts_with("HTTP/1.1 202 Accepted"));
        let gated_body = parse_json_body(&gated);
        assert_eq!(gated_body["outcome"], "approval_required");
        assert_eq!(gated_body["approval"]["action"], "git_branch_switch");
        assert_eq!(gated_body["approval"]["target"], "release/2026");
        assert_eq!(gated_body["approval"]["repository"]["branch"], "develop");

        let approvals = parse_json_body(&route_request("GET /approvals HTTP/1.1", &app));
        let records = approvals["approvals"]
            .as_array()
            .expect("approvals should be an array");
        assert_eq!(records.len(), 1);
        assert_eq!(records[0]["action"], "git_branch_switch");
        assert_eq!(records[0]["target"], "release/2026");
    }

    #[test]
    fn security_events_capture_denied_gated_and_allowed_outcomes() {
        let app = test_application();
        let trusted_session_query = trusted_session_query(&app);

        let _ = route_request(
            &format!("POST /policy/access-mode?mode=read_only&{trusted_session_query} HTTP/1.1"),
            &app,
        );
        let _ = route_request("POST /threads/thread-123/turns/start HTTP/1.1", &app);

        let _ = route_request(
            &format!(
                "POST /policy/access-mode?mode=control_with_approvals&{trusted_session_query} HTTP/1.1"
            ),
            &app,
        );
        let gated = parse_json_body(&route_request(
            "POST /threads/thread-123/git/push HTTP/1.1",
            &app,
        ));
        let approval_id = gated["approval"]["approval_id"]
            .as_str()
            .expect("approval id should be present")
            .to_string();

        let _ = route_request(
            &format!("POST /policy/access-mode?mode=full_control&{trusted_session_query} HTTP/1.1"),
            &app,
        );
        let _ = route_request(
            &format!("POST /approvals/{approval_id}/approve HTTP/1.1"),
            &app,
        );

        let events = parse_json_body(&route_request("GET /security/events HTTP/1.1", &app));
        let outcomes = events["events"]
            .as_array()
            .expect("security events list should be present")
            .iter()
            .filter_map(|record| record["event"]["payload"]["outcome"].as_str())
            .collect::<Vec<_>>();

        assert!(outcomes.contains(&"denied"));
        assert!(outcomes.contains(&"gated"));
        assert!(outcomes.contains(&"allowed"));
    }

    #[test]
    fn trust_revocation_records_mobile_and_desktop_security_audit_events() {
        let app = test_application();

        let _ = trusted_session_query(&app);
        let mobile_revoke = route_request(
            "POST /pairing/trust/revoke?phone_id=phone-1&actor=mobile-device HTTP/1.1",
            &app,
        );
        assert!(mobile_revoke.starts_with("HTTP/1.1 200 OK"));
        assert!(mobile_revoke.contains("\"revoked\":true"));

        let _ = trusted_session_query(&app);
        let desktop_revoke = route_request(
            "POST /pairing/trust/revoke?actor=desktop-shell HTTP/1.1",
            &app,
        );
        assert!(desktop_revoke.starts_with("HTTP/1.1 200 OK"));
        assert!(desktop_revoke.contains("\"revoked\":true"));

        let events = parse_json_body(&route_request("GET /security/events HTTP/1.1", &app));
        let records = events["events"]
            .as_array()
            .expect("security events list should be present");

        let has_mobile_revoke = records.iter().any(|record| {
            record["event"]["payload"]["action"] == "revoke_trust"
                && record["event"]["payload"]["target"] == "pairing.trust"
                && record["event"]["payload"]["outcome"] == "allowed"
                && record["event"]["payload"]["actor"] == "mobile-device"
        });
        let has_desktop_revoke = records.iter().any(|record| {
            record["event"]["payload"]["action"] == "revoke_trust"
                && record["event"]["payload"]["target"] == "pairing.trust"
                && record["event"]["payload"]["outcome"] == "allowed"
                && record["event"]["payload"]["actor"] == "desktop-shell"
        });

        assert!(
            has_mobile_revoke,
            "expected revoke_trust event for mobile unpair"
        );
        assert!(
            has_desktop_revoke,
            "expected revoke_trust event for desktop unpair"
        );
    }

    #[test]
    fn access_mode_mutations_require_trusted_session_authorization() {
        let app = test_application();

        let unauthorized =
            route_request("POST /policy/access-mode?mode=full_control HTTP/1.1", &app);
        assert!(unauthorized.starts_with("HTTP/1.1 403 Forbidden"));

        let trusted_session_query = trusted_session_query(&app);
        let authorized = route_request(
            &format!("POST /policy/access-mode?mode=full_control&{trusted_session_query} HTTP/1.1"),
            &app,
        );
        assert!(authorized.starts_with("HTTP/1.1 200 OK"));
    }

    #[test]
    fn failed_approval_execution_keeps_approval_pending() {
        let app = test_application();
        let trusted_session_query = trusted_session_query(&app);

        let elevated = route_request(
            &format!("POST /policy/access-mode?mode=full_control&{trusted_session_query} HTTP/1.1"),
            &app,
        );
        assert!(elevated.starts_with("HTTP/1.1 200 OK"));

        let approval = app.queue_approval(
            PendingApprovalAction::Pull {
                thread_id: "thread-missing".to_string(),
                remote: Some("origin".to_string()),
            },
            "dangerous_action_requires_approval",
            RepositoryContextDto {
                workspace: "/workspace/missing".to_string(),
                repository: "missing-repo".to_string(),
                branch: "main".to_string(),
                remote: "origin".to_string(),
            },
            crate::thread_api::GitStatusDto {
                dirty: false,
                ahead_by: 0,
                behind_by: 0,
            },
        );

        let resolve = route_request(
            &format!("POST /approvals/{}/approve HTTP/1.1", approval.approval_id),
            &app,
        );
        assert!(resolve.starts_with("HTTP/1.1 404 Not Found"));
        assert!(resolve.contains("\"code\":\"approval_target_not_found\""));

        let approvals = parse_json_body(&route_request("GET /approvals HTTP/1.1", &app));
        let record = approvals["approvals"]
            .as_array()
            .expect("approvals should be an array")
            .iter()
            .find(|record| record["approval_id"] == approval.approval_id)
            .expect("queued approval should still exist");

        assert_eq!(record["status"], "pending");
        assert!(record["resolved_at"].is_null());
    }

    #[test]
    fn pairing_session_route_returns_bridge_identity_and_qr_payload() {
        let app = test_application();

        let response = route_request("POST /pairing/session HTTP/1.1", &app);
        assert!(response.starts_with("HTTP/1.1 200 OK"));

        let body = parse_json_body(&response);
        assert_eq!(body["contract_version"], shared_contracts::CONTRACT_VERSION);
        assert!(
            body["bridge_identity"]["display_name"]
                .as_str()
                .is_some_and(|value| !value.trim().is_empty())
        );
        assert_eq!(
            body["bridge_identity"]["api_base_url"],
            "https://bridge.ts.net"
        );
        assert_eq!(body["pairing_session"]["session_id"], "pairing-session-1");

        let qr_payload = body["qr_payload"]
            .as_str()
            .expect("qr payload should be a JSON string");
        let qr_payload: Value =
            serde_json::from_str(qr_payload).expect("qr payload should decode as JSON");

        assert_eq!(qr_payload["u"], "https://bridge.ts.net");
        assert_eq!(qr_payload["b"], body["bridge_identity"]["bridge_id"]);
        assert_eq!(qr_payload["s"], body["pairing_session"]["session_id"]);
        assert_eq!(qr_payload["t"], body["pairing_session"]["pairing_token"]);
        assert!(qr_payload.get("bridge_name").is_none());
        assert_eq!(qr_payload["r"].as_array().map(std::vec::Vec::len), Some(1));
        assert_eq!(
            qr_payload["r"][0],
            serde_json::Value::String("https://bridge.ts.net".to_string())
        );
        assert!(qr_payload.get("i").is_none());
        assert!(qr_payload.get("e").is_none());
        assert!(qr_payload.get("bridge_api_routes").is_none());
    }

    #[test]
    fn pairing_session_route_issues_new_session_on_each_request() {
        let app = test_application();

        let first = parse_json_body(&route_request("POST /pairing/session HTTP/1.1", &app));
        let second = parse_json_body(&route_request("POST /pairing/session HTTP/1.1", &app));

        assert_ne!(
            first["pairing_session"]["session_id"],
            second["pairing_session"]["session_id"]
        );
        assert_ne!(
            first["pairing_session"]["pairing_token"],
            second["pairing_session"]["pairing_token"]
        );
    }

    #[test]
    fn stream_events_are_scoped_to_subscribed_thread() {
        let app = test_application();
        let thread_123 = app.stream_router.subscribe(vec!["thread-123".to_string()]);
        let thread_456 = app.stream_router.subscribe(vec!["thread-456".to_string()]);

        let response = route_request(
            "POST /threads/thread-123/turns/steer?instruction=Focus+on+routing HTTP/1.1",
            &app,
        );
        assert!(response.starts_with("HTTP/1.1 200 OK"));

        let event = thread_123
            .receiver
            .recv_timeout(Duration::from_millis(100))
            .expect("matching subscriber should receive event");
        assert_eq!(event.thread_id, "thread-123");

        let error = thread_456
            .receiver
            .recv_timeout(Duration::from_millis(100))
            .expect_err("non-matching subscriber should not receive event");
        assert!(matches!(error, RecvTimeoutError::Timeout));
    }

    #[test]
    fn pairing_finalize_consumes_session_and_rejects_reuse() {
        let app = test_application();

        let session = parse_json_body(&route_request("POST /pairing/session HTTP/1.1", &app));
        let session_id = session["pairing_session"]["session_id"]
            .as_str()
            .expect("session id should be present");
        let pairing_token = session["pairing_session"]["pairing_token"]
            .as_str()
            .expect("pairing token should be present");
        let bridge_id = session["bridge_identity"]["bridge_id"]
            .as_str()
            .expect("bridge id should be present");

        let finalize_path = format!(
            "POST /pairing/finalize?session_id={session_id}&pairing_token={pairing_token}&phone_id=phone-1&phone_name=iPhone&bridge_id={bridge_id} HTTP/1.1"
        );
        let first_finalize = route_request(&finalize_path, &app);
        assert!(first_finalize.starts_with("HTTP/1.1 200 OK"));

        let second_finalize = route_request(&finalize_path, &app);
        assert!(second_finalize.starts_with("HTTP/1.1 409 Conflict"));
        assert!(second_finalize.contains("\"code\":\"session_already_consumed\""));
    }

    #[test]
    fn pairing_handshake_fails_closed_on_bridge_identity_mismatch() {
        let app = test_application();

        let session = parse_json_body(&route_request("POST /pairing/session HTTP/1.1", &app));
        let session_id = session["pairing_session"]["session_id"]
            .as_str()
            .expect("session id should be present");
        let pairing_token = session["pairing_session"]["pairing_token"]
            .as_str()
            .expect("pairing token should be present");
        let bridge_id = session["bridge_identity"]["bridge_id"]
            .as_str()
            .expect("bridge id should be present");

        let finalize_path = format!(
            "POST /pairing/finalize?session_id={session_id}&pairing_token={pairing_token}&phone_id=phone-1&phone_name=iPhone&bridge_id={bridge_id} HTTP/1.1"
        );
        let finalize_response = route_request(&finalize_path, &app);
        assert!(finalize_response.starts_with("HTTP/1.1 200 OK"));

        let finalized = parse_json_body(&finalize_response);
        let session_token = finalized["session_token"]
            .as_str()
            .expect("session token should be present");

        let handshake_path = format!(
            "POST /pairing/handshake?phone_id=phone-1&bridge_id=bridge-other&session_token={session_token} HTTP/1.1"
        );
        let handshake = route_request(&handshake_path, &app);
        assert!(handshake.starts_with("HTTP/1.1 403 Forbidden"));
        assert!(handshake.contains("\"code\":\"bridge_identity_mismatch\""));
    }

    #[test]
    fn pairing_handshake_returns_bridge_identity_on_success() {
        let app = test_application();

        let session = parse_json_body(&route_request("POST /pairing/session HTTP/1.1", &app));
        let session_id = session["pairing_session"]["session_id"]
            .as_str()
            .expect("session id should be present");
        let pairing_token = session["pairing_session"]["pairing_token"]
            .as_str()
            .expect("pairing token should be present");
        let bridge_id = session["bridge_identity"]["bridge_id"]
            .as_str()
            .expect("bridge id should be present");

        let finalize_path = format!(
            "POST /pairing/finalize?session_id={session_id}&pairing_token={pairing_token}&phone_id=phone-1&phone_name=iPhone&bridge_id={bridge_id} HTTP/1.1"
        );
        let finalize_response = route_request(&finalize_path, &app);
        assert!(finalize_response.starts_with("HTTP/1.1 200 OK"));

        let finalized = parse_json_body(&finalize_response);
        let session_token = finalized["session_token"]
            .as_str()
            .expect("session token should be present");

        let handshake_path = format!(
            "POST /pairing/handshake?phone_id=phone-1&bridge_id={bridge_id}&session_token={session_token} HTTP/1.1"
        );
        let handshake_response = route_request(&handshake_path, &app);
        assert!(handshake_response.starts_with("HTTP/1.1 200 OK"));

        let handshake = parse_json_body(&handshake_response);
        assert_eq!(handshake["status"], "trusted");
        assert_eq!(handshake["bridge_identity"]["bridge_id"], bridge_id);
        assert!(
            handshake["bridge_identity"]["display_name"]
                .as_str()
                .is_some_and(|value| !value.trim().is_empty())
        );
    }

    #[test]
    fn pairing_finalize_allows_multiple_trusted_phones_per_mac() {
        let app = test_application();

        let first_session = parse_json_body(&route_request("POST /pairing/session HTTP/1.1", &app));
        let first_bridge_id = first_session["bridge_identity"]["bridge_id"]
            .as_str()
            .expect("bridge id should be present");
        let first_session_id = first_session["pairing_session"]["session_id"]
            .as_str()
            .expect("session id should be present");
        let first_pairing_token = first_session["pairing_session"]["pairing_token"]
            .as_str()
            .expect("pairing token should be present");

        let first_finalize_path = format!(
            "POST /pairing/finalize?session_id={first_session_id}&pairing_token={first_pairing_token}&phone_id=phone-1&phone_name=iPhone&bridge_id={first_bridge_id} HTTP/1.1"
        );
        let first_finalize = route_request(&first_finalize_path, &app);
        assert!(first_finalize.starts_with("HTTP/1.1 200 OK"));

        let second_session =
            parse_json_body(&route_request("POST /pairing/session HTTP/1.1", &app));
        let second_session_id = second_session["pairing_session"]["session_id"]
            .as_str()
            .expect("session id should be present");
        let second_pairing_token = second_session["pairing_session"]["pairing_token"]
            .as_str()
            .expect("pairing token should be present");

        let second_finalize_path = format!(
            "POST /pairing/finalize?session_id={second_session_id}&pairing_token={second_pairing_token}&phone_id=phone-2&phone_name=SecondPhone&bridge_id={first_bridge_id} HTTP/1.1"
        );
        let second_finalize = route_request(&second_finalize_path, &app);
        assert!(second_finalize.starts_with("HTTP/1.1 200 OK"));

        let trust_snapshot = app.trust_snapshot();
        assert_eq!(trust_snapshot.trusted_devices.len(), 2);
        assert_eq!(trust_snapshot.trusted_sessions.len(), 2);
    }

    fn test_application() -> BridgeApplication {
        test_application_with_pairing_route(true, None)
    }

    fn test_application_with_pairing_route(
        pairing_route_reachable: bool,
        pairing_route_message: Option<&str>,
    ) -> BridgeApplication {
        let mut runtime = CodexRuntimeSupervisor::new(CodexRuntimeConfig {
            mode: CodexRuntimeMode::Attach,
            endpoint: Some("ws://127.0.0.1:4222".to_string()),
            command: "codex".to_string(),
            args: vec!["app-server".to_string()],
        });
        runtime
            .initialize()
            .expect("test runtime should initialize");

        BridgeApplication::new(
            ThreadApiService::sample(),
            runtime,
            StreamRouter::new(),
            PairingSessionService::new(
                "127.0.0.1",
                3110,
                "https://bridge.ts.net",
                unique_test_state_dir(),
            ),
            PairingRouteState {
                pairing_base_url: "https://bridge.ts.net".to_string(),
                reachable: pairing_route_reachable,
                message: pairing_route_message.map(ToString::to_string),
                bridge_port: 3110,
                requires_runtime_serve_check: false,
            },
            StructuredLogger::new(InMemoryLogSink::default()),
        )
    }

    fn unique_test_state_dir() -> std::path::PathBuf {
        let unique = format!(
            "bridge-core-lib-test-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("system time before unix epoch")
                .as_nanos()
        );

        std::env::temp_dir().join(unique)
    }

    fn make_test_executable(name: &str) -> PathBuf {
        let path = unique_test_state_dir().join(name);
        fs::create_dir_all(
            path.parent()
                .expect("test executable should have a parent directory"),
        )
        .expect("should create test executable directory");
        fs::write(&path, b"#!/bin/sh\nexit 0\n").expect("should write test executable");
        #[cfg(unix)]
        {
            let mut permissions = fs::metadata(&path)
                .expect("test executable should exist")
                .permissions();
            permissions.set_mode(0o755);
            fs::set_permissions(&path, permissions).expect("should set executable permissions");
        }
        path
    }

    fn parse_json_body(response: &str) -> Value {
        let body = response
            .split("\r\n\r\n")
            .nth(1)
            .expect("response should include body");
        serde_json::from_str(body).expect("response body should decode as JSON")
    }

    fn trusted_session_query(app: &BridgeApplication) -> String {
        let session = parse_json_body(&route_request("POST /pairing/session HTTP/1.1", app));
        let session_id = session["pairing_session"]["session_id"]
            .as_str()
            .expect("session id should be present");
        let pairing_token = session["pairing_session"]["pairing_token"]
            .as_str()
            .expect("pairing token should be present");
        let bridge_id = session["bridge_identity"]["bridge_id"]
            .as_str()
            .expect("bridge id should be present");

        let finalize_path = format!(
            "POST /pairing/finalize?session_id={session_id}&pairing_token={pairing_token}&phone_id=phone-1&phone_name=iPhone&bridge_id={bridge_id} HTTP/1.1"
        );
        let finalized = parse_json_body(&route_request(&finalize_path, app));
        let session_token = finalized["session_token"]
            .as_str()
            .expect("session token should be present");

        format!("phone_id=phone-1&bridge_id={bridge_id}&session_token={session_token}")
    }
}
