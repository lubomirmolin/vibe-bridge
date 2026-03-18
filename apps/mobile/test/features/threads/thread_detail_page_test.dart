import 'dart:async';

import 'package:codex_mobile_companion/features/approvals/data/approval_bridge_api.dart';
import 'package:codex_mobile_companion/features/threads/data/thread_cache_repository.dart';
import 'package:codex_mobile_companion/features/threads/data/thread_detail_bridge_api.dart';
import 'package:codex_mobile_companion/features/threads/data/thread_list_bridge_api.dart';
import 'package:codex_mobile_companion/features/threads/data/thread_live_stream.dart';
import 'package:codex_mobile_companion/features/threads/presentation/thread_detail_page.dart';
import 'package:codex_mobile_companion/features/threads/presentation/thread_list_page.dart';
import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:codex_mobile_companion/foundation/storage/secure_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'opening a thread shows matching detail and mixed item types distinctly',
    (tester) async {
      final listApi = FakeThreadListBridgeApi(
        scriptedResults: [_threadSummaries()],
      );
      final detailApi = FakeThreadDetailBridgeApi(
        detailScriptByThreadId: {
          'thread-123': [_thread123Detail()],
        },
        timelineScriptByThreadId: {
          'thread-123': [_mixedTimelineEvents()],
        },
      );
      final liveStream = FakeThreadLiveStream();

      await _pumpThreadListApp(
        tester,
        listApi: listApi,
        detailApi: detailApi,
        liveStream: liveStream,
      );

      await tester.tap(find.byKey(const Key('thread-summary-card-thread-123')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('thread-detail-title')), findsOneWidget);
      expect(find.text('Implement shared contracts'), findsOneWidget);
      expect(find.byKey(const Key('thread-detail-thread-id')), findsOneWidget);
      expect(find.text('thread-123'), findsOneWidget);
      await _scrollUntilVisible(tester, find.text('User prompt'));
      expect(find.text('User prompt'), findsOneWidget);
      await _scrollUntilVisible(tester, find.text('Assistant output'));
      expect(find.text('Assistant output'), findsOneWidget);
      await _scrollUntilVisible(tester, find.text('Plan update'));
      expect(find.text('Plan update'), findsOneWidget);
      await _scrollUntilVisible(tester, find.text('Terminal output'));
      expect(find.text('Terminal output'), findsOneWidget);
      await _scrollUntilVisible(tester, find.text('File change'));
      expect(find.text('File change'), findsOneWidget);
      await _scrollUntilVisible(
        tester,
        find.textContaining('tail -n 100 app.log'),
      );
      expect(find.textContaining('tail -n 100 app.log'), findsOneWidget);
      await _scrollUntilVisible(tester, find.textContaining('lib/main.dart'));
      expect(find.textContaining('lib/main.dart'), findsOneWidget);
    },
  );

  testWidgets('idle composer starts turn and transitions to active controls', (
    tester,
  ) async {
    final detailApi = FakeThreadDetailBridgeApi(
      detailScriptByThreadId: {
        'thread-456': [_thread456Detail()],
      },
      timelineScriptByThreadId: {
        'thread-456': [<ThreadTimelineEntryDto>[]],
      },
      startTurnScriptByThreadId: {
        'thread-456': [
          _turnMutationResult(
            threadId: 'thread-456',
            operation: 'turn_start',
            status: ThreadStatus.running,
            message: 'Turn started and streaming is active',
          ),
        ],
      },
    );

    await _pumpThreadDetailApp(
      tester,
      detailApi: detailApi,
      threadId: 'thread-456',
    );

    expect(find.text('Start turn'), findsOneWidget);
    expect(find.byKey(const Key('turn-interrupt-button')), findsNothing);

    await tester.enterText(
      find.byKey(const Key('turn-composer-input')),
      'Draft release notes for today\'s bridge changes.',
    );
    await tester.tap(find.byKey(const Key('turn-composer-submit')));
    await tester.pumpAndSettle();

    expect(detailApi.startTurnPromptsByThreadId['thread-456'], [
      'Draft release notes for today\'s bridge changes.',
    ]);
    expect(find.text('Steer turn'), findsOneWidget);
    expect(find.byKey(const Key('turn-interrupt-button')), findsOneWidget);
    expect(find.text('Running'), findsOneWidget);
  });

  testWidgets('active composer steers and interrupt stops the active turn', (
    tester,
  ) async {
    final detailApi = FakeThreadDetailBridgeApi(
      detailScriptByThreadId: {
        'thread-123': [_thread123Detail()],
      },
      timelineScriptByThreadId: {
        'thread-123': [<ThreadTimelineEntryDto>[]],
      },
      steerTurnScriptByThreadId: {
        'thread-123': [
          _turnMutationResult(
            threadId: 'thread-123',
            operation: 'turn_steer',
            status: ThreadStatus.running,
            message: 'Steer instruction applied to active turn',
          ),
        ],
      },
      interruptTurnScriptByThreadId: {
        'thread-123': [
          _turnMutationResult(
            threadId: 'thread-123',
            operation: 'turn_interrupt',
            status: ThreadStatus.interrupted,
            message: 'Interrupt signal sent to active turn',
          ),
        ],
      },
    );

    await _pumpThreadDetailApp(
      tester,
      detailApi: detailApi,
      threadId: 'thread-123',
    );

    expect(find.text('Steer turn'), findsOneWidget);
    expect(find.byKey(const Key('turn-interrupt-button')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('turn-composer-input')),
      'Focus on reconnect deduplication details.',
    );
    await tester.tap(find.byKey(const Key('turn-composer-submit')));
    await tester.pumpAndSettle();

    expect(detailApi.steerTurnInstructionsByThreadId['thread-123'], [
      'Focus on reconnect deduplication details.',
    ]);

    await tester.tap(find.byKey(const Key('turn-interrupt-button')));
    await tester.pumpAndSettle();

    expect(detailApi.interruptTurnCallsByThreadId['thread-123'], 1);
    expect(find.text('Interrupted'), findsOneWidget);
    expect(find.text('Start turn'), findsOneWidget);
    expect(find.byKey(const Key('turn-interrupt-button')), findsNothing);
  });

  testWidgets('start failure surfaces clear error and keeps thread usable', (
    tester,
  ) async {
    final detailApi = FakeThreadDetailBridgeApi(
      detailScriptByThreadId: {
        'thread-456': [_thread456Detail()],
      },
      timelineScriptByThreadId: {
        'thread-456': [<ThreadTimelineEntryDto>[]],
      },
      startTurnScriptByThreadId: {
        'thread-456': [
          const ThreadTurnBridgeException(
            message: 'Turn start failed: bridge rejected prompt payload.',
          ),
          _turnMutationResult(
            threadId: 'thread-456',
            operation: 'turn_start',
            status: ThreadStatus.running,
            message: 'Turn started and streaming is active',
          ),
        ],
      },
    );

    await _pumpThreadDetailApp(
      tester,
      detailApi: detailApi,
      threadId: 'thread-456',
    );

    await tester.enterText(
      find.byKey(const Key('turn-composer-input')),
      'Start a new turn with this prompt.',
    );
    await tester.tap(find.byKey(const Key('turn-composer-submit')));
    await tester.pumpAndSettle();

    expect(
      find.text('Turn start failed: bridge rejected prompt payload.'),
      findsOneWidget,
    );
    expect(find.text('Start turn'), findsOneWidget);

    await tester.tap(find.byKey(const Key('turn-composer-submit')));
    await tester.pumpAndSettle();

    expect(
      find.text('Turn start failed: bridge rejected prompt payload.'),
      findsNothing,
    );
    expect(find.text('Running'), findsOneWidget);
    expect(find.text('Steer turn'), findsOneWidget);
  });

  testWidgets('interrupt failure keeps active status and reports clear error', (
    tester,
  ) async {
    final detailApi = FakeThreadDetailBridgeApi(
      detailScriptByThreadId: {
        'thread-123': [_thread123Detail()],
      },
      timelineScriptByThreadId: {
        'thread-123': [<ThreadTimelineEntryDto>[]],
      },
      interruptTurnScriptByThreadId: {
        'thread-123': [
          const ThreadTurnBridgeException(
            message: 'Bridge could not deliver interrupt signal.',
          ),
        ],
      },
    );

    await _pumpThreadDetailApp(
      tester,
      detailApi: detailApi,
      threadId: 'thread-123',
    );

    await tester.tap(find.byKey(const Key('turn-interrupt-button')));
    await tester.pumpAndSettle();

    expect(
      find.text('Interrupt failed: Bridge could not deliver interrupt signal.'),
      findsOneWidget,
    );
    expect(find.text('Running'), findsOneWidget);
    expect(find.text('Steer turn'), findsOneWidget);
    expect(find.byKey(const Key('turn-interrupt-button')), findsOneWidget);
  });

  testWidgets(
    'live stream updates detail and syncs lifecycle status back to list',
    (tester) async {
      final listApi = FakeThreadListBridgeApi(
        scriptedResults: [_threadSummaries()],
      );
      final detailApi = FakeThreadDetailBridgeApi(
        detailScriptByThreadId: {
          'thread-123': [_thread123Detail()],
        },
        timelineScriptByThreadId: {
          'thread-123': [<ThreadTimelineEntryDto>[]],
        },
      );
      final liveStream = FakeThreadLiveStream();

      await _pumpThreadListApp(
        tester,
        listApi: listApi,
        detailApi: detailApi,
        liveStream: liveStream,
      );

      await tester.tap(find.byKey(const Key('thread-summary-card-thread-123')));
      await tester.pumpAndSettle();

      liveStream.emit(
        BridgeEventEnvelope<Map<String, dynamic>>(
          contractVersion: contractVersion,
          eventId: 'evt-live-1',
          threadId: 'thread-123',
          kind: BridgeEventKind.messageDelta,
          occurredAt: '2026-03-18T10:11:00Z',
          payload: {'delta': 'Streaming chunk from live output.'},
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Streaming chunk from live output.'), findsOneWidget);

      liveStream.emit(
        BridgeEventEnvelope<Map<String, dynamic>>(
          contractVersion: contractVersion,
          eventId: 'evt-live-2',
          threadId: 'thread-123',
          kind: BridgeEventKind.threadStatusChanged,
          occurredAt: '2026-03-18T10:12:00Z',
          payload: {'status': 'completed', 'reason': 'turn_complete'},
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Completed'), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.text('Completed'), findsOneWidget);
    },
  );

  testWidgets('timeline browsing loads earlier history in coherent order', (
    tester,
  ) async {
    final listApi = FakeThreadListBridgeApi(
      scriptedResults: [_threadSummaries()],
    );
    final detailApi = FakeThreadDetailBridgeApi(
      detailScriptByThreadId: {
        'thread-123': [_thread123Detail()],
      },
      timelineScriptByThreadId: {
        'thread-123': [
          [
            _timelineEvent(
              id: 'evt-1',
              kind: BridgeEventKind.messageDelta,
              summary: 'First visible after history load',
              payload: {'delta': 'Oldest event'},
              occurredAt: '2026-03-18T09:01:00Z',
            ),
            _timelineEvent(
              id: 'evt-2',
              kind: BridgeEventKind.messageDelta,
              summary: 'Second oldest event',
              payload: {'delta': 'Older event'},
              occurredAt: '2026-03-18T09:02:00Z',
            ),
            _timelineEvent(
              id: 'evt-3',
              kind: BridgeEventKind.messageDelta,
              summary: 'Recent event one',
              payload: {'delta': 'Recent event A'},
              occurredAt: '2026-03-18T09:03:00Z',
            ),
            _timelineEvent(
              id: 'evt-4',
              kind: BridgeEventKind.messageDelta,
              summary: 'Recent event two',
              payload: {'delta': 'Recent event B'},
              occurredAt: '2026-03-18T09:04:00Z',
            ),
          ],
        ],
      },
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          threadListBridgeApiProvider.overrideWithValue(listApi),
          approvalBridgeApiProvider.overrideWithValue(EmptyApprovalBridgeApi()),
          threadDetailBridgeApiProvider.overrideWithValue(detailApi),
          threadLiveStreamProvider.overrideWithValue(FakeThreadLiveStream()),
          threadCacheRepositoryProvider.overrideWithValue(
            _newCacheRepository(),
          ),
        ],
        child: const MaterialApp(
          home: ThreadDetailPage(
            bridgeApiBaseUrl: _bridgeApiBaseUrl,
            threadId: 'thread-123',
            initialVisibleTimelineEntries: 2,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Oldest event'), findsNothing);
    expect(find.text('Older event'), findsNothing);
    await _scrollUntilVisible(tester, find.text('Recent event A'));
    expect(find.text('Recent event A'), findsOneWidget);
    await _scrollUntilVisible(tester, find.text('Recent event B'));
    expect(find.text('Recent event B'), findsOneWidget);

    await tester.tap(find.byKey(const Key('load-earlier-history')));
    await tester.pumpAndSettle();

    await _scrollUntilVisible(tester, find.text('Oldest event'));
    expect(find.text('Oldest event'), findsOneWidget);
    expect(find.text('Older event'), findsOneWidget);
    final oldestY = tester.getTopLeft(find.text('Oldest event')).dy;
    final olderY = tester.getTopLeft(find.text('Older event')).dy;
    expect(oldestY, lessThan(olderY));

    await _scrollUntilVisible(tester, find.text('Recent event B'));
    final recentAY = tester.getTopLeft(find.text('Recent event A')).dy;
    final recentBY = tester.getTopLeft(find.text('Recent event B')).dy;
    expect(recentAY, lessThan(recentBY));
  });

  testWidgets(
    'switching threads keeps live updates scoped to selected thread',
    (tester) async {
      final listApi = FakeThreadListBridgeApi(
        scriptedResults: [_threadSummaries()],
      );
      final detailApi = FakeThreadDetailBridgeApi(
        detailScriptByThreadId: {
          'thread-123': [_thread123Detail()],
          'thread-456': [_thread456Detail()],
        },
        timelineScriptByThreadId: {
          'thread-123': [<ThreadTimelineEntryDto>[]],
          'thread-456': [<ThreadTimelineEntryDto>[]],
        },
      );
      final liveStream = FakeThreadLiveStream();

      await _pumpThreadListApp(
        tester,
        listApi: listApi,
        detailApi: detailApi,
        liveStream: liveStream,
      );

      await tester.tap(find.byKey(const Key('thread-summary-card-thread-123')));
      await tester.pumpAndSettle();

      liveStream.emit(
        BridgeEventEnvelope<Map<String, dynamic>>(
          contractVersion: contractVersion,
          eventId: 'evt-t2-1',
          threadId: 'thread-456',
          kind: BridgeEventKind.messageDelta,
          occurredAt: '2026-03-18T10:30:00Z',
          payload: {'delta': 'Should not appear on thread 123'},
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Should not appear on thread 123'), findsNothing);

      liveStream.emit(
        BridgeEventEnvelope<Map<String, dynamic>>(
          contractVersion: contractVersion,
          eventId: 'evt-t1-1',
          threadId: 'thread-123',
          kind: BridgeEventKind.messageDelta,
          occurredAt: '2026-03-18T10:30:05Z',
          payload: {'delta': 'Visible on thread 123'},
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Visible on thread 123'), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('thread-summary-card-thread-456')));
      await tester.pumpAndSettle();

      liveStream.emit(
        BridgeEventEnvelope<Map<String, dynamic>>(
          contractVersion: contractVersion,
          eventId: 'evt-t1-2',
          threadId: 'thread-123',
          kind: BridgeEventKind.messageDelta,
          occurredAt: '2026-03-18T10:31:00Z',
          payload: {'delta': 'Old thread update should stay hidden'},
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Old thread update should stay hidden'), findsNothing);

      liveStream.emit(
        BridgeEventEnvelope<Map<String, dynamic>>(
          contractVersion: contractVersion,
          eventId: 'evt-t2-2',
          threadId: 'thread-456',
          kind: BridgeEventKind.messageDelta,
          occurredAt: '2026-03-18T10:31:10Z',
          payload: {'delta': 'Visible on thread 456'},
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Visible on thread 456'), findsOneWidget);
    },
  );

  testWidgets('reopening threads restores previously selected thread context', (
    tester,
  ) async {
    final cacheRepository = _newCacheRepository();
    await cacheRepository.saveSelectedThreadId('thread-456');

    final listApi = FakeThreadListBridgeApi(
      scriptedResults: [_threadSummaries()],
    );
    final detailApi = FakeThreadDetailBridgeApi(
      detailScriptByThreadId: {
        'thread-456': [_thread456Detail()],
      },
      timelineScriptByThreadId: {
        'thread-456': [<ThreadTimelineEntryDto>[]],
      },
    );

    await _pumpThreadListApp(
      tester,
      listApi: listApi,
      detailApi: detailApi,
      liveStream: FakeThreadLiveStream(),
      cacheRepository: cacheRepository,
    );

    expect(find.byKey(const Key('thread-detail-thread-id')), findsOneWidget);
    expect(find.text('thread-456'), findsOneWidget);
    expect(find.text('Investigate reconnect dedup'), findsOneWidget);
  });

  testWidgets('unavailable thread detail shows retryable fallback state', (
    tester,
  ) async {
    final listApi = FakeThreadListBridgeApi(
      scriptedResults: [_threadSummaries()],
    );
    final detailApi = FakeThreadDetailBridgeApi(
      detailScriptByThreadId: {
        'thread-123': [
          const ThreadDetailBridgeException(
            message: 'Thread was archived remotely.',
            isUnavailable: true,
          ),
          _thread123Detail(),
        ],
      },
      timelineScriptByThreadId: {
        'thread-123': [<ThreadTimelineEntryDto>[], <ThreadTimelineEntryDto>[]],
      },
    );

    await _pumpThreadListApp(
      tester,
      listApi: listApi,
      detailApi: detailApi,
      liveStream: FakeThreadLiveStream(),
    );

    await tester.tap(find.byKey(const Key('thread-summary-card-thread-123')));
    await tester.pumpAndSettle();

    expect(find.text('Thread unavailable'), findsOneWidget);
    expect(find.text('Thread was archived remotely.'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(find.text('Thread unavailable'), findsNothing);
    expect(find.text('Implement shared contracts'), findsOneWidget);
  });

  testWidgets(
    'offline mode keeps cached thread detail readable and blocks mutating actions',
    (tester) async {
      final cacheRepository = _newCacheRepository();
      await cacheRepository.saveThreadList(_threadSummaries());
      await cacheRepository.saveThreadDetail(
        detail: _thread123Detail(),
        timeline: _mixedTimelineEvents(),
      );

      final detailApi = FakeThreadDetailBridgeApi(
        detailScriptByThreadId: {
          'thread-123': [
            const ThreadDetailBridgeException(
              message: 'Cannot reach the bridge. Check your private route.',
              isConnectivityError: true,
            ),
          ],
        },
        timelineScriptByThreadId: {
          'thread-123': [
            const ThreadDetailBridgeException(
              message: 'Cannot reach the bridge. Check your private route.',
              isConnectivityError: true,
            ),
          ],
        },
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            threadListBridgeApiProvider.overrideWithValue(
              FakeThreadListBridgeApi(scriptedResults: [_threadSummaries()]),
            ),
            approvalBridgeApiProvider.overrideWithValue(
              EmptyApprovalBridgeApi(),
            ),
            threadDetailBridgeApiProvider.overrideWithValue(detailApi),
            threadLiveStreamProvider.overrideWithValue(FakeThreadLiveStream()),
            threadCacheRepositoryProvider.overrideWithValue(cacheRepository),
          ],
          child: const MaterialApp(
            home: ThreadDetailPage(
              bridgeApiBaseUrl: _bridgeApiBaseUrl,
              threadId: 'thread-123',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Implement shared contracts'), findsOneWidget);
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
    'disconnect keeps existing items deduplicated and exposes reconnect controls',
    (tester) async {
      final listApi = FakeThreadListBridgeApi(
        scriptedResults: [_threadSummaries()],
      );
      final detailApi = FakeThreadDetailBridgeApi(
        detailScriptByThreadId: {
          'thread-123': [_thread123Detail(), _thread123Detail()],
        },
        timelineScriptByThreadId: {
          'thread-123': [
            [
              _timelineEvent(
                id: 'evt-history-1',
                kind: BridgeEventKind.messageDelta,
                summary: 'Initial history event',
                payload: {'delta': 'Initial history event'},
                occurredAt: '2026-03-18T10:00:00Z',
              ),
            ],
            [
              _timelineEvent(
                id: 'evt-history-1',
                kind: BridgeEventKind.messageDelta,
                summary: 'Initial history event',
                payload: {'delta': 'Initial history event'},
                occurredAt: '2026-03-18T10:00:00Z',
              ),
              _timelineEvent(
                id: 'evt-live-1',
                kind: BridgeEventKind.messageDelta,
                summary: 'Streaming chunk from live output.',
                payload: {'delta': 'Streaming chunk from live output.'},
                occurredAt: '2026-03-18T10:01:00Z',
              ),
              _timelineEvent(
                id: 'evt-catchup-1',
                kind: BridgeEventKind.messageDelta,
                summary: 'Caught up after reconnect.',
                payload: {'delta': 'Caught up after reconnect.'},
                occurredAt: '2026-03-18T10:02:00Z',
              ),
            ],
          ],
        },
      );
      final liveStream = FakeThreadLiveStream();

      await _pumpThreadListApp(
        tester,
        listApi: listApi,
        detailApi: detailApi,
        liveStream: liveStream,
      );

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

      expect(find.byKey(const Key('retry-reconnect-catchup')), findsOneWidget);
      await tester.tap(find.byKey(const Key('retry-reconnect-catchup')));
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

Future<void> _pumpThreadListApp(
  WidgetTester tester, {
  required ThreadListBridgeApi listApi,
  required ThreadDetailBridgeApi detailApi,
  required ThreadLiveStream liveStream,
  ThreadCacheRepository? cacheRepository,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        threadListBridgeApiProvider.overrideWithValue(listApi),
        approvalBridgeApiProvider.overrideWithValue(EmptyApprovalBridgeApi()),
        threadDetailBridgeApiProvider.overrideWithValue(detailApi),
        threadLiveStreamProvider.overrideWithValue(liveStream),
        threadCacheRepositoryProvider.overrideWithValue(
          cacheRepository ?? _newCacheRepository(),
        ),
      ],
      child: const MaterialApp(
        home: ThreadListPage(bridgeApiBaseUrl: _bridgeApiBaseUrl),
      ),
    ),
  );

  await tester.pumpAndSettle();
}

Future<void> _pumpThreadDetailApp(
  WidgetTester tester, {
  required ThreadDetailBridgeApi detailApi,
  required String threadId,
  ThreadListBridgeApi? listApi,
  ThreadLiveStream? liveStream,
  ThreadCacheRepository? cacheRepository,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        threadListBridgeApiProvider.overrideWithValue(
          listApi ??
              FakeThreadListBridgeApi(scriptedResults: [_threadSummaries()]),
        ),
        approvalBridgeApiProvider.overrideWithValue(EmptyApprovalBridgeApi()),
        threadDetailBridgeApiProvider.overrideWithValue(detailApi),
        threadLiveStreamProvider.overrideWithValue(
          liveStream ?? FakeThreadLiveStream(),
        ),
        threadCacheRepositoryProvider.overrideWithValue(
          cacheRepository ?? _newCacheRepository(),
        ),
      ],
      child: MaterialApp(
        home: ThreadDetailPage(
          bridgeApiBaseUrl: _bridgeApiBaseUrl,
          threadId: threadId,
        ),
      ),
    ),
  );

  await tester.pumpAndSettle();
}

Future<void> _scrollUntilVisible(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    240,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

ThreadCacheRepository _newCacheRepository({
  InMemorySecureStore? store,
  DateTime Function()? nowUtc,
}) {
  return SecureStoreThreadCacheRepository(
    secureStore: store ?? InMemorySecureStore(),
    nowUtc: nowUtc ?? () => DateTime.utc(2026, 3, 18, 10, 0),
  );
}

const _bridgeApiBaseUrl = 'https://bridge.ts.net';

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

ThreadDetailDto _thread123Detail() {
  return const ThreadDetailDto(
    contractVersion: contractVersion,
    threadId: 'thread-123',
    title: 'Implement shared contracts',
    status: ThreadStatus.running,
    workspace: '/workspace/codex-mobile-companion',
    repository: 'codex-mobile-companion',
    branch: 'master',
    createdAt: '2026-03-18T09:45:00Z',
    updatedAt: '2026-03-18T10:00:00Z',
    source: 'cli',
    accessMode: AccessMode.controlWithApprovals,
    lastTurnSummary: 'Normalize event payloads',
  );
}

ThreadDetailDto _thread456Detail() {
  return const ThreadDetailDto(
    contractVersion: contractVersion,
    threadId: 'thread-456',
    title: 'Investigate reconnect dedup',
    status: ThreadStatus.idle,
    workspace: '/workspace/codex-runtime-tools',
    repository: 'codex-runtime-tools',
    branch: 'develop',
    createdAt: '2026-03-18T08:45:00Z',
    updatedAt: '2026-03-18T09:30:00Z',
    source: 'cli',
    accessMode: AccessMode.controlWithApprovals,
    lastTurnSummary: 'Idle',
  );
}

List<ThreadTimelineEntryDto> _mixedTimelineEvents() {
  return [
    _timelineEvent(
      id: 'evt-1',
      kind: BridgeEventKind.messageDelta,
      summary: 'User prompt',
      payload: {
        'type': 'userMessage',
        'content': [
          {'text': 'Please summarize the latest bridge logs.'},
        ],
      },
      occurredAt: '2026-03-18T10:01:00Z',
    ),
    _timelineEvent(
      id: 'evt-2',
      kind: BridgeEventKind.messageDelta,
      summary: 'Assistant output',
      payload: {'delta': 'Sure, gathering the latest output now.'},
      occurredAt: '2026-03-18T10:02:00Z',
    ),
    _timelineEvent(
      id: 'evt-3',
      kind: BridgeEventKind.planDelta,
      summary: 'Plan updated',
      payload: {'instruction': 'Collect logs and summarize failures'},
      occurredAt: '2026-03-18T10:03:00Z',
    ),
    _timelineEvent(
      id: 'evt-4',
      kind: BridgeEventKind.commandDelta,
      summary: 'Command output',
      payload: {
        'command': 'tail -n 100 app.log',
        'delta': 'running diagnostics...',
      },
      occurredAt: '2026-03-18T10:04:00Z',
    ),
    _timelineEvent(
      id: 'evt-5',
      kind: BridgeEventKind.fileChange,
      summary: 'File change',
      payload: {'path': 'lib/main.dart', 'summary': 'Adjusted parser mapping'},
      occurredAt: '2026-03-18T10:05:00Z',
    ),
  ];
}

ThreadTimelineEntryDto _timelineEvent({
  required String id,
  required BridgeEventKind kind,
  required String summary,
  required Map<String, dynamic> payload,
  required String occurredAt,
}) {
  return ThreadTimelineEntryDto(
    eventId: id,
    kind: kind,
    occurredAt: occurredAt,
    summary: summary,
    payload: payload,
  );
}

TurnMutationResult _turnMutationResult({
  required String threadId,
  required String operation,
  required ThreadStatus status,
  required String message,
}) {
  return TurnMutationResult(
    contractVersion: contractVersion,
    threadId: threadId,
    operation: operation,
    outcome: 'success',
    message: message,
    threadStatus: status,
  );
}

class FakeThreadDetailBridgeApi implements ThreadDetailBridgeApi {
  FakeThreadDetailBridgeApi({
    required Map<String, List<Object>> detailScriptByThreadId,
    required Map<String, List<Object>> timelineScriptByThreadId,
    Map<String, List<Object>>? startTurnScriptByThreadId,
    Map<String, List<Object>>? steerTurnScriptByThreadId,
    Map<String, List<Object>>? interruptTurnScriptByThreadId,
  }) : _detailScriptByThreadId = detailScriptByThreadId,
       _timelineScriptByThreadId = timelineScriptByThreadId,
       _startTurnScriptByThreadId = startTurnScriptByThreadId ?? {},
       _steerTurnScriptByThreadId = steerTurnScriptByThreadId ?? {},
       _interruptTurnScriptByThreadId = interruptTurnScriptByThreadId ?? {};

  final Map<String, List<Object>> _detailScriptByThreadId;
  final Map<String, List<Object>> _timelineScriptByThreadId;
  final Map<String, List<Object>> _startTurnScriptByThreadId;
  final Map<String, List<Object>> _steerTurnScriptByThreadId;
  final Map<String, List<Object>> _interruptTurnScriptByThreadId;
  int detailFetchCount = 0;
  int timelineFetchCount = 0;
  final Map<String, List<String>> startTurnPromptsByThreadId =
      <String, List<String>>{};
  final Map<String, List<String>> steerTurnInstructionsByThreadId =
      <String, List<String>>{};
  final Map<String, int> interruptTurnCallsByThreadId = <String, int>{};

  @override
  Future<ThreadDetailDto> fetchThreadDetail({
    required String bridgeApiBaseUrl,
    required String threadId,
  }) async {
    detailFetchCount += 1;
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
    timelineFetchCount += 1;
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
    startTurnPromptsByThreadId
        .putIfAbsent(threadId, () => <String>[])
        .add(prompt);

    final script = _startTurnScriptByThreadId[threadId];
    if (script == null || script.isEmpty) {
      return _turnMutationResult(
        threadId: threadId,
        operation: 'turn_start',
        status: ThreadStatus.running,
        message: 'Turn started and streaming is active',
      );
    }

    final scriptedResult = _nextResult(_startTurnScriptByThreadId, threadId);
    if (scriptedResult is TurnMutationResult) {
      return scriptedResult;
    }
    if (scriptedResult is ThreadTurnBridgeException) {
      throw scriptedResult;
    }

    throw StateError('Unsupported start-turn scripted result: $scriptedResult');
  }

  @override
  Future<TurnMutationResult> steerTurn({
    required String bridgeApiBaseUrl,
    required String threadId,
    required String instruction,
  }) async {
    steerTurnInstructionsByThreadId
        .putIfAbsent(threadId, () => <String>[])
        .add(instruction);

    final script = _steerTurnScriptByThreadId[threadId];
    if (script == null || script.isEmpty) {
      return _turnMutationResult(
        threadId: threadId,
        operation: 'turn_steer',
        status: ThreadStatus.running,
        message: 'Steer instruction applied to active turn',
      );
    }

    final scriptedResult = _nextResult(_steerTurnScriptByThreadId, threadId);
    if (scriptedResult is TurnMutationResult) {
      return scriptedResult;
    }
    if (scriptedResult is ThreadTurnBridgeException) {
      throw scriptedResult;
    }

    throw StateError('Unsupported steer-turn scripted result: $scriptedResult');
  }

  @override
  Future<TurnMutationResult> interruptTurn({
    required String bridgeApiBaseUrl,
    required String threadId,
  }) async {
    interruptTurnCallsByThreadId.update(
      threadId,
      (count) => count + 1,
      ifAbsent: () => 1,
    );

    final script = _interruptTurnScriptByThreadId[threadId];
    if (script == null || script.isEmpty) {
      return _turnMutationResult(
        threadId: threadId,
        operation: 'turn_interrupt',
        status: ThreadStatus.interrupted,
        message: 'Interrupt signal sent to active turn',
      );
    }

    final scriptedResult = _nextResult(
      _interruptTurnScriptByThreadId,
      threadId,
    );
    if (scriptedResult is TurnMutationResult) {
      return scriptedResult;
    }
    if (scriptedResult is ThreadTurnBridgeException) {
      throw scriptedResult;
    }

    throw StateError(
      'Unsupported interrupt-turn scripted result: $scriptedResult',
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
    required String threadId,
  }) async {
    final controller =
        StreamController<BridgeEventEnvelope<Map<String, dynamic>>>();
    _controllersByThreadId
        .putIfAbsent(
          threadId,
          () => <StreamController<BridgeEventEnvelope<Map<String, dynamic>>>>[],
        )
        .add(controller);

    return ThreadLiveSubscription(
      events: controller.stream,
      close: () async {
        _controllersByThreadId[threadId]?.remove(controller);
        if (!controller.isClosed) {
          await controller.close();
        }
      },
    );
  }

  void emit(BridgeEventEnvelope<Map<String, dynamic>> event) {
    final controllers = _controllersByThreadId[event.threadId];
    if (controllers == null) {
      return;
    }

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
    final controllers = _controllersByThreadId[threadId];
    if (controllers == null) {
      return;
    }

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
    final controllers = _controllersByThreadId[threadId];
    if (controllers == null) {
      return;
    }

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

class EmptyApprovalBridgeApi implements ApprovalBridgeApi {
  @override
  Future<AccessMode> fetchAccessMode({required String bridgeApiBaseUrl}) async {
    return AccessMode.readOnly;
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
  }) {
    throw UnimplementedError();
  }

  @override
  Future<ApprovalResolutionResponseDto> reject({
    required String bridgeApiBaseUrl,
    required String approvalId,
  }) {
    throw UnimplementedError();
  }
}
