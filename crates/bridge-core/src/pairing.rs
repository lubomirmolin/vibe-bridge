use std::collections::{BTreeSet, HashMap};
use std::fs;
use std::net::{IpAddr, Ipv4Addr};
use std::path::PathBuf;
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use shared_contracts::{BridgeApiRouteDto, BridgeApiRouteKind};

#[derive(Debug)]
pub struct PairingSessionService {
    bridge_id: String,
    bridge_name: String,
    api_base_url: String,
    next_sequence: u64,
    sessions: HashMap<String, PairingSessionRecord>,
    trust_registry: TrustRegistry,
}

impl PairingSessionService {
    pub fn new(
        host: &str,
        port: u16,
        pairing_base_url: impl Into<String>,
        state_directory: impl Into<PathBuf>,
    ) -> Self {
        let _ = (host, port);
        let trust_registry = TrustRegistry::load(
            state_directory.into().join("trust-registry.json"),
            generate_bridge_id(),
        );
        let bridge_id = trust_registry.bridge_id().to_string();
        let next_sequence = trust_registry.next_pairing_sequence();

        Self {
            bridge_id,
            bridge_name: resolve_bridge_name(),
            api_base_url: pairing_base_url.into(),
            next_sequence,
            sessions: HashMap::new(),
            trust_registry,
        }
    }

    pub fn bridge_id(&self) -> &str {
        &self.bridge_id
    }

    pub fn issue_session(&mut self) -> PairingSessionResponse {
        self.issue_session_with_routes(self.default_bridge_api_routes())
    }

    pub fn issue_session_with_routes(
        &mut self,
        bridge_api_routes: Vec<BridgeApiRouteDto>,
    ) -> PairingSessionResponse {
        let issued_at_epoch_seconds = unix_now_epoch_seconds();
        let expires_at_epoch_seconds = issued_at_epoch_seconds.saturating_add(300);
        let sequence = self.next_sequence;
        self.next_sequence = self.next_sequence.saturating_add(1);
        self.trust_registry
            .set_next_pairing_sequence(self.next_sequence);
        if let Err(error) = self.trust_registry.persist() {
            eprintln!("failed to persist pairing sequence state: {error}");
        }

        let session_id = format!("pairing-session-{sequence}");
        let pairing_token = format!("ptk-{issued_at_epoch_seconds:x}-{sequence:x}");

        let qr_payload = PairingQrPayload {
            contract_version: shared_contracts::CONTRACT_VERSION.to_string(),
            bridge_id: self.bridge_id.clone(),
            bridge_api_base_url: preferred_bridge_api_base_url(
                &bridge_api_routes,
                &self.api_base_url,
            ),
            routes: compact_pairing_qr_routes(&bridge_api_routes),
            session_id: session_id.clone(),
            pairing_token: pairing_token.clone(),
        };

        self.sessions.insert(
            session_id.clone(),
            PairingSessionRecord {
                pairing_token: pairing_token.clone(),
                issued_at_epoch_seconds,
                expires_at_epoch_seconds,
                consumed: false,
            },
        );

        let qr_payload =
            serde_json::to_string(&qr_payload).expect("pairing QR payload should serialize");

        eprintln!(
            "token-issued bridge_id={} session_id={session_id}",
            self.bridge_id
        );

        PairingSessionResponse {
            contract_version: shared_contracts::CONTRACT_VERSION.to_string(),
            bridge_identity: self.bridge_identity(&bridge_api_routes),
            bridge_api_routes,
            pairing_session: PairingSession {
                session_id,
                pairing_token,
                issued_at_epoch_seconds,
                expires_at_epoch_seconds,
            },
            qr_payload,
        }
    }

    pub fn finalize_trust(
        &mut self,
        request: PairingFinalizeRequest,
    ) -> Result<PairingFinalizeResponse, PairingFinalizeError> {
        self.finalize_trust_with_routes(request, self.default_bridge_api_routes())
    }

