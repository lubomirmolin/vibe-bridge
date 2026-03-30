import 'dart:convert';

import 'package:vibe_bridge/features/bridges/application/pairing_controller.dart';
import 'package:vibe_bridge/features/bridges/data/pairing_bridge_api.dart';
import 'package:vibe_bridge/features/bridges/domain/pairing_qr_payload.dart';
import 'package:vibe_bridge/foundation/storage/secure_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'compact QR payload pairs successfully and persists bridge identity from finalize response',
    () async {
      final store = InMemorySecureStore();
      final controller = PairingController(
        secureStore: store,
        bridgeApi: const FakePairingBridgeApi(
          bridgeName: 'Operator Workstation',
          bridgeApiBaseUrl: 'https://mac.taild54ede.ts.net',
        ),
        phoneDisplayName: 'Test Phone',
        nowUtc: () => DateTime.utc(2026, 3, 19, 9, 0),
      );
      addTearDown(controller.dispose);

      controller.openScanner();
      controller.submitScannedPayload(_compactPayload());

      expect(controller.state.step, PairingStep.review);
      expect(controller.state.pendingPayload?.bridgeName, 'Vibe bridge');

      await controller.confirmTrust();

      expect(controller.state.step, PairingStep.paired);
      expect(
        controller.state.trustedBridge?.bridgeName,
        'Operator Workstation',
      );
      expect(
        controller.state.trustedBridge?.bridgeApiBaseUrl,
        'https://mac.taild54ede.ts.net',
      );

      final storedTrust = await store.readSecret(
        SecureValueKey.trustedBridgeIdentity,
      );
      expect(storedTrust, isNotNull);

      final decodedTrust = jsonDecode(storedTrust!) as Map<String, dynamic>;
      expect(decodedTrust['bridge_id'], 'bridge-a1');
      expect(decodedTrust['bridge_name'], 'Operator Workstation');
      expect(
        decodedTrust['bridge_api_base_url'],
        'https://mac.taild54ede.ts.net',
      );
      expect(decodedTrust['session_id'], 'session-1');

      expect(
        await store.readSecret(SecureValueKey.sessionToken),
        'session-token-a1',
      );
    },
  );

  test(
    'trusted handshake refreshes stored bridge identity when machine name changes',
    () async {
      final store = InMemorySecureStore();
      await store.writeSecret(SecureValueKey.trustedBridgeIdentity, '''
{
  "bridge_id": "bridge-a1",
  "bridge_name": "Vibe bridge",
  "bridge_api_base_url": "https://bridge.ts.net",
  "session_id": "session-1",
  "paired_at_epoch_seconds": 100
}
''');
      await store.writeSecret(SecureValueKey.sessionToken, 'session-token-a1');
      await store.writeSecret(SecureValueKey.pairingPrivateKey, 'phone-a1');

      final controller = PairingController(
        secureStore: store,
        bridgeApi: const FakePairingBridgeApi(
          bridgeName: 'Operator Workstation',
          bridgeApiBaseUrl: 'https://mac.taild54ede.ts.net',
          handshakeResult: PairingHandshakeResult.trusted(
            bridgeId: 'bridge-a1',
            bridgeName: 'Operator Workstation',
            bridgeApiBaseUrl: 'https://mac.taild54ede.ts.net',
            sessionId: 'session-1',
          ),
        ),
        phoneDisplayName: 'Test Phone',
        nowUtc: () => DateTime.utc(2026, 3, 19, 9, 0),
      );
      addTearDown(controller.dispose);

      await _flushAsync();

      expect(controller.state.step, PairingStep.paired);
      expect(
        controller.state.trustedBridge?.bridgeName,
        'Operator Workstation',
      );
      expect(
        controller.state.trustedBridge?.bridgeApiBaseUrl,
        'https://mac.taild54ede.ts.net',
      );

      final storedTrust = await store.readSecret(
        SecureValueKey.trustedBridgeIdentity,
      );
      final decodedTrust = jsonDecode(storedTrust!) as Map<String, dynamic>;
      expect(decodedTrust['bridge_name'], 'Operator Workstation');
      expect(
        decodedTrust['bridge_api_base_url'],
        'https://mac.taild54ede.ts.net',
      );
    },
  );
}

String _compactPayload() {
  return '''
{
  "v": "2026-03-17",
  "b": "bridge-a1",
  "u": "https://bridge.ts.net",
  "r": [
    "https://bridge.ts.net"
  ],
  "s": "session-1",
  "t": "ptk-abc",
  "i": 1773910800,
  "e": 1773911100
}
''';
}

class FakePairingBridgeApi implements PairingBridgeApi {
  const FakePairingBridgeApi({
    required this.bridgeName,
    required this.bridgeApiBaseUrl,
    this.handshakeResult = const PairingHandshakeResult.trusted(
      bridgeId: 'bridge-a1',
      bridgeName: 'Operator Workstation',
      bridgeApiBaseUrl: 'https://mac.taild54ede.ts.net',
      sessionId: 'session-1',
    ),
  });

  final String bridgeName;
  final String bridgeApiBaseUrl;
  final PairingHandshakeResult handshakeResult;

  @override
  Future<PairingFinalizeResult> finalizeTrust({
    required PairingQrPayload payload,
    required String phoneId,
    required String phoneName,
  }) async {
    return PairingFinalizeResult.success(
      sessionToken: 'session-token-a1',
      bridgeId: payload.bridgeId,
      bridgeName: bridgeName,
      bridgeApiBaseUrl: bridgeApiBaseUrl,
      bridgeApiRoutes: payload.bridgeApiRoutes,
    );
  }

  @override
  Future<PairingHandshakeResult> handshake({
    required TrustedBridgeIdentity trustedBridge,
    required String phoneId,
    required String sessionToken,
  }) async {
    return handshakeResult;
  }

  @override
  Future<PairingRevokeResult> revokeTrust({
    required TrustedBridgeIdentity trustedBridge,
    required String? phoneId,
  }) async {
    return const PairingRevokeResult.success();
  }
}

Future<void> _flushAsync() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}
