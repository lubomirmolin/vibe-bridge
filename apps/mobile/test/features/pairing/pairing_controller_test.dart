import 'dart:convert';

import 'package:codex_mobile_companion/features/pairing/application/pairing_controller.dart';
import 'package:codex_mobile_companion/features/pairing/data/pairing_bridge_api.dart';
import 'package:codex_mobile_companion/features/pairing/domain/pairing_qr_payload.dart';
import 'package:codex_mobile_companion/foundation/storage/secure_store.dart';
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
      expect(
        controller.state.pendingPayload?.bridgeName,
        'Codex Mobile Companion',
      );

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
}

String _compactPayload() {
  return '''
{
  "v": "2026-03-17",
  "b": "bridge-a1",
  "u": "https://bridge.ts.net",
  "s": "session-1",
  "t": "ptk-abc"
}
''';
}

class FakePairingBridgeApi implements PairingBridgeApi {
  const FakePairingBridgeApi({
    required this.bridgeName,
    required this.bridgeApiBaseUrl,
  });

  final String bridgeName;
  final String bridgeApiBaseUrl;

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
    );
  }

  @override
  Future<PairingHandshakeResult> handshake({
    required TrustedBridgeIdentity trustedBridge,
    required String phoneId,
    required String sessionToken,
  }) async {
    return const PairingHandshakeResult.trusted();
  }

  @override
  Future<PairingRevokeResult> revokeTrust({
    required TrustedBridgeIdentity trustedBridge,
    required String? phoneId,
  }) async {
    return const PairingRevokeResult.success();
  }
}
