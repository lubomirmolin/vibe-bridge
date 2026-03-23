use std::env;
use std::fs;
use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4};
use std::path::PathBuf;
use std::process::Command;
use std::sync::{Arc, RwLock};

use if_addrs::{IfAddr, get_if_addrs};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use shared_contracts::{
    BridgeApiRouteDto, BridgeApiRouteKind, NetworkSettingsDto, PairingRouteInventoryDto,
};

use crate::pairing::is_private_bridge_api_base_url;

const FALLBACK_PRIVATE_PAIRING_BASE_URL: &str = "https://bridge.ts.net";
const NETWORK_SETTINGS_FILE_NAME: &str = "network-settings.json";
const TAILSCALE_BIN_OVERRIDE_ENV: &str = "CODEX_MOBILE_COMPANION_TAILSCALE_BIN";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PairingRouteContract {
    pub pairing_base_url: String,
    pub reachable: bool,
    pub message: Option<String>,
    pub requires_runtime_serve_check: bool,
}

#[derive(Debug, Clone)]
pub struct PairingRouteState {
    inner: Arc<PairingRouteStateInner>,
}

impl PartialEq for PairingRouteState {
    fn eq(&self, other: &Self) -> bool {
        self.inner.tailscale_pairing_base_url == other.inner.tailscale_pairing_base_url
            && self.inner.tailscale_reachable == other.inner.tailscale_reachable
            && self.inner.tailscale_message == other.inner.tailscale_message
            && self.inner.bridge_port == other.inner.bridge_port
            && self.inner.requires_runtime_serve_check == other.inner.requires_runtime_serve_check
            && self
                .inner
                .settings
                .read()
                .expect("network settings lock should not be poisoned")
                .eq(&other
                    .inner
                    .settings
                    .read()
                    .expect("network settings lock should not be poisoned"))
            && self
                .inner
                .lan_runtime
                .read()
                .expect("lan runtime lock should not be poisoned")
                .eq(&other
                    .inner
                    .lan_runtime
                    .read()
                    .expect("lan runtime lock should not be poisoned"))
    }
}

impl Eq for PairingRouteState {}

#[derive(Debug)]
struct PairingRouteStateInner {
    tailscale_pairing_base_url: String,
    tailscale_reachable: bool,
    tailscale_message: Option<String>,
    bridge_port: u16,
    requires_runtime_serve_check: bool,
    settings_path: PathBuf,
    settings: RwLock<NetworkSettingsState>,
    lan_runtime: RwLock<LanRuntimeState>,
}

pub type PairingRouteHealth = PairingRouteInventoryDto;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
struct NetworkSettingsState {
    #[serde(default)]
    local_network_pairing_enabled: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
struct LanRuntimeState {
    active_bind_addr: Option<SocketAddr>,
    last_error: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct RouteCandidate {
    route: BridgeApiRouteDto,
    message: Option<String>,
}

impl PairingRouteState {
    pub fn new(
        pairing_base_url: String,
        reachable: bool,
        message: Option<String>,
        bridge_port: u16,
        requires_runtime_serve_check: bool,
        state_directory: impl Into<PathBuf>,
    ) -> Self {
        let settings_path = state_directory.into().join(NETWORK_SETTINGS_FILE_NAME);
        let settings = load_network_settings(&settings_path);
        Self {
            inner: Arc::new(PairingRouteStateInner {
                tailscale_pairing_base_url: pairing_base_url,
                tailscale_reachable: reachable,
                tailscale_message: message,
                bridge_port,
                requires_runtime_serve_check,
                settings_path,
                settings: RwLock::new(settings),
                lan_runtime: RwLock::new(LanRuntimeState::default()),
            }),
        }
    }

    pub fn pairing_base_url(&self) -> String {
        self.preferred_route_base_url()
            .unwrap_or_else(|| self.inner.tailscale_pairing_base_url.clone())
    }

    pub fn pairing_routes(&self) -> Vec<BridgeApiRouteDto> {
        self.route_candidates()
            .into_iter()
            .filter(|candidate| candidate.route.reachable)
            .map(|candidate| candidate.route)
            .collect()
    }

    pub fn health(&self) -> PairingRouteHealth {
        let candidates = self.route_candidates();
        let routes = candidates
            .iter()
            .map(|candidate| candidate.route.clone())
            .collect::<Vec<_>>();
        let advertised_base_url = routes
            .iter()
            .find(|route| route.reachable && route.is_preferred)
            .map(|route| route.base_url.clone())
            .or_else(|| {
                routes
                    .iter()
                    .find(|route| route.reachable)
                    .map(|route| route.base_url.clone())
            });
        let reachable = routes.iter().any(|route| route.reachable);
        let message = if reachable {
            None
        } else {
            candidates
                .into_iter()
                .find_map(|candidate| candidate.message)
        };

        PairingRouteInventoryDto {
            reachable,
            advertised_base_url,
            routes,
            message,
        }
    }