    pub fn finalize_trust_with_routes(
        &mut self,
        request: PairingFinalizeRequest,
        bridge_api_routes: Vec<BridgeApiRouteDto>,
    ) -> Result<PairingFinalizeResponse, PairingFinalizeError> {
        eprintln!(
            "pairing-finalize-request bridge_id={} phone_id={} phone_name={} session_id={} trusted_device_count={} active_session_count={}",
            self.bridge_id,
            request.phone_id,
            request.phone_name,
            request.session_id,
            self.trust_registry.state.trusted_phones.len(),
            self.trust_registry.state.active_sessions.len(),
        );
        if request.bridge_id != self.bridge_id {
            return Err(PairingFinalizeError::BridgeIdentityMismatch);
        }

        if bridge_api_routes.is_empty() {
            return Err(PairingFinalizeError::PrivateBridgePathRequired);
        }

        let Some(session) = self.sessions.get_mut(&request.session_id) else {
            return Err(PairingFinalizeError::UnknownPairingSession);
        };

        if session.pairing_token != request.pairing_token {
            return Err(PairingFinalizeError::InvalidPairingToken);
        }

        let now = unix_now_epoch_seconds();
        if now >= session.expires_at_epoch_seconds {
            return Err(PairingFinalizeError::PairingSessionExpired);
        }

        if session.consumed
            || self
                .trust_registry
                .state
                .consumed_pairing_sessions
                .contains(&request.session_id)
        {
            return Err(PairingFinalizeError::SessionAlreadyConsumed);
        }

        let trusted_at_epoch_seconds = unix_now_epoch_seconds();
        let session_token = format!(
            "sts-{trusted_at_epoch_seconds:x}-{:x}",
            self.next_sequence.saturating_add(99)
        );

        self.trust_registry
            .state
            .trusted_phones
            .retain(|record| record.phone_id != request.phone_id);
        self.trust_registry
            .state
            .trusted_phones
            .push(TrustedPhoneRecord {
                phone_id: request.phone_id.clone(),
                phone_name: request.phone_name.clone(),
                paired_at_epoch_seconds: trusted_at_epoch_seconds,
            });
        self.trust_registry
            .state
            .active_sessions
            .retain(|record| record.phone_id != request.phone_id);
        self.trust_registry
            .state
            .active_sessions
            .push(TrustedSessionRecord {
                phone_id: request.phone_id.clone(),
                bridge_id: self.bridge_id.clone(),
                session_id: request.session_id.clone(),
                session_token: session_token.clone(),
                finalized_at_epoch_seconds: trusted_at_epoch_seconds,
            });
        self.trust_registry
            .state
            .consumed_pairing_sessions
            .insert(request.session_id.clone());
        session.consumed = true;

        self.trust_registry
            .persist()
            .map_err(PairingFinalizeError::Storage)?;

        eprintln!(
            "pairing-finalize-success bridge_id={} trusted_device_count={} active_session_count={} trusted_phone_id={} session_id={}",
            self.bridge_id,
            self.trust_registry.state.trusted_phones.len(),
            self.trust_registry.state.active_sessions.len(),
            request.phone_id,
            request.session_id,
        );

        Ok(PairingFinalizeResponse {
            contract_version: shared_contracts::CONTRACT_VERSION.to_string(),
            bridge_identity: self.bridge_identity(&bridge_api_routes),
            bridge_api_routes,
            trusted_phone: TrustedPhoneState {
                phone_id: request.phone_id,
                phone_name: request.phone_name,
                session_id: request.session_id,
                paired_at_epoch_seconds: trusted_at_epoch_seconds,
            },
            session_token,
        })
    }

    pub fn handshake(
        &self,
        request: PairingHandshakeRequest,
    ) -> Result<PairingHandshakeResponse, PairingHandshakeError> {
        self.handshake_with_routes(request, self.default_bridge_api_routes())
    }

    pub fn handshake_with_routes(
        &self,
        request: PairingHandshakeRequest,
        bridge_api_routes: Vec<BridgeApiRouteDto>,
    ) -> Result<PairingHandshakeResponse, PairingHandshakeError> {
        if request.bridge_id != self.bridge_id {
            return Err(PairingHandshakeError::BridgeIdentityMismatch);
        }

        if self
            .trust_registry
            .state
            .revoked_session_tokens
            .contains(&request.session_token)
        {
            return Err(PairingHandshakeError::TrustRevoked);
        }

        let Some(active_session) =
            self.trust_registry
                .state
                .active_sessions
                .iter()
                .find(|session| {
                    session.phone_id == request.phone_id
                        && session.session_token == request.session_token
                })
        else {
            let phone_is_trusted = self
                .trust_registry
                .state
                .trusted_phones
                .iter()
                .any(|phone| phone.phone_id == request.phone_id);
            if !phone_is_trusted {
                return Err(PairingHandshakeError::TrustedPhoneMismatch);
            }

            let has_session_for_phone = self
                .trust_registry
                .state
                .active_sessions
                .iter()
                .any(|session| session.phone_id == request.phone_id);
            return Err(if has_session_for_phone {
                PairingHandshakeError::SessionTokenMismatch
            } else {
                PairingHandshakeError::TrustRevoked
            });
        };

        if active_session.bridge_id != self.bridge_id {
            return Err(PairingHandshakeError::BridgeIdentityMismatch);
        }

        Ok(PairingHandshakeResponse {
            contract_version: shared_contracts::CONTRACT_VERSION.to_string(),
            bridge_id: self.bridge_id.clone(),
            bridge_identity: self.bridge_identity(&bridge_api_routes),
            bridge_api_routes,
            phone_id: request.phone_id,
            session_id: active_session.session_id.clone(),
            status: "trusted".to_string(),
        })
    }

