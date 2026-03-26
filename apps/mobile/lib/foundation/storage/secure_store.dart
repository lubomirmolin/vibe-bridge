import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

enum SecureValueKey {
  pairingPrivateKey,
  sessionToken,
  trustedBridgeIdentity,
  savedBridgeRegistry,
  threadListCache,
  selectedThreadId,
  desktopIntegrationEnabled,
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
      case SecureValueKey.savedBridgeRegistry:
        return 'saved_bridge_registry';
      case SecureValueKey.threadListCache:
        return 'thread_list_cache';
      case SecureValueKey.selectedThreadId:
        return 'selected_thread_id';
      case SecureValueKey.desktopIntegrationEnabled:
        return 'desktop_integration_enabled';
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

class PersistedSecureStore implements SecureStore {
  PersistedSecureStore({
    FlutterSecureStorage? storage,
    InMemorySecureStore? fallbackStore,
  }) : _storage = storage ?? const FlutterSecureStorage(),
       _fallbackStore = fallbackStore ?? InMemorySecureStore();

  final FlutterSecureStorage _storage;
  final InMemorySecureStore _fallbackStore;

  @override
  Future<void> writeSecret(SecureValueKey key, String value) async {
    if (await _writeToPersistentStore(key, value)) {
      return;
    }

    await _fallbackStore.writeSecret(key, value);
  }

  @override
  Future<String?> readSecret(SecureValueKey key) async {
    final persisted = await _readFromPersistentStore(key);
    if (persisted != null) {
      return persisted;
    }

    return _fallbackStore.readSecret(key);
  }

  @override
  Future<void> removeSecret(SecureValueKey key) async {
    if (await _removeFromPersistentStore(key)) {
      return;
    }

    await _fallbackStore.removeSecret(key);
  }

  Future<bool> _writeToPersistentStore(SecureValueKey key, String value) async {
    try {
      await _storage.write(key: key.wireValue, value: value);
      return true;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (error) {
      if (_isUnavailablePluginError(error)) {
        return false;
      }
      rethrow;
    }
  }

  Future<String?> _readFromPersistentStore(SecureValueKey key) async {
    try {
      return await _storage.read(key: key.wireValue);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (error) {
      if (_isUnavailablePluginError(error)) {
        return null;
      }
      rethrow;
    }
  }

  Future<bool> _removeFromPersistentStore(SecureValueKey key) async {
    try {
      await _storage.delete(key: key.wireValue);
      return true;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (error) {
      if (_isUnavailablePluginError(error)) {
        return false;
      }
      rethrow;
    }
  }

  bool _isUnavailablePluginError(PlatformException error) {
    final normalizedCode = error.code.toLowerCase();
    final normalizedMessage = (error.message ?? '').toLowerCase();

    return normalizedCode == 'missing_plugin_exception' ||
        normalizedCode == 'missing_plugin' ||
        normalizedCode == '-34018' ||
        normalizedCode == 'channel-error' ||
        normalizedMessage.contains('missingpluginexception') ||
        normalizedMessage.contains(
          'unable to establish connection on channel',
        ) ||
        normalizedMessage.contains("a required entitlement isn't present");
  }
}
