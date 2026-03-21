import 'dart:async';

import 'package:codex_mobile_companion/features/threads/application/thread_detail_controller.dart';
import 'package:codex_mobile_companion/features/threads/application/thread_list_controller.dart';
import 'package:codex_mobile_companion/features/threads/data/thread_cache_repository.dart';
import 'package:codex_mobile_companion/features/threads/data/thread_detail_bridge_api.dart';
import 'package:codex_mobile_companion/features/threads/data/thread_list_bridge_api.dart';
import 'package:codex_mobile_companion/features/threads/data/thread_live_stream.dart';
import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:codex_mobile_companion/foundation/storage/secure_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'thread-list reconnect keeps scheduling automatic retries after repeated failures',
    () async {
      final listApi = ScriptedThreadListBridgeApi(
        scriptedResults: [
          _threadSummaries(
            reconnectThreadStatus: ThreadStatus.completed,
            reconnectUpdatedAt: '2026-03-18T09:30:00Z',
          ),
          const ThreadListBridgeException(
            'Cannot reach the bridge. Check your private route.',
            isConnectivityError: true,
          ),
          const ThreadListBridgeException(
            'Cannot reach the bridge. Check your private route.',
            isConnectivityError: true,
          ),
          _threadSummaries(
            reconnectThreadStatus: ThreadStatus.running,
            reconnectUpdatedAt: '2026-03-18T12:00:00Z',
          ),
        ],
      );
      final liveStream = ScriptedThreadLiveStream();
      final controller = ThreadListController(
        bridgeApi: listApi,
        cacheRepository: _newCacheRepository(),
        liveStream: liveStream,
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
      );
      addTearDown(controller.dispose);

      await _waitUntil(
        () => listApi.fetchCallCount >= 1 && liveStream.totalSubscriptions >= 1,
      );

      liveStream.emitErrorAll();
      await _waitUntil(() => controller.state.hasStaleMessage);

      await Future<void>.delayed(const Duration(seconds: 7));

      expect(listApi.fetchCallCount, greaterThanOrEqualTo(4));
      expect(
        controller.state.threads
            .firstWhere((thread) => thread.threadId == 'thread-456')
            .status,
        ThreadStatus.running,
      );
    },
  );

  test(
    'thread-detail reconnect keeps scheduling catch-up retries after repeated failures',
    () async {
      final listController = ThreadListController(
        bridgeApi: ScriptedThreadListBridgeApi(
          scriptedResults: [
            _threadSummaries(
              reconnectThreadStatus: ThreadStatus.idle,
              reconnectUpdatedAt: '2026-03-18T09:30:00Z',
            ),
          ],
        ),
        cacheRepository: _newCacheRepository(),
        liveStream: ScriptedThreadLiveStream(),
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
      );
      addTearDown(listController.dispose);

      final detailApi = ScriptedThreadDetailBridgeApi(
        detailScriptByThreadId: {
          'thread-123': [
            const ThreadDetailBridgeException(
              message: 'Cannot reach the bridge. Check your private route.',
              isConnectivityError: true,
            ),
            const ThreadDetailBridgeException(
              message: 'Cannot reach the bridge. Check your private route.',
              isConnectivityError: true,
            ),
            _thread123Detail(),
          ],
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
              _timelineEvent(
                id: 'evt-catchup-2',
                kind: BridgeEventKind.messageDelta,
                summary: 'Recovered after repeated reconnect failures.',
                payload: {
                  'delta': 'Recovered after repeated reconnect failures.',
                },
                occurredAt: '2026-03-18T10:03:00Z',
              ),
            ],
          ],
        },
      );

      final detailController = ThreadDetailController(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
        threadId: 'thread-123',
        initialVisibleTimelineEntries: 20,
        bridgeApi: detailApi,
        liveStream: ScriptedThreadLiveStream(),
        threadListController: listController,
      );
      addTearDown(detailController.dispose);

      await _waitUntil(() => !detailController.state.isLoading);
      expect(detailApi.detailFetchCount, 1);

      await detailController.retryReconnectCatchUp();
      await Future<void>.delayed(const Duration(seconds: 5));

      expect(detailApi.detailFetchCount, greaterThanOrEqualTo(3));
      expect(
        detailController.state.items.any(
          (item) => item.eventId == 'evt-catchup-2',
        ),
        isTrue,
      );
    },
  );

  test(
    'thread-detail logs when the first assistant message arrives after submit',
    () async {
      final listController = ThreadListController(
        bridgeApi: ScriptedThreadListBridgeApi(
          scriptedResults: [
            _threadSummaries(
              reconnectThreadStatus: ThreadStatus.idle,
              reconnectUpdatedAt: '2026-03-18T09:30:00Z',
            ),
          ],
        ),
        cacheRepository: _newCacheRepository(),
        liveStream: ScriptedThreadLiveStream(),
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
      );
      addTearDown(listController.dispose);

      final detailApi = ScriptedThreadDetailBridgeApi(
        detailScriptByThreadId: {
          'thread-123': [
            const ThreadDetailDto(
              contractVersion: contractVersion,
              threadId: 'thread-123',
              title: 'Implement shared contracts',
              status: ThreadStatus.idle,
              workspace: '/workspace/codex-mobile-companion',
              repository: 'codex-mobile-companion',
              branch: 'master',
              createdAt: '2026-03-18T09:45:00Z',
              updatedAt: '2026-03-18T10:00:00Z',
              source: 'cli',
              accessMode: AccessMode.controlWithApprovals,
              lastTurnSummary: 'Normalize event payloads',
            ),
          ],
        },
        timelineScriptByThreadId: {
          'thread-123': [<ThreadTimelineEntryDto>[]],
        },
      );
      final liveStream = ScriptedThreadLiveStream();
      final logs = <String>[];

      final detailController = ThreadDetailController(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
        threadId: 'thread-123',
        initialVisibleTimelineEntries: 20,
        bridgeApi: detailApi,
        liveStream: liveStream,
        threadListController: listController,
        debugLog: logs.add,
      );
      addTearDown(detailController.dispose);

      await _waitUntil(() => !detailController.state.isLoading);

      final submitted = await detailController.submitComposerInput(
        'Log when the assistant replies.',
      );
      expect(submitted, isTrue);

      liveStream.emit(
        BridgeEventEnvelope<Map<String, dynamic>>(
          contractVersion: contractVersion,
          eventId: 'evt-assistant-1',
          threadId: 'thread-123',
          kind: BridgeEventKind.messageDelta,
          occurredAt: '2026-03-18T10:04:00Z',
          payload: {'delta': 'Here is the first streamed reply chunk.'},
        ),
      );

      await _waitUntil(
        () => logs.any(
          (entry) => entry.contains('thread_detail_response_received'),
        ),
      );

      final responseLogs = logs
          .where((entry) => entry.contains('thread_detail_response_received'))
          .toList(growable: false);
      expect(responseLogs, hasLength(1));
      expect(responseLogs.single, contains('threadId=thread-123'));
      expect(responseLogs.single, contains('eventId=evt-assistant-1'));
      expect(responseLogs.single, contains('elapsedMs='));
      expect(responseLogs.single, contains('chars=39'));
    },
  );

  test(
    'thread-detail keeps the accumulated assistant message body during live deltas',
    () async {
      final listController = ThreadListController(
        bridgeApi: ScriptedThreadListBridgeApi(
          scriptedResults: [
            _threadSummaries(
              reconnectThreadStatus: ThreadStatus.idle,
              reconnectUpdatedAt: '2026-03-18T09:30:00Z',
            ),
          ],
        ),
        cacheRepository: _newCacheRepository(),
        liveStream: ScriptedThreadLiveStream(),
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
      );
      addTearDown(listController.dispose);

      final detailApi = ScriptedThreadDetailBridgeApi(
        detailScriptByThreadId: {
          'thread-123': [
            const ThreadDetailDto(
              contractVersion: contractVersion,
              threadId: 'thread-123',
              title: 'Implement shared contracts',
              status: ThreadStatus.idle,
              workspace: '/workspace/codex-mobile-companion',
              repository: 'codex-mobile-companion',
              branch: 'master',
              createdAt: '2026-03-18T09:45:00Z',
              updatedAt: '2026-03-18T10:00:00Z',
              source: 'cli',
              accessMode: AccessMode.controlWithApprovals,
              lastTurnSummary: 'Normalize event payloads',
            ),
          ],
        },
        timelineScriptByThreadId: {
          'thread-123': [<ThreadTimelineEntryDto>[]],
        },
      );
      final liveStream = ScriptedThreadLiveStream();
      final logs = <String>[];

      final detailController = ThreadDetailController(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
        threadId: 'thread-123',
        initialVisibleTimelineEntries: 20,
        bridgeApi: detailApi,
        liveStream: liveStream,
        threadListController: listController,
        debugLog: logs.add,
      );
      addTearDown(detailController.dispose);

      await _waitUntil(() => !detailController.state.isLoading);
      await _waitUntil(() => liveStream.totalSubscriptions >= 1);

      liveStream.emit(
        BridgeEventEnvelope<Map<String, dynamic>>(
          contractVersion: contractVersion,
          eventId: 'evt-assistant-1',
          threadId: 'thread-123',
          kind: BridgeEventKind.messageDelta,
          occurredAt: '2026-03-18T10:04:00Z',
          payload: {'delta': 'Hello', 'replace': true},
        ),
      );
      await _waitUntil(() => detailController.state.items.isNotEmpty);

      liveStream.emit(
        BridgeEventEnvelope<Map<String, dynamic>>(
          contractVersion: contractVersion,
          eventId: 'evt-assistant-1',
          threadId: 'thread-123',
          kind: BridgeEventKind.messageDelta,
          occurredAt: '2026-03-18T10:04:01Z',
          payload: {'delta': ' there.'},
        ),
      );

      await _waitUntil(
        () =>
            detailController.state.items.length == 1 &&
            detailController.state.items.single.body == 'Hello there.',
      );

      expect(detailController.state.items, hasLength(1));
      expect(detailController.state.items.single.body, 'Hello there.');
      expect(
        logs.where((entry) => entry.contains('thread_detail_live_event')),
        hasLength(2),
      );
    },
  );
}

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 3),
  Duration step = const Duration(milliseconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) {
      return;
    }
    await Future<void>.delayed(step);
  }

  if (!condition()) {
    fail('Timed out while waiting for expected asynchronous condition.');
  }
}

