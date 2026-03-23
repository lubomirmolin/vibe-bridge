import 'package:codex_mobile_companion/features/pairing/application/pairing_controller.dart';
import 'package:codex_mobile_companion/features/pairing/data/pairing_bridge_api.dart';
import 'package:codex_mobile_companion/features/pairing/domain/pairing_qr_payload.dart';
import 'package:codex_mobile_companion/features/settings/data/settings_bridge_api.dart';
import 'package:codex_mobile_companion/features/settings/presentation/settings_page.dart';
import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:codex_mobile_companion/foundation/storage/secure_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'settings shows paired bridge info, access mode, desktop integration, and security events',
    (tester) async {
      final store = InMemorySecureStore();
      await store.writeSecret(SecureValueKey.trustedBridgeIdentity, '''
{
  "bridge_id": "bridge-a1",
  "bridge_name": "Codex Mobile Companion",
  "bridge_api_base_url": "https://bridge.ts.net",
  "session_id": "session-abc",
  "paired_at_epoch_seconds": 100
}
''');
      await store.writeSecret(SecureValueKey.sessionToken, 'session-token');
      await store.writeSecret(SecureValueKey.pairingPrivateKey, 'phone-a1');

      final settingsApi = FakeSettingsBridgeApi(
        accessMode: AccessMode.controlWithApprovals,
        events: [
          SecurityEventRecordDto(
            severity: 'info',
            category: 'policy',
            event: BridgeEventEnvelope<Map<String, dynamic>>(
              contractVersion: contractVersion,
              eventId: 'evt-security-1',
              threadId: 'security',
              kind: BridgeEventKind.securityAudit,
              occurredAt: '2026-03-18T10:10:00Z',
              payload: {
                'actor': 'mobile-settings',
                'action': 'set_access_mode',
                'target': 'policy.access_mode',
                'outcome': 'allowed',
                'reason': 'mode=control_with_approvals',
              },
            ),
          ),
        ],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            secureStoreProvider.overrideWithValue(store),
            pairingBridgeApiProvider.overrideWithValue(FakePairingBridgeApi()),
            settingsBridgeApiProvider.overrideWithValue(settingsApi),
          ],
          child: const MaterialApp(
            home: SettingsPage(bridgeApiBaseUrl: 'https://bridge.ts.net'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Paired Bridge'), findsOneWidget);
      expect(find.text('Codex Mobile Companion'), findsAtLeastNWidgets(1));
      expect(find.textContaining('Session: session-abc'), findsOneWidget);
      expect(
        find.byKey(const Key('desktop-integration-toggle')),
        findsOneWidget,
      );

      await tester.scrollUntilVisible(
        find.text('Actor: mobile-settings'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      expect(find.text('Actor: mobile-settings'), findsOneWidget);
      expect(find.text('Target: policy.access_mode'), findsOneWidget);
      expect(find.text('set_access_mode • allowed'), findsOneWidget);
    },
  );

  testWidgets('security events render newest-first before truncation', (
    tester,
  ) async {
    final store = InMemorySecureStore();
    await store.writeSecret(SecureValueKey.trustedBridgeIdentity, '''
{
  "bridge_id": "bridge-a1",
  "bridge_name": "Codex Mobile Companion",
  "bridge_api_base_url": "https://bridge.ts.net",
  "session_id": "session-abc",
  "paired_at_epoch_seconds": 100
}
''');
    await store.writeSecret(SecureValueKey.sessionToken, 'session-token');
    await store.writeSecret(SecureValueKey.pairingPrivateKey, 'phone-a1');

    final events = List<SecurityEventRecordDto>.generate(10, (index) {
      final itemNumber = index + 1;
      return SecurityEventRecordDto(
        severity: 'info',
        category: 'policy',
        event: BridgeEventEnvelope<Map<String, dynamic>>(
          contractVersion: contractVersion,
          eventId: 'evt-security-$itemNumber',
          threadId: 'security',
          kind: BridgeEventKind.securityAudit,
          occurredAt:
              '2026-03-18T10:${itemNumber.toString().padLeft(2, '0')}:00Z',
          payload: {
            'actor': 'mobile-settings-$itemNumber',
            'action': 'set_access_mode',
            'target': 'policy.access_mode.$itemNumber',
            'outcome': 'allowed',
            'reason': 'mode=control_with_approvals',
          },
        ),
      );
    });

    final settingsApi = FakeSettingsBridgeApi(
      accessMode: AccessMode.controlWithApprovals,
      events: events,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          secureStoreProvider.overrideWithValue(store),
          pairingBridgeApiProvider.overrideWithValue(FakePairingBridgeApi()),
          settingsBridgeApiProvider.overrideWithValue(settingsApi),
        ],
        child: const MaterialApp(
          home: SettingsPage(bridgeApiBaseUrl: 'https://bridge.ts.net'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('Actor: mobile-settings-10'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    expect(find.text('Actor: mobile-settings-10'), findsOneWidget);
    expect(find.text('Actor: mobile-settings-9'), findsOneWidget);
    expect(find.text('Actor: mobile-settings-3'), findsOneWidget);
    expect(find.text('Actor: mobile-settings-2'), findsNothing);
    expect(find.text('Actor: mobile-settings-1'), findsNothing);
  });

  testWidgets('settings access mode switch updates bridge policy', (
    tester,
  ) async {
    final store = InMemorySecureStore();
    await store.writeSecret(SecureValueKey.trustedBridgeIdentity, '''
{
  "bridge_id": "bridge-a1",
  "bridge_name": "Codex Mobile Companion",
  "bridge_api_base_url": "https://bridge.ts.net",
  "session_id": "session-abc",
  "paired_at_epoch_seconds": 100
}
''');
    await store.writeSecret(SecureValueKey.sessionToken, 'session-token');
    await store.writeSecret(SecureValueKey.pairingPrivateKey, 'phone-a1');

    final settingsApi = FakeSettingsBridgeApi(
      accessMode: AccessMode.fullControl,
      events: const <SecurityEventRecordDto>[],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          secureStoreProvider.overrideWithValue(store),
          pairingBridgeApiProvider.overrideWithValue(FakePairingBridgeApi()),
          settingsBridgeApiProvider.overrideWithValue(settingsApi),
        ],
        child: const MaterialApp(
          home: SettingsPage(bridgeApiBaseUrl: 'https://bridge.ts.net'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Read-only'));
    await tester.pumpAndSettle();

    expect(settingsApi.setModeCalls, isNotEmpty);
    expect(settingsApi.setModeCalls.single.accessMode, AccessMode.readOnly);
    expect(settingsApi.setModeCalls.single.phoneId, 'phone-a1');

    await tester.scrollUntilVisible(
      find.byKey(const Key('desktop-integration-toggle')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('desktop-integration-toggle')));
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byKey(const Key('desktop-integration-toggle')),
        matching: find.byWidgetPredicate(
          (widget) => widget is SwitchListTile && widget.value == false,
        ),
      ),
      findsOneWidget,
    );
  });

  testWidgets('desktop integration toggle persists across relaunch', (
    tester,
  ) async {
    final store = InMemorySecureStore();
    await store.writeSecret(SecureValueKey.trustedBridgeIdentity, '''
{
  "bridge_id": "bridge-a1",
  "bridge_name": "Codex Mobile Companion",
  "bridge_api_base_url": "https://bridge.ts.net",
  "session_id": "session-abc",
  "paired_at_epoch_seconds": 100
}
''');
    await store.writeSecret(SecureValueKey.sessionToken, 'session-token');
    await store.writeSecret(SecureValueKey.pairingPrivateKey, 'phone-a1');

    final settingsApi = FakeSettingsBridgeApi(
      accessMode: AccessMode.controlWithApprovals,
      events: const <SecurityEventRecordDto>[],
    );

    Future<void> pumpSettingsPage() async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            secureStoreProvider.overrideWithValue(store),
            pairingBridgeApiProvider.overrideWithValue(FakePairingBridgeApi()),
            settingsBridgeApiProvider.overrideWithValue(settingsApi),
          ],
          child: const MaterialApp(
            home: SettingsPage(bridgeApiBaseUrl: 'https://bridge.ts.net'),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await pumpSettingsPage();

    await tester.scrollUntilVisible(
      find.byKey(const Key('desktop-integration-toggle')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('desktop-integration-toggle')));
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byKey(const Key('desktop-integration-toggle')),
        matching: find.byWidgetPredicate(
          (widget) => widget is SwitchListTile && widget.value == false,
        ),
      ),
      findsOneWidget,
    );

    await pumpSettingsPage();

    await tester.scrollUntilVisible(
      find.byKey(const Key('desktop-integration-toggle')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byKey(const Key('desktop-integration-toggle')),
        matching: find.byWidgetPredicate(
          (widget) => widget is SwitchListTile && widget.value == false,
        ),
      ),
      findsOneWidget,
    );
  });
}

class FakePairingBridgeApi implements PairingBridgeApi {
  @override
  Future<PairingFinalizeResult> finalizeTrust({
    required PairingQrPayload payload,
    required String phoneId,
    required String phoneName,
  }) async {
    return PairingFinalizeResult.success(
      sessionToken: 'token',
      bridgeId: payload.bridgeId,
      bridgeName: payload.bridgeName,
      bridgeApiBaseUrl: payload.bridgeApiBaseUrl,
      bridgeApiRoutes: payload.bridgeApiRoutes,
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

class SetModeCall {
  const SetModeCall({
    required this.accessMode,
    required this.phoneId,
    required this.bridgeId,
    required this.sessionToken,
  });

  final AccessMode accessMode;
  final String phoneId;
  final String bridgeId;
  final String sessionToken;
}

class FakeSettingsBridgeApi implements SettingsBridgeApi {
  FakeSettingsBridgeApi({required this.accessMode, required this.events});

  AccessMode accessMode;
  final List<SecurityEventRecordDto> events;
  final List<SetModeCall> setModeCalls = <SetModeCall>[];

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
    setModeCalls.add(
      SetModeCall(
        accessMode: accessMode,
        phoneId: phoneId,
        bridgeId: bridgeId,
        sessionToken: sessionToken,
      ),
    );
    this.accessMode = accessMode;
    return accessMode;
  }
}
