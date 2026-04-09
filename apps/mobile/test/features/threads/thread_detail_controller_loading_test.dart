import 'dart:async';

import 'package:vibe_bridge/features/threads/application/thread_detail_controller.dart';
import 'package:vibe_bridge/features/threads/application/thread_list_controller.dart';
import 'package:vibe_bridge/features/threads/data/thread_cache_repository.dart';
import 'package:vibe_bridge/features/threads/data/thread_detail_bridge_api.dart';
import 'package:vibe_bridge/features/threads/data/thread_list_bridge_api.dart';
import 'package:vibe_bridge/features/threads/data/thread_live_stream.dart';
import 'package:vibe_bridge/foundation/contracts/bridge_contracts.dart';
import 'package:vibe_bridge/foundation/logging/thread_diagnostics.dart';
import 'package:vibe_bridge/foundation/storage/secure_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('loadThread records diagnostics when timeline fetch fails', () async {
    final diagnostics = _RecordingThreadDiagnosticsService();
    final listController = ThreadListController(
      bridgeApi: _StaticThreadListBridgeApi(),
      cacheRepository: _newCacheRepository(),
      liveStream: _IdleThreadLiveStream(),
      bridgeApiBaseUrl: _bridgeApiBaseUrl,
    );
    addTearDown(listController.dispose);

    final controller = ThreadDetailController(
      bridgeApiBaseUrl: _bridgeApiBaseUrl,
      threadId: 'codex:thread-123',
      initialVisibleTimelineEntries: 80,
      bridgeApi: _ScriptedThreadDetailBridgeApi(
        detail: _threadDetail(),
        timelineError: const ThreadDetailBridgeException(
          message: 'Couldn’t load thread history right now.',
        ),
      ),
      liveStream: _IdleThreadLiveStream(),
      threadListController: listController,
      diagnostics: diagnostics,
    );
    addTearDown(controller.dispose);

    await _waitUntil(
      () => diagnostics.records.any(
        (record) => record.kind == 'thread_load_failed',
      ),
    );

    final failure = diagnostics.records.lastWhere(
      (record) => record.kind == 'thread_load_failed',
    );
    expect(failure.threadId, 'codex:thread-123');
    expect(failure.data['phase'], 'fetch_thread_timeline');
    expect(failure.data['error'], 'Couldn’t load thread history right now.');
    expect(
      controller.state.errorMessage,
      'Couldn’t load thread history right now.',
    );
    expect(controller.state.isLoading, isFalse);
  });

  test('loadThread tolerates malformed command output in timeline entries', () async {
    final diagnostics = _RecordingThreadDiagnosticsService();
    final listController = ThreadListController(
      bridgeApi: _StaticThreadListBridgeApi(),
      cacheRepository: _newCacheRepository(),
      liveStream: _IdleThreadLiveStream(),
      bridgeApiBaseUrl: _bridgeApiBaseUrl,
    );
    addTearDown(listController.dispose);

    final controller = ThreadDetailController(
      bridgeApiBaseUrl: _bridgeApiBaseUrl,
      threadId: 'codex:thread-123',
      initialVisibleTimelineEntries: 80,
      bridgeApi: _ScriptedThreadDetailBridgeApi(
        detail: _threadDetail(),
        timelinePageScript: <Object>[
          ThreadTimelinePageDto(
            contractVersion: contractVersion,
            thread: _threadDetail(),
            entries: <ThreadTimelineEntryDto>[
              ThreadTimelineEntryDto(
                eventId: 'event-1',
                kind: BridgeEventKind.commandDelta,
                occurredAt: '2026-04-08T10:05:00Z',
                summary: 'Background terminal finished',
                payload: <String, dynamic>{
                  'output': '''
random prefix
*** End Patch
still terminal output
*** Begin Patch
*** Update File: apps/mobile/lib/main.dart
+hello
''',
                },
              ),
            ],
            nextBefore: null,
            hasMoreBefore: false,
          ),
        ],
      ),
      liveStream: _IdleThreadLiveStream(),
      threadListController: listController,
      diagnostics: diagnostics,
    );
    addTearDown(controller.dispose);

    await _waitUntil(() => controller.state.isLoading == false);

    expect(controller.state.errorMessage, isNull);
    expect(controller.state.items, hasLength(1));
    expect(controller.state.items.single.type, ThreadActivityItemType.fileChange);
    expect(controller.state.items.single.body, contains('*** Begin Patch'));
    expect(
      diagnostics.records.any((record) => record.kind == 'thread_load_failed'),
      isFalse,
    );
  });

  test(
    'loadEarlierHistory records diagnostics when pagination throws',
    () async {
      final diagnostics = _RecordingThreadDiagnosticsService();
      final listController = ThreadListController(
        bridgeApi: _StaticThreadListBridgeApi(),
        cacheRepository: _newCacheRepository(),
        liveStream: _IdleThreadLiveStream(),
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
      );
      addTearDown(listController.dispose);

      final controller = ThreadDetailController(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
        threadId: 'codex:thread-123',
        initialVisibleTimelineEntries: 2,
        bridgeApi: _ScriptedThreadDetailBridgeApi(
          detail: _threadDetail(),
          timelinePageScript: <Object>[
            ThreadTimelinePageDto(
              contractVersion: contractVersion,
              thread: _threadDetail(),
              entries: const <ThreadTimelineEntryDto>[],
              nextBefore: 'evt-before-1',
              hasMoreBefore: true,
            ),
            StateError('pagination exploded'),
          ],
        ),
        liveStream: _IdleThreadLiveStream(),
        threadListController: listController,
        diagnostics: diagnostics,
      );
      addTearDown(controller.dispose);

      await _waitUntil(() => controller.state.isLoading == false);

      await controller.loadEarlierHistory();

      await _waitUntil(
        () => diagnostics.records.any(
          (record) => record.kind == 'thread_history_load_failed',
        ),
      );

      final failure = diagnostics.records.lastWhere(
        (record) => record.kind == 'thread_history_load_failed',
      );
      expect(failure.threadId, 'codex:thread-123');
      expect(failure.data['phase'], 'fetch_thread_timeline_before');
      expect(failure.data['errorType'], 'StateError');
      expect(
        controller.state.streamErrorMessage,
        'Couldn’t load older history right now.',
      );
    },
  );
}