    pub fn network_settings(&self) -> NetworkSettingsDto {
        let settings = self
            .inner
            .settings
            .read()
            .expect("network settings lock should not be poisoned")
            .clone();
        let health = self.health();
        NetworkSettingsDto {
            contract_version: shared_contracts::CONTRACT_VERSION.to_string(),
            local_network_pairing_enabled: settings.local_network_pairing_enabled,
            routes: health.routes,
            message: health.message,
        }
    }

    pub fn set_local_network_pairing_enabled(
        &self,
        enabled: bool,
    ) -> Result<NetworkSettingsDto, String> {
        {
            let mut settings = self
                .inner
                .settings
                .write()
                .expect("network settings lock should not be poisoned");
            settings.local_network_pairing_enabled = enabled;
            persist_network_settings(&self.inner.settings_path, &settings)?;
        }

        if !enabled {
            self.clear_lan_listener_runtime();
        }

        Ok(self.network_settings())
    }

    pub fn desired_lan_listener_addr(&self) -> Option<SocketAddr> {
        let settings = self
            .inner
            .settings
            .read()
            .expect("network settings lock should not be poisoned");
        if !settings.local_network_pairing_enabled {
            return None;
        }

        discover_best_local_network_ipv4()
            .map(|ip| SocketAddr::V4(SocketAddrV4::new(ip, self.inner.bridge_port)))
    }

    pub fn record_lan_listener_active(&self, bind_addr: SocketAddr) {
        let mut lan_runtime = self
            .inner
            .lan_runtime
            .write()
            .expect("lan runtime lock should not be poisoned");
        lan_runtime.active_bind_addr = Some(bind_addr);
        lan_runtime.last_error = None;
    }

    pub fn record_lan_listener_error(&self, error: impl Into<String>) {
        let mut lan_runtime = self
            .inner
            .lan_runtime
            .write()
            .expect("lan runtime lock should not be poisoned");
        lan_runtime.active_bind_addr = None;
        lan_runtime.last_error = Some(error.into());
    }

    pub fn clear_lan_listener_runtime(&self) {
        let mut lan_runtime = self
            .inner
            .lan_runtime
            .write()
            .expect("lan runtime lock should not be poisoned");
        lan_runtime.active_bind_addr = None;
        lan_runtime.last_error = None;
    }

    fn preferred_route_base_url(&self) -> Option<String> {
        self.pairing_routes()
            .into_iter()
            .find(|route| route.is_preferred)
            .map(|route| route.base_url)
            .or_else(|| {
                self.pairing_routes()
                    .into_iter()
                    .next()
                    .map(|route| route.base_url)
            })
    }

    fn route_candidates(&self) -> Vec<RouteCandidate> {
        let tailscale = self.tailscale_candidate();
        let lan = self.local_network_candidate();

        let tailscale_reachable = tailscale.route.reachable;
        let lan_reachable = lan
            .as_ref()
            .map(|candidate| candidate.route.reachable)
            .unwrap_or(false);

        let mut routes = vec![RouteCandidate {
            route: BridgeApiRouteDto {
                is_preferred: tailscale_reachable,
                ..tailscale.route
            },
            message: tailscale.message,
        }];

        if let Some(mut lan_candidate) = lan {
            lan_candidate.route.is_preferred = !tailscale_reachable && lan_reachable;
            routes.push(lan_candidate);
        }

        routes
    }

    fn tailscale_candidate(&self) -> RouteCandidate {
        if self.inner.requires_runtime_serve_check {
            if let Some(pairing_base_url) =
                discover_verified_tailscale_pairing_base_url(self.inner.bridge_port)
            {
                return RouteCandidate {
                    route: BridgeApiRouteDto {
                        id: "tailscale".to_string(),
                        kind: BridgeApiRouteKind::Tailscale,
                        base_url: pairing_base_url,
                        reachable: true,
                        is_preferred: false,
                    },
                    message: None,
                };
            }

            if self.inner.tailscale_reachable {
                return RouteCandidate {
                    route: BridgeApiRouteDto {
                        id: "tailscale".to_string(),
                        kind: BridgeApiRouteKind::Tailscale,
                        base_url: self.inner.tailscale_pairing_base_url.clone(),
                        reachable: false,
                        is_preferred: false,
                    },
                    message: Some(format!(
                        "Tailscale pairing route is unavailable: verified tailscale serve mapping for localhost port {} is no longer active.",
                        self.inner.bridge_port
                    )),
                };
            }
        }

        RouteCandidate {
            route: BridgeApiRouteDto {
                id: "tailscale".to_string(),
                kind: BridgeApiRouteKind::Tailscale,
                base_url: self.inner.tailscale_pairing_base_url.clone(),
                reachable: self.inner.tailscale_reachable,
                is_preferred: false,
            },
            message: self.inner.tailscale_message.clone(),
        }
    }

