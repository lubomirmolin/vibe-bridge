use std::collections::HashMap;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SecureValueKey {
    PairingPrivateKey,
    SessionToken,
    TrustedBridgeIdentity,
}

impl SecureValueKey {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::PairingPrivateKey => "pairing_private_key",
            Self::SessionToken => "session_token",
            Self::TrustedBridgeIdentity => "trusted_bridge_identity",
        }
    }
}

pub trait SecureStore {
    fn write_secret(&mut self, key: SecureValueKey, value: String);
    fn read_secret(&self, key: SecureValueKey) -> Option<&str>;
    fn remove_secret(&mut self, key: SecureValueKey);
}

#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct InMemorySecureStore {
    values: HashMap<SecureValueKey, String>,
}

impl InMemorySecureStore {
    pub fn new() -> Self {
        Self::default()
    }
}

impl SecureStore for InMemorySecureStore {
    fn write_secret(&mut self, key: SecureValueKey, value: String) {
        self.values.insert(key, value);
    }

    fn read_secret(&self, key: SecureValueKey) -> Option<&str> {
        self.values.get(&key).map(String::as_str)
    }

    fn remove_secret(&mut self, key: SecureValueKey) {
        self.values.remove(&key);
    }
}

#[cfg(test)]
mod tests {
    use super::{InMemorySecureStore, SecureStore, SecureValueKey};

    #[test]
    fn secure_values_follow_set_read_delete_lifecycle() {
        let mut store = InMemorySecureStore::new();

        store.write_secret(SecureValueKey::SessionToken, "token-1".to_string());
        assert_eq!(
            store.read_secret(SecureValueKey::SessionToken),
            Some("token-1")
        );

        store.remove_secret(SecureValueKey::SessionToken);
        assert_eq!(store.read_secret(SecureValueKey::SessionToken), None);
    }

    #[test]
    fn key_names_match_cross_platform_contract() {
        assert_eq!(
            SecureValueKey::PairingPrivateKey.as_str(),
            "pairing_private_key"
        );
        assert_eq!(SecureValueKey::SessionToken.as_str(), "session_token");
        assert_eq!(
            SecureValueKey::TrustedBridgeIdentity.as_str(),
            "trusted_bridge_identity"
        );
    }
}
