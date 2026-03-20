import 'dart:async';

import 'package:codex_mobile_companion/features/approvals/application/approvals_queue_controller.dart';
import 'package:codex_mobile_companion/features/approvals/data/approval_bridge_api.dart';
import 'package:codex_mobile_companion/features/pairing/application/pairing_controller.dart';
import 'package:codex_mobile_companion/features/pairing/data/pairing_bridge_api.dart';
import 'package:codex_mobile_companion/features/pairing/domain/pairing_qr_payload.dart';
import 'package:codex_mobile_companion/features/pairing/presentation/pairing_flow_page.dart';
import 'package:codex_mobile_companion/features/threads/application/thread_detail_controller.dart';
import 'package:codex_mobile_companion/features/threads/data/thread_cache_repository.dart';
import 'package:codex_mobile_companion/features/threads/data/thread_detail_bridge_api.dart';
import 'package:codex_mobile_companion/features/threads/data/thread_list_bridge_api.dart';
import 'package:codex_mobile_companion/features/threads/data/thread_live_stream.dart';
import 'package:codex_mobile_companion/features/threads/presentation/thread_list_page.dart';
import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:codex_mobile_companion/foundation/storage/secure_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('first-run pairing lands directly in a live usable thread list', (
    tester,
  ) async {
    final secureStore = InMemorySecureStore();
    final liveStream = FakeThreadLiveStream();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          secureStoreProvider.overrideWithValue(secureStore),
          pairingBridgeApiProvider.overrideWithValue(FakePairingBridgeApi()),
          nowUtcProvider.overrideWithValue(DateTime.utc(2026, 3, 18, 10, 0)),
          threadCacheRepositoryProvider.overrideWithValue(
            _newCacheRepository(),
          ),
          threadListBridgeApiProvider.overrideWithValue(
            FakeThreadListBridgeApi(scriptedResults: [_threadSummaries()]),
          ),
          threadDetailBridgeApiProvider.overrideWithValue(
            FakeThreadDetailBridgeApi(
              detailScriptByThreadId: {
                'thread-123': [
                  _threadDetail(
                    threadId: 'thread-123',
                    title: 'Implement shared contracts',
                    status: ThreadStatus.running,
                  ),
                ],
              },
              timelineScriptByThreadId: {
                'thread-123': [
                  [
                    _timelineEvent(
                      id: 'evt-first-run-base',
                      summary: 'Initial timeline event',
                      payload: {'delta': 'Initial timeline event'},
                      occurredAt: '2026-03-18T10:00:00Z',
                    ),
                  ],
                ],
              },
            ),
          ),
          threadLiveStreamProvider.overrideWithValue(liveStream),
          approvalBridgeApiProvider.overrideWithValue(
            FakeApprovalBridgeApi(fetchApprovalsScript: [const []]),
          ),
        ],
        child: const MaterialApp(
          home: PairingFlowPage(
            enableCameraPreview: false,
            autoOpenThreadsOnPairing: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Initialize Pairing'), findsOneWidget);

    await tester.tap(find.text('Initialize Pairing'));
    await tester.pumpAndSettle();

    await _submitPayloadFromController(tester, _validPairingPayloadJson());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Trust & Connect'));
    await tester.pumpAndSettle();

    await _pumpUntilFound(tester, find.text('Threads'));
    expect(find.text('Threads'), findsOneWidget);
    await _pumpUntilFound(
      tester,
      find.byKey(const Key('thread-summary-card-thread-123')),
    );
    expect(
      find.byKey(const Key('thread-summary-card-thread-123')),
      findsOneWidget,
    );
    await _pumpUntil(
      tester,
      () => liveStream.subscribeCountFor(null) >= 1,
      description: 'thread list live subscription',
    );

    liveStream.emit(
      const BridgeEventEnvelope<Map<String, dynamic>>(
        contractVersion: contractVersion,
        eventId: 'evt-first-run-status',
        threadId: 'thread-123',
        kind: BridgeEventKind.threadStatusChanged,
        occurredAt: '2026-03-18T10:01:00Z',
        payload: {'status': 'completed'},
      ),
    );
    await tester.pumpAndSettle();

    await _pumpUntilFound(tester, find.text('COMPLETED'));
    expect(find.text('COMPLETED'), findsOneWidget);
    expect(
      await secureStore.readSecret(SecureValueKey.sessionToken),
      isNotNull,
    );
  });

  testWidgets(
    'revoked trust reconnect fails closed with explicit re-pair-required security state',
    (tester) async {
      final secureStore = InMemorySecureStore();
      await secureStore.writeSecret(SecureValueKey.trustedBridgeIdentity, '''
{
  "bridge_id": "bridge-a1",
  "bridge_name": "Codex Mobile Companion",
  "bridge_api_base_url": "https://bridge.ts.net",
  "session_id": "session-reconnect",
  "paired_at_epoch_seconds": 100
}
''');
      await secureStore.writeSecret(
        SecureValueKey.sessionToken,
        'revoked-session-token',
      );

      final pairingBridgeApi = FakePairingBridgeApi(
        handshakeResult: const PairingHandshakeResult.untrusted(
          code: 'trust_revoked',
          message:
              'Trust was revoked for this session. Re-pair from the Mac pairing QR.',
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            secureStoreProvider.overrideWithValue(secureStore),
            pairingBridgeApiProvider.overrideWithValue(pairingBridgeApi),
            nowUtcProvider.overrideWithValue(DateTime.utc(2026, 3, 18, 10, 0)),
          ],
          child: const MaterialApp(
            home: PairingFlowPage(enableCameraPreview: false),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Initialize Pairing'), findsOneWidget);
      expect(find.text('Re-pair required'), findsOneWidget);
      expect(
        find.text(
          'Trust was revoked for this session. Re-pair from the Mac pairing QR.',
        ),
        findsOneWidget,
      );
      expect(
        await secureStore.readSecret(SecureValueKey.trustedBridgeIdentity),
        isNull,
      );
      expect(await secureStore.readSecret(SecureValueKey.sessionToken), isNull);
    },
  );

  testWidgets(
    'bridge identity mismatch reconnect fails closed with explicit re-pair-required security state',
    (tester) async {
      final secureStore = InMemorySecureStore();
      await secureStore.writeSecret(SecureValueKey.trustedBridgeIdentity, '''
{
  "bridge_id": "bridge-a1",
  "bridge_name": "Codex Mobile Companion",
  "bridge_api_base_url": "https://bridge.ts.net",
  "session_id": "session-reconnect",
  "paired_at_epoch_seconds": 100
}
''');
      await secureStore.writeSecret(
        SecureValueKey.sessionToken,
        'identity-mismatch-session-token',
      );

      final pairingBridgeApi = FakePairingBridgeApi(
        handshakeResult: const PairingHandshakeResult.untrusted(
          code: 'bridge_identity_mismatch',
          message:
              'Stored bridge identity did not match the active bridge. Re-pair is required.',
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            secureStoreProvider.overrideWithValue(secureStore),
            pairingBridgeApiProvider.overrideWithValue(pairingBridgeApi),
            nowUtcProvider.overrideWithValue(DateTime.utc(2026, 3, 18, 10, 0)),
          ],
          child: const MaterialApp(
            home: PairingFlowPage(enableCameraPreview: false),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Initialize Pairing'), findsOneWidget);
      expect(find.text('Re-pair required'), findsOneWidget);
      expect(
        find.text(
          'Stored bridge identity did not match the active bridge. Re-pair is required.',
        ),
        findsOneWidget,
      );
      expect(
        await secureStore.readSecret(SecureValueKey.trustedBridgeIdentity),
        isNull,
      );
      expect(await secureStore.readSecret(SecureValueKey.sessionToken), isNull);
    },
  );

  testWidgets(
    'offline relaunch restores selected thread from cache and blocks mutating actions',
    (tester) async {
      final cacheRepository = _newCacheRepository();
      await cacheRepository.saveThreadList(_threadSummaries());
      await cacheRepository.saveSelectedThreadId('thread-456');

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            threadCacheRepositoryProvider.overrideWithValue(cacheRepository),
            threadListBridgeApiProvider.overrideWithValue(
              FakeThreadListBridgeApi(
                scriptedResults: [
                  const ThreadListBridgeException(
                    'Cannot reach the bridge. Check your private route.',
                    isConnectivityError: true,
                  ),
                ],
              ),
            ),
            threadDetailBridgeApiProvider.overrideWithValue(
              FakeThreadDetailBridgeApi(
                detailScriptByThreadId: {
                  'thread-456': [
                    const ThreadDetailBridgeException(
                      message:
                          'Cannot reach the bridge. Check your private route.',
                      isConnectivityError: true,
                    ),
                  ],
                },
                timelineScriptByThreadId: {
                  'thread-456': [
                    const ThreadDetailBridgeException(
                      message:
                          'Cannot reach the bridge. Check your private route.',
                      isConnectivityError: true,
                    ),
                  ],
                },
              ),
            ),
            threadLiveStreamProvider.overrideWithValue(FakeThreadLiveStream()),
          ],
          child: const MaterialApp(
            home: ThreadListPage(bridgeApiBaseUrl: 'https://bridge.ts.net'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Investigate reconnect dedup'), findsOneWidget);
      expect(
        find.textContaining('Bridge is offline. Showing cached threads.'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Mutating actions stay blocked until reconnect.'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'disconnect keeps thread readable and deduplicated with reconnect controls',
    (tester) async {
      final detailApi = FakeThreadDetailBridgeApi(
        detailScriptByThreadId: {
          'thread-123': [
            _threadDetail(
              threadId: 'thread-123',
              title: 'Implement shared contracts',
              status: ThreadStatus.running,
            ),
            _threadDetail(
              threadId: 'thread-123',
              title: 'Implement shared contracts',
              status: ThreadStatus.completed,
            ),
          ],
        },
        timelineScriptByThreadId: {
          'thread-123': [
            [
              _timelineEvent(
                id: 'evt-1',
                summary: 'Initial event',
                payload: {'delta': 'Initial event'},
                occurredAt: '2026-03-18T10:00:00Z',
              ),
            ],
            [
              _timelineEvent(
                id: 'evt-1',
                summary: 'Initial event',
                payload: {'delta': 'Initial event'},
                occurredAt: '2026-03-18T10:00:00Z',
              ),
              _timelineEvent(
                id: 'evt-live-1',
                summary: 'Streaming chunk from live output.',
                payload: {'delta': 'Streaming chunk from live output.'},
                occurredAt: '2026-03-18T10:01:00Z',
              ),
              _timelineEvent(
                id: 'evt-catchup-2',
                summary: 'Missed while disconnected',
                payload: {'delta': 'Missed while disconnected'},
                occurredAt: '2026-03-18T10:02:00Z',
              ),
            ],
          ],
        },
      );
      final liveStream = FakeThreadLiveStream();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            threadCacheRepositoryProvider.overrideWithValue(
              _newCacheRepository(),
            ),
            threadListBridgeApiProvider.overrideWithValue(
              FakeThreadListBridgeApi(scriptedResults: [_threadSummaries()]),
            ),
            threadDetailBridgeApiProvider.overrideWithValue(detailApi),
            threadLiveStreamProvider.overrideWithValue(liveStream),
          ],
          child: const MaterialApp(
            home: ThreadListPage(bridgeApiBaseUrl: 'https://bridge.ts.net'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('thread-summary-card-thread-123')));
      await tester.pumpAndSettle();

      liveStream.emit(
        BridgeEventEnvelope<Map<String, dynamic>>(
          contractVersion: contractVersion,
          eventId: 'evt-live-1',
          threadId: 'thread-123',
          kind: BridgeEventKind.messageDelta,
          occurredAt: '2026-03-18T10:01:00Z',
          payload: {'delta': 'Streaming chunk from live output.'},
        ),
      );
      await tester.pumpAndSettle();

      await _scrollUntilVisible(
        tester,
        find.byKey(const Key('thread-message-card-evt-live-1')),
      );

      expect(
        find.byKey(const Key('thread-message-card-evt-live-1')),
        findsOneWidget,
      );

      liveStream.emitError('thread-123');
      await tester.pumpAndSettle();

      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();

      await _scrollUntilVisible(
        tester,
        find.byKey(const Key('thread-message-card-evt-live-1')),
      );

      expect(
        find.byKey(const Key('thread-message-card-evt-live-1')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'reconnect restores trusted session, selected thread, approvals, and repo context without duplication',
    (tester) async {
      final secureStore = InMemorySecureStore();
      await secureStore.writeSecret(SecureValueKey.trustedBridgeIdentity, '''
{
  "bridge_id": "bridge-a1",
  "bridge_name": "Codex Mobile Companion",
  "bridge_api_base_url": "https://bridge.ts.net",
  "session_id": "session-reconnect",
  "paired_at_epoch_seconds": 100
}
''');
      await secureStore.writeSecret(
        SecureValueKey.sessionToken,
        'active-session-token',
      );

      final cacheRepository = SecureStoreThreadCacheRepository(
        secureStore: secureStore,
        nowUtc: () => DateTime.utc(2026, 3, 18, 10, 0),
      );
      await cacheRepository.saveThreadList(_threadSummaries());
      await cacheRepository.saveSelectedThreadId('thread-123');

      final pairingBridgeApi = FakePairingBridgeApi(
        handshakeScript: const [
          PairingHandshakeResult.connectivityUnavailable(
            message:
                'Private bridge path is currently unreachable. Reconnect to Tailscale and retry.',
          ),
          PairingHandshakeResult.trusted(),
        ],
      );

      final detailApi = FakeThreadDetailBridgeApi(
        detailScriptByThreadId: {
          'thread-123': [
            _threadDetail(
              threadId: 'thread-123',
              title: 'Implement shared contracts',
              status: ThreadStatus.running,
            ),
            _threadDetail(
              threadId: 'thread-123',
              title: 'Implement shared contracts',
              status: ThreadStatus.running,
            ),
            _threadDetail(
              threadId: 'thread-123',
              title: 'Implement shared contracts',
              status: ThreadStatus.running,
            ),
            _threadDetail(
              threadId: 'thread-123',
              title: 'Implement shared contracts',
              status: ThreadStatus.running,
            ),
          ],
        },
        timelineScriptByThreadId: {
          'thread-123': [
            [
              _timelineEvent(
                id: 'evt-base-restore',
                summary: 'Cached base timeline event',
                payload: {'delta': 'Cached base timeline event'},
                occurredAt: '2026-03-18T10:00:00Z',
              ),
            ],
            [
              _timelineEvent(
                id: 'evt-base-restore',
                summary: 'Cached base timeline event',
                payload: {'delta': 'Cached base timeline event'},
                occurredAt: '2026-03-18T10:00:00Z',
              ),
              _timelineEvent(
                id: 'evt-live-restore',
                summary: 'Live output emitted before disconnect',
                payload: {'delta': 'Live output emitted before disconnect'},
                occurredAt: '2026-03-18T10:01:00Z',
              ),
              _timelineEvent(
                id: 'evt-catchup-restore',
                summary: 'Missed while reconnecting',
                payload: {'delta': 'Missed while reconnecting'},
                occurredAt: '2026-03-18T10:02:00Z',
              ),
            ],
          ],
        },
      );

      final approvalApi = FakeApprovalBridgeApi(
        fetchApprovalsScript: [
          const ApprovalBridgeException(
            message: 'Cannot reach the bridge. Check your private route.',
            isConnectivityError: true,
          ),
          [_pendingApprovalRecord(threadId: 'thread-123')],
        ],
      );

      final liveStream = FakeThreadLiveStream();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            secureStoreProvider.overrideWithValue(secureStore),
            pairingBridgeApiProvider.overrideWithValue(pairingBridgeApi),
            nowUtcProvider.overrideWithValue(DateTime.utc(2026, 3, 18, 10, 0)),
            threadCacheRepositoryProvider.overrideWithValue(cacheRepository),
            threadListBridgeApiProvider.overrideWithValue(
              FakeThreadListBridgeApi(
                scriptedResults: [_threadSummaries(), _threadSummaries()],
              ),
            ),
            threadDetailBridgeApiProvider.overrideWithValue(detailApi),
            threadLiveStreamProvider.overrideWithValue(liveStream),
            approvalBridgeApiProvider.overrideWithValue(approvalApi),
          ],
          child: const MaterialApp(
            home: PairingFlowPage(enableCameraPreview: false),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Disconnected'), findsOneWidget);
      expect(
        find.text(
          'Private bridge path is currently unreachable. Reconnect to Tailscale and retry.',
        ),
        findsOneWidget,
      );

      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();

      expect(find.text('Paired with Codex Mobile Companion'), findsOneWidget);
      expect(pairingBridgeApi.handshakeCalls, greaterThanOrEqualTo(2));

      await tester.tap(find.text('Open sessions'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('thread-detail-title')), findsOneWidget);
      expect(find.text('Implement shared contracts'), findsOneWidget);

      const liveEvent = BridgeEventEnvelope<Map<String, dynamic>>(
        contractVersion: contractVersion,
        eventId: 'evt-live-restore',
        threadId: 'thread-123',
        kind: BridgeEventKind.messageDelta,
        occurredAt: '2026-03-18T10:01:00Z',
        payload: {'delta': 'Live output emitted before disconnect'},
      );

      liveStream.emit(liveEvent);
      liveStream.emit(liveEvent);
      await tester.pumpAndSettle();

      await _scrollUntilVisible(
        tester,
        find.byKey(const Key('thread-message-card-evt-live-restore')),
      );
      expect(
        find.byKey(const Key('thread-message-card-evt-live-restore')),
        findsOneWidget,
      );

      liveStream.emitError('thread-123');
      await tester.pumpAndSettle();

      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();

      liveStream.emit(
        BridgeEventEnvelope<Map<String, dynamic>>(
          contractVersion: contractVersion,
          eventId: 'evt-approval-restore',
          threadId: 'thread-123',
          kind: BridgeEventKind.approvalRequested,
          occurredAt: '2026-03-18T10:03:00Z',
          payload: _pendingApprovalRecord(threadId: 'thread-123').toJson(),
        ),
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp).first),
      );

      await _pumpUntil(
        tester,
        () {
          final detailState = container.read(
            threadDetailControllerProvider(
              const ThreadDetailControllerArgs(
                bridgeApiBaseUrl: 'https://bridge.ts.net',
                threadId: 'thread-123',
              ),
            ),
          );
          final approvalsState = container.read(
            approvalsQueueControllerProvider('https://bridge.ts.net'),
          );

          return detailState.items.any(
                (item) => item.eventId == 'evt-live-restore',
              ) &&
              detailState.items.any(
                (item) => item.eventId == 'evt-catchup-restore',
              ) &&
              approvalsState
                  .forThread('thread-123')
                  .any(
                    (item) => item.approval.approvalId == 'approval-restore',
                  );
        },
        description: 'reconnect catch-up and approval restore',
        timeout: const Duration(seconds: 10),
      );

      final detailState = container.read(
        threadDetailControllerProvider(
          const ThreadDetailControllerArgs(
            bridgeApiBaseUrl: 'https://bridge.ts.net',
            threadId: 'thread-123',
          ),
        ),
      );

      expect(
        detailState.items
            .where((item) => item.eventId == 'evt-live-restore')
            .length,
        1,
      );
      expect(
        detailState.items
            .where((item) => item.eventId == 'evt-catchup-restore')
            .length,
        1,
      );
      expect(
        detailState.gitStatus?.repository.repository,
        'codex-mobile-companion',
      );
      expect(detailState.gitStatus?.repository.branch, 'master');
      expect(detailState.gitStatus?.repository.remote, 'origin');
      expect(
        detailState.gitStatus?.repository.workspace,
        '/workspace/codex-mobile-companion',
      );

      final approvalsState = container.read(
        approvalsQueueControllerProvider('https://bridge.ts.net'),
      );
      final restoredApprovalCount = approvalsState
          .forThread('thread-123')
          .where((item) => item.approval.approvalId == 'approval-restore')
          .length;
      expect(restoredApprovalCount, 1);
      expect(approvalsState.pendingCount, 1);

      expect(
        liveStream.subscribeCountFor('thread-123'),
        greaterThanOrEqualTo(2),
      );
      expect(approvalApi.fetchApprovalsCallCount, greaterThanOrEqualTo(2));
    },
  );
}

String _validPairingPayloadJson({
  String bridgeId = 'bridge-a1',
  String sessionId = 'session-first-run',
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

Future<void> _pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    if (finder.evaluate().isNotEmpty) {
      return;
    }
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  required String description,
  Duration timeout = const Duration(seconds: 5),
}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    if (condition()) {
      return;
    }
    await tester.pump(const Duration(milliseconds: 100));
  }

  fail('Timed out waiting for $description');
}

Future<void> _submitPayloadFromController(
  WidgetTester tester,
  String payload,
) async {
  final container = ProviderScope.containerOf(
    tester.element(find.byType(PairingFlowPage)),
  );
  container
      .read(pairingControllerProvider.notifier)
      .submitScannedPayload(payload);
}

Future<void> _scrollUntilVisible(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isNotEmpty) {
    return;
  }

  final scrollables = find.byType(Scrollable);
  if (scrollables.evaluate().isEmpty) {
    return;
  }

  final scrollable = scrollables.first;

  for (var attempt = 0; attempt < 25; attempt += 1) {
    if (finder.evaluate().isNotEmpty) {
      return;
    }

    await tester.drag(scrollable, const Offset(0, -300));
    await tester.pump(const Duration(milliseconds: 100));
  }

  for (var attempt = 0; attempt < 25; attempt += 1) {
    if (finder.evaluate().isNotEmpty) {
      return;
    }

    await tester.drag(scrollable, const Offset(0, 300));
    await tester.pump(const Duration(milliseconds: 100));
  }

  fail('Timed out scrolling to finder: $finder');
}

ThreadCacheRepository _newCacheRepository() {
  return SecureStoreThreadCacheRepository(
    secureStore: InMemorySecureStore(),
    nowUtc: () => DateTime.utc(2026, 3, 18, 10, 0),
  );
}

List<ThreadSummaryDto> _threadSummaries() {
  return const [
    ThreadSummaryDto(
      contractVersion: contractVersion,
      threadId: 'thread-123',
      title: 'Implement shared contracts',
      status: ThreadStatus.running,
      workspace: '/workspace/codex-mobile-companion',
      repository: 'codex-mobile-companion',
      branch: 'master',
      updatedAt: '2026-03-18T10:00:00Z',
    ),
    ThreadSummaryDto(
      contractVersion: contractVersion,
      threadId: 'thread-456',
      title: 'Investigate reconnect dedup',
      status: ThreadStatus.idle,
      workspace: '/workspace/codex-runtime-tools',
      repository: 'codex-runtime-tools',
      branch: 'develop',
      updatedAt: '2026-03-18T09:30:00Z',
    ),
  ];
}

ThreadDetailDto _threadDetail({
  required String threadId,
  required String title,
  required ThreadStatus status,
}) {
  return ThreadDetailDto(
    contractVersion: contractVersion,
    threadId: threadId,
    title: title,
    status: status,
    workspace: '/workspace/codex-mobile-companion',
    repository: 'codex-mobile-companion',
    branch: 'master',
    createdAt: '2026-03-18T09:45:00Z',
    updatedAt: '2026-03-18T10:00:00Z',
    source: 'cli',
    accessMode: AccessMode.controlWithApprovals,
    lastTurnSummary: 'Summary',
  );
}

ThreadTimelineEntryDto _timelineEvent({
  required String id,
  required String summary,
  required Map<String, dynamic> payload,
  required String occurredAt,
}) {
  return ThreadTimelineEntryDto(
    eventId: id,
    kind: BridgeEventKind.messageDelta,
    occurredAt: occurredAt,
    summary: summary,
    payload: payload,
  );
}

ApprovalRecordDto _pendingApprovalRecord({required String threadId}) {
  return ApprovalRecordDto(
    contractVersion: contractVersion,
    approvalId: 'approval-restore',
    threadId: threadId,
    action: 'git_pull',
    target: 'git.pull',
    reason: 'full_control_required',
    status: ApprovalStatus.pending,
    requestedAt: '2026-03-18T10:03:00Z',
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
  FakePairingBridgeApi({
    this.handshakeResult = const PairingHandshakeResult.trusted(),
    List<PairingHandshakeResult>? handshakeScript,
    this.revokeResult = const PairingRevokeResult.success(),
  }) : _handshakeScript = handshakeScript;

  final PairingHandshakeResult handshakeResult;
  final List<PairingHandshakeResult>? _handshakeScript;
  final PairingRevokeResult revokeResult;
  int handshakeCalls = 0;

  @override
  Future<PairingFinalizeResult> finalizeTrust({
    required PairingQrPayload payload,
    required String phoneId,
    required String phoneName,
  }) async {
    return PairingFinalizeResult.success(
      sessionToken: 'session-token',
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
    return revokeResult;
  }
}

class FakeApprovalBridgeApi implements ApprovalBridgeApi {
  FakeApprovalBridgeApi({
    this.accessMode = AccessMode.fullControl,
    required List<Object> fetchApprovalsScript,
  }) : _fetchApprovalsScript = fetchApprovalsScript;

  final AccessMode accessMode;
  final List<Object> _fetchApprovalsScript;
  int fetchAccessModeCallCount = 0;
  int fetchApprovalsCallCount = 0;

  @override
  Future<AccessMode> fetchAccessMode({required String bridgeApiBaseUrl}) async {
    fetchAccessModeCallCount += 1;
    return accessMode;
  }

  @override
  Future<List<ApprovalRecordDto>> fetchApprovals({
    required String bridgeApiBaseUrl,
  }) async {
    fetchApprovalsCallCount += 1;
    final scriptedResult = _nextFetchApprovalsResult();
    if (scriptedResult is List<ApprovalRecordDto>) {
      return scriptedResult;
    }
    if (scriptedResult is ApprovalBridgeException) {
      throw scriptedResult;
    }

    throw StateError(
      'Unsupported approvals scripted result type: $scriptedResult',
    );
  }

  @override
  Future<ApprovalResolutionResponseDto> approve({
    required String bridgeApiBaseUrl,
    required String approvalId,
  }) async {
    throw const ApprovalResolutionBridgeException(
      message: 'Approvals are read-only in this integration harness.',
    );
  }

  @override
  Future<ApprovalResolutionResponseDto> reject({
    required String bridgeApiBaseUrl,
    required String approvalId,
  }) async {
    throw const ApprovalResolutionBridgeException(
      message: 'Approvals are read-only in this integration harness.',
    );
  }

  Object _nextFetchApprovalsResult() {
    if (_fetchApprovalsScript.isEmpty) {
      return const <ApprovalRecordDto>[];
    }

    final scriptedResult = _fetchApprovalsScript.first;
    if (_fetchApprovalsScript.length > 1) {
      _fetchApprovalsScript.removeAt(0);
    }
    return scriptedResult;
  }
}

class FakeThreadDetailBridgeApi implements ThreadDetailBridgeApi {
  FakeThreadDetailBridgeApi({
    required Map<String, List<Object>> detailScriptByThreadId,
    required Map<String, List<Object>> timelineScriptByThreadId,
  }) : _detailScriptByThreadId = detailScriptByThreadId,
       _timelineScriptByThreadId = timelineScriptByThreadId;

  final Map<String, List<Object>> _detailScriptByThreadId;
  final Map<String, List<Object>> _timelineScriptByThreadId;

  @override
  Future<ThreadDetailDto> fetchThreadDetail({
    required String bridgeApiBaseUrl,
    required String threadId,
  }) async {
    final scriptedResult = _nextResult(_detailScriptByThreadId, threadId);
    if (scriptedResult is ThreadDetailDto) {
      return scriptedResult;
    }
    if (scriptedResult is ThreadDetailBridgeException) {
      throw scriptedResult;
    }

    throw StateError('Unsupported detail scripted result: $scriptedResult');
  }

  @override
  Future<ThreadTimelinePageDto> fetchThreadTimelinePage({
    required String bridgeApiBaseUrl,
    required String threadId,
    String? before,
    int limit = 50,
  }) async {
    final detail = await fetchThreadDetail(
      bridgeApiBaseUrl: bridgeApiBaseUrl,
      threadId: threadId,
    );

    final entries = await fetchThreadTimeline(
      bridgeApiBaseUrl: bridgeApiBaseUrl,
      threadId: threadId,
    );

    return ThreadTimelinePageDto(
      contractVersion: contractVersion,
      thread: detail,
      entries: entries,
      nextBefore: null,
      hasMoreBefore: false,
    );
  }

  @override
  Future<List<ThreadTimelineEntryDto>> fetchThreadTimeline({
    required String bridgeApiBaseUrl,
    required String threadId,
  }) async {
    final scriptedResult = _nextResult(_timelineScriptByThreadId, threadId);
    if (scriptedResult is List<ThreadTimelineEntryDto>) {
      return scriptedResult;
    }
    if (scriptedResult is ThreadDetailBridgeException) {
      throw scriptedResult;
    }

    throw StateError('Unsupported timeline scripted result: $scriptedResult');
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
      message: 'Turn started and streaming is active',
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
      message: 'Steer instruction applied to active turn',
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
      message: 'Interrupt signal sent to active turn',
      threadStatus: ThreadStatus.interrupted,
    );
  }

  @override
  Future<GitStatusResponseDto> fetchGitStatus({
    required String bridgeApiBaseUrl,
    required String threadId,
  }) async {
    final detail = await fetchThreadDetail(
      bridgeApiBaseUrl: bridgeApiBaseUrl,
      threadId: threadId,
    );
    return GitStatusResponseDto(
      contractVersion: contractVersion,
      threadId: threadId,
      repository: RepositoryContextDto(
        workspace: detail.workspace,
        repository: detail.repository,
        branch: detail.branch,
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
    final detail = await fetchThreadDetail(
      bridgeApiBaseUrl: bridgeApiBaseUrl,
      threadId: threadId,
    );
    return MutationResultResponseDto(
      contractVersion: contractVersion,
      threadId: threadId,
      operation: 'git_branch_switch',
      outcome: 'success',
      message: 'Switched branch to $branch',
      threadStatus: detail.status,
      repository: RepositoryContextDto(
        workspace: detail.workspace,
        repository: detail.repository,
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
    final detail = await fetchThreadDetail(
      bridgeApiBaseUrl: bridgeApiBaseUrl,
      threadId: threadId,
    );
    return MutationResultResponseDto(
      contractVersion: contractVersion,
      threadId: threadId,
      operation: 'git_pull',
      outcome: 'success',
      message: 'Pull complete',
      threadStatus: detail.status,
      repository: RepositoryContextDto(
        workspace: detail.workspace,
        repository: detail.repository,
        branch: detail.branch,
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
      message:
          'Requested Codex.app to open the matching shared thread. Desktop refresh is best effort; mobile remains fully usable.',
      bestEffort: true,
    );
  }

  @override
  Future<MutationResultResponseDto> pushRepository({
    required String bridgeApiBaseUrl,
    required String threadId,
    String? remote,
  }) async {
    final detail = await fetchThreadDetail(
      bridgeApiBaseUrl: bridgeApiBaseUrl,
      threadId: threadId,
    );
    return MutationResultResponseDto(
      contractVersion: contractVersion,
      threadId: threadId,
      operation: 'git_push',
      outcome: 'success',
      message: 'Push complete',
      threadStatus: detail.status,
      repository: RepositoryContextDto(
        workspace: detail.workspace,
        repository: detail.repository,
        branch: detail.branch,
        remote: remote ?? 'origin',
      ),
      status: const GitStatusDto(dirty: false, aheadBy: 0, behindBy: 0),
    );
  }

  Object _nextResult(
    Map<String, List<Object>> scriptByThreadId,
    String threadId,
  ) {
    final script = scriptByThreadId[threadId];
    if (script == null || script.isEmpty) {
      throw StateError('Missing scripted result for thread "$threadId".');
    }

    final result = script.first;
    if (script.length > 1) {
      script.removeAt(0);
    }

    return result;
  }
}

class FakeThreadLiveStream implements ThreadLiveStream {
  static const _allThreadsKey = '__all__';

  final Map<String, int> _subscribeCountsByThreadId = <String, int>{};
  final Map<
    String,
    List<StreamController<BridgeEventEnvelope<Map<String, dynamic>>>>
  >
  _controllersByThreadId =
      <
        String,
        List<StreamController<BridgeEventEnvelope<Map<String, dynamic>>>>
      >{};

  @override
  Future<ThreadLiveSubscription> subscribe({
    required String bridgeApiBaseUrl,
    String? threadId,
  }) async {
    final normalizedThreadId = threadId ?? _allThreadsKey;
    _subscribeCountsByThreadId[normalizedThreadId] =
        (_subscribeCountsByThreadId[normalizedThreadId] ?? 0) + 1;
    final controller =
        StreamController<BridgeEventEnvelope<Map<String, dynamic>>>();
    _controllersByThreadId
        .putIfAbsent(
          normalizedThreadId,
          () => <StreamController<BridgeEventEnvelope<Map<String, dynamic>>>>[],
        )
        .add(controller);

    return ThreadLiveSubscription(
      events: controller.stream,
      close: () async {
        _controllersByThreadId[normalizedThreadId]?.remove(controller);
        if (!controller.isClosed) {
          await controller.close();
        }
      },
    );
  }

  int subscribeCountFor(String? threadId) {
    final normalizedThreadId = threadId ?? _allThreadsKey;
    return _subscribeCountsByThreadId[normalizedThreadId] ?? 0;
  }

  void emit(BridgeEventEnvelope<Map<String, dynamic>> event) {
    final controllers =
        <StreamController<BridgeEventEnvelope<Map<String, dynamic>>>>[
          ...?_controllersByThreadId[event.threadId],
          ...?_controllersByThreadId[_allThreadsKey],
        ];

    for (final controller
        in List<
          StreamController<BridgeEventEnvelope<Map<String, dynamic>>>
        >.from(controllers)) {
      if (!controller.isClosed) {
        controller.add(event);
      }
    }
  }

  void emitError(String threadId) {
    final controllers =
        <StreamController<BridgeEventEnvelope<Map<String, dynamic>>>>[
          ...?_controllersByThreadId[threadId],
          ...?_controllersByThreadId[_allThreadsKey],
        ];

    for (final controller
        in List<
          StreamController<BridgeEventEnvelope<Map<String, dynamic>>>
        >.from(controllers)) {
      if (!controller.isClosed) {
        controller.addError(StateError('stream disconnected'));
      }
    }
  }

  Future<void> closeThread(String threadId) async {
    final controllers =
        <StreamController<BridgeEventEnvelope<Map<String, dynamic>>>>[
          ...?_controllersByThreadId[threadId],
          ...?_controllersByThreadId[_allThreadsKey],
        ];

    for (final controller
        in List<
          StreamController<BridgeEventEnvelope<Map<String, dynamic>>>
        >.from(controllers)) {
      if (!controller.isClosed) {
        await controller.close();
      }
    }

    _controllersByThreadId.remove(threadId);
  }
}

class FakeThreadListBridgeApi implements ThreadListBridgeApi {
  FakeThreadListBridgeApi({required this.scriptedResults});

  final List<Object> scriptedResults;
  int _nextResultIndex = 0;

  @override
  Future<List<ThreadSummaryDto>> fetchThreads({
    required String bridgeApiBaseUrl,
  }) async {
    final index = _nextResultIndex;
    if (_nextResultIndex < scriptedResults.length - 1) {
      _nextResultIndex += 1;
    }

    final scriptedResult = scriptedResults[index];
    if (scriptedResult is List<ThreadSummaryDto>) {
      return scriptedResult;
    }
    if (scriptedResult is ThreadListBridgeException) {
      throw scriptedResult;
    }

    throw StateError('Unsupported scripted result type: $scriptedResult');
  }
}