    pub fn revoke_trust(
        &mut self,
        request: PairingRevokeRequest,
    ) -> Result<PairingRevokeResponse, String> {
        eprintln!(
            "pairing-revoke-request bridge_id={} requested_phone_id={:?} trusted_device_count={} active_session_count={}",
            self.bridge_id,
            request.phone_id,
            self.trust_registry.state.trusted_phones.len(),
            self.trust_registry.state.active_sessions.len(),
        );
        let requested_phone_id = request.phone_id.as_deref();
        let active_sessions_before = self.trust_registry.state.active_sessions.len();
        let trusted_phones_before = self.trust_registry.state.trusted_phones.len();
        let mut revoked_tokens = Vec::new();

        self.trust_registry.state.active_sessions.retain(|session| {
            let should_remove = requested_phone_id
                .map(|phone_id| phone_id == session.phone_id)
                .unwrap_or(true);
            if should_remove {
                revoked_tokens.push(session.session_token.clone());
            }
            !should_remove
        });

        for session_token in revoked_tokens {
            self.trust_registry
                .state
                .revoked_session_tokens
                .insert(session_token);
        }

        self.trust_registry.state.trusted_phones.retain(|phone| {
            !requested_phone_id
                .map(|phone_id| phone_id == phone.phone_id)
                .unwrap_or(true)
        });
        let revoked = self.trust_registry.state.active_sessions.len() < active_sessions_before
            || self.trust_registry.state.trusted_phones.len() < trusted_phones_before;

        self.trust_registry.persist()?;

        eprintln!(
            "pairing-revoke-result bridge_id={} revoked={} trusted_device_count={} active_session_count={}",
            self.bridge_id,
            revoked,
            self.trust_registry.state.trusted_phones.len(),
            self.trust_registry.state.active_sessions.len(),
        );

        Ok(PairingRevokeResponse {
            contract_version: shared_contracts::CONTRACT_VERSION.to_string(),
            revoked,
        })
    }

    pub fn trust_snapshot(&self) -> PairingTrustSnapshot {
        let trusted_devices = self
            .trust_registry
            .state
            .trusted_phones
            .iter()
            .map(|record| PairingTrustedDeviceSnapshot {
                phone_id: record.phone_id.clone(),
                phone_name: record.phone_name.clone(),
                paired_at_epoch_seconds: record.paired_at_epoch_seconds,
            })
            .collect::<Vec<_>>();

        let trusted_sessions = self
            .trust_registry
            .state
            .active_sessions
            .iter()
            .map(|record| PairingTrustedSessionSnapshot {
                phone_id: record.phone_id.clone(),
                session_id: record.session_id.clone(),
                finalized_at_epoch_seconds: record.finalized_at_epoch_seconds,
            })
            .collect::<Vec<_>>();

        eprintln!(
            "pairing-trust-snapshot bridge_id={} registry_path={} trusted_device_count={} active_session_count={} trusted_phone_id={:?} active_session_id={:?}",
            self.bridge_id,
            self.trust_registry.path.display(),
            trusted_devices.len(),
            trusted_sessions.len(),
            trusted_devices
                .first()
                .map(|record| record.phone_id.as_str()),
            trusted_sessions
                .first()
                .map(|record| record.session_id.as_str()),
        );

        PairingTrustSnapshot {
            trusted_phone: trusted_devices.first().cloned(),
            active_session: trusted_sessions.first().cloned(),
            trusted_devices,
            trusted_sessions,
        }
    }

    fn bridge_identity(&self, bridge_api_routes: &[BridgeApiRouteDto]) -> PairingBridgeIdentity {
        PairingBridgeIdentity {
            bridge_id: self.bridge_id.clone(),
            display_name: self.bridge_name.clone(),
            api_base_url: preferred_bridge_api_base_url(bridge_api_routes, &self.api_base_url),
        }
    }

