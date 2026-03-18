import 'package:codex_mobile_companion/foundation/storage/persistence_boundary.dart';
import 'package:codex_mobile_companion/foundation/storage/secure_store.dart';
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
    await firstStore.writeSecret(
      SecureValueKey.selectedThreadId,
      'thread-123',
    );

    final secondStore = PersistedSecureStore(
      storage: const FlutterSecureStorage(),
    );
    expect(await secondStore.readSecret(SecureValueKey.sessionToken), 'session-1');
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

  test('secure key names align to shared contract metadata', () {
    expect(SecureValueKey.pairingPrivateKey.wireValue, 'pairing_private_key');
    expect(SecureValueKey.sessionToken.wireValue, 'session_token');
    expect(
      SecureValueKey.trustedBridgeIdentity.wireValue,
      'trusted_bridge_identity',
    );
    expect(SecureValueKey.threadListCache.wireValue, 'thread_list_cache');
    expect(SecureValueKey.threadDetailsCache.wireValue, 'thread_details_cache');
    expect(SecureValueKey.selectedThreadId.wireValue, 'selected_thread_id');
    expect(
      SecureValueKey.notificationPreferences.wireValue,
      'notification_preferences',
    );
    expect(
      SecureValueKey.runtimeNotificationSeenEventIds.wireValue,
      'runtime_notification_seen_event_ids',
    );
    expect(
      SecureValueKey.runtimeNotificationPendingLaunchTarget.wireValue,
      'runtime_notification_pending_launch_target',
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
