import 'dart:async';

import 'package:vibe_bridge/features/threads/application/thread_detail_controller.dart';
import 'package:vibe_bridge/features/threads/application/thread_list_controller.dart';
import 'package:vibe_bridge/features/threads/data/thread_cache_repository.dart';
import 'package:vibe_bridge/features/threads/data/thread_detail_bridge_api.dart';
import 'package:vibe_bridge/features/threads/data/thread_list_bridge_api.dart';
import 'package:vibe_bridge/features/threads/data/thread_live_stream.dart';
import 'package:vibe_bridge/features/threads/domain/thread_activity_item.dart';
import 'package:vibe_bridge/foundation/connectivity/live_connection_state.dart';
import 'package:vibe_bridge/foundation/contracts/bridge_contracts.dart';
import 'package:vibe_bridge/foundation/storage/secure_store.dart';
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
      expect(
        controller.state.liveConnectionState,
        LiveConnectionState.connected,
      );
      expect(controller.state.hasStaleMessage, isFalse);
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
              workspace: '/workspace/vibe-bridge-companion',
              repository: 'vibe-bridge-companion',
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
              workspace: '/workspace/vibe-bridge-companion',
              repository: 'vibe-bridge-companion',
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

  test(
    'thread-detail skips snapshot timeline refresh after healthy live completion',
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
              workspace: '/workspace/vibe-bridge-companion',
              repository: 'vibe-bridge-companion',
              branch: 'master',
              createdAt: '2026-03-18T09:45:00Z',
              updatedAt: '2026-03-18T10:00:00Z',
              source: 'cli',
              accessMode: AccessMode.controlWithApprovals,
              lastTurnSummary: 'Normalize event payloads',
            ),
            const ThreadDetailDto(
              contractVersion: contractVersion,
              threadId: 'thread-123',
              title: 'Implement shared contracts',
              status: ThreadStatus.completed,
              workspace: '/workspace/vibe-bridge-companion',
              repository: 'vibe-bridge-companion',
              branch: 'master',
              createdAt: '2026-03-18T09:45:00Z',
              updatedAt: '2026-03-18T10:05:00Z',
              source: 'cli',
              accessMode: AccessMode.controlWithApprovals,
              lastTurnSummary: 'Patched tests cleanly.',
            ),
          ],
        },
        timelineScriptByThreadId: {
          'thread-123': [<ThreadTimelineEntryDto>[]],
        },
      );
      final liveStream = ScriptedThreadLiveStream();

      final detailController = ThreadDetailController(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
        threadId: 'thread-123',
        initialVisibleTimelineEntries: 20,
        bridgeApi: detailApi,
        liveStream: liveStream,
        threadListController: listController,
      );
      addTearDown(detailController.dispose);

      await _waitUntil(() => !detailController.state.isLoading);
      await _waitUntil(() => liveStream.totalSubscriptions >= 1);

      final submitted = await detailController.submitComposerInput(
        'Please stream this fix live.',
      );
      expect(submitted, isTrue);

      liveStream.emit(
        const BridgeEventEnvelope<Map<String, dynamic>>(
          contractVersion: contractVersion,
          eventId: 'evt-assistant-live',
          threadId: 'thread-123',
          kind: BridgeEventKind.messageDelta,
          occurredAt: '2026-03-18T10:04:00Z',
          payload: {
            'type': 'agentMessage',
            'role': 'assistant',
            'text': 'Streaming the fix live.',
          },
        ),
      );
      await _waitUntil(() => detailController.state.items.isNotEmpty);

      liveStream.emit(
        const BridgeEventEnvelope<Map<String, dynamic>>(
          contractVersion: contractVersion,
          eventId: 'evt-status-complete',
          threadId: 'thread-123',
          kind: BridgeEventKind.threadStatusChanged,
          occurredAt: '2026-03-18T10:04:02Z',
          payload: {'status': 'completed', 'reason': 'upstream_notification'},
        ),
      );

      await _waitUntil(() => detailApi.detailFetchCount >= 2);

      expect(detailController.state.thread?.status, ThreadStatus.completed);
      final assistantBodies = detailController.state.items
          .where((item) => item.type == ThreadActivityItemType.assistantOutput)
          .map((item) => item.body)
          .toList(growable: false);
      expect(assistantBodies, ['Streaming the fix live.']);
      expect(detailApi.timelineFetchCount, 1);
    },
  );

  test(
    'thread-detail accepts newer completed detail when the live completion event is missed',
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
              workspace: '/workspace/vibe-bridge-companion',
              repository: 'vibe-bridge-companion',
              branch: 'master',
              createdAt: '2026-03-18T09:45:00Z',
              updatedAt: '2026-03-18T10:00:00Z',
              source: 'cli',
              accessMode: AccessMode.controlWithApprovals,
              lastTurnSummary: 'Normalize event payloads',
            ),
            const ThreadDetailDto(
              contractVersion: contractVersion,
              threadId: 'thread-123',
              title: 'Implement shared contracts',
              status: ThreadStatus.completed,
              workspace: '/workspace/vibe-bridge-companion',
              repository: 'vibe-bridge-companion',
              branch: 'master',
              createdAt: '2026-03-18T09:45:00Z',
              updatedAt: '2026-03-18T10:05:00Z',
              source: 'cli',
              accessMode: AccessMode.controlWithApprovals,
              lastTurnSummary: 'Patched tests cleanly.',
            ),
          ],
        },
        timelineScriptByThreadId: {
          'thread-123': [<ThreadTimelineEntryDto>[]],
        },
      );
      final liveStream = ScriptedThreadLiveStream();

      final detailController = ThreadDetailController(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
        threadId: 'thread-123',
        initialVisibleTimelineEntries: 20,
        bridgeApi: detailApi,
        liveStream: liveStream,
        threadListController: listController,
      );
      addTearDown(detailController.dispose);

      await _waitUntil(() => !detailController.state.isLoading);
      await _waitUntil(() => liveStream.totalSubscriptions >= 1);

      final submitted = await detailController.submitComposerInput(
        'Please stream this fix live.',
      );
      expect(submitted, isTrue);

      liveStream.emit(
        const BridgeEventEnvelope<Map<String, dynamic>>(
          contractVersion: contractVersion,
          eventId: 'evt-assistant-live',
          threadId: 'thread-123',
          kind: BridgeEventKind.messageDelta,
          occurredAt: '2026-03-18T10:04:00Z',
          payload: {
            'type': 'agentMessage',
            'role': 'assistant',
            'text': 'Streaming the fix live.',
          },
        ),
      );

      await _waitUntil(
        () =>
            detailApi.detailFetchCount >= 2 &&
            detailController.state.thread?.status == ThreadStatus.completed,
      );

      expect(detailController.state.thread?.status, ThreadStatus.completed);
      final assistantBodies = detailController.state.items
          .where((item) => item.type == ThreadActivityItemType.assistantOutput)
          .map((item) => item.body)
          .toList(growable: false);
      expect(assistantBodies, ['Streaming the fix live.']);
      expect(detailApi.timelineFetchCount, 1);
    },
  );

  test(
    'thread-detail refreshes snapshot timeline after completion without meaningful live activity',
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
              workspace: '/workspace/vibe-bridge-companion',
              repository: 'vibe-bridge-companion',
              branch: 'master',
              createdAt: '2026-03-18T09:45:00Z',
              updatedAt: '2026-03-18T10:00:00Z',
              source: 'cli',
              accessMode: AccessMode.controlWithApprovals,
              lastTurnSummary: 'Normalize event payloads',
            ),
            const ThreadDetailDto(
              contractVersion: contractVersion,
              threadId: 'thread-123',
              title: 'Implement shared contracts',
              status: ThreadStatus.completed,
              workspace: '/workspace/vibe-bridge-companion',
              repository: 'vibe-bridge-companion',
              branch: 'master',
              createdAt: '2026-03-18T09:45:00Z',
              updatedAt: '2026-03-18T10:05:00Z',
              source: 'cli',
              accessMode: AccessMode.controlWithApprovals,
              lastTurnSummary: 'Patched tests from snapshot replay.',
            ),
          ],
        },
        timelineScriptByThreadId: {
          'thread-123': [
            <ThreadTimelineEntryDto>[],
            <ThreadTimelineEntryDto>[
              _timelineEvent(
                id: 'evt-assistant-final',
                kind: BridgeEventKind.messageDelta,
                summary: 'Patched tests from snapshot replay.',
                payload: {
                  'type': 'agentMessage',
                  'role': 'assistant',
                  'text': 'Patched tests from snapshot replay.',
                },
                occurredAt: '2026-03-18T10:04:03Z',
              ),
            ],
          ],
        },
      );
      final liveStream = ScriptedThreadLiveStream();

      final detailController = ThreadDetailController(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
        threadId: 'thread-123',
        initialVisibleTimelineEntries: 20,
        bridgeApi: detailApi,
        liveStream: liveStream,
        threadListController: listController,
      );
      addTearDown(detailController.dispose);

      await _waitUntil(() => !detailController.state.isLoading);
      await _waitUntil(() => liveStream.totalSubscriptions >= 1);

      final submitted = await detailController.submitComposerInput(
        'Please finish this turn.',
      );
      expect(submitted, isTrue);

      liveStream.emit(
        const BridgeEventEnvelope<Map<String, dynamic>>(
          contractVersion: contractVersion,
          eventId: 'evt-status-complete',
          threadId: 'thread-123',
          kind: BridgeEventKind.threadStatusChanged,
          occurredAt: '2026-03-18T10:04:02Z',
          payload: {'status': 'completed', 'reason': 'upstream_notification'},
        ),
      );

      await _waitUntil(() => detailApi.timelineFetchCount >= 2);
      await _waitUntil(
        () => detailController.state.items.any(
          (item) => item.eventId == 'evt-assistant-final',
        ),
      );

      expect(detailController.state.thread?.status, ThreadStatus.completed);
      expect(detailApi.timelineFetchCount, 2);
      expect(
        detailController.state.items.any(
          (item) =>
              item.eventId == 'evt-assistant-final' &&
              item.body == 'Patched tests from snapshot replay.',
        ),
        isTrue,
      );
    },
  );

  test(
    'thread-detail ignores a fresher idle refresh while a mobile-started turn is still streaming',
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

      final staleRefreshUpdatedAt = DateTime.now()
          .toUtc()
          .add(const Duration(minutes: 5))
          .toIso8601String();
      final detailApi = ScriptedThreadDetailBridgeApi(
        detailScriptByThreadId: {
          'thread-123': [
            const ThreadDetailDto(
              contractVersion: contractVersion,
              threadId: 'thread-123',
              title: 'Implement shared contracts',
              status: ThreadStatus.idle,
              workspace: '/workspace/vibe-bridge-companion',
              repository: 'vibe-bridge-companion',
              branch: 'master',
              createdAt: '2026-03-18T09:45:00Z',
              updatedAt: '2026-03-18T10:00:00Z',
              source: 'cli',
              accessMode: AccessMode.controlWithApprovals,
              lastTurnSummary: 'Normalize event payloads',
            ),
            ThreadDetailDto(
              contractVersion: contractVersion,
              threadId: 'thread-123',
              title: 'Implement shared contracts',
              status: ThreadStatus.idle,
              workspace: '/workspace/vibe-bridge-companion',
              repository: 'vibe-bridge-companion',
              branch: 'master',
              createdAt: '2026-03-18T09:45:00Z',
              updatedAt: staleRefreshUpdatedAt,
              source: 'cli',
              accessMode: AccessMode.controlWithApprovals,
              lastTurnSummary: 'Bridge detail still says idle.',
            ),
          ],
        },
        timelineScriptByThreadId: {
          'thread-123': [<ThreadTimelineEntryDto>[]],
        },
      );
      final liveStream = ScriptedThreadLiveStream();

      final detailController = ThreadDetailController(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
        threadId: 'thread-123',
        initialVisibleTimelineEntries: 20,
        bridgeApi: detailApi,
        liveStream: liveStream,
        threadListController: listController,
      );
      addTearDown(detailController.dispose);

      await _waitUntil(() => !detailController.state.isLoading);
      await _waitUntil(() => liveStream.totalSubscriptions >= 1);

      final submitted = await detailController.submitComposerInput(
        'Please keep streaming from mobile.',
      );
      expect(submitted, isTrue);
      expect(detailController.state.thread?.status, ThreadStatus.running);

      liveStream.emit(
        BridgeEventEnvelope<Map<String, dynamic>>(
          contractVersion: contractVersion,
          eventId: 'evt-mobile-stream-1',
          threadId: 'thread-123',
          kind: BridgeEventKind.messageDelta,
          occurredAt: '2026-03-18T10:04:00Z',
          payload: {'delta': 'Still streaming from the active mobile turn.'},
        ),
      );

      await _waitUntil(() => detailController.state.items.isNotEmpty);
      await _waitUntil(() => detailApi.detailFetchCount >= 2);

      expect(detailController.state.items, hasLength(1));
      expect(
        detailController.state.items.single.body,
        'Still streaming from the active mobile turn.',
      );
      expect(detailController.state.thread?.status, ThreadStatus.running);
      expect(
        listController.state.threads
            .firstWhere((thread) => thread.threadId == 'thread-123')
            .status,
        ThreadStatus.running,
      );
    },
  );

  test(
    'thread-detail snapshot refresh fetches enough history to replace older malformed live assistant text',
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

      final timelineEntries = <ThreadTimelineEntryDto>[
        _timelineEvent(
          id: 'evt-assistant-review',
          kind: BridgeEventKind.messageDelta,
          summary:
              'hero + badges + screenshot - 3-line value proposition - key features',
          payload: {
            'type': 'agentMessage',
            'role': 'assistant',
            'text':
                'hero + badges + screenshot - 3-line value proposition - key features',
          },
          occurredAt: '2026-03-18T10:04:01Z',
        ),
        for (var index = 0; index < 25; index += 1)
          _timelineEvent(
            id: 'evt-filler-$index',
            kind: BridgeEventKind.commandDelta,
            summary: 'filler $index',
            payload: {'type': 'command', 'output': 'filler $index'},
            occurredAt:
                '2026-03-18T10:${(5 + index).toString().padLeft(2, '0')}:00Z',
          ),
      ];

      final detailApi = ScriptedThreadDetailBridgeApi(
        detailScriptByThreadId: {
          'thread-123': [
            const ThreadDetailDto(
              contractVersion: contractVersion,
              threadId: 'thread-123',
              title: 'Implement shared contracts',
              status: ThreadStatus.idle,
              workspace: '/workspace/vibe-bridge-companion',
              repository: 'vibe-bridge-companion',
              branch: 'master',
              createdAt: '2026-03-18T09:45:00Z',
              updatedAt: '2026-03-18T10:00:00Z',
              source: 'cli',
              accessMode: AccessMode.controlWithApprovals,
              lastTurnSummary: 'Normalize event payloads',
            ),
            const ThreadDetailDto(
              contractVersion: contractVersion,
              threadId: 'thread-123',
              title: 'Implement shared contracts',
              status: ThreadStatus.completed,
              workspace: '/workspace/vibe-bridge-companion',
              repository: 'vibe-bridge-companion',
              branch: 'master',
              createdAt: '2026-03-18T09:45:00Z',
              updatedAt: '2026-03-18T10:31:00Z',
              source: 'cli',
              accessMode: AccessMode.controlWithApprovals,
              lastTurnSummary: 'Patched tests from snapshot replay.',
            ),
          ],
        },
        timelineScriptByThreadId: {
          'thread-123': [<ThreadTimelineEntryDto>[], timelineEntries],
        },
      );
      final liveStream = ScriptedThreadLiveStream();

      final detailController = ThreadDetailController(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
        threadId: 'thread-123',
        initialVisibleTimelineEntries: 20,
        bridgeApi: detailApi,
        liveStream: liveStream,
        threadListController: listController,
      );
      addTearDown(detailController.dispose);

      await _waitUntil(() => !detailController.state.isLoading);
      await _waitUntil(() => liveStream.totalSubscriptions >= 1);

      final submitted = await detailController.submitComposerInput(
        'Please finish this turn.',
      );
      expect(submitted, isTrue);

      liveStream.emit(
        const BridgeEventEnvelope<Map<String, dynamic>>(
          contractVersion: contractVersion,
          eventId: 'evt-assistant-review',
          threadId: 'thread-123',
          kind: BridgeEventKind.messageDelta,
          occurredAt: '2026-03-18T10:04:01Z',
          payload: {
            'type': 'agentMessage',
            'role': 'assistant',
            'delta':
                'hero + badges + screenshot-3-line value proposition- key features',
            'replace': true,
          },
        ),
      );

      for (var index = 0; index < 19; index += 1) {
        liveStream.emit(
          BridgeEventEnvelope<Map<String, dynamic>>(
            contractVersion: contractVersion,
            eventId: 'evt-live-filler-$index',
            threadId: 'thread-123',
            kind: BridgeEventKind.commandDelta,
            occurredAt:
                '2026-03-18T10:${(5 + index).toString().padLeft(2, '0')}:00Z',
            payload: {'type': 'command', 'output': 'live filler $index'},
          ),
        );
      }

      await _waitUntil(() => detailController.state.items.length == 20);

      liveStream.emit(
        const BridgeEventEnvelope<Map<String, dynamic>>(
          contractVersion: contractVersion,
          eventId: 'evt-status-complete',
          threadId: 'thread-123',
          kind: BridgeEventKind.threadStatusChanged,
          occurredAt: '2026-03-18T10:30:00Z',
          payload: {'status': 'completed', 'reason': 'upstream_notification'},
        ),
      );

      await _waitUntil(() => detailApi.timelineFetchCount >= 2);
      await _waitUntil(
        () => detailController.state.items.any(
          (item) =>
              item.eventId == 'evt-assistant-review' &&
              item.body ==
                  'hero + badges + screenshot - 3-line value proposition - key features',
        ),
      );

      expect(
        detailController.state.items
            .firstWhere((item) => item.eventId == 'evt-assistant-review')
            .body,
        'hero + badges + screenshot - 3-line value proposition - key features',
      );
    },
  );

  test(
    'thread-detail keeps pending snapshot refresh after completed status even if trailing live deltas arrive',
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
              workspace: '/workspace/vibe-bridge-companion',
              repository: 'vibe-bridge-companion',
              branch: 'master',
              createdAt: '2026-03-18T09:45:00Z',
              updatedAt: '2026-03-18T10:00:00Z',
              source: 'cli',
              accessMode: AccessMode.controlWithApprovals,
              lastTurnSummary: 'Normalize event payloads',
            ),
            const ThreadDetailDto(
              contractVersion: contractVersion,
              threadId: 'thread-123',
              title: 'Implement shared contracts',
              status: ThreadStatus.completed,
              workspace: '/workspace/vibe-bridge-companion',
              repository: 'vibe-bridge-companion',
              branch: 'master',
              createdAt: '2026-03-18T09:45:00Z',
              updatedAt: '2026-03-18T10:05:00Z',
              source: 'cli',
              accessMode: AccessMode.controlWithApprovals,
              lastTurnSummary: 'Pair your phone in 5 minutes.',
            ),
          ],
        },
        timelineScriptByThreadId: {
          'thread-123': [
            <ThreadTimelineEntryDto>[],
            <ThreadTimelineEntryDto>[
              _timelineEvent(
                id: 'evt-assistant-final',
                kind: BridgeEventKind.messageDelta,
                summary: 'Pair your phone in 5 minutes.',
                payload: {
                  'type': 'agentMessage',
                  'role': 'assistant',
                  'text': 'Pair your phone in 5 minutes.',
                },
                occurredAt: '2026-03-18T10:04:03Z',
              ),
            ],
          ],
        },
      );
      final liveStream = ScriptedThreadLiveStream();

      final detailController = ThreadDetailController(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
        threadId: 'thread-123',
        initialVisibleTimelineEntries: 20,
        bridgeApi: detailApi,
        liveStream: liveStream,
        threadListController: listController,
      );
      addTearDown(detailController.dispose);

      await _waitUntil(() => !detailController.state.isLoading);
      await _waitUntil(() => liveStream.totalSubscriptions >= 1);

      final submitted = await detailController.submitComposerInput(
        'Please finish this turn.',
      );
      expect(submitted, isTrue);

      liveStream.emit(
        const BridgeEventEnvelope<Map<String, dynamic>>(
          contractVersion: contractVersion,
          eventId: 'evt-assistant-final',
          threadId: 'thread-123',
          kind: BridgeEventKind.messageDelta,
          occurredAt: '2026-03-18T10:04:01Z',
          payload: {
            'type': 'agentMessage',
            'role': 'assistant',
            'delta': 'Pair your phone in5 minutes.',
            'replace': true,
          },
        ),
      );
      await _waitUntil(() => detailController.state.items.isNotEmpty);

      liveStream.emit(
        const BridgeEventEnvelope<Map<String, dynamic>>(
          contractVersion: contractVersion,
          eventId: 'evt-status-complete',
          threadId: 'thread-123',
          kind: BridgeEventKind.threadStatusChanged,
          occurredAt: '2026-03-18T10:04:02Z',
          payload: {'status': 'completed', 'reason': 'upstream_notification'},
        ),
      );

      liveStream.emit(
        const BridgeEventEnvelope<Map<String, dynamic>>(
          contractVersion: contractVersion,
          eventId: 'evt-assistant-final',
          threadId: 'thread-123',
          kind: BridgeEventKind.messageDelta,
          occurredAt: '2026-03-18T10:04:03Z',
          payload: {
            'type': 'agentMessage',
            'role': 'assistant',
            'delta': '.',
            'replace': false,
          },
        ),
      );

      await _waitUntil(() => detailApi.timelineFetchCount >= 2);
      await _waitUntil(
        () => detailController.state.items.any(
          (item) =>
              item.eventId == 'evt-assistant-final' &&
              item.body == 'Pair your phone in 5 minutes.',
        ),
      );

      expect(detailApi.timelineFetchCount, 2);
      expect(
        detailController.state.items
            .firstWhere((item) => item.eventId == 'evt-assistant-final')
            .body,
        'Pair your phone in 5 minutes.',
      );
    },
  );

  test('thread-detail ignores exact duplicate live assistant frames', () async {
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
            workspace: '/workspace/vibe-bridge-companion',
            repository: 'vibe-bridge-companion',
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

    final duplicatedFrame = BridgeEventEnvelope<Map<String, dynamic>>(
      contractVersion: contractVersion,
      eventId: 'evt-assistant-dup',
      threadId: 'thread-123',
      kind: BridgeEventKind.messageDelta,
      occurredAt: '2026-03-18T10:04:00Z',
      payload: {'delta': 'Hello there.', 'replace': true},
    );

    liveStream.emit(duplicatedFrame);
    await _waitUntil(() => detailController.state.items.isNotEmpty);
    liveStream.emit(duplicatedFrame);

    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(detailController.state.items, hasLength(1));
    expect(detailController.state.items.single.body, 'Hello there.');
    expect(
      logs.where(
        (entry) => entry.contains('thread_detail_duplicate_live_frame'),
      ),
      hasLength(1),
    );
  });

  test(
    'thread-detail reconnect catch-up keeps completed detail while deduplicating replayed live items',
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
              workspace: '/workspace/vibe-bridge-companion',
              repository: 'vibe-bridge-companion',
              branch: 'master',
              createdAt: '2026-03-18T09:45:00Z',
              updatedAt: '2026-03-18T10:00:00Z',
              source: 'cli',
              accessMode: AccessMode.controlWithApprovals,
              lastTurnSummary: 'Normalize event payloads',
            ),
            const ThreadDetailDto(
              contractVersion: contractVersion,
              threadId: 'thread-123',
              title: 'Implement shared contracts',
              status: ThreadStatus.completed,
              workspace: '/workspace/vibe-bridge-companion',
              repository: 'vibe-bridge-companion',
              branch: 'master',
              createdAt: '2026-03-18T09:45:00Z',
              updatedAt: '2026-03-18T10:05:00Z',
              source: 'cli',
              accessMode: AccessMode.controlWithApprovals,
              lastTurnSummary: 'Patched tests',
            ),
          ],
        },
        timelineScriptByThreadId: {
          'thread-123': [
            <ThreadTimelineEntryDto>[],
            <ThreadTimelineEntryDto>[
              _timelineEvent(
                id: 'evt-user-canonical',
                kind: BridgeEventKind.messageDelta,
                summary: 'Ship the fix',
                payload: {
                  'type': 'userMessage',
                  'role': 'user',
                  'text': 'Ship the fix',
                },
                occurredAt: '2026-03-18T10:04:00Z',
              ),
              _timelineEvent(
                id: 'evt-assistant-canonical',
                kind: BridgeEventKind.messageDelta,
                summary: 'Patched tests',
                payload: {
                  'type': 'agentMessage',
                  'role': 'assistant',
                  'text': 'Patched tests',
                },
                occurredAt: '2026-03-18T10:04:01Z',
              ),
            ],
          ],
        },
      );
      final liveStream = ScriptedThreadLiveStream();

      final detailController = ThreadDetailController(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
        threadId: 'thread-123',
        initialVisibleTimelineEntries: 20,
        bridgeApi: detailApi,
        liveStream: liveStream,
        threadListController: listController,
      );
      addTearDown(detailController.dispose);

      await _waitUntil(() => !detailController.state.isLoading);
      await _waitUntil(() => liveStream.totalSubscriptions >= 1);

      final submitted = await detailController.submitComposerInput(
        'Ship the fix',
      );
      expect(submitted, isTrue);

      liveStream.emit(
        const BridgeEventEnvelope<Map<String, dynamic>>(
          contractVersion: contractVersion,
          eventId: 'evt-user-live',
          threadId: 'thread-123',
          kind: BridgeEventKind.messageDelta,
          occurredAt: '2026-03-18T10:04:00Z',
          payload: {
            'type': 'userMessage',
            'role': 'user',
            'text': 'Ship the fix',
          },
        ),
      );
      liveStream.emit(
        const BridgeEventEnvelope<Map<String, dynamic>>(
          contractVersion: contractVersion,
          eventId: 'evt-assistant-live',
          threadId: 'thread-123',
          kind: BridgeEventKind.messageDelta,
          occurredAt: '2026-03-18T10:04:01Z',
          payload: {'type': 'agentMessage', 'role': 'assistant', 'text': 'Pat'},
        ),
      );

      await _waitUntil(() => detailController.state.items.length == 2);

      await detailController.retryReconnectCatchUp();

      final promptBodies = detailController.state.items
          .where((item) => item.type == ThreadActivityItemType.userPrompt)
          .map((item) => item.body)
          .toList(growable: false);
      final assistantBodies = detailController.state.items
          .where((item) => item.type == ThreadActivityItemType.assistantOutput)
          .map((item) => item.body)
          .toList(growable: false);

      expect(detailController.state.thread?.status, ThreadStatus.completed);
      expect(promptBodies, ['Ship the fix']);
      expect(assistantBodies, ['Patched tests']);
      expect(detailController.state.items, hasLength(2));
    },
  );

  test(
    'thread-detail merges synthetic same-turn prompt during reconnect catch-up',
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
              workspace: '/workspace/vibe-bridge-companion',
              repository: 'vibe-bridge-companion',
              branch: 'master',
              createdAt: '2026-03-18T09:45:00Z',
              updatedAt: '2026-03-18T10:00:00Z',
              source: 'cli',
              accessMode: AccessMode.controlWithApprovals,
              lastTurnSummary: 'Normalize event payloads',
            ),
            const ThreadDetailDto(
              contractVersion: contractVersion,
              threadId: 'thread-123',
              title: 'Implement shared contracts',
              status: ThreadStatus.completed,
              workspace: '/workspace/vibe-bridge-companion',
              repository: 'vibe-bridge-companion',
              branch: 'master',
              createdAt: '2026-03-18T09:45:00Z',
              updatedAt: '2026-03-18T10:04:10Z',
              source: 'cli',
              accessMode: AccessMode.controlWithApprovals,
              lastTurnSummary: 'Patched tests',
            ),
          ],
        },
        timelineScriptByThreadId: {
          'thread-123': [
            <ThreadTimelineEntryDto>[],
            <ThreadTimelineEntryDto>[
              _timelineEvent(
                id: 'turn-123-item-user-1',
                kind: BridgeEventKind.messageDelta,
                summary: 'Ship the fix',
                payload: {
                  'type': 'userMessage',
                  'role': 'user',
                  'text': 'Ship the fix',
                },
                occurredAt: '2026-03-18T10:04:08Z',
              ),
              _timelineEvent(
                id: 'evt-assistant-canonical',
                kind: BridgeEventKind.messageDelta,
                summary: 'Patched tests',
                payload: {
                  'type': 'agentMessage',
                  'role': 'assistant',
                  'text': 'Patched tests',
                },
                occurredAt: '2026-03-18T10:04:09Z',
              ),
            ],
          ],
        },
      );
      final liveStream = ScriptedThreadLiveStream();

      final detailController = ThreadDetailController(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
        threadId: 'thread-123',
        initialVisibleTimelineEntries: 20,
        bridgeApi: detailApi,
        liveStream: liveStream,
        threadListController: listController,
      );
      addTearDown(detailController.dispose);

      await _waitUntil(() => !detailController.state.isLoading);
      await _waitUntil(() => liveStream.totalSubscriptions >= 1);

      final submitted = await detailController.submitComposerInput(
        'Ship the fix',
      );
      expect(submitted, isTrue);

      liveStream.emit(
        const BridgeEventEnvelope<Map<String, dynamic>>(
          contractVersion: contractVersion,
          eventId: 'turn-123-visible-user-prompt',
          threadId: 'thread-123',
          kind: BridgeEventKind.messageDelta,
          occurredAt: '2026-03-18T10:04:00Z',
          payload: {
            'type': 'userMessage',
            'role': 'user',
            'text': 'Ship the fix',
          },
        ),
      );
      liveStream.emit(
        const BridgeEventEnvelope<Map<String, dynamic>>(
          contractVersion: contractVersion,
          eventId: 'evt-assistant-live',
          threadId: 'thread-123',
          kind: BridgeEventKind.messageDelta,
          occurredAt: '2026-03-18T10:04:01Z',
          payload: {
            'type': 'agentMessage',
            'role': 'assistant',
            'text': 'Patched tests',
          },
        ),
      );

      await _waitUntil(() => detailController.state.items.length == 2);

      await detailController.retryReconnectCatchUp();

      await _waitUntil(
        () =>
            detailController.state.items.length == 2 &&
            detailController.state.items[0].eventId == 'turn-123-item-user-1' &&
            detailController.state.items[1].eventId ==
                'evt-assistant-canonical',
      );

      expect(
        detailController.state.items.map((item) => item.eventId).toList(),
        ['turn-123-item-user-1', 'evt-assistant-canonical'],
      );
      expect(detailController.state.items.map((item) => item.body).toList(), [
        'Ship the fix',
        'Patched tests',
      ]);
    },
  );

  test(
    'thread-detail should not duplicate logically identical live and catch-up messages with different event ids',
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
              workspace: '/workspace/vibe-bridge-companion',
              repository: 'vibe-bridge-companion',
              branch: 'master',
              createdAt: '2026-03-18T09:45:00Z',
              updatedAt: '2026-03-18T10:00:00Z',
              source: 'cli',
              accessMode: AccessMode.controlWithApprovals,
              lastTurnSummary: 'Normalize event payloads',
            ),
            const ThreadDetailDto(
              contractVersion: contractVersion,
              threadId: 'thread-123',
              title: 'Implement shared contracts',
              status: ThreadStatus.running,
              workspace: '/workspace/vibe-bridge-companion',
              repository: 'vibe-bridge-companion',
              branch: 'master',
              createdAt: '2026-03-18T09:45:00Z',
              updatedAt: '2026-03-18T10:04:05Z',
              source: 'cli',
              accessMode: AccessMode.controlWithApprovals,
              lastTurnSummary: 'Patched tests',
            ),
          ],
        },
        timelineScriptByThreadId: {
          'thread-123': [
            <ThreadTimelineEntryDto>[],
            <ThreadTimelineEntryDto>[
              _timelineEvent(
                id: 'evt-user-catchup',
                kind: BridgeEventKind.messageDelta,
                summary: 'Ship the fix',
                payload: {
                  'type': 'userMessage',
                  'role': 'user',
                  'text': 'Ship the fix',
                },
                occurredAt: '2026-03-18T10:04:00Z',
              ),
              _timelineEvent(
                id: 'evt-assistant-catchup',
                kind: BridgeEventKind.messageDelta,
                summary: 'Patched tests',
                payload: {
                  'type': 'agentMessage',
                  'role': 'assistant',
                  'text': 'Patched tests',
                },
                occurredAt: '2026-03-18T10:04:01Z',
              ),
            ],
          ],
        },
      );
      final liveStream = ScriptedThreadLiveStream();

      final detailController = ThreadDetailController(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
        threadId: 'thread-123',
        initialVisibleTimelineEntries: 20,
        bridgeApi: detailApi,
        liveStream: liveStream,
        threadListController: listController,
      );
      addTearDown(detailController.dispose);

      await _waitUntil(() => !detailController.state.isLoading);
      await _waitUntil(() => liveStream.totalSubscriptions >= 1);

      final submitted = await detailController.submitComposerInput(
        'Ship the fix',
      );
      expect(submitted, isTrue);

      liveStream.emit(
        const BridgeEventEnvelope<Map<String, dynamic>>(
          contractVersion: contractVersion,
          eventId: 'evt-user-live',
          threadId: 'thread-123',
          kind: BridgeEventKind.messageDelta,
          occurredAt: '2026-03-18T10:04:00Z',
          payload: {
            'type': 'userMessage',
            'role': 'user',
            'text': 'Ship the fix',
          },
        ),
      );
      liveStream.emit(
        const BridgeEventEnvelope<Map<String, dynamic>>(
          contractVersion: contractVersion,
          eventId: 'evt-assistant-live',
          threadId: 'thread-123',
          kind: BridgeEventKind.messageDelta,
          occurredAt: '2026-03-18T10:04:01Z',
          payload: {'type': 'agentMessage', 'role': 'assistant', 'text': 'Pat'},
        ),
      );

      await _waitUntil(() => detailController.state.items.length == 2);

      await detailController.retryReconnectCatchUp();

      final promptBodies = detailController.state.items
          .where((item) => item.type == ThreadActivityItemType.userPrompt)
          .map((item) => item.body)
          .toList(growable: false);
      final assistantBodies = detailController.state.items
          .where((item) => item.type == ThreadActivityItemType.assistantOutput)
          .map((item) => item.body)
          .toList(growable: false);

      expect(promptBodies, ['Ship the fix']);
      expect(assistantBodies, ['Patched tests']);
      expect(detailController.state.items, hasLength(2));
    },
  );

  test(
    'thread-detail reconciles archived assistant text when live text only differs by dropped spaces',
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
              workspace: '/workspace/vibe-bridge-companion',
              repository: 'vibe-bridge-companion',
              branch: 'master',
              createdAt: '2026-03-18T09:45:00Z',
              updatedAt: '2026-03-18T10:00:00Z',
              source: 'cli',
              accessMode: AccessMode.controlWithApprovals,
              lastTurnSummary: 'Normalize event payloads',
            ),
            const ThreadDetailDto(
              contractVersion: contractVersion,
              threadId: 'thread-123',
              title: 'Implement shared contracts',
              status: ThreadStatus.running,
              workspace: '/workspace/vibe-bridge-companion',
              repository: 'vibe-bridge-companion',
              branch: 'master',
              createdAt: '2026-03-18T09:45:00Z',
              updatedAt: '2026-03-18T10:04:05Z',
              source: 'cli',
              accessMode: AccessMode.controlWithApprovals,
              lastTurnSummary:
                  'Rewrite Quick Start around “pair your phone in 5 minutes.”',
            ),
          ],
        },
        timelineScriptByThreadId: {
          'thread-123': [
            <ThreadTimelineEntryDto>[],
            <ThreadTimelineEntryDto>[
              _timelineEvent(
                id: 'evt-assistant-catchup',
                kind: BridgeEventKind.messageDelta,
                summary:
                    '- Add 1-2 real product screenshots. Rewrite Quick Start around “pair your phone in 5 minutes.”',
                payload: {
                  'type': 'agentMessage',
                  'role': 'assistant',
                  'text':
                      '- Add 1-2 real product screenshots. Rewrite Quick Start around “pair your phone in 5 minutes.”',
                },
                occurredAt: '2026-03-18T10:04:01Z',
              ),
            ],
          ],
        },
      );
      final liveStream = ScriptedThreadLiveStream();

      final detailController = ThreadDetailController(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
        threadId: 'thread-123',
        initialVisibleTimelineEntries: 20,
        bridgeApi: detailApi,
        liveStream: liveStream,
        threadListController: listController,
      );
      addTearDown(detailController.dispose);

      await _waitUntil(() => !detailController.state.isLoading);
      await _waitUntil(() => liveStream.totalSubscriptions >= 1);

      final submitted = await detailController.submitComposerInput(
        'Ship the README polish.',
      );
      expect(submitted, isTrue);

      liveStream.emit(
        const BridgeEventEnvelope<Map<String, dynamic>>(
          contractVersion: contractVersion,
          eventId: 'evt-assistant-live',
          threadId: 'thread-123',
          kind: BridgeEventKind.messageDelta,
          occurredAt: '2026-03-18T10:04:01Z',
          payload: {
            'type': 'agentMessage',
            'role': 'assistant',
            'text':
                '- Add1-2 real product screenshots. Rewrite Quick Start around “pair your phone in5 minutes.”',
          },
        ),
      );

      await _waitUntil(() => detailController.state.items.length == 1);

      await detailController.retryReconnectCatchUp();

      final assistantBodies = detailController.state.items
          .where((item) => item.type == ThreadActivityItemType.assistantOutput)
          .map((item) => item.body)
          .toList(growable: false);

      expect(assistantBodies, [
        '- Add 1-2 real product screenshots. Rewrite Quick Start around “pair your phone in 5 minutes.”',
      ]);
      expect(detailController.state.items, hasLength(1));
    },
  );

  test(
    'thread-detail forwards image attachments when submitting a turn',
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
              workspace: '/workspace/vibe-bridge-companion',
              repository: 'vibe-bridge-companion',
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

      final submitted = await detailController.submitComposerInput(
        '',
        images: const <String>['data:image/png;base64,AAA'],
      );

      expect(submitted, isTrue);
      expect(detailApi.startTurnPromptsByThreadId['thread-123'], ['']);
      expect(detailApi.startTurnImagesByThreadId['thread-123'], [
        ['data:image/png;base64,AAA'],
      ]);
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
      workspace: '/workspace/vibe-bridge-companion',
      repository: 'vibe-bridge-companion',
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
    workspace: '/workspace/vibe-bridge-companion',
    repository: 'vibe-bridge-companion',
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
  int timelineFetchCount = 0;
  final Map<String, List<String>> startTurnPromptsByThreadId =
      <String, List<String>>{};
  final Map<String, List<List<String>>> startTurnImagesByThreadId =
      <String, List<List<String>>>{};

  @override
  Future<ModelCatalogDto> fetchModelCatalog({
    required String bridgeApiBaseUrl,
    required ProviderKind provider,
  }) async {
    return fallbackModelCatalogForProvider(provider);
  }

  @override
  Future<SpeechModelStatusDto> fetchSpeechStatus({
    required String bridgeApiBaseUrl,
  }) async {
    return const SpeechModelStatusDto(
      contractVersion: contractVersion,
      provider: 'fluid_audio',
      modelId: 'parakeet-tdt-0.6b-v3-coreml',
      state: SpeechModelState.unsupported,
    );
  }

  @override
  Future<SpeechTranscriptionResultDto> transcribeAudio({
    required String bridgeApiBaseUrl,
    required List<int> audioBytes,
    String fileName = 'voice-message.wav',
  }) async {
    throw const ThreadSpeechBridgeException(message: 'Speech is unused here.');
  }

  @override
  Future<ThreadSnapshotDto> createThread({
    required String bridgeApiBaseUrl,
    required String workspace,
    required ProviderKind provider,
    String? model,
  }) async {
    throw const ThreadCreateBridgeException(
      message: 'Thread creation is not used in reconnect retry tests.',
    );
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
  Future<ThreadUsageDto> fetchThreadUsage({
    required String bridgeApiBaseUrl,
    required String threadId,
  }) async {
    throw const ThreadUsageBridgeException(
      message: 'Usage is unavailable in this test.',
    );
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
        workspace: '/workspace/vibe-bridge-companion',
        repository: 'vibe-bridge-companion',
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
    String? turnId,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<TurnMutationResult> startCommitAction({
    required String bridgeApiBaseUrl,
    required String threadId,
    String? model,
    String? effort,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<TurnMutationResult> startTurn({
    required String bridgeApiBaseUrl,
    required String threadId,
    required String prompt,
    TurnMode mode = TurnMode.act,
    List<String> images = const <String>[],
    String? model,
    String? effort,
  }) {
    startTurnPromptsByThreadId
        .putIfAbsent(threadId, () => <String>[])
        .add(prompt);
    startTurnImagesByThreadId
        .putIfAbsent(threadId, () => <List<String>>[])
        .add(List<String>.unmodifiable(images));
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
  Future<TurnMutationResult> respondToUserInput({
    required String bridgeApiBaseUrl,
    required String threadId,
    required String requestId,
    List<UserInputAnswerDto> answers = const <UserInputAnswerDto>[],
    String? freeText,
    String? model,
    String? effort,
  }) {
    return Future<TurnMutationResult>.value(
      TurnMutationResult(
        contractVersion: contractVersion,
        threadId: threadId,
        operation: 'turn_respond',
        outcome: 'accepted',
        threadStatus: ThreadStatus.running,
        message: 'Plan clarification accepted',
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
