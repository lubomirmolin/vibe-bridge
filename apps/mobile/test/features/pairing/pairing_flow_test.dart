import 'package:codex_mobile_companion/features/pairing/application/pairing_controller.dart';
import 'package:codex_mobile_companion/features/pairing/data/pairing_bridge_api.dart';
import 'package:codex_mobile_companion/features/pairing/domain/pairing_qr_payload.dart';
import 'package:codex_mobile_companion/features/pairing/presentation/pairing_flow_page.dart';
import 'package:codex_mobile_companion/foundation/storage/secure_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'valid scan is reviewed and requires explicit trust confirmation',
    (tester) async {
      final store = InMemorySecureStore();
      final bridgeApi = FakePairingBridgeApi();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            secureStoreProvider.overrideWithValue(store),
            pairingBridgeApiProvider.overrideWithValue(bridgeApi),
            nowUtcProvider.overrideWithValue(DateTime.utc(2026, 3, 17, 21, 0)),
          ],
          child: const MaterialApp(
            home: PairingFlowPage(enableCameraPreview: false),
          ),
        ),
      );

      await tester.tap(find.text('Scan pairing QR'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('manual-payload-input')),
        _validPayloadJson(),
      );
      await tester.tap(find.text('Submit scanned payload'));
      await tester.pumpAndSettle();

      expect(find.text('Confirm bridge trust'), findsOneWidget);
      expect(
        await store.readSecret(SecureValueKey.trustedBridgeIdentity),
        isNull,
      );

      await tester.tap(find.text('Confirm trust'));
      await tester.pumpAndSettle();

      expect(find.text('Paired with Codex Mobile Companion'), findsOneWidget);
      expect(
        await store.readSecret(SecureValueKey.trustedBridgeIdentity),
        isNotNull,
      );
      expect(
        await store.readSecret(SecureValueKey.sessionToken),
        'bridge-session-token',
      );
    },
  );

  testWidgets('invalid scan shows clear rescan feedback', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          pairingBridgeApiProvider.overrideWithValue(FakePairingBridgeApi()),
          nowUtcProvider.overrideWithValue(DateTime.utc(2026, 3, 17, 21, 0)),
        ],
        child: const MaterialApp(
          home: PairingFlowPage(enableCameraPreview: false),
        ),
      ),
    );

    await tester.tap(find.text('Scan pairing QR'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('manual-payload-input')),
      '{"broken":',
    );
    await tester.tap(find.text('Submit scanned payload'));
    await tester.pumpAndSettle();

    expect(
      find.text('This QR code is invalid. Please rescan from your Mac.'),
      findsOneWidget,
    );
    expect(find.text('Pair your phone to this Mac'), findsNothing);
  });

  testWidgets(
    'permission denied scanner state shows recovery guidance and manual fallback path',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            pairingBridgeApiProvider.overrideWithValue(FakePairingBridgeApi()),
            nowUtcProvider.overrideWithValue(DateTime.utc(2026, 3, 17, 21, 0)),
          ],
          child: const MaterialApp(
            home: PairingFlowPage(
              enableCameraPreview: false,
              initialScannerIssue: PairingScannerIssue.permissionDenied(),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Scan pairing QR'));
      await tester.pumpAndSettle();

      expect(find.text('Camera permission is blocked'), findsOneWidget);
      expect(
        find.text(
          'Enable camera access in system Settings, then retry scanning. You can still pair by pasting the QR payload below.',
        ),
        findsOneWidget,
      );
      expect(find.text('Retry camera'), findsOneWidget);
      expect(find.byKey(const Key('manual-payload-input')), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('manual-payload-input')),
        _validPayloadJson(sessionId: 'permission-denied-manual-fallback'),
      );
      await tester.ensureVisible(find.text('Submit scanned payload'));
      await tester.tap(find.text('Submit scanned payload'));
      await tester.pumpAndSettle();

      expect(find.text('Confirm bridge trust'), findsOneWidget);
    },
  );

  testWidgets(
    'scanner failure state surfaces retry guidance and failure details',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            pairingBridgeApiProvider.overrideWithValue(FakePairingBridgeApi()),
            nowUtcProvider.overrideWithValue(DateTime.utc(2026, 3, 17, 21, 0)),
          ],
          child: const MaterialApp(
            home: PairingFlowPage(
              enableCameraPreview: false,
              initialScannerIssue: PairingScannerIssue.failure(
                details: 'Camera stream failed to initialize.',
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Scan pairing QR'));
      await tester.pumpAndSettle();

      expect(find.text('Scanner is unavailable right now'), findsOneWidget);
      expect(
        find.text(
          'We could not read from the camera. Retry scanning or continue with the manual payload fallback.',
        ),
        findsOneWidget,
      );
      expect(find.text('Camera stream failed to initialize.'), findsOneWidget);
      expect(find.text('Retry camera'), findsOneWidget);
      expect(find.byKey(const Key('manual-payload-input')), findsOneWidget);
    },
  );

  testWidgets('cancel from confirmation leaves app in clean unpaired state', (
    tester,
  ) async {
    final store = InMemorySecureStore();
    final bridgeApi = FakePairingBridgeApi();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          secureStoreProvider.overrideWithValue(store),
          pairingBridgeApiProvider.overrideWithValue(bridgeApi),
          nowUtcProvider.overrideWithValue(DateTime.utc(2026, 3, 17, 21, 0)),
        ],
        child: const MaterialApp(
          home: PairingFlowPage(enableCameraPreview: false),
        ),
      ),
    );

    await tester.tap(find.text('Scan pairing QR'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('manual-payload-input')),
      _validPayloadJson(),
    );
    await tester.tap(find.text('Submit scanned payload'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.text('Pair your phone to this Mac'), findsOneWidget);
    expect(
      await store.readSecret(SecureValueKey.trustedBridgeIdentity),
      isNull,
    );
  });

  testWidgets('reused payload is rejected after successful confirmation', (
    tester,
  ) async {
    final bridgeApi = FakePairingBridgeApi();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          pairingBridgeApiProvider.overrideWithValue(bridgeApi),
          nowUtcProvider.overrideWithValue(DateTime.utc(2026, 3, 17, 21, 0)),
        ],
        child: const MaterialApp(
          home: PairingFlowPage(enableCameraPreview: false),
        ),
      ),
    );

    await tester.tap(find.text('Scan pairing QR'));
    await tester.pumpAndSettle();

    final payload = _validPayloadJson(sessionId: 'session-reuse');
    await tester.enterText(
      find.byKey(const Key('manual-payload-input')),
      payload,
    );
    await tester.tap(find.text('Submit scanned payload'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Confirm trust'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Scan another QR'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('manual-payload-input')),
      payload,
    );
    await tester.tap(find.text('Submit scanned payload'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'This pairing QR code was already used. Please rescan from your Mac.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('same phone cannot silently trust a second Mac without reset', (
    tester,
  ) async {
    final bridgeApi = FakePairingBridgeApi();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          pairingBridgeApiProvider.overrideWithValue(bridgeApi),
          nowUtcProvider.overrideWithValue(DateTime.utc(2026, 3, 17, 21, 0)),
        ],
        child: const MaterialApp(
          home: PairingFlowPage(enableCameraPreview: false),
        ),
      ),
    );

    await tester.tap(find.text('Scan pairing QR'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('manual-payload-input')),
      _validPayloadJson(bridgeId: 'bridge-a1', sessionId: 'session-first'),
    );
    await tester.tap(find.text('Submit scanned payload'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Confirm trust'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Scan another QR'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('manual-payload-input')),
      _validPayloadJson(bridgeId: 'bridge-b2', sessionId: 'session-second'),
    );
    await tester.tap(find.text('Submit scanned payload'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Confirm trust'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'This phone is already paired with a different Mac. Reset trust before replacing it.',
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'revoked trust on reconnect clears local trust and requires re-pair',
    (tester) async {
      final store = InMemorySecureStore();
      await store.writeSecret(SecureValueKey.trustedBridgeIdentity, '''
{
  "bridge_id": "bridge-a1",
  "bridge_name": "Codex Mobile Companion",
  "bridge_api_base_url": "https://bridge.ts.net",
  "session_id": "session-reconnect",
  "paired_at_epoch_seconds": 100
}
''');
      await store.writeSecret(
        SecureValueKey.sessionToken,
        'revoked-session-token',
      );

      final bridgeApi = FakePairingBridgeApi(
        handshakeResult: const PairingHandshakeResult.untrusted(
          code: 'trust_revoked',
          message:
              'Trust was revoked for this session. Re-pair from the Mac pairing QR.',
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            secureStoreProvider.overrideWithValue(store),
            pairingBridgeApiProvider.overrideWithValue(bridgeApi),
            nowUtcProvider.overrideWithValue(DateTime.utc(2026, 3, 17, 21, 0)),
          ],
          child: const MaterialApp(
            home: PairingFlowPage(enableCameraPreview: false),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Pair your phone to this Mac'), findsOneWidget);
      expect(
        find.text(
          'Trust was revoked for this session. Re-pair from the Mac pairing QR.',
        ),
        findsOneWidget,
      );
      expect(
        await store.readSecret(SecureValueKey.trustedBridgeIdentity),
        isNull,
      );
      expect(await store.readSecret(SecureValueKey.sessionToken), isNull);
    },
  );

  testWidgets(
    'unreachable trusted bridge path on reconnect fails closed and clears local trust',
    (tester) async {
      final store = InMemorySecureStore();
      await store.writeSecret(SecureValueKey.trustedBridgeIdentity, '''
{
  "bridge_id": "bridge-a1",
  "bridge_name": "Codex Mobile Companion",
  "bridge_api_base_url": "https://bridge.ts.net",
  "session_id": "session-reconnect",
  "paired_at_epoch_seconds": 100
}
''');
      await store.writeSecret(
        SecureValueKey.sessionToken,
        'active-session-token',
      );

      final bridgeApi = FakePairingBridgeApi(
        handshakeResult: const PairingHandshakeResult.connectivityUnavailable(
          message:
              'Private bridge path is currently unreachable. Reconnect to Tailscale and retry.',
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            secureStoreProvider.overrideWithValue(store),
            pairingBridgeApiProvider.overrideWithValue(bridgeApi),
            nowUtcProvider.overrideWithValue(DateTime.utc(2026, 3, 17, 21, 0)),
          ],
          child: const MaterialApp(
            home: PairingFlowPage(enableCameraPreview: false),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Pair your phone to this Mac'), findsOneWidget);
      expect(
        find.text(
          'Private bridge path is currently unreachable. Reconnect to Tailscale and retry.',
        ),
        findsOneWidget,
      );
      expect(
        await store.readSecret(SecureValueKey.trustedBridgeIdentity),
        isNull,
      );
      expect(await store.readSecret(SecureValueKey.sessionToken), isNull);
    },
  );
}

String _validPayloadJson({
  String bridgeId = 'bridge-a1',
  String sessionId = 'session-1',
}) {
  return '''
{
  "contract_version": "2026-03-17",
  "bridge_id": "$bridgeId",
  "bridge_name": "Codex Mobile Companion",
  "bridge_api_base_url": "https://bridge.ts.net",
  "session_id": "$sessionId",
  "pairing_token": "ptk-abc",
  "issued_at_epoch_seconds": 170,
  "expires_at_epoch_seconds": 10000000000
}
''';
}

class FakePairingBridgeApi implements PairingBridgeApi {
  FakePairingBridgeApi({
    this.handshakeResult = const PairingHandshakeResult.trusted(),
  });

  final PairingHandshakeResult handshakeResult;
  final Set<String> _consumedSessions = <String>{};

  @override
  Future<PairingFinalizeResult> finalizeTrust({
    required PairingQrPayload payload,
    required String phoneId,
    required String phoneName,
  }) async {
    if (_consumedSessions.contains(payload.sessionId)) {
      return const PairingFinalizeResult.failure(
        code: 'session_already_consumed',
        message:
            'Pairing session was already consumed. Please rescan from your Mac.',
      );
    }

    _consumedSessions.add(payload.sessionId);
    return const PairingFinalizeResult.success(
      sessionToken: 'bridge-session-token',
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
}
