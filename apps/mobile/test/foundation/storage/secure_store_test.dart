import 'package:vibe_bridge/foundation/storage/persistence_boundary.dart';
import 'package:vibe_bridge/foundation/storage/secure_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('secure store writes, reads, and removes secrets', () async {
    final store = InMemorySecureStore();

    await store.writeSecret(SecureValueKey.sessionToken, 'token-1');
    expect(await store.readSecret(SecureValueKey.sessionToken), 'token-1');

    await store.removeSecret(SecureValueKey.sessionToken);
    expect(await store.readSecret(SecureValueKey.sessionToken), isNull);
  });

  test('persisted secure store survives re-instantiation', () async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});

    final firstStore = PersistedSecureStore(
      storage: const FlutterSecureStorage(),
    );
    await firstStore.writeSecret(SecureValueKey.sessionToken, 'session-1');
    await firstStore.writeSecret(SecureValueKey.selectedThreadId, 'thread-123');

    final secondStore = PersistedSecureStore(
      storage: const FlutterSecureStorage(),
    );
    expect(
      await secondStore.readSecret(SecureValueKey.sessionToken),
      'session-1',
    );
    expect(
      await secondStore.readSecret(SecureValueKey.selectedThreadId),
      'thread-123',
    );

    await secondStore.removeSecret(SecureValueKey.sessionToken);

    final thirdStore = PersistedSecureStore(
      storage: const FlutterSecureStorage(),
    );
    expect(await thirdStore.readSecret(SecureValueKey.sessionToken), isNull);
  });

  test(
    'persisted secure store falls back when macOS entitlement is missing',
    () async {
      final store = PersistedSecureStore(
        storage: _ThrowingFlutterSecureStorage(
          PlatformException(
            code: '-34018',
            message: "A required entitlement isn't present.",
          ),
        ),
      );

      await store.writeSecret(SecureValueKey.selectedThreadId, 'thread-123');

      expect(
        await store.readSecret(SecureValueKey.selectedThreadId),
        'thread-123',
      );
    },
  );

  test('secure key names align to shared contract metadata', () {
    expect(SecureValueKey.pairingPrivateKey.wireValue, 'pairing_private_key');
    expect(SecureValueKey.sessionToken.wireValue, 'session_token');
    expect(
      SecureValueKey.trustedBridgeIdentity.wireValue,
      'trusted_bridge_identity',
    );
    expect(
      SecureValueKey.savedBridgeRegistry.wireValue,
      'saved_bridge_registry',
    );
    expect(SecureValueKey.threadListCache.wireValue, 'thread_list_cache');
    expect(SecureValueKey.selectedThreadId.wireValue, 'selected_thread_id');
    expect(
      SecureValueKey.desktopIntegrationEnabled.wireValue,
      'desktop_integration_enabled',
    );
  });

  test('persistence boundary routes sqlite scopes and excludes secrets', () {
    const boundary = PersistenceBoundary(baseDirectory: '/tmp/mobile');

    expect(
      boundary.sqlitePathFor(PersistenceScope.threadsCache),
      '/tmp/mobile/state/threads-cache.sqlite',
    );
    expect(
      boundary.sqlitePathFor(PersistenceScope.timelineCache),
      '/tmp/mobile/state/timeline-cache.sqlite',
    );
    expect(
      boundary.sqlitePathFor(PersistenceScope.securityAudit),
      '/tmp/mobile/state/security-audit.sqlite',
    );
    expect(
      boundary.requiresSecureStore(PersistenceScope.securityAudit),
      isFalse,
    );
  });
}

class _ThrowingFlutterSecureStorage extends FlutterSecureStorage {
  _ThrowingFlutterSecureStorage(this.error);

  final PlatformException error;

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    WindowsOptions? wOptions,
    MacOsOptions? mOptions,
  }) async {
    throw error;
  }

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    WindowsOptions? wOptions,
    MacOsOptions? mOptions,
  }) async {
    throw error;
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    WindowsOptions? wOptions,
    MacOsOptions? mOptions,
  }) async {
    throw error;
  }
}
