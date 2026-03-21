use std::env;
use std::path::PathBuf;
use std::process::Command;

use serde::Serialize;
use serde_json::Value;

use crate::pairing::is_private_bridge_api_base_url;

const FALLBACK_PRIVATE_PAIRING_BASE_URL: &str = "https://bridge.ts.net";
const TAILSCALE_BIN_OVERRIDE_ENV: &str = "CODEX_MOBILE_COMPANION_TAILSCALE_BIN";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PairingRouteContract {
    pub pairing_base_url: String,
    pub reachable: bool,
    pub message: Option<String>,
    pub requires_runtime_serve_check: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PairingRouteState {
    pairing_base_url: String,
    reachable: bool,
    message: Option<String>,
    bridge_port: u16,
    requires_runtime_serve_check: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PairingRouteHealth {
    pub reachable: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub advertised_base_url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
}

impl PairingRouteState {
    pub fn new(
        pairing_base_url: String,
        reachable: bool,
        message: Option<String>,
        bridge_port: u16,
        requires_runtime_serve_check: bool,
    ) -> Self {
        Self {
            pairing_base_url,
            reachable,
            message,
            bridge_port,
            requires_runtime_serve_check,
        }
    }

    pub fn pairing_base_url(&self) -> &str {
        &self.pairing_base_url
    }

    pub fn health(&self) -> PairingRouteHealth {
        if self.reachable && self.requires_runtime_serve_check {
            let verified_base_url = discover_verified_tailscale_pairing_base_url(self.bridge_port);
            if verified_base_url.as_deref() != Some(self.pairing_base_url.as_str()) {
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

pub fn resolve_pairing_route_contract(
    port: u16,
    pairing_base_url: Option<String>,
) -> Result<PairingRouteContract, String> {
    if let Some(explicit_pairing_base_url) = pairing_base_url {
        if !is_private_bridge_api_base_url(&explicit_pairing_base_url) {
            return Err(
                "--pairing-base-url must be a private https Tailscale hostname".to_string(),
            );
        }

        return Ok(PairingRouteContract::explicit(explicit_pairing_base_url));
    }

    Ok(resolve_default_pairing_route_contract(port))
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
    let output = Command::new(&tailscale_bin)
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
    let output = Command::new(tailscale_bin).args(args).output().ok()?;

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
    if is_private_bridge_api_base_url(&candidate) {
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
    let Some(web_entry) =
        serve_status
            .get("Web")
            .and_then(Value::as_object)
            .and_then(|web_routes| {
                web_routes.iter().find_map(|(key, route)| {
                    (key.trim().trim_end_matches('.').to_ascii_lowercase() == expected_web_key)
                        .then_some(route)
                })
            })
    else {
        return false;
    };

    let root_handler = web_entry
        .get("Handlers")
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
