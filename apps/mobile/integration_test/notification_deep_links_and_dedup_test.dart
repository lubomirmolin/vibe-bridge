import 'dart:async';

import 'package:codex_mobile_companion/features/approvals/data/approval_bridge_api.dart';
import 'package:codex_mobile_companion/features/pairing/application/pairing_controller.dart';
import 'package:codex_mobile_companion/features/pairing/data/pairing_bridge_api.dart';
import 'package:codex_mobile_companion/features/pairing/domain/pairing_qr_payload.dart';
import 'package:codex_mobile_companion/features/settings/data/settings_bridge_api.dart';
import 'package:codex_mobile_companion/features/settings/application/runtime_notification_delivery_controller.dart';
import 'package:codex_mobile_companion/features/threads/data/thread_detail_bridge_api.dart';
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
    'approval notification opens approval detail context from settings',
    (tester) async {
      final secureStore = await _pairedSecureStore();
      final liveStream = FakeThreadLiveStream();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appSecureStoreProvider.overrideWithValue(secureStore),
            pairingBridgeApiProvider.overrideWithValue(FakePairingBridgeApi()),
            settingsBridgeApiProvider.overrideWithValue(FakeSettingsBridgeApi()),
            threadLiveStreamProvider.overrideWithValue(liveStream),
            approvalBridgeApiProvider.overrideWithValue(
              FakeApprovalBridgeApi(
                approvals: [
                  _approvalRecord(
                    approvalId: 'approval-123',
                    threadId: 'thread-123',
                  ),
                ],
              ),
            ),
            threadDetailBridgeApiProvider.overrideWithValue(
              FakeThreadDetailBridgeApi(),
            ),
          ],
          child: const CodexMobileApp(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('open-device-settings')));
      await tester.pumpAndSettle();
      expect(find.text('Device settings'), findsOneWidget);

      liveStream.emit(
        BridgeEventEnvelope<Map<String, dynamic>>(
          contractVersion: contractVersion,
          eventId: 'evt-approval-open-1',
          threadId: 'thread-123',
          kind: BridgeEventKind.approvalRequested,
          occurredAt: '2026-03-18T12:00:00Z',
          payload: {
            'approval_id': 'approval-123',
            'thread_id': 'thread-123',
            'reason': 'Approval required for protected push.',
          },
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.textContaining('Approval requested:'), findsOneWidget);

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(find.text('Approval detail'), findsOneWidget);
      expect(find.byKey(const Key('approval-detail-id')), findsOneWidget);
      expect(find.textContaining('approval-123'), findsOneWidget);
    },
  );

  testWidgets(
    'live activity notification opens the matching thread detail context',
    (tester) async {
      final secureStore = await _pairedSecureStore();
      final liveStream = FakeThreadLiveStream();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appSecureStoreProvider.overrideWithValue(secureStore),
            pairingBridgeApiProvider.overrideWithValue(FakePairingBridgeApi()),
            settingsBridgeApiProvider.overrideWithValue(FakeSettingsBridgeApi()),
            threadLiveStreamProvider.overrideWithValue(liveStream),
            approvalBridgeApiProvider.overrideWithValue(
              FakeApprovalBridgeApi(approvals: const []),
            ),
            threadDetailBridgeApiProvider.overrideWithValue(
              FakeThreadDetailBridgeApi(),
            ),
          ],
          child: const CodexMobileApp(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('open-device-settings')));
      await tester.pumpAndSettle();

      liveStream.emit(
        BridgeEventEnvelope<Map<String, dynamic>>(
          contractVersion: contractVersion,
          eventId: 'evt-live-open-1',
          threadId: 'thread-123',
          kind: BridgeEventKind.messageDelta,
          occurredAt: '2026-03-18T12:01:00Z',
          payload: {'delta': 'Thread output available.'},
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.textContaining('Live activity update:'), findsOneWidget);

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(find.text('Thread detail'), findsOneWidget);
      expect(find.byKey(const Key('thread-detail-thread-id')), findsOneWidget);
      expect(find.text('thread-123'), findsWidgets);
    },
  );

  testWidgets(
    'stale approval notification does not open invalid approval context',
    (tester) async {
      final secureStore = await _pairedSecureStore();
      final liveStream = FakeThreadLiveStream();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appSecureStoreProvider.overrideWithValue(secureStore),
            pairingBridgeApiProvider.overrideWithValue(FakePairingBridgeApi()),
            settingsBridgeApiProvider.overrideWithValue(FakeSettingsBridgeApi()),
            threadLiveStreamProvider.overrideWithValue(liveStream),
            approvalBridgeApiProvider.overrideWithValue(
              FakeApprovalBridgeApi(approvals: const []),
            ),
            threadDetailBridgeApiProvider.overrideWithValue(
              FakeThreadDetailBridgeApi(),
            ),
          ],
          child: const CodexMobileApp(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('open-device-settings')));
      await tester.pumpAndSettle();

      liveStream.emit(
        BridgeEventEnvelope<Map<String, dynamic>>(
          contractVersion: contractVersion,
          eventId: 'evt-approval-stale-1',
          threadId: 'thread-123',
          kind: BridgeEventKind.approvalRequested,
          occurredAt: '2026-03-18T12:02:00Z',
          payload: {
            'approval_id': 'approval-stale',
            'thread_id': 'thread-123',
            'reason': 'This approval was already resolved elsewhere.',
          },
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(find.text('Device settings'), findsOneWidget);
      expect(find.text('Approval detail'), findsNothing);
      expect(find.textContaining('no longer actionable'), findsOneWidget);
    },
  );

  testWidgets(
    'cold-start launch target opens the correct thread context',
    (tester) async {
      final secureStore = await _pairedSecureStore();
      await secureStore.writeSecret(
        SecureValueKey.runtimeNotificationPendingLaunchTarget,
        '{"event_id":"evt-cold-start-thread","target":{"target_type":"thread_detail","thread_id":"thread-cold-start"}}',
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appSecureStoreProvider.overrideWithValue(secureStore),
            pairingBridgeApiProvider.overrideWithValue(FakePairingBridgeApi()),
            settingsBridgeApiProvider.overrideWithValue(FakeSettingsBridgeApi()),
            threadLiveStreamProvider.overrideWithValue(FakeThreadLiveStream()),
            approvalBridgeApiProvider.overrideWithValue(
              FakeApprovalBridgeApi(approvals: const []),
            ),
            threadDetailBridgeApiProvider.overrideWithValue(
              FakeThreadDetailBridgeApi(),
            ),
          ],
          child: const CodexMobileApp(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Thread detail'), findsOneWidget);
      expect(find.text('thread-cold-start'), findsWidgets);
    },
  );

  testWidgets(
    'duplicate notification event IDs are suppressed across reconnect cycles',
    (tester) async {
      final secureStore = await _pairedSecureStore();
      final liveStream = FakeThreadLiveStream();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appSecureStoreProvider.overrideWithValue(secureStore),
            pairingBridgeApiProvider.overrideWithValue(FakePairingBridgeApi()),
            settingsBridgeApiProvider.overrideWithValue(FakeSettingsBridgeApi()),
            threadLiveStreamProvider.overrideWithValue(liveStream),
            approvalBridgeApiProvider.overrideWithValue(
              FakeApprovalBridgeApi(approvals: const []),
            ),
            threadDetailBridgeApiProvider.overrideWithValue(
              FakeThreadDetailBridgeApi(),
            ),
          ],
          child: const CodexMobileApp(),
        ),
      );
      await tester.pumpAndSettle();

      liveStream.emit(
        BridgeEventEnvelope<Map<String, dynamic>>(
          contractVersion: contractVersion,
          eventId: 'evt-dedup-1',
          threadId: 'thread-123',
          kind: BridgeEventKind.messageDelta,
          occurredAt: '2026-03-18T12:03:00Z',
          payload: {'delta': 'First delivery'},
        ),
      );
      liveStream.emit(
        BridgeEventEnvelope<Map<String, dynamic>>(
          contractVersion: contractVersion,
          eventId: 'evt-dedup-1',
          threadId: 'thread-123',
          kind: BridgeEventKind.messageDelta,
          occurredAt: '2026-03-18T12:03:01Z',
          payload: {'delta': 'Duplicate delivery'},
        ),
      );
      await tester.pumpAndSettle();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp).first),
      );
      final runtimeState = container.read(
        runtimeNotificationDeliveryControllerProvider('https://bridge.ts.net'),
      );

      expect(
        runtimeState.recentNotifications
            .where((notification) => notification.eventId == 'evt-dedup-1')
            .length,
        1,
      );
    },
  );
}