    fn default_bridge_api_routes(&self) -> Vec<BridgeApiRouteDto> {
        vec![BridgeApiRouteDto {
            id: match bridge_api_route_kind_for_base_url(&self.api_base_url) {
                BridgeApiRouteKind::Tailscale => "tailscale".to_string(),
                BridgeApiRouteKind::LocalNetwork => "local_network".to_string(),
            },
            kind: bridge_api_route_kind_for_base_url(&self.api_base_url),
            base_url: self.api_base_url.clone(),
            reachable: true,
            is_preferred: true,
        }]
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct PairingSessionRecord {
    pairing_token: String,
    issued_at_epoch_seconds: u64,
    expires_at_epoch_seconds: u64,
    consumed: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PairingFinalizeRequest {
    pub session_id: String,
    pub pairing_token: String,
    pub phone_id: String,
    pub phone_name: String,
    pub bridge_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PairingFinalizeError {
    UnknownPairingSession,
    InvalidPairingToken,
    PairingSessionExpired,
    SessionAlreadyConsumed,
    BridgeIdentityMismatch,
    PrivateBridgePathRequired,
    TrustedPhoneConflict,
    Storage(String),
}

impl PairingFinalizeError {
    pub const fn code(&self) -> &'static str {
        match self {
            Self::UnknownPairingSession => "unknown_pairing_session",
            Self::InvalidPairingToken => "invalid_pairing_token",
            Self::PairingSessionExpired => "pairing_session_expired",
            Self::SessionAlreadyConsumed => "session_already_consumed",
            Self::BridgeIdentityMismatch => "bridge_identity_mismatch",
            Self::PrivateBridgePathRequired => "private_bridge_path_required",
            Self::TrustedPhoneConflict => "trusted_phone_conflict",
            Self::Storage(_) => "storage_error",
        }
    }

    pub fn message(&self) -> String {
        match self {
            Self::UnknownPairingSession => {
                "Pairing session was not found. Please rescan from your Mac.".to_string()
            }
            Self::InvalidPairingToken => {
                "Pairing token is invalid. Please rescan from your Mac.".to_string()
            }
            Self::PairingSessionExpired => {
                "Pairing session expired. Please rescan from your Mac.".to_string()
            }
            Self::SessionAlreadyConsumed => {
                "Pairing session was already consumed. Please rescan from your Mac.".to_string()
            }
            Self::BridgeIdentityMismatch => {
                "Bridge identity did not match the active bridge. Re-pair is required.".to_string()
            }
            Self::PrivateBridgePathRequired => {
                "Pairing must complete through the private Tailscale bridge path.".to_string()
            }
            Self::TrustedPhoneConflict => {
                "This Mac is already paired with another phone. Reset trust before replacing it."
                    .to_string()
            }
            Self::Storage(error) => format!("Failed to persist trust state: {error}"),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PairingHandshakeRequest {
    pub phone_id: String,
    pub bridge_id: String,
    pub session_token: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PairingHandshakeError {
    BridgeIdentityMismatch,
    TrustRevoked,
    TrustedPhoneMismatch,
    SessionTokenMismatch,
}

impl PairingHandshakeError {
    pub const fn code(&self) -> &'static str {
        match self {
            Self::BridgeIdentityMismatch => "bridge_identity_mismatch",
            Self::TrustRevoked => "trust_revoked",
            Self::TrustedPhoneMismatch => "trusted_phone_mismatch",
            Self::SessionTokenMismatch => "session_token_mismatch",
        }
    }

    pub const fn message(&self) -> &'static str {
        match self {
            Self::BridgeIdentityMismatch => {
                "Stored bridge identity did not match the active bridge. Re-pair is required."
            }
            Self::TrustRevoked => {
                "Trust was revoked for this session. Re-pair from the Mac pairing QR."
            }
            Self::TrustedPhoneMismatch => {
                "This bridge is trusted for a different phone. Reset trust before pairing."
            }
            Self::SessionTokenMismatch => {
                "Stored session token no longer matches bridge trust. Re-pair is required."
            }
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PairingRevokeRequest {
    pub phone_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PairingRevokeResponse {
    pub contract_version: String,
    pub revoked: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PairingFinalizeResponse {
    pub contract_version: String,
    pub bridge_identity: PairingBridgeIdentity,
    pub bridge_api_routes: Vec<BridgeApiRouteDto>,
    pub trusted_phone: TrustedPhoneState,
    pub session_token: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PairingHandshakeResponse {
    pub contract_version: String,
    pub bridge_id: String,
    pub bridge_identity: PairingBridgeIdentity,
    pub bridge_api_routes: Vec<BridgeApiRouteDto>,
    pub phone_id: String,
    pub session_id: String,
    pub status: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct TrustedPhoneState {
    pub phone_id: String,
    pub phone_name: String,
    pub session_id: String,
    pub paired_at_epoch_seconds: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PairingSessionResponse {
    pub contract_version: String,
    pub bridge_identity: PairingBridgeIdentity,
    pub bridge_api_routes: Vec<BridgeApiRouteDto>,
    pub pairing_session: PairingSession,
    pub qr_payload: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PairingBridgeIdentity {
    pub bridge_id: String,
    pub display_name: String,
    pub api_base_url: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PairingSession {
    pub session_id: String,
    pub pairing_token: String,
    pub issued_at_epoch_seconds: u64,
    pub expires_at_epoch_seconds: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PairingTrustSnapshot {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub trusted_phone: Option<PairingTrustedDeviceSnapshot>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub active_session: Option<PairingTrustedSessionSnapshot>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub trusted_devices: Vec<PairingTrustedDeviceSnapshot>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub trusted_sessions: Vec<PairingTrustedSessionSnapshot>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PairingTrustedDeviceSnapshot {
    pub phone_id: String,
    pub phone_name: String,
    pub paired_at_epoch_seconds: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PairingTrustedSessionSnapshot {
    pub phone_id: String,
    pub session_id: String,
    pub finalized_at_epoch_seconds: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
struct PairingQrPayload {
    #[serde(rename = "v")]
    contract_version: String,
    #[serde(rename = "b")]
    bridge_id: String,
    #[serde(rename = "u")]
    bridge_api_base_url: String,
    #[serde(rename = "r")]
    routes: Vec<String>,
    #[serde(rename = "s")]
    session_id: String,
    #[serde(rename = "t")]
    pairing_token: String,
}

fn compact_pairing_qr_routes(bridge_api_routes: &[BridgeApiRouteDto]) -> Vec<String> {
    let mut preferred_routes = bridge_api_routes
        .iter()
        .filter(|route| route.reachable && route.is_preferred)
        .map(|route| route.base_url.clone())
        .collect::<Vec<_>>();
    let mut fallback_routes = bridge_api_routes
        .iter()
        .filter(|route| route.reachable && !route.is_preferred)
        .map(|route| route.base_url.clone())
        .collect::<Vec<_>>();

    preferred_routes.append(&mut fallback_routes);
    preferred_routes.dedup();
    preferred_routes
}

fn preferred_bridge_api_base_url(
    bridge_api_routes: &[BridgeApiRouteDto],
    fallback_api_base_url: &str,
) -> String {
    bridge_api_routes
        .iter()
        .find(|route| route.reachable && route.is_preferred)
        .or_else(|| bridge_api_routes.iter().find(|route| route.reachable))
        .map(|route| route.base_url.clone())
        .unwrap_or_else(|| fallback_api_base_url.to_string())
}

fn bridge_api_route_kind_for_base_url(base_url: &str) -> BridgeApiRouteKind {
    if is_private_bridge_api_base_url(base_url) {
        BridgeApiRouteKind::Tailscale
    } else {
        BridgeApiRouteKind::LocalNetwork
    }
}

fn resolve_bridge_name() -> String {
    resolve_bridge_name_with(|| {
        let output = Command::new("hostname").output().ok()?;
        if !output.status.success() {
            return None;
        }

        String::from_utf8(output.stdout).ok()
    })
}

fn resolve_bridge_name_with<F>(read_hostname: F) -> String
where
    F: FnOnce() -> Option<String>,
{
    normalize_bridge_name(read_hostname())
        .or_else(|| platform_bridge_name_fallback().map(str::to_string))
        .unwrap_or_else(|| "Codex Mobile Companion".to_string())
}

fn normalize_bridge_name(raw_hostname: Option<String>) -> Option<String> {
    raw_hostname.and_then(|value| {
        let trimmed = value.trim();
        if trimmed.is_empty() {
            None
        } else {
            Some(trimmed.to_string())
        }
    })
}

fn platform_bridge_name_fallback() -> Option<&'static str> {
    #[cfg(target_os = "macos")]
    {
        return Some("Mac");
    }

    #[cfg(target_os = "linux")]
    {
        return Some("Linux");
    }

    #[allow(unreachable_code)]
    None
}

#[derive(Debug)]
struct TrustRegistry {
    path: PathBuf,
    state: TrustRegistryState,
}

impl TrustRegistry {
    fn load(path: PathBuf, bridge_identity_seed: String) -> Self {
        let mut state = fs::read_to_string(&path)
            .ok()
            .and_then(|raw| serde_json::from_str::<TrustRegistryState>(&raw).ok())
            .unwrap_or_default();

        if state.next_pairing_sequence == 0 {
            state.next_pairing_sequence =
                infer_next_pairing_sequence(&state.consumed_pairing_sessions);
        }
        state.migrate_legacy_trust_state();

        let bridge_id = state
            .bridge_id
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(ToString::to_string)
            .unwrap_or(bridge_identity_seed);
        state.bridge_id = Some(bridge_id);

        let registry = Self { path, state };
        if let Err(error) = registry.persist() {
            eprintln!("failed to persist trust registry on load: {error}");
        }
        registry
    }

    fn bridge_id(&self) -> &str {
        self.state
            .bridge_id
            .as_deref()
            .expect("trust registry bridge_id should always be set")
    }

    fn next_pairing_sequence(&self) -> u64 {
        self.state.next_pairing_sequence.max(1)
    }

    fn set_next_pairing_sequence(&mut self, next_pairing_sequence: u64) {
        self.state.next_pairing_sequence = next_pairing_sequence.max(1);
    }

    fn persist(&self) -> Result<(), String> {
        if let Some(parent) = self.path.parent() {
            fs::create_dir_all(parent)
                .map_err(|error| format!("failed to prepare trust directory: {error}"))?;
        }

        let encoded = serde_json::to_string_pretty(&self.state)
            .map_err(|error| format!("failed to encode trust registry: {error}"))?;
        fs::write(&self.path, encoded)
            .map_err(|error| format!("failed to persist trust registry: {error}"))
    }
}

impl TrustRegistryState {
    fn migrate_legacy_trust_state(&mut self) {
        if self.trusted_phones.is_empty() {
            if let Some(trusted_phone) = self.trusted_phone.take() {
                self.trusted_phones.push(trusted_phone);
            }
        } else {
            self.trusted_phone = None;
        }

        if self.active_sessions.is_empty() {
            if let Some(active_session) = self.active_session.take() {
                self.active_sessions.push(active_session);
            }
        } else {
            self.active_session = None;
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
struct TrustRegistryState {
    #[serde(default)]
    bridge_id: Option<String>,
    #[serde(default)]
    next_pairing_sequence: u64,
    #[serde(default)]
    trusted_phones: Vec<TrustedPhoneRecord>,
    #[serde(default)]
    active_sessions: Vec<TrustedSessionRecord>,
    #[serde(default, skip_serializing)]
    trusted_phone: Option<TrustedPhoneRecord>,
    #[serde(default, skip_serializing)]
    active_session: Option<TrustedSessionRecord>,
    #[serde(default)]
    consumed_pairing_sessions: BTreeSet<String>,
    #[serde(default)]
    revoked_session_tokens: BTreeSet<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct TrustedPhoneRecord {
    phone_id: String,
    phone_name: String,
    paired_at_epoch_seconds: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct TrustedSessionRecord {
    phone_id: String,
    bridge_id: String,
    session_id: String,
    session_token: String,
    finalized_at_epoch_seconds: u64,
}

pub fn is_private_bridge_api_base_url(raw_url: &str) -> bool {
    let Some((scheme, host)) = parse_url_scheme_and_host(raw_url) else {
        return false;
    };

    if scheme != "https" {
        return false;
    }

    if host.is_empty() || is_loopback_or_private_host(&host) {
        return false;
    }

    host.ends_with(".ts.net") || host.ends_with(".tailscale.net")
}

fn parse_url_scheme_and_host(raw_url: &str) -> Option<(String, String)> {
    let (scheme, rest) = raw_url.split_once("://")?;
    let authority = rest.split('/').next().unwrap_or_default().trim();
    if scheme.trim().is_empty() || authority.is_empty() {
        return None;
    }

    let without_credentials = authority
        .rsplit_once('@')
        .map(|(_, host)| host)
        .unwrap_or(authority);

    let host = without_credentials
        .trim()
        .trim_start_matches('[')
        .trim_end_matches(']')
        .split(':')
        .next()
        .unwrap_or_default()
        .to_ascii_lowercase();

    Some((scheme.trim().to_ascii_lowercase(), host))
}

fn is_loopback_or_private_host(host: &str) -> bool {
    if host == "localhost" {
        return true;
    }

    if let Ok(ip_addr) = host.parse::<IpAddr>() {
        return match ip_addr {
            IpAddr::V4(ip) => is_private_or_loopback_v4(ip),
            IpAddr::V6(ip) => ip.is_loopback() || ip.is_unique_local(),
        };
    }

    false
}

fn is_private_or_loopback_v4(ip: Ipv4Addr) -> bool {
    ip.is_private() || ip.is_loopback() || ip.is_link_local()
}

fn infer_next_pairing_sequence(consumed_pairing_sessions: &BTreeSet<String>) -> u64 {
    consumed_pairing_sessions
        .iter()
        .filter_map(|session_id| parse_pairing_session_sequence(session_id))
        .max()
        .map(|last| last.saturating_add(1))
        .unwrap_or(1)
}

fn parse_pairing_session_sequence(session_id: &str) -> Option<u64> {
    let raw = session_id.strip_prefix("pairing-session-")?;
    raw.parse::<u64>().ok()
}

fn generate_bridge_id() -> String {
    let mut hash = 0xcbf29ce484222325_u64;
    for byte in format!("{}:{}", unix_now_epoch_nanoseconds(), std::process::id()).bytes() {
        hash ^= byte as u64;
        hash = hash.wrapping_mul(0x100000001b3_u64);
    }
    format!("bridge-{hash:016x}")
}

fn unix_now_epoch_nanoseconds() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or_default()
}

fn unix_now_epoch_seconds() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use serde_json::Value;
    use shared_contracts::{BridgeApiRouteDto, BridgeApiRouteKind};

    use super::{
        PairingFinalizeError, PairingFinalizeRequest, PairingHandshakeError,
        PairingHandshakeRequest, PairingRevokeRequest, PairingSessionService,
        is_private_bridge_api_base_url, platform_bridge_name_fallback, resolve_bridge_name_with,
    };

    #[test]
    fn private_bridge_url_validation_accepts_tailscale_hosts_and_rejects_local_hosts() {
        assert!(is_private_bridge_api_base_url(
            "https://bridge-example.tailnet.ts.net"
        ));
        assert!(is_private_bridge_api_base_url("https://bridge.ts.net"));
        assert!(!is_private_bridge_api_base_url("http://127.0.0.1:3110"));
        assert!(!is_private_bridge_api_base_url("https://localhost:3110"));
        assert!(!is_private_bridge_api_base_url("https://192.168.1.50:3110"));
    }

    #[test]
    fn finalize_consumes_session_and_rejects_reuse() {
        let mut service = test_service("https://bridge.ts.net");

        let issued = service.issue_session();
        let request = PairingFinalizeRequest {
            session_id: issued.pairing_session.session_id.clone(),
            pairing_token: issued.pairing_session.pairing_token.clone(),
            phone_id: "phone-1".to_string(),
            phone_name: "iPhone".to_string(),
            bridge_id: issued.bridge_identity.bridge_id,
        };

        let first = service
            .finalize_trust(request.clone())
            .expect("first finalize should succeed");
        assert!(first.session_token.starts_with("sts-"));

        let second = service
            .finalize_trust(request)
            .expect_err("reused session should be rejected");
        assert_eq!(second, PairingFinalizeError::SessionAlreadyConsumed);
    }

    #[test]
    fn trust_persists_across_restart_and_reconnect_handshake_succeeds() {
        let test_dir = unique_test_state_dir("persists-across-restart");
        let mut first = PairingSessionService::new(
            "127.0.0.1",
            3110,
            "https://bridge.ts.net",
            test_dir.clone(),
        );

        let issued = first.issue_session();
        let finalize = first
            .finalize_trust(PairingFinalizeRequest {
                session_id: issued.pairing_session.session_id,
                pairing_token: issued.pairing_session.pairing_token,
                phone_id: "phone-1".to_string(),
                phone_name: "Primary Phone".to_string(),
                bridge_id: issued.bridge_identity.bridge_id.clone(),
            })
            .expect("initial finalize should succeed");

        drop(first);

        let restarted = PairingSessionService::new(
            "127.0.0.1",
            3110,
            "https://bridge.ts.net",
            test_dir.clone(),
        );
        let handshake = restarted
            .handshake(PairingHandshakeRequest {
                phone_id: "phone-1".to_string(),
                bridge_id: issued.bridge_identity.bridge_id,
                session_token: finalize.session_token,
            })
            .expect("reconnect handshake should succeed after restart");

        assert_eq!(handshake.status, "trusted");
        assert_eq!(
            handshake.bridge_identity.display_name,
            restarted.bridge_name.as_str()
        );
        assert_eq!(
            handshake.bridge_identity.api_base_url,
            "https://bridge.ts.net"
        );

        let _ = std::fs::remove_dir_all(test_dir);
    }

    #[test]
    fn bridge_name_resolution_prefers_trimmed_hostname_and_falls_back() {
        assert_eq!(
            resolve_bridge_name_with(|| Some("  Operator Workstation \n".to_string())),
            "Operator Workstation"
        );

        let expected = platform_bridge_name_fallback()
            .unwrap_or("Codex Mobile Companion")
            .to_string();
        assert_eq!(
            resolve_bridge_name_with(|| Some("   ".to_string())),
            expected
        );
        assert_eq!(resolve_bridge_name_with(|| None), expected);
    }

    #[test]
    fn finalize_allows_multiple_trusted_phones() {
        let mut service = test_service("https://bridge.ts.net");

        let first = service.issue_session();
        service
            .finalize_trust(PairingFinalizeRequest {
                session_id: first.pairing_session.session_id,
                pairing_token: first.pairing_session.pairing_token,
                phone_id: "phone-1".to_string(),
                phone_name: "Primary".to_string(),
                bridge_id: first.bridge_identity.bridge_id.clone(),
            })
            .expect("first phone should pair");

        let second = service.issue_session();
        let second_finalize = service
            .finalize_trust(PairingFinalizeRequest {
                session_id: second.pairing_session.session_id,
                pairing_token: second.pairing_session.pairing_token,
                phone_id: "phone-2".to_string(),
                phone_name: "Second".to_string(),
                bridge_id: second.bridge_identity.bridge_id,
            })
            .expect("second phone should pair");

        assert!(second_finalize.session_token.starts_with("sts-"));
        let snapshot = service.trust_snapshot();
        assert_eq!(snapshot.trusted_devices.len(), 2);
        assert_eq!(snapshot.trusted_sessions.len(), 2);
    }

    #[test]
    fn revoked_trust_fails_closed_on_handshake() {
        let mut service = test_service("https://bridge.ts.net");

        let issued = service.issue_session();
        let finalized = service
            .finalize_trust(PairingFinalizeRequest {
                session_id: issued.pairing_session.session_id,
                pairing_token: issued.pairing_session.pairing_token,
                phone_id: "phone-1".to_string(),
                phone_name: "Primary".to_string(),
                bridge_id: issued.bridge_identity.bridge_id.clone(),
            })
            .expect("pairing should succeed");

        service
            .revoke_trust(PairingRevokeRequest {
                phone_id: Some("phone-1".to_string()),
            })
            .expect("revoke should persist");

        let error = service
            .handshake(PairingHandshakeRequest {
                phone_id: "phone-1".to_string(),
                bridge_id: issued.bridge_identity.bridge_id,
                session_token: finalized.session_token,
            })
            .expect_err("revoked trust must fail closed");

        assert_eq!(error, PairingHandshakeError::TrustRevoked);
    }

    #[test]
    fn revoke_only_removes_requested_phone() {
        let mut service = test_service("https://bridge.ts.net");

        let first = service.issue_session();
        let first_finalize = service
            .finalize_trust(PairingFinalizeRequest {
                session_id: first.pairing_session.session_id,
                pairing_token: first.pairing_session.pairing_token,
                phone_id: "phone-1".to_string(),
                phone_name: "Primary".to_string(),
                bridge_id: first.bridge_identity.bridge_id.clone(),
            })
            .expect("first phone should pair");

        let second = service.issue_session();
        service
            .finalize_trust(PairingFinalizeRequest {
                session_id: second.pairing_session.session_id,
                pairing_token: second.pairing_session.pairing_token,
                phone_id: "phone-2".to_string(),
                phone_name: "Second".to_string(),
                bridge_id: second.bridge_identity.bridge_id.clone(),
            })
            .expect("second phone should pair");

        let revoke = service
            .revoke_trust(PairingRevokeRequest {
                phone_id: Some("phone-2".to_string()),
            })
            .expect("targeted revoke should persist");
        assert!(revoke.revoked);

        let snapshot = service.trust_snapshot();
        assert_eq!(snapshot.trusted_devices.len(), 1);
        assert_eq!(snapshot.trusted_devices[0].phone_id, "phone-1");
        assert_eq!(snapshot.trusted_sessions.len(), 1);
        assert_eq!(snapshot.trusted_sessions[0].phone_id, "phone-1");

        let handshake = service.handshake(PairingHandshakeRequest {
            phone_id: "phone-1".to_string(),
            bridge_id: first.bridge_identity.bridge_id,
            session_token: first_finalize.session_token,
        });
        assert!(handshake.is_ok());
    }

    #[test]
    fn bridge_identity_persists_across_restart_and_bind_changes() {
        let test_dir = unique_test_state_dir("bridge-identity-persisted");

        let first = PairingSessionService::new(
            "127.0.0.1",
            3110,
            "https://bridge.ts.net",
            test_dir.clone(),
        );
        let first_bridge_id = first.bridge_id().to_string();
        drop(first);

        let restarted =
            PairingSessionService::new("0.0.0.0", 9999, "https://bridge.ts.net", test_dir.clone());

        assert_eq!(restarted.bridge_id(), first_bridge_id);

        let _ = std::fs::remove_dir_all(test_dir);
    }

    #[test]
    fn consumed_session_ids_do_not_collide_with_new_sessions_after_restart() {
        let test_dir = unique_test_state_dir("session-collision-safe");
        let mut first = PairingSessionService::new(
            "127.0.0.1",
            3110,
            "https://bridge.ts.net",
            test_dir.clone(),
        );

        let first_session = first.issue_session();
        let first_session_id = first_session.pairing_session.session_id.clone();

        first
            .finalize_trust(PairingFinalizeRequest {
                session_id: first_session.pairing_session.session_id,
                pairing_token: first_session.pairing_session.pairing_token,
                phone_id: "phone-1".to_string(),
                phone_name: "Primary".to_string(),
                bridge_id: first_session.bridge_identity.bridge_id,
            })
            .expect("first session should finalize");

        drop(first);

        let mut restarted = PairingSessionService::new(
            "127.0.0.1",
            3110,
            "https://bridge.ts.net",
            test_dir.clone(),
        );
        let second_session = restarted.issue_session();
        assert_ne!(first_session_id, second_session.pairing_session.session_id);

        let second_finalize = restarted.finalize_trust(PairingFinalizeRequest {
            session_id: second_session.pairing_session.session_id,
            pairing_token: second_session.pairing_session.pairing_token,
            phone_id: "phone-1".to_string(),
            phone_name: "Primary".to_string(),
            bridge_id: second_session.bridge_identity.bridge_id,
        });

        assert!(second_finalize.is_ok());

        let _ = std::fs::remove_dir_all(test_dir);
    }

    #[test]
    fn issued_qr_payload_uses_compact_route_and_timestamp_fields() {
        let mut service = test_service("https://bridge.ts.net");
        let issued = service.issue_session_with_routes(vec![
            BridgeApiRouteDto {
                id: "tailscale".to_string(),
                kind: BridgeApiRouteKind::Tailscale,
                base_url: "https://bridge.ts.net".to_string(),
                reachable: true,
                is_preferred: true,
            },
            BridgeApiRouteDto {
                id: "local_network".to_string(),
                kind: BridgeApiRouteKind::LocalNetwork,
                base_url: "http://192.168.1.10:3110".to_string(),
                reachable: true,
                is_preferred: false,
            },
        ]);

        let qr_payload: Value =
            serde_json::from_str(&issued.qr_payload).expect("qr payload should decode");

        assert_eq!(qr_payload["u"], "https://bridge.ts.net");
        assert_eq!(qr_payload["b"], issued.bridge_identity.bridge_id);
        assert_eq!(qr_payload["s"], issued.pairing_session.session_id);
        assert_eq!(qr_payload["t"], issued.pairing_session.pairing_token);
        assert_eq!(
            qr_payload["r"],
            serde_json::json!(["https://bridge.ts.net", "http://192.168.1.10:3110"])
        );
        assert!(qr_payload.get("i").is_none());
        assert!(qr_payload.get("e").is_none());
        assert!(qr_payload.get("bridge_api_routes").is_none());
        assert!(qr_payload.get("issued_at_epoch_seconds").is_none());
        assert!(qr_payload.get("expires_at_epoch_seconds").is_none());
    }

    fn test_service(pairing_base_url: &str) -> PairingSessionService {
        PairingSessionService::new(
            "127.0.0.1",
            3110,
            pairing_base_url,
            unique_test_state_dir("pairing-service"),
        )
    }

    fn unique_test_state_dir(suffix: &str) -> PathBuf {
        let unique = format!(
            "bridge-core-{suffix}-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("system time before unix epoch")
                .as_nanos()
        );

        std::env::temp_dir().join(unique)
    }
}
