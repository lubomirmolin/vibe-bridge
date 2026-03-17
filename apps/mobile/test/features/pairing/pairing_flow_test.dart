import 'package:codex_mobile_companion/features/pairing/application/pairing_controller.dart';
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

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            secureStoreProvider.overrideWithValue(store),
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
    },
  );

  testWidgets('invalid scan shows clear rescan feedback', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
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

  testWidgets('cancel from confirmation leaves app in clean unpaired state', (
    tester,
  ) async {
    final store = InMemorySecureStore();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          secureStoreProvider.overrideWithValue(store),
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
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
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
}

String _validPayloadJson({String sessionId = 'session-1'}) {
  return '''
{
  "contract_version": "2026-03-17",
  "bridge_id": "bridge-a1",
  "bridge_name": "Codex Mobile Companion",
  "bridge_api_base_url": "https://bridge.ts.net",
  "session_id": "$sessionId",
  "pairing_token": "ptk-abc",
  "issued_at_epoch_seconds": 170,
  "expires_at_epoch_seconds": 10000000000
}
''';
}
