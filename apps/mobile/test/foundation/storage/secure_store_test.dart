import 'package:codex_mobile_companion/foundation/storage/persistence_boundary.dart';
import 'package:codex_mobile_companion/foundation/storage/secure_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('secure store writes, reads, and removes secrets', () async {
    final store = InMemorySecureStore();

    await store.writeSecret(SecureValueKey.sessionToken, 'token-1');
    expect(await store.readSecret(SecureValueKey.sessionToken), 'token-1');

    await store.removeSecret(SecureValueKey.sessionToken);
    expect(await store.readSecret(SecureValueKey.sessionToken), isNull);
  });

  test('secure key names align to shared contract metadata', () {
    expect(SecureValueKey.pairingPrivateKey.wireValue, 'pairing_private_key');
    expect(SecureValueKey.sessionToken.wireValue, 'session_token');
    expect(
      SecureValueKey.trustedBridgeIdentity.wireValue,
      'trusted_bridge_identity',
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