Future<InMemorySecureStore> _pairedSecureStore() async {
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
  await secureStore.writeSecret(SecureValueKey.pairingPrivateKey, 'phone-a1');
  return secureStore;
}

ApprovalRecordDto _approvalRecord({
  required String approvalId,
  required String threadId,
}) {
  return ApprovalRecordDto(
    contractVersion: contractVersion,
    approvalId: approvalId,
    threadId: threadId,
    action: 'git_push',
    target: 'origin/main',
    reason: 'full_control_required',
    status: ApprovalStatus.pending,
    requestedAt: '2026-03-18T12:00:00Z',
    resolvedAt: null,
    repository: const RepositoryContextDto(
      workspace: '/workspace/codex-mobile-companion',
      repository: 'codex-mobile-companion',
      branch: 'master',
      remote: 'origin',
    ),
    gitStatus: const GitStatusDto(dirty: false, aheadBy: 0, behindBy: 0),
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
    return AccessMode.fullControl;
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

class FakeApprovalBridgeApi implements ApprovalBridgeApi {
  FakeApprovalBridgeApi({required List<ApprovalRecordDto> approvals})
    : _approvals = approvals;

  final List<ApprovalRecordDto> _approvals;

  @override
  Future<AccessMode> fetchAccessMode({required String bridgeApiBaseUrl}) async {
    return AccessMode.fullControl;
  }

  @override
  Future<List<ApprovalRecordDto>> fetchApprovals({
    required String bridgeApiBaseUrl,
  }) async {
    return List<ApprovalRecordDto>.from(_approvals);
  }

  @override
  Future<ApprovalResolutionResponseDto> approve({
    required String bridgeApiBaseUrl,
    required String approvalId,
  }) async {
    throw const ApprovalResolutionBridgeException(
      message: 'Approve is not used in this integration test.',
    );
  }

  @override
  Future<ApprovalResolutionResponseDto> reject({
    required String bridgeApiBaseUrl,
    required String approvalId,
  }) async {
    throw const ApprovalResolutionBridgeException(
      message: 'Reject is not used in this integration test.',
    );
  }
}

class FakeThreadDetailBridgeApi implements ThreadDetailBridgeApi {
  @override
  Future<ThreadDetailDto> fetchThreadDetail({
    required String bridgeApiBaseUrl,
    required String threadId,
  }) async {
    return ThreadDetailDto(
      contractVersion: contractVersion,
      threadId: threadId,
      title: 'Thread $threadId',
      status: ThreadStatus.running,
      workspace: '/workspace/codex-mobile-companion',
      repository: 'codex-mobile-companion',
      branch: 'master',
      createdAt: '2026-03-18T10:00:00Z',
      updatedAt: '2026-03-18T12:01:00Z',
      source: 'cli',
      accessMode: AccessMode.fullControl,
      lastTurnSummary: 'Summary',
    );
  }

  @override
  Future<List<ThreadTimelineEntryDto>> fetchThreadTimeline({
    required String bridgeApiBaseUrl,
    required String threadId,
  }) async {
    return <ThreadTimelineEntryDto>[
      ThreadTimelineEntryDto(
        eventId: 'evt-$threadId-base',
        kind: BridgeEventKind.messageDelta,
        occurredAt: '2026-03-18T12:01:00Z',
        summary: 'Thread update',
        payload: const {'delta': 'Thread update'},
      ),
    ];
  }

  @override
  Future<TurnMutationResult> startTurn({
    required String bridgeApiBaseUrl,
    required String threadId,
    required String prompt,
  }) async {
    return TurnMutationResult(
      contractVersion: contractVersion,
      threadId: threadId,
      operation: 'turn_start',
      outcome: 'success',
      message: 'Turn started',
      threadStatus: ThreadStatus.running,
    );
  }

  @override
  Future<TurnMutationResult> steerTurn({
    required String bridgeApiBaseUrl,
    required String threadId,
    required String instruction,
  }) async {
    return TurnMutationResult(
      contractVersion: contractVersion,
      threadId: threadId,
      operation: 'turn_steer',
      outcome: 'success',
      message: 'Turn steered',
      threadStatus: ThreadStatus.running,
    );
  }

  @override
  Future<TurnMutationResult> interruptTurn({
    required String bridgeApiBaseUrl,
    required String threadId,
  }) async {
    return TurnMutationResult(
      contractVersion: contractVersion,
      threadId: threadId,
      operation: 'turn_interrupt',
      outcome: 'success',
      message: 'Turn interrupted',
      threadStatus: ThreadStatus.interrupted,
    );
  }

  @override
  Future<GitStatusResponseDto> fetchGitStatus({
    required String bridgeApiBaseUrl,
    required String threadId,
  }) async {
    return GitStatusResponseDto(
      contractVersion: contractVersion,
      threadId: threadId,
      repository: const RepositoryContextDto(
        workspace: '/workspace/codex-mobile-companion',
        repository: 'codex-mobile-companion',
        branch: 'master',
        remote: 'origin',
      ),
      status: const GitStatusDto(dirty: false, aheadBy: 0, behindBy: 0),
    );
  }

  @override
  Future<MutationResultResponseDto> switchBranch({
    required String bridgeApiBaseUrl,
    required String threadId,
    required String branch,
  }) async {
    return MutationResultResponseDto(
      contractVersion: contractVersion,
      threadId: threadId,
      operation: 'git_branch_switch',
      outcome: 'success',
      message: 'Switched to $branch',
      threadStatus: ThreadStatus.running,
      repository: RepositoryContextDto(
        workspace: '/workspace/codex-mobile-companion',
        repository: 'codex-mobile-companion',
        branch: branch,
        remote: 'origin',
      ),
      status: const GitStatusDto(dirty: false, aheadBy: 0, behindBy: 0),
    );
  }

  @override
  Future<MutationResultResponseDto> pullRepository({
    required String bridgeApiBaseUrl,
    required String threadId,
    String? remote,
  }) async {
    return MutationResultResponseDto(
      contractVersion: contractVersion,
      threadId: threadId,
      operation: 'git_pull',
      outcome: 'success',
      message: 'Pull complete',
      threadStatus: ThreadStatus.running,
      repository: RepositoryContextDto(
        workspace: '/workspace/codex-mobile-companion',
        repository: 'codex-mobile-companion',
        branch: 'master',
        remote: remote ?? 'origin',
      ),
      status: const GitStatusDto(dirty: false, aheadBy: 0, behindBy: 0),
    );
  }

  @override
  Future<MutationResultResponseDto> pushRepository({
    required String bridgeApiBaseUrl,
    required String threadId,
    String? remote,
  }) async {
    return MutationResultResponseDto(
      contractVersion: contractVersion,
      threadId: threadId,
      operation: 'git_push',
      outcome: 'success',
      message: 'Push complete',
      threadStatus: ThreadStatus.running,
      repository: RepositoryContextDto(
        workspace: '/workspace/codex-mobile-companion',
        repository: 'codex-mobile-companion',
        branch: 'master',
        remote: remote ?? 'origin',
      ),
      status: const GitStatusDto(dirty: false, aheadBy: 0, behindBy: 0),
    );
  }

  @override
  Future<OpenOnMacResponseDto> openOnMac({
    required String bridgeApiBaseUrl,
    required String threadId,
  }) async {
    return OpenOnMacResponseDto(
      contractVersion: contractVersion,
      threadId: threadId,
      attemptedUrl: 'codex://thread/$threadId',
      message: 'Requested open on Mac.',
      bestEffort: true,
    );
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