    fn local_network_candidate(&self) -> Option<RouteCandidate> {
        let settings = self
            .inner
            .settings
            .read()
            .expect("network settings lock should not be poisoned")
            .clone();
        if !settings.local_network_pairing_enabled {
            return None;
        }

        let desired_addr = discover_best_local_network_ipv4()
            .map(|ip| SocketAddr::V4(SocketAddrV4::new(ip, self.inner.bridge_port)));
        let lan_runtime = self
            .inner
            .lan_runtime
            .read()
            .expect("lan runtime lock should not be poisoned")
            .clone();

        let (base_url, reachable, message) = match desired_addr {
            Some(addr) if lan_runtime.active_bind_addr == Some(addr) => {
                (format!("http://{addr}"), true, None)
            }
            Some(addr) => (
                format!("http://{addr}"),
                false,
                lan_runtime.last_error.or_else(|| {
                    Some(format!(
                        "Local network pairing is enabled, but the bridge has not started listening on {} yet.",
                        addr
                    ))
                }),
            ),
            None => (
                format!("http://127.0.0.1:{}", self.inner.bridge_port),
                false,
                Some(
                    "Local network pairing is enabled, but no eligible private IPv4 address is available on this host."
                        .to_string(),
                ),
            ),
        };

        Some(RouteCandidate {
            route: BridgeApiRouteDto {
                id: "local_network".to_string(),
                kind: BridgeApiRouteKind::LocalNetwork,
                base_url,
                reachable,
                is_preferred: false,
            },
            message,
        })
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
            "Tailscale pairing route is unavailable: failed to launch `tailscale serve --bg {port}`: {error}"
        ));
    }

    match discover_route(port) {
        Some(pairing_base_url) => PairingRouteContract::verified(pairing_base_url),
        None => PairingRouteContract::degraded(format!(
            "Tailscale pairing route is unavailable: `tailscale serve --bg {port}` ran, but no verified mapping to localhost:{port} was found in `tailscale serve status --json`."
        )),
    }
}

fn load_network_settings(path: &PathBuf) -> NetworkSettingsState {
    fs::read_to_string(path)
        .ok()
        .and_then(|raw| serde_json::from_str::<NetworkSettingsState>(&raw).ok())
        .unwrap_or_default()
}

fn persist_network_settings(path: &PathBuf, settings: &NetworkSettingsState) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .map_err(|error| format!("failed to prepare network settings directory: {error}"))?;
    }

    let encoded = serde_json::to_string_pretty(settings)
        .map_err(|error| format!("failed to encode network settings: {error}"))?;
    fs::write(path, encoded).map_err(|error| format!("failed to persist network settings: {error}"))
}

fn discover_best_local_network_ipv4() -> Option<Ipv4Addr> {
    let mut candidates = get_if_addrs()
        .ok()?
        .into_iter()
        .filter_map(|interface| match interface.addr {
            IfAddr::V4(v4) if is_eligible_local_network_ipv4(v4.ip, &interface.name) => {
                Some((interface_priority(&interface.name), interface.name, v4.ip))
            }
            _ => None,
        })
        .collect::<Vec<_>>();

    candidates.sort_by(|left, right| {
        right
            .0
            .cmp(&left.0)
            .then_with(|| left.1.cmp(&right.1))
            .then_with(|| left.2.octets().cmp(&right.2.octets()))
    });

    candidates.into_iter().map(|(_, _, ip)| ip).next()
}

fn is_eligible_local_network_ipv4(ip: Ipv4Addr, interface_name: &str) -> bool {
    ip.is_private()
        && !ip.is_link_local()
        && !ip.is_loopback()
        && !interface_name_is_virtual(interface_name)
}

fn interface_name_is_virtual(name: &str) -> bool {
    let normalized = name.trim().to_ascii_lowercase();
    [
        "lo",
        "utun",
        "awdl",
        "llw",
        "tailscale",
        "ts",
        "tun",
        "tap",
        "docker",
        "veth",
        "bridge",
        "br-",
        "vmnet",
        "vboxnet",
        "virbr",
    ]
    .iter()
    .any(|prefix| normalized.starts_with(prefix))
}

fn interface_priority(name: &str) -> u8 {
    let normalized = name.trim().to_ascii_lowercase();
    if normalized.starts_with("en")
        || normalized.starts_with("eth")
        || normalized.starts_with("wlan")
        || normalized.starts_with("wifi")
        || normalized.starts_with("wl")
    {
        3
    } else if normalized.starts_with("lan") {
        2
    } else {
        1
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

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use super::PairingRouteState;

    #[test]
    fn health_recovers_when_verified_route_appears_after_startup() {
        let state = PairingRouteState::new(
            "https://bridge.ts.net".to_string(),
            false,
            Some("stale startup error".to_string()),
            65530,
            true,
            PathBuf::from("."),
        );

        let health = state.health();
        let routes = state.pairing_routes();
        if health.reachable {
            assert!(health.advertised_base_url.is_some());
            assert!(!routes.is_empty());
        } else {
            assert!(routes.is_empty());
        }
    }
}
