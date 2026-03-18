import 'dart:async';

import 'package:codex_mobile_companion/features/approvals/data/approval_bridge_api.dart';
import 'package:codex_mobile_companion/features/pairing/application/pairing_controller.dart';
import 'package:codex_mobile_companion/features/pairing/data/pairing_bridge_api.dart';
import 'package:codex_mobile_companion/features/pairing/domain/pairing_qr_payload.dart';
import 'package:codex_mobile_companion/features/settings/data/settings_bridge_api.dart';
import 'package:codex_mobile_companion/features/threads/data/thread_list_bridge_api.dart';
import 'package:codex_mobile_companion/features/threads/data/thread_live_stream.dart';
import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:codex_mobile_companion/foundation/storage/secure_store.dart';
import 'package:codex_mobile_companion/foundation/storage/secure_store_provider.dart';
import 'package:codex_mobile_companion/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'runtime notifications surface globally while user is off thread routes',
    (tester) async {
      final secureStore = InMemorySecureStore();
      await secureStore.writeSecret(SecureValueKey.trustedBridgeIdentity, '''
{
  "bridge_id": "bridge-a1",
  "bridge_name": "Codex Mobile Companion",
  "bridge_api_base_url": "https://bridge.ts.net",
  "session_id": "session-abc",
  "paired_at_epoch_seconds": 100
}
''');
      await secureStore.writeSecret(SecureValueKey.sessionToken, 'token-a1');
      await secureStore.writeSecret(
        SecureValueKey.pairingPrivateKey,
        'phone-a1',
      );

      final liveStream = FakeThreadLiveStream();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appSecureStoreProvider.overrideWithValue(secureStore),
            pairingBridgeApiProvider.overrideWithValue(FakePairingBridgeApi()),
            settingsBridgeApiProvider.overrideWithValue(
              FakeSettingsBridgeApi(),
            ),
            threadListBridgeApiProvider.overrideWithValue(
              FakeThreadListBridgeApi(),
            ),
            approvalBridgeApiProvider.overrideWithValue(
              FakeApprovalBridgeApi(),
            ),
            threadLiveStreamProvider.overrideWithValue(liveStream),
          ],
          child: const CodexMobileApp(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Threads'), findsOneWidget);

      await tester.tap(
        find.byKey(const Key('open-device-settings-from-threads')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Device settings'), findsOneWidget);

      liveStream.emit(
        BridgeEventEnvelope<Map<String, dynamic>>(
          contractVersion: contractVersion,
          eventId: 'evt-global-1',
          threadId: 'thread-123',
          kind: BridgeEventKind.approvalRequested,
          occurredAt: '2026-03-18T12:00:00Z',
          payload: {'reason': 'Approval required for protected push.'},
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(
        find.textContaining(
          'Approval requested: Approval required for protected push.',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'approval notification toggle suppresses then re-enables runtime delivery from settings',
    (tester) async {
      final secureStore = InMemorySecureStore();
      await secureStore.writeSecret(SecureValueKey.trustedBridgeIdentity, '''
{
  "bridge_id": "bridge-a1",
  "bridge_name": "Codex Mobile Companion",
  "bridge_api_base_url": "https://bridge.ts.net",
  "session_id": "session-abc",
  "paired_at_epoch_seconds": 100
}
''');
      await secureStore.writeSecret(SecureValueKey.sessionToken, 'token-a1');
      await secureStore.writeSecret(
        SecureValueKey.pairingPrivateKey,
        'phone-a1',
      );

      final liveStream = FakeThreadLiveStream();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appSecureStoreProvider.overrideWithValue(secureStore),
            pairingBridgeApiProvider.overrideWithValue(FakePairingBridgeApi()),
            settingsBridgeApiProvider.overrideWithValue(
              FakeSettingsBridgeApi(),
            ),
            threadListBridgeApiProvider.overrideWithValue(
              FakeThreadListBridgeApi(),
            ),
            approvalBridgeApiProvider.overrideWithValue(
              FakeApprovalBridgeApi(),
            ),
            threadLiveStreamProvider.overrideWithValue(liveStream),
          ],
          child: const CodexMobileApp(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('open-device-settings-from-threads')),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('approval-notification-toggle')));
      await tester.pumpAndSettle();

      liveStream.emit(
        BridgeEventEnvelope<Map<String, dynamic>>(
          contractVersion: contractVersion,
          eventId: 'evt-global-suppressed',
          threadId: 'thread-123',
          kind: BridgeEventKind.approvalRequested,
          occurredAt: '2026-03-18T12:01:00Z',
          payload: {'reason': 'Suppressed while notifications are disabled.'},
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(
        find.textContaining(
          'Approval requested: Suppressed while notifications are disabled.',
        ),
        findsNothing,
      );

      await tester.tap(find.byKey(const Key('approval-notification-toggle')));
      await tester.pumpAndSettle();

      liveStream.emit(
        BridgeEventEnvelope<Map<String, dynamic>>(
          contractVersion: contractVersion,
          eventId: 'evt-global-delivered',
          threadId: 'thread-123',
          kind: BridgeEventKind.approvalRequested,
          occurredAt: '2026-03-18T12:02:00Z',
          payload: {'reason': 'Delivered after re-enable.'},
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(
        find.textContaining('Approval requested: Delivered after re-enable.'),
        findsOneWidget,
      );
    },
  );
}

class FakePairingBridgeApi implements PairingBridgeApi {
  @override
  Future<PairingFinalizeResult> finalizeTrust({
    required PairingQrPayload payload,
    required String phoneId,
    required String phoneName,
  }) async {
    return const PairingFinalizeResult.success(sessionToken: 'token-a1');
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

class FakeSettingsBridgeApi implements SettingsBridgeApi {
  @override
  Future<AccessMode> fetchAccessMode({required String bridgeApiBaseUrl}) async {
    return AccessMode.controlWithApprovals;
  }

  @override
  Future<List<SecurityEventRecordDto>> fetchSecurityEvents({
    required String bridgeApiBaseUrl,
  }) async {
    return const <SecurityEventRecordDto>[];
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

class FakeThreadLiveStream implements ThreadLiveStream {
  final List<StreamController<BridgeEventEnvelope<Map<String, dynamic>>>>
  _controllers =
      <StreamController<BridgeEventEnvelope<Map<String, dynamic>>>>[];

  @override
  Future<ThreadLiveSubscription> subscribe({
    required String bridgeApiBaseUrl,
    String? threadId,
  }) async {
    final controller =
        StreamController<BridgeEventEnvelope<Map<String, dynamic>>>();
    _controllers.add(controller);

    return ThreadLiveSubscription(
      events: controller.stream,
      close: () async {
        _controllers.remove(controller);
        if (!controller.isClosed) {
          await controller.close();
        }
      },
    );
  }

  void emit(BridgeEventEnvelope<Map<String, dynamic>> event) {
    for (final controller
        in List<
          StreamController<BridgeEventEnvelope<Map<String, dynamic>>>
        >.from(_controllers)) {
      if (!controller.isClosed) {
        controller.add(event);
      }
    }
  }
}

class FakeThreadListBridgeApi implements ThreadListBridgeApi {
  @override
  Future<List<ThreadSummaryDto>> fetchThreads({
    required String bridgeApiBaseUrl,
  }) async {
    return const [
      ThreadSummaryDto(
        contractVersion: contractVersion,
        threadId: 'thread-123',
        title: 'Thread thread-123',
        status: ThreadStatus.running,
        workspace: '/workspace/codex-mobile-companion',
        repository: 'codex-mobile-companion',
        branch: 'master',
        updatedAt: '2026-03-18T12:00:00Z',
      ),
    ];
  }
}

class FakeApprovalBridgeApi implements ApprovalBridgeApi {
  @override
  Future<AccessMode> fetchAccessMode({required String bridgeApiBaseUrl}) async {
    return AccessMode.controlWithApprovals;
  }

  @override
  Future<List<ApprovalRecordDto>> fetchApprovals({
    required String bridgeApiBaseUrl,
  }) async {
    return const <ApprovalRecordDto>[];
  }

  @override
  Future<ApprovalResolutionResponseDto> approve({
    required String bridgeApiBaseUrl,
    required String approvalId,
  }) async {
    throw const ApprovalResolutionBridgeException(
      message: 'Approve is not used in this test.',
    );
  }

  @override
  Future<ApprovalResolutionResponseDto> reject({
    required String bridgeApiBaseUrl,
    required String approvalId,
  }) async {
    throw const ApprovalResolutionBridgeException(
      message: 'Reject is not used in this test.',
    );
  }
}
