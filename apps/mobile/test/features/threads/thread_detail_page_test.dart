import 'dart:async';

import 'package:codex_mobile_companion/features/threads/data/thread_detail_bridge_api.dart';
import 'package:codex_mobile_companion/features/threads/data/thread_list_bridge_api.dart';
import 'package:codex_mobile_companion/features/threads/data/thread_live_stream.dart';
import 'package:codex_mobile_companion/features/threads/presentation/thread_detail_page.dart';
import 'package:codex_mobile_companion/features/threads/presentation/thread_list_page.dart';
import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'opening a thread shows matching detail and mixed item types distinctly',
    (tester) async {
      final listApi = FakeThreadListBridgeApi(scriptedResults: [_threadSummaries()]);
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
      expect(find.text('User prompt'), findsOneWidget);
      expect(find.text('Assistant output'), findsOneWidget);
      expect(find.text('Plan update'), findsOneWidget);
      expect(find.text('Terminal output'), findsOneWidget);
      expect(find.text('File change'), findsOneWidget);
      expect(find.textContaining('tail -n 100 app.log'), findsOneWidget);
      expect(find.textContaining('lib/main.dart'), findsOneWidget);
    },
  );

  testWidgets('live stream updates detail and syncs lifecycle status back to list', (
    tester,
  ) async {
    final listApi = FakeThreadListBridgeApi(scriptedResults: [_threadSummaries()]);
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
  });

  testWidgets('timeline browsing loads earlier history in coherent order', (
    tester,
  ) async {
    final listApi = FakeThreadListBridgeApi(scriptedResults: [_threadSummaries()]);
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
          threadDetailBridgeApiProvider.overrideWithValue(detailApi),
          threadLiveStreamProvider.overrideWithValue(FakeThreadLiveStream()),
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
    expect(find.text('Recent event A'), findsOneWidget);
    expect(find.text('Recent event B'), findsOneWidget);

    await tester.tap(find.byKey(const Key('load-earlier-history')));
    await tester.pumpAndSettle();

    expect(find.text('Oldest event'), findsOneWidget);
    expect(find.text('Older event'), findsOneWidget);

    final oldestY = tester.getTopLeft(find.text('Oldest event')).dy;
    final olderY = tester.getTopLeft(find.text('Older event')).dy;
    final recentAY = tester.getTopLeft(find.text('Recent event A')).dy;
    final recentBY = tester.getTopLeft(find.text('Recent event B')).dy;

    expect(oldestY, lessThan(olderY));
    expect(olderY, lessThan(recentAY));
    expect(recentAY, lessThan(recentBY));
  });

  testWidgets('switching threads keeps live updates scoped to selected thread', (
    tester,
  ) async {
    final listApi = FakeThreadListBridgeApi(scriptedResults: [_threadSummaries()]);
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
  });

  testWidgets('unavailable thread detail shows retryable fallback state', (
    tester,
  ) async {
    final listApi = FakeThreadListBridgeApi(scriptedResults: [_threadSummaries()]);
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
}

Future<void> _pumpThreadListApp(
  WidgetTester tester, {
  required ThreadListBridgeApi listApi,
  required ThreadDetailBridgeApi detailApi,
  required ThreadLiveStream liveStream,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        threadListBridgeApiProvider.overrideWithValue(listApi),
        threadDetailBridgeApiProvider.overrideWithValue(detailApi),
        threadLiveStreamProvider.overrideWithValue(liveStream),
      ],
      child: const MaterialApp(
        home: ThreadListPage(bridgeApiBaseUrl: _bridgeApiBaseUrl),
      ),
    ),
  );

  await tester.pumpAndSettle();
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

  Object _nextResult(Map<String, List<Object>> scriptByThreadId, String threadId) {
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
  final Map<String, List<StreamController<BridgeEventEnvelope<Map<String, dynamic>>>>>
  _controllersByThreadId =
      <String, List<StreamController<BridgeEventEnvelope<Map<String, dynamic>>>>>{};

  @override
  Future<ThreadLiveSubscription> subscribe({
    required String bridgeApiBaseUrl,
    required String threadId,
  }) async {
    final controller = StreamController<BridgeEventEnvelope<Map<String, dynamic>>>();
    _controllersByThreadId.putIfAbsent(threadId, () => <StreamController<BridgeEventEnvelope<Map<String, dynamic>>>>[]).add(controller);

    return ThreadLiveSubscription(
      events: controller.stream,
      close: () async {
        _controllersByThreadId[threadId]?.remove(controller);
        await controller.close();
      },
    );
  }

  void emit(BridgeEventEnvelope<Map<String, dynamic>> event) {
    final controllers = _controllersByThreadId[event.threadId];
    if (controllers == null) {
      return;
    }

    for (final controller in List<StreamController<BridgeEventEnvelope<Map<String, dynamic>>>>.from(controllers)) {
      if (!controller.isClosed) {
        controller.add(event);
      }
    }
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
