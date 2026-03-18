enum SecureValueKey {
  pairingPrivateKey,
  sessionToken,
  trustedBridgeIdentity,
  threadListCache,
  threadDetailsCache,
  selectedThreadId,
}

extension SecureValueKeyMetadata on SecureValueKey {
  String get wireValue {
    switch (this) {
      case SecureValueKey.pairingPrivateKey:
        return 'pairing_private_key';
      case SecureValueKey.sessionToken:
        return 'session_token';
      case SecureValueKey.trustedBridgeIdentity:
        return 'trusted_bridge_identity';
      case SecureValueKey.threadListCache:
        return 'thread_list_cache';
      case SecureValueKey.threadDetailsCache:
        return 'thread_details_cache';
      case SecureValueKey.selectedThreadId:
        return 'selected_thread_id';
    }
  }
}

abstract class SecureStore {
  Future<void> writeSecret(SecureValueKey key, String value);
  Future<String?> readSecret(SecureValueKey key);
  Future<void> removeSecret(SecureValueKey key);
}

class InMemorySecureStore implements SecureStore {
  final Map<SecureValueKey, String> _values = <SecureValueKey, String>{};

  @override
  Future<void> writeSecret(SecureValueKey key, String value) async {
    _values[key] = value;
  }

  @override
  Future<String?> readSecret(SecureValueKey key) async {
    return _values[key];
  }

  @override
  Future<void> removeSecret(SecureValueKey key) async {
    _values.remove(key);
  }
}
