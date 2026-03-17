import Foundation

enum SecureValueKey: String, CaseIterable {
    case pairingPrivateKey = "pairing_private_key"
    case sessionToken = "session_token"
    case trustedBridgeIdentity = "trusted_bridge_identity"
}

protocol SecureStore {
    func writeSecret(_ value: String, for key: SecureValueKey)
    func readSecret(for key: SecureValueKey) -> String?
    func removeSecret(for key: SecureValueKey)
}

final class InMemorySecureStore: SecureStore {
    private var values: [SecureValueKey: String] = [:]

    func writeSecret(_ value: String, for key: SecureValueKey) {
        values[key] = value
    }

    func readSecret(for key: SecureValueKey) -> String? {
        values[key]
    }

    func removeSecret(for key: SecureValueKey) {
        values.removeValue(forKey: key)
    }
}
