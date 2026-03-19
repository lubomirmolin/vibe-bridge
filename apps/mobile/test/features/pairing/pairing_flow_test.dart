import 'package:codex_mobile_companion/features/pairing/application/pairing_controller.dart';
import 'package:codex_mobile_companion/features/pairing/data/pairing_bridge_api.dart';
import 'package:codex_mobile_companion/features/pairing/domain/pairing_qr_payload.dart';
import 'package:codex_mobile_companion/features/pairing/presentation/pairing_flow_page.dart';
import 'package:codex_mobile_companion/features/settings/data/settings_bridge_api.dart';
import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:codex_mobile_companion/foundation/storage/secure_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

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
      expect(find.text('Re-pair required for security'), findsOneWidget);
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
    'bridge identity mismatch on reconnect clears local trust and requires re-pair',
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
        'mismatched-session-token',
      );

      final bridgeApi = FakePairingBridgeApi(
        handshakeResult: const PairingHandshakeResult.untrusted(
          code: 'bridge_identity_mismatch',
          message:
              'Stored bridge identity did not match the active bridge. Re-pair is required.',
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
      expect(find.text('Re-pair required for security'), findsOneWidget);
      expect(
        find.text(
          'Stored bridge identity did not match the active bridge. Re-pair is required.',
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
    'unreachable trusted bridge path on reconnect preserves trust with explicit disconnected state',
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

      expect(find.text('Paired with Codex Mobile Companion'), findsOneWidget);
      expect(find.text('Bridge disconnected'), findsOneWidget);
      expect(
        find.text(
          'Private bridge path is currently unreachable. Reconnect to Tailscale and retry.',
        ),
        findsOneWidget,
      );
      expect(
        await store.readSecret(SecureValueKey.trustedBridgeIdentity),
        isNotNull,
      );
      expect(await store.readSecret(SecureValueKey.sessionToken), isNotNull);
    },
  );

  testWidgets(
    'disconnected trusted bridge reconnects automatically without manual retry',
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
        handshakeScript: const [
          PairingHandshakeResult.connectivityUnavailable(
            message:
                'Private bridge path is currently unreachable. Reconnect to Tailscale and retry.',
          ),
          PairingHandshakeResult.trusted(),
        ],
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

      expect(find.text('Bridge disconnected'), findsOneWidget);
      expect(
        find.text(
          'Private bridge path is currently unreachable. Reconnect to Tailscale and retry.',
        ),
        findsOneWidget,
      );

      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();

      expect(find.text('Paired with Codex Mobile Companion'), findsOneWidget);
      expect(find.text('Bridge disconnected'), findsNothing);
      expect(bridgeApi.handshakeCalls, greaterThanOrEqualTo(2));
    },
  );

  testWidgets(
    'disconnected trusted bridge keeps retrying automatically across repeated failures',
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
        handshakeScript: const [
          PairingHandshakeResult.connectivityUnavailable(
            message:
                'Private bridge path is currently unreachable. Reconnect to Tailscale and retry.',
          ),
          PairingHandshakeResult.connectivityUnavailable(
            message:
                'Private bridge path is currently unreachable. Reconnect to Tailscale and retry.',
          ),
          PairingHandshakeResult.trusted(),
        ],
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

      expect(find.text('Bridge disconnected'), findsOneWidget);
      expect(bridgeApi.handshakeCalls, 1);

      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();

      expect(find.text('Bridge disconnected'), findsOneWidget);
      expect(bridgeApi.handshakeCalls, greaterThanOrEqualTo(2));

      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();

      expect(find.text('Paired with Codex Mobile Companion'), findsOneWidget);
      expect(find.text('Bridge disconnected'), findsNothing);
      expect(bridgeApi.handshakeCalls, greaterThanOrEqualTo(3));
    },
  );

  testWidgets(
    'unpairing from settings clears local trust and returns to unpaired UI',
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
      await store.writeSecret(
        SecureValueKey.pairingPrivateKey,
        'phone-test-id',
      );

      final bridgeApi = FakePairingBridgeApi();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            secureStoreProvider.overrideWithValue(store),
            pairingBridgeApiProvider.overrideWithValue(bridgeApi),
            settingsBridgeApiProvider.overrideWithValue(
              FakeSettingsBridgeApi(),
            ),
            nowUtcProvider.overrideWithValue(DateTime.utc(2026, 3, 17, 21, 0)),
          ],
          child: const MaterialApp(
            home: PairingFlowPage(enableCameraPreview: false),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Paired with Codex Mobile Companion'), findsOneWidget);

      await tester.tap(find.byKey(const Key('open-device-settings')));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.byKey(const Key('unpair-device-button')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('unpair-device-button')));
      await tester.pumpAndSettle();

      expect(find.text('Pair your phone to this Mac'), findsOneWidget);
      expect(
        await store.readSecret(SecureValueKey.trustedBridgeIdentity),
        isNull,
      );
      expect(await store.readSecret(SecureValueKey.sessionToken), isNull);
      expect(bridgeApi.revokeTrustCalls, 1);
    },
  );
}