ThreadCacheRepository _newCacheRepository() {
  return SecureStoreThreadCacheRepository(
    secureStore: InMemorySecureStore(),
    nowUtc: () => DateTime.utc(2026, 3, 18, 10, 0),
  );
}

const _bridgeApiBaseUrl = 'https://bridge.ts.net';

List<ThreadSummaryDto> _threadSummaries({
  required ThreadStatus reconnectThreadStatus,
  required String reconnectUpdatedAt,
}) {
  return [
    const ThreadSummaryDto(
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
      status: reconnectThreadStatus,
      workspace: '/workspace/codex-runtime-tools',
      repository: 'codex-runtime-tools',
      branch: 'develop',
      updatedAt: reconnectUpdatedAt,
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

class ScriptedThreadListBridgeApi implements ThreadListBridgeApi {
  ScriptedThreadListBridgeApi({required this.scriptedResults});

  final List<Object> scriptedResults;
  int _nextResultIndex = 0;
  int fetchCallCount = 0;

  @override
  Future<List<ThreadSummaryDto>> fetchThreads({
    required String bridgeApiBaseUrl,
  }) async {
    fetchCallCount += 1;

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

class ScriptedThreadDetailBridgeApi implements ThreadDetailBridgeApi {
  ScriptedThreadDetailBridgeApi({
    required Map<String, List<Object>> detailScriptByThreadId,
    required Map<String, List<Object>> timelineScriptByThreadId,
  }) : _detailScriptByThreadId = detailScriptByThreadId,
       _timelineScriptByThreadId = timelineScriptByThreadId;

  final Map<String, List<Object>> _detailScriptByThreadId;
  final Map<String, List<Object>> _timelineScriptByThreadId;
  int detailFetchCount = 0;

  @override
  Future<ModelCatalogDto> fetchModelCatalog({
    required String bridgeApiBaseUrl,
  }) async {
    return fallbackModelCatalog;
  }

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
  Future<ThreadTimelinePageDto> fetchThreadTimelinePage({
    required String bridgeApiBaseUrl,
    required String threadId,
    String? before,
    int limit = 50,
  }) async {
    final detail = _detailScriptByThreadId[threadId]
        ?.whereType<ThreadDetailDto>()
        .cast<ThreadDetailDto?>()
        .firstWhere((entry) => entry != null, orElse: () => null);
    if (detail == null) {
      throw StateError('Missing scripted detail for thread "$threadId".');
    }

    final entries = await fetchThreadTimeline(
      bridgeApiBaseUrl: bridgeApiBaseUrl,
      threadId: threadId,
    );
    final endIndex = before == null
        ? entries.length
        : entries.indexWhere((entry) => entry.eventId == before);
    final normalizedEndIndex = endIndex < 0 ? entries.length : endIndex;
    final startIndex = normalizedEndIndex - limit < 0
        ? 0
        : normalizedEndIndex - limit;
    final pageEntries = entries.sublist(startIndex, normalizedEndIndex);
    final hasMoreBefore = startIndex > 0;
    return ThreadTimelinePageDto(
      contractVersion: contractVersion,
      thread: detail,
      entries: pageEntries,
      nextBefore: hasMoreBefore ? entries[startIndex].eventId : null,
      hasMoreBefore: hasMoreBefore,
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
  Future<TurnMutationResult> interruptTurn({
    required String bridgeApiBaseUrl,
    required String threadId,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<TurnMutationResult> startTurn({
    required String bridgeApiBaseUrl,
    required String threadId,
    required String prompt,
  }) {
    return Future<TurnMutationResult>.value(
      TurnMutationResult(
        contractVersion: contractVersion,
        threadId: threadId,
        operation: 'turn_start',
        outcome: 'accepted',
        threadStatus: ThreadStatus.running,
        message: 'Turn started and streaming is active',
      ),
    );
  }

  @override
  Future<TurnMutationResult> steerTurn({
    required String bridgeApiBaseUrl,
    required String threadId,
    required String instruction,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<MutationResultResponseDto> pullRepository({
    required String bridgeApiBaseUrl,
    required String threadId,
    String? remote,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<MutationResultResponseDto> pushRepository({
    required String bridgeApiBaseUrl,
    required String threadId,
    String? remote,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<MutationResultResponseDto> switchBranch({
    required String bridgeApiBaseUrl,
    required String threadId,
    required String branch,
  }) {
    throw UnimplementedError();
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

class ScriptedThreadLiveStream implements ThreadLiveStream {
  final List<StreamController<BridgeEventEnvelope<Map<String, dynamic>>>>
  _controllers =
      <StreamController<BridgeEventEnvelope<Map<String, dynamic>>>>[];

  int totalSubscriptions = 0;

  @override
  Future<ThreadLiveSubscription> subscribe({
    required String bridgeApiBaseUrl,
    String? threadId,
  }) async {
    totalSubscriptions += 1;
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

  void emitErrorAll() {
    for (final controller
        in List<
          StreamController<BridgeEventEnvelope<Map<String, dynamic>>>
        >.from(_controllers)) {
      if (!controller.isClosed) {
        controller.addError(StateError('stream disconnected'));
      }
    }
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
