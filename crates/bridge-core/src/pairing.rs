use std::collections::{BTreeSet, HashMap};
use std::fs;
use std::net::{IpAddr, Ipv4Addr};
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

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
        let bridge_id = derive_bridge_id(host, port);
        let trust_registry = TrustRegistry::load(
            state_directory.into().join("trust-registry.json"),
            bridge_id.clone(),
        );

        Self {
            bridge_id,
            bridge_name: "Codex Mobile Companion".to_string(),
            api_base_url: pairing_base_url.into(),
            next_sequence: 1,
            sessions: HashMap::new(),
            trust_registry,
        }
    }

    pub fn bridge_id(&self) -> &str {
        &self.bridge_id
    }

    pub fn issue_session(&mut self) -> PairingSessionResponse {
        let issued_at_epoch_seconds = unix_now_epoch_seconds();
        let expires_at_epoch_seconds = issued_at_epoch_seconds.saturating_add(300);
        let sequence = self.next_sequence;
        self.next_sequence = self.next_sequence.saturating_add(1);

        let session_id = format!("pairing-session-{sequence}");
        let pairing_token = format!("ptk-{issued_at_epoch_seconds:x}-{sequence:x}");

        let qr_payload = PairingQrPayload {
            contract_version: shared_contracts::CONTRACT_VERSION.to_string(),
            bridge_id: self.bridge_id.clone(),
            bridge_name: self.bridge_name.clone(),
            bridge_api_base_url: self.api_base_url.clone(),
            session_id: session_id.clone(),
            pairing_token: pairing_token.clone(),
            issued_at_epoch_seconds,
            expires_at_epoch_seconds,
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
            bridge_identity: PairingBridgeIdentity {
                bridge_id: self.bridge_id.clone(),
                display_name: self.bridge_name.clone(),
                api_base_url: self.api_base_url.clone(),
            },
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
        if request.bridge_id != self.bridge_id {
            return Err(PairingFinalizeError::BridgeIdentityMismatch);
        }

        if !is_private_bridge_api_base_url(&self.api_base_url) {
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

        if let Some(active_phone) = &self.trust_registry.state.trusted_phone
            && active_phone.phone_id != request.phone_id
        {
            return Err(PairingFinalizeError::TrustedPhoneConflict);
        }

        let trusted_at_epoch_seconds = unix_now_epoch_seconds();
        let session_token = format!(
            "sts-{trusted_at_epoch_seconds:x}-{:x}",
            self.next_sequence.saturating_add(99)
        );

        self.trust_registry.state.trusted_phone = Some(TrustedPhoneRecord {
            phone_id: request.phone_id.clone(),
            phone_name: request.phone_name.clone(),
            paired_at_epoch_seconds: trusted_at_epoch_seconds,
        });
        self.trust_registry.state.active_session = Some(TrustedSessionRecord {
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

        Ok(PairingFinalizeResponse {
            contract_version: shared_contracts::CONTRACT_VERSION.to_string(),
            bridge_identity: PairingBridgeIdentity {
                bridge_id: self.bridge_id.clone(),
                display_name: self.bridge_name.clone(),
                api_base_url: self.api_base_url.clone(),
            },
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

        let Some(active_session) = &self.trust_registry.state.active_session else {
            return Err(PairingHandshakeError::TrustRevoked);
        };

        if active_session.bridge_id != self.bridge_id {
            return Err(PairingHandshakeError::BridgeIdentityMismatch);
        }

        if active_session.phone_id != request.phone_id {
            return Err(PairingHandshakeError::TrustedPhoneMismatch);
        }

        if active_session.session_token != request.session_token {
            return Err(PairingHandshakeError::SessionTokenMismatch);
        }

        Ok(PairingHandshakeResponse {
            contract_version: shared_contracts::CONTRACT_VERSION.to_string(),
            bridge_id: self.bridge_id.clone(),
            phone_id: request.phone_id,
            session_id: active_session.session_id.clone(),
            status: "trusted".to_string(),
        })
    }

    pub fn revoke_trust(
        &mut self,
        request: PairingRevokeRequest,
    ) -> Result<PairingRevokeResponse, String> {
        let mut revoked = false;

        if let Some(active_session) = &self.trust_registry.state.active_session {
            let matches_phone = request
                .phone_id
                .as_deref()
                .map(|phone_id| phone_id == active_session.phone_id)
                .unwrap_or(true);

            if matches_phone {
                self.trust_registry
                    .state
                    .revoked_session_tokens
                    .insert(active_session.session_token.clone());
                self.trust_registry.state.active_session = None;
                self.trust_registry.state.trusted_phone = None;
                revoked = true;
            }
        }

        self.trust_registry.persist()?;

        Ok(PairingRevokeResponse {
            contract_version: shared_contracts::CONTRACT_VERSION.to_string(),
            revoked,
        })
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
    pub trusted_phone: TrustedPhoneState,
    pub session_token: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PairingHandshakeResponse {
    pub contract_version: String,
    pub bridge_id: String,
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
struct PairingQrPayload {
    contract_version: String,
    bridge_id: String,
    bridge_name: String,
    bridge_api_base_url: String,
    session_id: String,
    pairing_token: String,
    issued_at_epoch_seconds: u64,
    expires_at_epoch_seconds: u64,
}

#[derive(Debug)]
struct TrustRegistry {
    path: PathBuf,
    state: TrustRegistryState,
}

impl TrustRegistry {
    fn load(path: PathBuf, bridge_id: String) -> Self {
        let state = fs::read_to_string(&path)
            .ok()
            .and_then(|raw| serde_json::from_str::<TrustRegistryState>(&raw).ok())
            .unwrap_or_default();

        let mut registry = Self { path, state };
        registry.state.bridge_id = Some(bridge_id);
        registry
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

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
struct TrustRegistryState {
    #[serde(default)]
    bridge_id: Option<String>,
    #[serde(default)]
    trusted_phone: Option<TrustedPhoneRecord>,
    #[serde(default)]
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

fn derive_bridge_id(host: &str, port: u16) -> String {
    let mut hash = 0xcbf29ce484222325_u64;
    for byte in format!("{host}:{port}").bytes() {
        hash ^= byte as u64;
        hash = hash.wrapping_mul(0x100000001b3_u64);
    }
    format!("bridge-{hash:016x}")
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

    use super::{
        PairingFinalizeError, PairingFinalizeRequest, PairingHandshakeError,
        PairingHandshakeRequest, PairingRevokeRequest, PairingSessionService,
        is_private_bridge_api_base_url,
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

        let _ = std::fs::remove_dir_all(test_dir);
    }

    #[test]
    fn finalize_blocks_second_phone_without_explicit_reset() {
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
        let error = service
            .finalize_trust(PairingFinalizeRequest {
                session_id: second.pairing_session.session_id,
                pairing_token: second.pairing_session.pairing_token,
                phone_id: "phone-2".to_string(),
                phone_name: "Second".to_string(),
                bridge_id: second.bridge_identity.bridge_id,
            })
            .expect_err("second phone must be blocked");

        assert_eq!(error, PairingFinalizeError::TrustedPhoneConflict);
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