String _validPayloadJson({
  String bridgeId = 'bridge-a1',
  String sessionId = 'session-1',
}) {
  return '''
{
  "v": "2026-03-17",
  "b": "$bridgeId",
  "u": "https://bridge.ts.net",
  "s": "$sessionId",
  "t": "ptk-abc"
}
''';
}

class FakePairingBridgeApi implements PairingBridgeApi {
  FakePairingBridgeApi({
    this.handshakeResult = const PairingHandshakeResult.trusted(),
    List<PairingHandshakeResult>? handshakeScript,
    this.revokeResult = const PairingRevokeResult.success(),
  }) : _handshakeScript = handshakeScript;

  final PairingHandshakeResult handshakeResult;
  final List<PairingHandshakeResult>? _handshakeScript;
  final PairingRevokeResult revokeResult;
  final Set<String> _consumedSessions = <String>{};
  int revokeTrustCalls = 0;
  int handshakeCalls = 0;

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
    return PairingFinalizeResult.success(
      sessionToken: 'bridge-session-token',
      bridgeId: payload.bridgeId,
      bridgeName: payload.bridgeName,
      bridgeApiBaseUrl: payload.bridgeApiBaseUrl,
    );
  }

  @override
  Future<PairingHandshakeResult> handshake({
    required TrustedBridgeIdentity trustedBridge,
    required String phoneId,
    required String sessionToken,
  }) async {
    handshakeCalls += 1;

    final handshakeScript = _handshakeScript;
    if (handshakeScript != null && handshakeScript.isNotEmpty) {
      final scriptIndex = handshakeCalls - 1;
      if (scriptIndex < handshakeScript.length) {
        return handshakeScript[scriptIndex];
      }
      return handshakeScript.last;
    }

    return handshakeResult;
  }

  @override
  Future<PairingRevokeResult> revokeTrust({
    required TrustedBridgeIdentity trustedBridge,
    required String? phoneId,
  }) async {
    revokeTrustCalls += 1;
    return revokeResult;
  }
}

class FakeSettingsBridgeApi implements SettingsBridgeApi {
  FakeSettingsBridgeApi({
    this.accessMode = AccessMode.fullControl,
    this.events = const <SecurityEventRecordDto>[],
  });

  final AccessMode accessMode;
  final List<SecurityEventRecordDto> events;

  @override
  Future<AccessMode> fetchAccessMode({required String bridgeApiBaseUrl}) async {
    return accessMode;
  }

  @override
  Future<List<SecurityEventRecordDto>> fetchSecurityEvents({
    required String bridgeApiBaseUrl,
  }) async {
    return events;
  }

  @override
  Future<AccessMode> setAccessMode({
    required String bridgeApiBaseUrl,
    required AccessMode accessMode,
    required String phoneId,
    required String bridgeId,
    required String sessionToken,
    String actor = 'mobile-device',
  }) async {
    return accessMode;
  }
}
