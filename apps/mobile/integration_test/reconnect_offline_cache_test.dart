import 'dart:async';

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
  testWidgets(
    'offline relaunch restores selected thread from cache and blocks mutating actions',
    (tester) async {
      final cacheRepository = _newCacheRepository();
      await cacheRepository.saveThreadList(_threadSummaries());
      await cacheRepository.saveSelectedThreadId('thread-456');
      await cacheRepository.saveThreadDetail(
        detail: _threadDetail(
          threadId: 'thread-456',
          title: 'Investigate reconnect dedup',
          status: ThreadStatus.idle,
        ),
        timeline: [
          _timelineEvent(
            id: 'evt-cached-1',
            summary: 'Cached timeline item',
            payload: {'delta': 'Cached timeline item'},
            occurredAt: '2026-03-18T10:01:00Z',
          ),
        ],
      );

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
      expect(find.text('thread-456'), findsOneWidget);
      expect(
        find.textContaining(
          'Bridge is offline. Showing cached thread content.',
        ),
        findsOneWidget,
      );
      expect(
        find.text(
          'Mutating actions are blocked while the bridge or private route is unavailable.',
        ),
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
        find.byKey(const Key('thread-activity-evt-live-1')),
      );

      expect(
        find.byKey(const Key('thread-activity-evt-live-1')),
        findsOneWidget,
      );

      liveStream.emitError('thread-123');
      await tester.pumpAndSettle();

      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();

      await _scrollUntilVisible(
        tester,
        find.byKey(const Key('thread-activity-evt-live-1')),
      );

      expect(
        find.byKey(const Key('thread-activity-evt-live-1')),
        findsOneWidget,
      );
    },
  );
}

Future<void> _scrollUntilVisible(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    240,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
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