const _bridgeApiBaseUrl = 'https://bridge.ts.net';

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
    nowUtc: () => DateTime.utc(2026, 4, 8, 12, 0),
  );
}

ThreadDetailDto _threadDetail() {
  return const ThreadDetailDto(
    contractVersion: contractVersion,
    threadId: 'codex:thread-123',
    title: 'Portable client large thread',
    status: ThreadStatus.completed,
    workspace: '/workspace/portable-client',
    repository: 'portable-client',
    branch: 'main',
    createdAt: '2026-04-08T10:00:00Z',
    updatedAt: '2026-04-08T10:30:00Z',
    source: 'cli',
    accessMode: AccessMode.controlWithApprovals,
    lastTurnSummary: 'Large archive thread for diagnostics.',
  );
}

class _StaticThreadListBridgeApi implements ThreadListBridgeApi {
  @override
  Future<List<ThreadSummaryDto>> fetchThreads({
    required String bridgeApiBaseUrl,
  }) async {
    return const <ThreadSummaryDto>[];
  }
}

class _IdleThreadLiveStream implements ThreadLiveStream {
  @override
  Future<ThreadLiveSubscription> subscribe({
    required String bridgeApiBaseUrl,
    String? threadId,
    int? afterSeq,
  }) async {
    final controller =
        StreamController<BridgeEventEnvelope<Map<String, dynamic>>>(sync: true);
    return ThreadLiveSubscription(
      events: controller.stream,
      close: () async {
        await controller.close();
      },
    );
  }
}

class _ScriptedThreadDetailBridgeApi extends ThreadDetailBridgeApi {
  _ScriptedThreadDetailBridgeApi({
    required this.detail,
    this.timelineError,
    List<Object>? timelinePageScript,
  }) : _timelinePageScript = timelinePageScript ?? <Object>[];

  final ThreadDetailDto detail;
  final ThreadDetailBridgeException? timelineError;
  final List<Object> _timelinePageScript;

  @override
  Future<ThreadSnapshotDto> createThread({
    required String bridgeApiBaseUrl,
    required String workspace,
    required ProviderKind provider,
    String? model,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<ThreadDetailDto> fetchThreadDetail({
    required String bridgeApiBaseUrl,
    required String threadId,
  }) async {
    return detail;
  }

  @override
  Future<GitStatusResponseDto> fetchGitStatus({
    required String bridgeApiBaseUrl,
    required String threadId,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<OpenOnMacResponseDto> openOnMac({
    required String bridgeApiBaseUrl,
    required String threadId,
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
  Future<TurnMutationResult> startTurn({
    required String bridgeApiBaseUrl,
    required String threadId,
    required String prompt,
    String? clientMessageId,
    String? clientTurnIntentId,
    TurnMode mode = TurnMode.act,
    List<String> images = const <String>[],
    String? model,
    String? effort,
  }) {
    throw UnimplementedError();
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
  Future<MutationResultResponseDto> switchBranch({
    required String bridgeApiBaseUrl,
    required String threadId,
    required String branch,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<ThreadTimelinePageDto> fetchThreadTimelinePage({
    required String bridgeApiBaseUrl,
    required String threadId,
    String? before,
    int limit = 50,
  }) async {
    if (_timelinePageScript.isNotEmpty) {
      final result = _timelinePageScript.first;
      if (_timelinePageScript.length > 1) {
        _timelinePageScript.removeAt(0);
      }
      if (result is ThreadTimelinePageDto) {
        return result;
      }
      if (result is Exception) {
        throw result;
      }
      if (result is Error) {
        throw result;
      }
      throw StateError('Unsupported timeline page result: $result');
    }
    if (timelineError != null) {
      throw timelineError!;
    }
    return ThreadTimelinePageDto(
      contractVersion: contractVersion,
      thread: detail,
      entries: const <ThreadTimelineEntryDto>[],
      nextBefore: null,
      hasMoreBefore: false,
    );
  }

  @override
  Future<List<ThreadTimelineEntryDto>> fetchThreadTimeline({
    required String bridgeApiBaseUrl,
    required String threadId,
  }) async {
    final page = await fetchThreadTimelinePage(
      bridgeApiBaseUrl: bridgeApiBaseUrl,
      threadId: threadId,
    );
    return page.entries;
  }

  @override
  Future<TurnMutationResult> interruptTurn({
    required String bridgeApiBaseUrl,
    required String threadId,
    String? turnId,
  }) {
    throw UnimplementedError();
  }
}

class _RecordingThreadDiagnosticsService extends ThreadDiagnosticsService {
  final List<_RecordedDiagnostic> records = <_RecordedDiagnostic>[];

  @override
  Future<void> record({
    required String kind,
    String? threadId,
    Map<String, Object?> data = const <String, Object?>{},
  }) {
    records.add(
      _RecordedDiagnostic(
        kind: kind,
        threadId: threadId,
        data: Map<String, Object?>.from(data),
      ),
    );
    return Future<void>.value();
  }
}

class _RecordedDiagnostic {
  const _RecordedDiagnostic({
    required this.kind,
    required this.threadId,
    required this.data,
  });

  final String kind;
  final String? threadId;
  final Map<String, Object?> data;
}
