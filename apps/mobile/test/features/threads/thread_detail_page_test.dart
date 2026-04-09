import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:vibe_bridge/features/approvals/data/approval_bridge_api.dart';
import 'package:vibe_bridge/features/settings/application/desktop_integration_controller.dart';
import 'package:vibe_bridge/features/settings/application/runtime_access_mode.dart';
import 'package:vibe_bridge/features/settings/data/settings_bridge_api.dart';
import 'package:vibe_bridge/features/threads/application/thread_detail_controller.dart';
import 'package:vibe_bridge/features/threads/data/thread_cache_repository.dart';
import 'package:vibe_bridge/features/threads/data/thread_detail_bridge_api.dart';
import 'package:vibe_bridge/features/threads/data/thread_list_bridge_api.dart';
import 'package:vibe_bridge/features/threads/data/thread_live_stream.dart';
import 'package:vibe_bridge/features/threads/domain/thread_activity_item.dart';
import 'package:vibe_bridge/features/threads/domain/thread_timeline_block.dart';
import 'package:vibe_bridge/features/threads/presentation/thread_detail_page.dart';
import 'package:vibe_bridge/features/threads/presentation/thread_list_page.dart';
import 'package:vibe_bridge/foundation/contracts/bridge_contracts.dart';
import 'package:vibe_bridge/foundation/media/speech_capture.dart';
import 'package:vibe_bridge/foundation/storage/secure_store.dart';
import 'package:vibe_bridge/foundation/storage/secure_store_provider.dart';
import 'package:codex_ui/codex_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

void main() {
  testWidgets(
    'opening a thread shows matching detail and mixed item types distinctly',
    (tester) async {
      final listApi = FakeThreadListBridgeApi(
        scriptedResults: [_threadSummaries()],
      );
      final detailApi = FakeThreadDetailBridgeApi(
        detailScriptByThreadId: {
          'thread-123': [_thread123Detail(status: ThreadStatus.completed)],
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
      expect(
        tester.widget<Text>(find.byKey(const Key('thread-detail-title'))).data,
        'Implement shared contracts',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('thread-detail-title')))
            .style
            ?.color,
        AppTheme.textMain,
      );
      expect(
        find.byKey(const Key('thread-detail-metadata-scroll')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('thread-detail-metadata-scroll')),
          matching: find.text('vibe-bridge-companion'),
        ),
        findsOneWidget,
      );
      await _scrollUntilVisible(
        tester,
        find.text('Please summarize the latest bridge logs.'),
      );
      expect(
        find.text('Please summarize the latest bridge logs.'),
        findsOneWidget,
      );
      await _scrollUntilVisible(
        tester,
        find.text('Sure, gathering the latest output now.'),
      );
      expect(
        find.text('Sure, gathering the latest output now.'),
        findsOneWidget,
      );
      await _scrollUntilVisible(tester, find.text('Plan update'));
      expect(find.text('Plan update'), findsOneWidget);
    },
  );

  testWidgets('structured plan updates render progress and checklist steps', (
    tester,
  ) async {
    final detailApi = FakeThreadDetailBridgeApi(
      detailScriptByThreadId: {
        'thread-123': [_thread123Detail(status: ThreadStatus.running)],
      },
      timelineScriptByThreadId: {
        'thread-123': [_structuredPlanTimelineEvents()],
      },
    );

    await _pumpThreadDetailApp(
      tester,
      detailApi: detailApi,
      threadId: 'thread-123',
    );

    await _scrollUntilVisible(tester, find.text('1 out of 3 tasks completed'));
    expect(find.text('1 out of 3 tasks completed'), findsOneWidget);
    expect(find.text('1. Inspect bridge payload'), findsOneWidget);
    expect(find.textContaining('2. Add Flutter card'), findsOneWidget);
    expect(find.textContaining('In progress'), findsOneWidget);
    expect(find.text('3. Run targeted tests'), findsOneWidget);
  });

  testWidgets(
    'real-thread header follows bridge detail metadata on initial load',
    (tester) async {
      final fixture = _loadRealThreadFixture();
      final staleTimelineThread = ThreadDetailDto(
        contractVersion: fixture.detail.contractVersion,
        threadId: fixture.detail.threadId,
        title: 'Delegate subagents to fix tests',
        status: ThreadStatus.running,
        workspace: '/Users/lubomirmolin/PhpstormProjects/wrong-workspace',
        repository: 'wrong-workspace',
        branch: 'feature/wrong-thread',
        createdAt: fixture.detail.createdAt,
        updatedAt: fixture.detail.updatedAt,
        source: 'cli',
        accessMode: fixture.detail.accessMode,
        lastTurnSummary:
            'can you help me debug why the threads detail is very spotty?',
      );

      final detailApi = FakeThreadDetailBridgeApi(
        detailScriptByThreadId: {
          fixture.detail.threadId: [fixture.detail],
        },
        timelineScriptByThreadId: {
          fixture.detail.threadId: [fixture.timelineEntries],
        },
        timelineThreadByThreadId: {
          fixture.detail.threadId: staleTimelineThread,
        },
      );

      await _pumpThreadDetailApp(
        tester,
        detailApi: detailApi,
        threadId: fixture.detail.threadId,
        initialVisibleTimelineEntries: 80,
      );
      await tester.pumpAndSettle();

      expect(find.text(fixture.detail.title), findsOneWidget);
      expect(find.text(fixture.detail.repository), findsOneWidget);
      expect(find.text('Completed'), findsOneWidget);
      expect(find.text('Delegate subagents to fix tests'), findsNothing);
      expect(find.text('wrong-workspace'), findsNothing);
    },
  );

  testWidgets('thread detail shows compact Codex usage bars under composer', (
    tester,
  ) async {
    final detailApi = FakeThreadDetailBridgeApi(
      detailScriptByThreadId: {
        'codex:thread-usage': [
          _thread123Detail(threadId: 'codex:thread-usage'),
        ],
      },
      timelineScriptByThreadId: {
        'codex:thread-usage': [const <ThreadTimelineEntryDto>[]],
      },
      threadUsageScriptByThreadId: {
        'codex:thread-usage': [
          const ThreadUsageDto(
            contractVersion: contractVersion,
            threadId: 'codex:thread-usage',
            provider: ProviderKind.codex,
            planType: 'pro',
            primaryWindow: ThreadUsageWindowDto(
              usedPercent: 6,
              limitWindowSeconds: 18000,
              resetAfterSeconds: 12223,
              resetAt: 1774996694,
            ),
            secondaryWindow: ThreadUsageWindowDto(
              usedPercent: 42,
              limitWindowSeconds: 604800,
              resetAfterSeconds: 213053,
              resetAt: 1775197525,
            ),
          ),
        ],
      },
    );

    await _pumpThreadDetailApp(
      tester,
      detailApi: detailApi,
      threadId: 'codex:thread-usage',
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('thread-usage-primary-window')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('thread-usage-secondary-window')),
      findsOneWidget,
    );
    expect(find.text('4h'), findsOneWidget);
    expect(find.text('3d'), findsOneWidget);
  });

  testWidgets(
    'thread detail shows inline loader until initial timeline page resolves',
    (tester) async {
      final timelineCompleter = Completer<List<ThreadTimelineEntryDto>>();
      final detailApi = FakeThreadDetailBridgeApi(
        detailScriptByThreadId: {
          'thread-456': [_thread456Detail()],
        },
        timelineScriptByThreadId: {
          'thread-456': [timelineCompleter.future],
        },
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appSecureStoreProvider.overrideWithValue(InMemorySecureStore()),
            threadListBridgeApiProvider.overrideWithValue(
              FakeThreadListBridgeApi(scriptedResults: [_threadSummaries()]),
            ),
            approvalBridgeApiProvider.overrideWithValue(
              EmptyApprovalBridgeApi(),
            ),
            threadDetailBridgeApiProvider.overrideWithValue(detailApi),
            settingsBridgeApiProvider.overrideWithValue(
              FakeSettingsBridgeApi(),
            ),
            threadLiveStreamProvider.overrideWithValue(FakeThreadLiveStream()),
            threadCacheRepositoryProvider.overrideWithValue(
              _newCacheRepository(),
            ),
          ],
          child: const MaterialApp(
            home: ThreadDetailPage(
              bridgeApiBaseUrl: _bridgeApiBaseUrl,
              threadId: 'thread-456',
            ),
          ),
        ),
      );

      await tester.pump();
      await _pumpForTransientUiWork(tester, iterations: 2);

      expect(find.byKey(const Key('thread-detail-title')), findsOneWidget);
      expect(find.text('Investigate reconnect dedup'), findsOneWidget);
      expect(
        find.byKey(const Key('thread-detail-timeline-loading-state')),
        findsOneWidget,
      );
      expect(find.text('Loading timeline…'), findsOneWidget);
      expect(find.text('No timeline entries yet.'), findsNothing);

      timelineCompleter.complete(_mixedTimelineEvents());
      await tester.pump();
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('thread-detail-timeline-loading-state')),
        findsNothing,
      );
      expect(find.text('No timeline entries yet.'), findsNothing);
      await _scrollUntilVisible(
        tester,
        find.text('Please summarize the latest bridge logs.'),
      );
      expect(
        find.text('Please summarize the latest bridge logs.'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'thread detail shows empty timeline state only after initial empty page resolves',
    (tester) async {
      final timelineCompleter = Completer<List<ThreadTimelineEntryDto>>();
      final detailApi = FakeThreadDetailBridgeApi(
        detailScriptByThreadId: {
          'thread-456': [_thread456Detail()],
        },
        timelineScriptByThreadId: {
          'thread-456': [timelineCompleter.future],
        },
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appSecureStoreProvider.overrideWithValue(InMemorySecureStore()),
            threadListBridgeApiProvider.overrideWithValue(
              FakeThreadListBridgeApi(scriptedResults: [_threadSummaries()]),
            ),
            approvalBridgeApiProvider.overrideWithValue(
              EmptyApprovalBridgeApi(),
            ),
            threadDetailBridgeApiProvider.overrideWithValue(detailApi),
            settingsBridgeApiProvider.overrideWithValue(
              FakeSettingsBridgeApi(),
            ),
            threadLiveStreamProvider.overrideWithValue(FakeThreadLiveStream()),
            threadCacheRepositoryProvider.overrideWithValue(
              _newCacheRepository(),
            ),
          ],
          child: const MaterialApp(
            home: ThreadDetailPage(
              bridgeApiBaseUrl: _bridgeApiBaseUrl,
              threadId: 'thread-456',
            ),
          ),
        ),
      );

      await tester.pump();
      await _pumpForTransientUiWork(tester, iterations: 2);

      expect(
        find.byKey(const Key('thread-detail-timeline-loading-state')),
        findsOneWidget,
      );
      expect(find.text('No timeline entries yet.'), findsNothing);

      timelineCompleter.complete(const <ThreadTimelineEntryDto>[]);
      await tester.pump();
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('thread-detail-timeline-loading-state')),
        findsNothing,
      );
      expect(find.text('No timeline entries yet.'), findsOneWidget);
    },
  );

  testWidgets(
    'thread detail deduplicates duplicate initial timeline event ids',
    (tester) async {
      const duplicateEventId = '0c9c581a-534e-46ee-994a-7f55181f6d47-claude-4';
      final detailApi = FakeThreadDetailBridgeApi(
        detailScriptByThreadId: {
          'thread-123': [_thread123Detail(status: ThreadStatus.completed)],
        },
        timelineScriptByThreadId: {
          'thread-123': [
            [
              _timelineEvent(
                id: duplicateEventId,
                kind: BridgeEventKind.messageDelta,
                summary: 'Claude duplicate output',
                payload: {
                  'type': 'agentMessage',
                  'role': 'assistant',
                  'text': 'Claude duplicate output',
                },
                occurredAt: '2026-03-18T10:02:00Z',
              ),
              _timelineEvent(
                id: duplicateEventId,
                kind: BridgeEventKind.messageDelta,
                summary: 'Claude duplicate output',
                payload: {
                  'type': 'agentMessage',
                  'role': 'assistant',
                  'text': 'Claude duplicate output',
                },
                occurredAt: '2026-03-18T10:02:00Z',
              ),
            ],
          ],
        },
      );

      await _pumpThreadDetailApp(
        tester,
        detailApi: detailApi,
        threadId: 'thread-123',
      );
      await tester.pumpAndSettle();

      expect(find.text('Claude duplicate output'), findsOneWidget);
      expect(
        find.byKey(Key('thread-message-card-$duplicateEventId')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'thread detail reaches the true bottom after a delayed large timeline load',
    (tester) async {
      final timelineCompleter = Completer<List<ThreadTimelineEntryDto>>();
      final detailApi = FakeThreadDetailBridgeApi(
        detailScriptByThreadId: {
          'thread-123': [_thread123Detail(status: ThreadStatus.completed)],
        },
        timelineScriptByThreadId: {
          'thread-123': [timelineCompleter.future],
        },
      );

      await _pumpThreadDetailApp(
        tester,
        detailApi: detailApi,
        threadId: 'thread-123',
        initialVisibleTimelineEntries: 160,
      );

      expect(
        find.byKey(const Key('thread-detail-timeline-loading-state')),
        findsOneWidget,
      );

      timelineCompleter.complete(<ThreadTimelineEntryDto>[
        for (var index = 0; index < 160; index += 1)
          _timelineEvent(
            id: 'evt-large-thread-$index',
            kind: BridgeEventKind.messageDelta,
            summary: 'Assistant output',
            payload: {
              'delta':
                  'Large thread entry $index\n${List<String>.filled(4, 'filler line $index').join('\n')}',
            },
            occurredAt:
                '2026-03-18T${(10 + (index ~/ 60)).toString().padLeft(2, '0')}:${(index % 60).toString().padLeft(2, '0')}:00Z',
          ),
      ]);

      await tester.pump();
      await _pumpForTransientUiWork(tester, iterations: 16);

      final position = _threadDetailScrollPosition(tester);
      expect(position.pixels, closeTo(position.maxScrollExtent, 1));
      expect(find.textContaining('Large thread entry 159'), findsOneWidget);
    },
  );

  testWidgets(
    'thread list header plus opens draft detail and submits first prompt through a created thread',
    (tester) async {
      final createdThread = ThreadDetailDto(
        contractVersion: contractVersion,
        threadId: 'thread-new',
        title: 'Fresh session',
        status: ThreadStatus.idle,
        workspace: '/workspace/vibe-bridge-companion',
        repository: 'vibe-bridge-companion',
        branch: 'main',
        createdAt: '2026-03-18T12:00:00Z',
        updatedAt: '2026-03-18T12:00:00Z',
        source: 'cli',
        accessMode: AccessMode.controlWithApprovals,
        lastTurnSummary: '',
      );
      final listApi = FakeThreadListBridgeApi(
        scriptedResults: [_threadSummaries()],
      );
      final detailApi = FakeThreadDetailBridgeApi(
        detailScriptByThreadId: {
          'thread-new': [createdThread],
        },
        timelineScriptByThreadId: {
          'thread-new': [<ThreadTimelineEntryDto>[]],
        },
        createThreadScript: [
          ThreadSnapshotDto(
            contractVersion: contractVersion,
            thread: createdThread,
            entries: const <ThreadTimelineEntryDto>[],
            approvals: const <ApprovalSummaryDto>[],
          ),
        ],
      );

      await _pumpThreadListApp(
        tester,
        listApi: listApi,
        detailApi: detailApi,
        liveStream: FakeThreadLiveStream(),
      );

      await tester.tap(find.byKey(const Key('thread-list-create-button')));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(
          const Key(
            'thread-list-workspace-option-/workspace/vibe-bridge-companion',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('thread-draft-title')), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('thread-draft-title')))
            .style
            ?.color,
        AppTheme.textMain,
      );
      expect(
        find.byKey(const Key('thread-draft-workspace-path')),
        findsOneWidget,
      );

      await tester.enterText(
        find.byKey(const Key('turn-composer-input')),
        'Plan the release',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('turn-composer-submit')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(detailApi.createThreadCallCount, 1);
      expect(
        detailApi.createdThreadWorkspaces,
        contains('/workspace/vibe-bridge-companion'),
      );
      expect(
        detailApi.startTurnPromptsByThreadId['thread-new'],
        equals(<String>['Plan the release']),
      );
      expect(find.byKey(const Key('thread-detail-title')), findsOneWidget);
    },
  );

  testWidgets(
    'live thread detail refreshes the generated title without leaving the page',
    (tester) async {
      final initialDetail = ThreadDetailDto(
        contractVersion: contractVersion,
        threadId: 'thread-123',
        title: 'New Thread',
        status: ThreadStatus.running,
        workspace: '/workspace/vibe-bridge-companion',
        repository: 'vibe-bridge-companion',
        branch: 'master',
        createdAt: '2026-03-18T09:45:00Z',
        updatedAt: '2026-03-18T10:00:00Z',
        source: 'cli',
        accessMode: AccessMode.controlWithApprovals,
        lastTurnSummary: 'Starting up',
      );
      final refreshedDetail = ThreadDetailDto(
        contractVersion: contractVersion,
        threadId: 'thread-123',
        title: 'Implement shared contracts',
        status: ThreadStatus.running,
        workspace: '/workspace/vibe-bridge-companion',
        repository: 'vibe-bridge-companion',
        branch: 'master',
        createdAt: '2026-03-18T09:45:00Z',
        updatedAt: '2026-03-18T10:00:02Z',
        source: 'cli',
        accessMode: AccessMode.controlWithApprovals,
        lastTurnSummary: 'Normalizing shared contract fields',
      );
      final listApi = FakeThreadListBridgeApi(
        scriptedResults: [
          [
            const ThreadSummaryDto(
              contractVersion: contractVersion,
              threadId: 'thread-123',
              title: 'New Thread',
              status: ThreadStatus.running,
              workspace: '/workspace/vibe-bridge-companion',
              repository: 'vibe-bridge-companion',
              branch: 'master',
              updatedAt: '2026-03-18T10:00:00Z',
            ),
          ],
        ],
      );
      final detailApi = FakeThreadDetailBridgeApi(
        detailScriptByThreadId: {
          'thread-123': [initialDetail, refreshedDetail],
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

      expect(
        tester.widget<Text>(find.byKey(const Key('thread-detail-title'))).data,
        'New Thread',
      );

      liveStream.emit(
        BridgeEventEnvelope<Map<String, dynamic>>(
          contractVersion: contractVersion,
          eventId: 'evt-title-refresh',
          threadId: 'thread-123',
          kind: BridgeEventKind.messageDelta,
          occurredAt: '2026-03-18T10:00:01Z',
          payload: {
            'type': 'agentMessage',
            'delta': 'Normalizing shared contract fields',
          },
        ),
      );

      await tester.pump(const Duration(milliseconds: 750));
      await tester.pumpAndSettle();

      expect(
        tester.widget<Text>(find.byKey(const Key('thread-detail-title'))).data,
        'Implement shared contracts',
      );
    },
  );

  testWidgets(
    'draft thread submission navigates even when selected-thread persistence stalls',
    (tester) async {
      final createdThread = ThreadDetailDto(
        contractVersion: contractVersion,
        threadId: 'thread-new',
        title: 'Fresh session',
        status: ThreadStatus.idle,
        workspace: '/workspace/vibe-bridge-companion',
        repository: 'vibe-bridge-companion',
        branch: 'main',
        createdAt: '2026-03-18T12:00:00Z',
        updatedAt: '2026-03-18T12:00:00Z',
        source: 'cli',
        accessMode: AccessMode.controlWithApprovals,
        lastTurnSummary: '',
      );
      final listApi = FakeThreadListBridgeApi(
        scriptedResults: [_threadSummaries()],
      );
      final detailApi = FakeThreadDetailBridgeApi(
        detailScriptByThreadId: {
          'thread-new': [createdThread],
        },
        timelineScriptByThreadId: {
          'thread-new': [<ThreadTimelineEntryDto>[]],
        },
        createThreadScript: [
          ThreadSnapshotDto(
            contractVersion: contractVersion,
            thread: createdThread,
            entries: const <ThreadTimelineEntryDto>[],
            approvals: const <ApprovalSummaryDto>[],
          ),
        ],
      );

      await _pumpThreadListApp(
        tester,
        listApi: listApi,
        detailApi: detailApi,
        liveStream: FakeThreadLiveStream(),
        cacheRepository: _HangingSelectedThreadCacheRepository(),
      );

      await tester.tap(find.byKey(const Key('thread-list-create-button')));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(
          const Key(
            'thread-list-workspace-option-/workspace/vibe-bridge-companion',
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('turn-composer-input')),
        'Plan the release',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('turn-composer-submit')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byKey(const Key('thread-detail-title')), findsOneWidget);
      expect(detailApi.createThreadCallCount, 1);
      expect(
        detailApi.startTurnPromptsByThreadId['thread-new'],
        equals(<String>['Plan the release']),
      );
    },
  );

  testWidgets('thread detail submits composer input from the keyboard action', (
    tester,
  ) async {
    final detailApi = FakeThreadDetailBridgeApi(
      detailScriptByThreadId: {
        'thread-456': [_thread456Detail()],
      },
      timelineScriptByThreadId: {
        'thread-456': [<ThreadTimelineEntryDto>[]],
      },
    );

    await _pumpThreadDetailApp(
      tester,
      detailApi: detailApi,
      threadId: 'thread-456',
    );

    final composerInput = find.byKey(const Key('turn-composer-input'));
    await tester.showKeyboard(composerInput);
    await tester.enterText(composerInput, 'Send this from the keyboard.');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(detailApi.startTurnPromptsByThreadId['thread-456'], [
      'Send this from the keyboard.',
    ]);
  });

  testWidgets(
    'thread detail restores an unsent composer draft after leaving and reopening',
    (tester) async {
      final detailApi = FakeThreadDetailBridgeApi(
        detailScriptByThreadId: {
          'thread-123': [
            _thread123Detail(status: ThreadStatus.idle),
            _thread123Detail(status: ThreadStatus.idle),
          ],
        },
        timelineScriptByThreadId: {
          'thread-123': [
            <ThreadTimelineEntryDto>[],
            <ThreadTimelineEntryDto>[],
          ],
        },
      );
      final store = InMemorySecureStore();
      final cacheRepository = _newCacheRepository(store: store);

      await _pumpThreadDetailApp(
        tester,
        detailApi: detailApi,
        threadId: 'thread-123',
        cacheRepository: cacheRepository,
        store: store,
      );

      await tester.enterText(
        find.byKey(const Key('turn-composer-input')),
        'Unsaved prompt draft',
      );
      await tester.pumpAndSettle();

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();

      await _pumpThreadDetailApp(
        tester,
        detailApi: detailApi,
        threadId: 'thread-123',
        cacheRepository: cacheRepository,
        store: store,
      );
      await tester.pumpAndSettle();

      final composer = tester.widget<TextField>(
        find.byKey(const Key('turn-composer-input')),
      );
      expect(composer.controller?.text, 'Unsaved prompt draft');
    },
  );

  testWidgets(
    'successful composer submission clears the persisted thread draft',
    (tester) async {
      final detailApi = FakeThreadDetailBridgeApi(
        detailScriptByThreadId: {
          'thread-123': [
            _thread123Detail(status: ThreadStatus.idle),
            _thread123Detail(status: ThreadStatus.idle),
          ],
        },
        timelineScriptByThreadId: {
          'thread-123': [
            <ThreadTimelineEntryDto>[],
            <ThreadTimelineEntryDto>[],
          ],
        },
        startTurnScriptByThreadId: {
          'thread-123': [
            _turnMutationResult(
              threadId: 'thread-123',
              operation: 'start_turn',
              status: ThreadStatus.running,
              message: 'Turn started',
            ),
          ],
        },
      );
      final store = InMemorySecureStore();
      final cacheRepository = _newCacheRepository(store: store);

      await _pumpThreadDetailApp(
        tester,
        detailApi: detailApi,
        threadId: 'thread-123',
        cacheRepository: cacheRepository,
        store: store,
      );

      await tester.enterText(
        find.byKey(const Key('turn-composer-input')),
        'Ship the fix',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('turn-composer-submit')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();

      await _pumpThreadDetailApp(
        tester,
        detailApi: detailApi,
        threadId: 'thread-123',
        cacheRepository: cacheRepository,
        store: store,
      );
      await tester.pumpAndSettle();

      final composer = tester.widget<TextField>(
        find.byKey(const Key('turn-composer-input')),
      );
      expect(composer.controller?.text, isEmpty);
    },
  );

  testWidgets(
    'real-thread initial 80-entry slice keeps latest context and bundled work activity visible',
    (tester) async {
      final fixture = _loadRealThreadFixture();

      final detailApi = FakeThreadDetailBridgeApi(
        detailScriptByThreadId: {
          fixture.detail.threadId: [fixture.detail],
        },
        timelineScriptByThreadId: {
          fixture.detail.threadId: [fixture.timelineEntries],
        },
      );

      await _pumpThreadDetailApp(
        tester,
        detailApi: detailApi,
        threadId: fixture.detail.threadId,
        initialVisibleTimelineEntries: 80,
      );
      await tester.pumpAndSettle();

      final latestMessage = find.textContaining(
        'All of the old local app/server processes are down.',
      );
      final workSummary = find.byKey(const Key('thread-work-summary-title'));

      final args = ThreadDetailControllerArgs(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
        threadId: fixture.detail.threadId,
        initialVisibleTimelineEntries: 80,
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ThreadDetailPage)),
      );
      final controllerState = container.read(
        threadDetailControllerProvider(args),
      );

      await _scrollUntilVisible(tester, latestMessage);

      expect(latestMessage, findsOneWidget);
      expect(workSummary, findsWidgets);
      expect(
        controllerState.visibleItems.any(
          (item) =>
              item.type == ThreadActivityItemType.fileChange &&
              item.body.contains('*** Begin Patch'),
        ),
        isTrue,
      );
      expect(
        controllerState.visibleItems.any(
          (item) =>
              item.type == ThreadActivityItemType.terminalOutput &&
              item.body.contains('kill -9 16121 16103'),
        ),
        isTrue,
      );
      expect(detailApi.timelineFetchCount, 1);
    },
  );

  testWidgets(
    'real-thread older-history pagination prepends older activity and keeps event ids unique',
    (tester) async {
      final latestPageFixture = _loadRealThreadFixture();
      final olderPageFixture = _loadRealThreadOlderTimelineFixture();
      final duplicatedOlderEntries = <ThreadTimelineEntryDto>[
        olderPageFixture.entries.first,
        olderPageFixture.entries[1],
        olderPageFixture.entries[1],
        ...olderPageFixture.entries.skip(2),
      ];

      final combinedTimeline = <ThreadTimelineEntryDto>[
        ...duplicatedOlderEntries,
        ...latestPageFixture.timelineEntries,
      ];

      final detailApi = FakeThreadDetailBridgeApi(
        detailScriptByThreadId: {
          latestPageFixture.detail.threadId: [latestPageFixture.detail],
        },
        timelineScriptByThreadId: {
          latestPageFixture.detail.threadId: [combinedTimeline],
        },
      );

      await _pumpThreadDetailApp(
        tester,
        detailApi: detailApi,
        threadId: latestPageFixture.detail.threadId,
        initialVisibleTimelineEntries: 80,
      );
      await tester.pumpAndSettle();

      final args = ThreadDetailControllerArgs(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
        threadId: latestPageFixture.detail.threadId,
        initialVisibleTimelineEntries: 80,
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ThreadDetailPage)),
      );
      final controller = container.read(
        threadDetailControllerProvider(args).notifier,
      );

      var controllerState = container.read(
        threadDetailControllerProvider(args),
      );
      final initialIds = controllerState.items
          .map((item) => item.eventId)
          .toList(growable: false);
      expect(initialIds.length, 80);
      expect(initialIds.toSet().length, 80);

      await controller.loadEarlierHistory();
      await tester.pumpAndSettle();

      controllerState = container.read(threadDetailControllerProvider(args));
      expect(controllerState.items.length, greaterThan(initialIds.length));

      await controller.loadEarlierHistory();
      await tester.pumpAndSettle();

      controllerState = container.read(threadDetailControllerProvider(args));
      final pagedIds = controllerState.items
          .map((item) => item.eventId)
          .toList(growable: false);

      expect(pagedIds.length, greaterThan(initialIds.length));
      expect(pagedIds.toSet().length, pagedIds.length);
      expect(controllerState.hasMoreBefore, isFalse);
      expect(pagedIds.first, equals(olderPageFixture.entries.first.eventId));
      expect(
        pagedIds.last,
        equals(latestPageFixture.timelineEntries.last.eventId),
      );
    },
  );

  testWidgets(
    'real-thread older-history pagination keeps the current viewport anchored while prepending earlier events',
    (tester) async {
      final latestPageFixture = _loadRealThreadFixture();
      final olderPageFixture = _loadRealThreadOlderTimelineFixture();
      final combinedTimeline = <ThreadTimelineEntryDto>[
        ...olderPageFixture.entries,
        ...latestPageFixture.timelineEntries,
      ];

      final detailApi = FakeThreadDetailBridgeApi(
        detailScriptByThreadId: {
          latestPageFixture.detail.threadId: [latestPageFixture.detail],
        },
        timelineScriptByThreadId: {
          latestPageFixture.detail.threadId: [combinedTimeline],
        },
      );

      await _pumpThreadDetailApp(
        tester,
        detailApi: detailApi,
        threadId: latestPageFixture.detail.threadId,
        initialVisibleTimelineEntries: 80,
      );
      await tester.pumpAndSettle();

      final scrollViewFinder = find.byKey(
        const Key('thread-detail-scroll-view'),
      );
      final scrollView = tester.widget<ListView>(scrollViewFinder);
      final scrollController = scrollView.controller!;
      final args = ThreadDetailControllerArgs(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
        threadId: latestPageFixture.detail.threadId,
        initialVisibleTimelineEntries: 80,
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ThreadDetailPage)),
      );
      final controllerState = container.read(
        threadDetailControllerProvider(args),
      );
      final initialBlocks = buildThreadTimelineBlocks(
        controllerState.visibleItems,
      );
      final anchorFinder = find.byKey(
        ValueKey(_timelineBlockKeyForTest(initialBlocks.first)),
      );

      scrollController.jumpTo(100);
      await tester.pump();

      expect(anchorFinder, findsOneWidget);
      final anchorTopBefore = tester.getTopLeft(anchorFinder).dy;

      await tester.drag(scrollViewFinder, const Offset(0, 80));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();

      expect(detailApi.timelineFetchCount, 2);

      final anchorTopAfter = tester.getTopLeft(anchorFinder).dy;
      expect(anchorTopAfter, closeTo(anchorTopBefore, 48));
    },
  );

  testWidgets(
    'Fix Codex thread status older-history pagination follows the correct before cursor across deep archived pages',
    (tester) async {
      final latestPageFixture =
          _loadFixCodexThreadStatusLatestTimelineFixture();
      final firstOlderPageFixture =
          _loadFixCodexThreadStatusOlderTimelineFixture();
      final secondOlderPageFixture =
          _loadFixCodexThreadStatusOldestTimelineFixture();

      final detailApi = _ScriptedTimelinePageThreadDetailBridgeApi(
        detail: latestPageFixture.thread,
        pagesByBefore: {
          null: latestPageFixture,
          latestPageFixture.nextBefore!: firstOlderPageFixture,
          firstOlderPageFixture.nextBefore!: secondOlderPageFixture,
        },
      );

      await _pumpThreadDetailApp(
        tester,
        detailApi: detailApi,
        threadId: latestPageFixture.thread.threadId,
        initialVisibleTimelineEntries: 80,
      );
      await tester.pumpAndSettle();

      final args = ThreadDetailControllerArgs(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
        threadId: latestPageFixture.thread.threadId,
        initialVisibleTimelineEntries: 80,
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ThreadDetailPage)),
      );
      final controller = container.read(
        threadDetailControllerProvider(args).notifier,
      );

      expect(detailApi.historyRequests.length, 1);
      expect(detailApi.historyRequests.single.before, isNull);

      await controller.loadEarlierHistory();
      await tester.pumpAndSettle();

      var controllerState = container.read(
        threadDetailControllerProvider(args),
      );

      expect(detailApi.historyRequests.length, 2);
      expect(detailApi.historyRequests[1].before, latestPageFixture.nextBefore);
      expect(
        controllerState.visibleItems.any(
          (item) => item.body.contains(
            'I’m editing the controller now. The change is narrow',
          ),
        ),
        isTrue,
      );

      await controller.loadEarlierHistory();
      await tester.pumpAndSettle();

      controllerState = container.read(threadDetailControllerProvider(args));

      expect(detailApi.historyRequests.length, 3);
      expect(
        detailApi.historyRequests[2].before,
        firstOlderPageFixture.nextBefore,
      );
      expect(controllerState.hasMoreBefore, isTrue);
    },
  );

  testWidgets(
    'Fix Codex thread status older-history pagination keeps the current viewport anchored across multi-page prepends',
    (tester) async {
      final latestPageFixture =
          _loadFixCodexThreadStatusLatestTimelineFixture();
      final firstOlderPageFixture =
          _loadFixCodexThreadStatusOlderTimelineFixture();
      final secondOlderPageFixture =
          _loadFixCodexThreadStatusOldestTimelineFixture();

      final detailApi = _ScriptedTimelinePageThreadDetailBridgeApi(
        detail: latestPageFixture.thread,
        pagesByBefore: {
          null: latestPageFixture,
          latestPageFixture.nextBefore!: firstOlderPageFixture,
          firstOlderPageFixture.nextBefore!: secondOlderPageFixture,
        },
        delaysByBefore: {
          latestPageFixture.nextBefore: const Duration(milliseconds: 120),
          firstOlderPageFixture.nextBefore: const Duration(milliseconds: 120),
        },
      );

      await _pumpThreadDetailApp(
        tester,
        detailApi: detailApi,
        threadId: latestPageFixture.thread.threadId,
        initialVisibleTimelineEntries: 80,
      );
      await tester.pumpAndSettle();

      final scrollViewFinder = find.byKey(
        const Key('thread-detail-scroll-view'),
      );
      final scrollView = tester.widget<ListView>(scrollViewFinder);
      final scrollController = scrollView.controller!;
      final args = ThreadDetailControllerArgs(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
        threadId: latestPageFixture.thread.threadId,
        initialVisibleTimelineEntries: 80,
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ThreadDetailPage)),
      );
      final controllerState = container.read(
        threadDetailControllerProvider(args),
      );
      final initialBlocks = buildThreadTimelineBlocks(
        controllerState.visibleItems,
      );
      final anchorBlock = initialBlocks.firstWhere(
        (block) => block.item != null,
        orElse: () => initialBlocks.first,
      );
      final anchorFinder = find.byKey(
        ValueKey(_timelineBlockKeyForTest(anchorBlock)),
      );

      scrollController.jumpTo(100);
      await tester.pump();

      expect(anchorFinder, findsOneWidget);
      final anchorTopBefore = tester.getTopLeft(anchorFinder).dy;

      await tester.drag(scrollViewFinder, const Offset(0, 80));
      await tester.pump();
      await _pumpUntilCondition(
        tester,
        () => detailApi.completedHistoryRequests >= 2,
      );
      await tester.pumpAndSettle();

      expect(detailApi.historyRequests.length, 2);
      expect(detailApi.historyRequests[1].before, latestPageFixture.nextBefore);

      final anchorTopAfter = tester.getTopLeft(anchorFinder).dy;
      expect(anchorTopAfter, closeTo(anchorTopBefore, 72));
    },
  );

  testWidgets(
    'real-thread apply_patch activity renders as file-change UI without raw patch scaffolding as the primary view',
    (tester) async {
      final fixture = _loadRealThreadFixture();
      final applyPatchEntry = fixture.timelineEntries.firstWhere(
        (entry) =>
            entry.kind == BridgeEventKind.fileChange &&
            (entry.payload['change'] as String?)?.contains('*** Begin Patch') ==
                true,
      );

      final detailApi = FakeThreadDetailBridgeApi(
        detailScriptByThreadId: {
          fixture.detail.threadId: [fixture.detail],
        },
        timelineScriptByThreadId: {
          fixture.detail.threadId: [
            <ThreadTimelineEntryDto>[applyPatchEntry],
          ],
        },
      );

      await _pumpThreadDetailApp(
        tester,
        detailApi: detailApi,
        threadId: fixture.detail.threadId,
      );
      await tester.pumpAndSettle();

      final toggle = find.byKey(
        const Key('thread-file-change-toggle-thread_api.rs'),
      );
      await _scrollUntilVisible(tester, toggle);

      expect(toggle, findsOneWidget);
      expect(find.textContaining('*** Begin Patch'), findsNothing);

      await tester.tap(toggle);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('thread-diff-file-thread_api.rs')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'real-thread hidden noise suppression keeps labeled exploration grouping and meaningful activity visible',
    (tester) async {
      final fixture = _loadRealThreadFixture();

      final hiddenNoiseEntry = fixture.timelineEntries.firstWhere(
        (entry) =>
            entry.kind == BridgeEventKind.commandDelta &&
            entry.payload['command'] == 'write_stdin',
      );
      final readExplorationEntry = fixture.timelineEntries.firstWhere(
        (entry) =>
            entry.annotations?.groupKind ==
                ThreadTimelineGroupKind.exploration &&
            entry.annotations?.explorationKind ==
                ThreadTimelineExplorationKind.read &&
            entry.annotations?.entryLabel == 'Read thread_api.rs',
      );
      final searchExplorationSource = fixture.timelineEntries.firstWhere((
        entry,
      ) {
        if (entry.kind != BridgeEventKind.commandDelta) {
          return false;
        }
        final arguments = entry.payload['arguments'];
        return arguments is String && arguments.contains(' rg ');
      });
      final searchExplorationEntry = ThreadTimelineEntryDto(
        eventId: '${searchExplorationSource.eventId}-search-annotation',
        kind: searchExplorationSource.kind,
        occurredAt: searchExplorationSource.occurredAt,
        summary: searchExplorationSource.summary,
        payload: searchExplorationSource.payload,
        annotations: _explorationAnnotations(
          explorationKind: ThreadTimelineExplorationKind.search,
          entryLabel: 'Search process state',
        ),
      );
      final fileChangeEntry = fixture.timelineEntries.firstWhere(
        (entry) =>
            entry.kind == BridgeEventKind.fileChange &&
            (entry.payload['change'] as String?)?.contains('*** Begin Patch') ==
                true,
      );
      final messageEntry = fixture.timelineEntries.firstWhere((entry) {
        if (entry.kind != BridgeEventKind.messageDelta) {
          return false;
        }
        final delta = entry.payload['delta'];
        return delta is String &&
            delta.contains(
              'All of the old local app/server processes are down.',
            );
      });

      final timeline = <ThreadTimelineEntryDto>[
        hiddenNoiseEntry,
        readExplorationEntry,
        searchExplorationEntry,
        fileChangeEntry,
        messageEntry,
      ]..sort((a, b) => a.occurredAt.compareTo(b.occurredAt));

      final detailApi = FakeThreadDetailBridgeApi(
        detailScriptByThreadId: {
          fixture.detail.threadId: [fixture.detail],
        },
        timelineScriptByThreadId: {
          fixture.detail.threadId: [timeline],
        },
      );

      await _pumpThreadDetailApp(
        tester,
        detailApi: detailApi,
        threadId: fixture.detail.threadId,
      );
      await tester.pumpAndSettle();

      await _scrollUntilVisible(
        tester,
        find.byKey(const Key('thread-work-summary-title')),
      );

      expect(find.text('write_stdin'), findsNothing);
      expect(
        find.byKey(const Key('thread-work-summary-title')),
        findsOneWidget,
      );
      expect(find.text('Explored 1 file, 1 search'), findsNothing);

      await tester.tap(find.byKey(const Key('thread-work-summary-title')));
      await tester.pumpAndSettle();

      expect(find.text('Explored 1 file, 1 search'), findsOneWidget);
      expect(find.text('Read thread_api.rs'), findsOneWidget);
      expect(
        find.byKey(const Key('thread-file-change-toggle-thread_api.rs')),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'All of the old local app/server processes are down.',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'real-thread grouped exploration preserves read labels and bridge search label/count',
    (tester) async {
      final detailFixture = _loadRealThreadFixture();
      final explorationFixture =
          _loadRealThreadSearchExplorationTimelineFixture();

      final explorationEntries = explorationFixture.entries
          .where(
            (entry) =>
                entry.annotations?.groupKind ==
                    ThreadTimelineGroupKind.exploration &&
                (entry.annotations?.explorationKind ==
                        ThreadTimelineExplorationKind.read ||
                    entry.annotations?.explorationKind ==
                        ThreadTimelineExplorationKind.search),
          )
          .toList(growable: false);
      final fileChangeEntry = explorationFixture.entries.firstWhere(
        (entry) =>
            entry.eventId == '019d0d0c-07df-7632-81fa-a1636651400a-archive-474',
      );

      final timeline = <ThreadTimelineEntryDto>[
        ...explorationEntries,
        fileChangeEntry,
      ]..sort((a, b) => a.occurredAt.compareTo(b.occurredAt));

      final detailApi = FakeThreadDetailBridgeApi(
        detailScriptByThreadId: {
          detailFixture.detail.threadId: [detailFixture.detail],
        },
        timelineScriptByThreadId: {
          detailFixture.detail.threadId: [timeline],
        },
      );

      await _pumpThreadDetailApp(
        tester,
        detailApi: detailApi,
        threadId: detailFixture.detail.threadId,
      );
      await tester.pumpAndSettle();

      await _scrollUntilVisible(
        tester,
        find.byKey(const Key('thread-work-summary-title')),
      );

      expect(
        find.byKey(const Key('thread-work-summary-title')),
        findsOneWidget,
      );
      expect(find.text('Explored 2 files, 4 searches'), findsNothing);

      await tester.tap(find.byKey(const Key('thread-work-summary-title')));
      await tester.pumpAndSettle();

      expect(find.text('Explored 2 files, 4 searches'), findsOneWidget);
      expect(find.text('Read thread_detail_controller.dart'), findsOneWidget);
      expect(find.text('Read thread_api.rs'), findsOneWidget);
      expect(find.text('Search (4)'), findsOneWidget);
      expect(
        find.byKey(const Key('thread-file-change-toggle-thread_api.rs')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'assistant code blocks infer syntax highlighting from nearby file path',
    (tester) async {
      final detailApi = FakeThreadDetailBridgeApi(
        detailScriptByThreadId: {
          'thread-123': [_thread123Detail(status: ThreadStatus.completed)],
        },
        timelineScriptByThreadId: {
          'thread-123': [
            <ThreadTimelineEntryDto>[
              _timelineEvent(
                id: 'evt-code',
                kind: BridgeEventKind.messageDelta,
                summary: 'Assistant output',
                payload: {
                  'type': 'agentMessage',
                  'text':
                      'Updated `apps/mobile/lib/main.dart`:\n\n```\nvoid main() {\n  runApp(const Placeholder());\n}\n```',
                },
                occurredAt: '2026-03-18T10:02:00Z',
              ),
            ],
          ],
        },
      );

      await _pumpThreadDetailApp(
        tester,
        detailApi: detailApi,
        threadId: 'thread-123',
      );
      await tester.pumpAndSettle();

      await _scrollUntilVisible(
        tester,
        find.byKey(const Key('thread-code-file-main.dart')),
      );
      expect(
        find.byKey(const Key('thread-code-file-main.dart')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('thread-code-language-dart')),
        findsOneWidget,
      );
      expect(
        find.textContaining('runApp(const Placeholder())'),
        findsOneWidget,
      );
    },
  );

  testWidgets('assistant inline backticks render as quoted text', (
    tester,
  ) async {
    final detailApi = FakeThreadDetailBridgeApi(
      detailScriptByThreadId: {
        'thread-123': [_thread123Detail(status: ThreadStatus.completed)],
      },
      timelineScriptByThreadId: {
        'thread-123': [
          <ThreadTimelineEntryDto>[
            _timelineEvent(
              id: 'evt-quote',
              kind: BridgeEventKind.messageDelta,
              summary: 'Assistant output',
              payload: {
                'type': 'agentMessage',
                'text':
                    'Summary: `This came from the earlier discussion.` Next step.',
              },
              occurredAt: '2026-03-18T10:02:00Z',
            ),
          ],
        ],
      },
    );

    await _pumpThreadDetailApp(
      tester,
      detailApi: detailApi,
      threadId: 'thread-123',
    );
    await tester.pumpAndSettle();

    await _scrollUntilVisible(
      tester,
      find.byKey(const Key('thread-message-text-0')),
    );
    final textFinder = find.byKey(const Key('thread-message-text-0'));
    expect(textFinder, findsWidgets);
    final selectableTextFinder = find.descendant(
      of: textFinder.first,
      matching: find.byType(SelectableText),
    );
    expect(selectableTextFinder, findsOneWidget);
    final messageText = tester.widget<SelectableText>(selectableTextFinder);
    final rootSpan = messageText.textSpan;
    expect(rootSpan, isNotNull);
    final children = rootSpan!.children;
    expect(children, hasLength(3));
    expect((children![0] as TextSpan).text, 'Summary: ');
    expect(
      (children[1] as TextSpan).text,
      'This came from the earlier discussion.',
    );
    expect((children[1] as TextSpan).style?.color, AppTheme.emerald);
    expect((children[2] as TextSpan).text, ' Next step.');
  });

  testWidgets(
    'assistant standalone markdown bold titles render without asterisks',
    (tester) async {
      final detailApi = FakeThreadDetailBridgeApi(
        detailScriptByThreadId: {
          'thread-123': [_thread123Detail(status: ThreadStatus.completed)],
        },
        timelineScriptByThreadId: {
          'thread-123': [
            <ThreadTimelineEntryDto>[
              _timelineEvent(
                id: 'evt-title',
                kind: BridgeEventKind.messageDelta,
                summary: 'Assistant output',
                payload: {
                  'type': 'agentMessage',
                  'text': '** Title **\nBody copy follows.',
                },
                occurredAt: '2026-03-18T10:02:00Z',
              ),
            ],
          ],
        },
      );

      await _pumpThreadDetailApp(
        tester,
        detailApi: detailApi,
        threadId: 'thread-123',
      );
      await tester.pumpAndSettle();

      await _scrollUntilVisible(
        tester,
        find.byKey(const Key('thread-message-text-0')),
      );
      expect(find.text('** Title **'), findsNothing);

      final textFinder = find.byKey(const Key('thread-message-text-0'));
      final selectableTextFinder = find.descendant(
        of: textFinder.first,
        matching: find.byType(SelectableText),
      );
      final messageText = tester.widget<SelectableText>(selectableTextFinder);
      final rootSpan = messageText.textSpan;
      expect(rootSpan, isNotNull);
      final children = rootSpan!.children;
      expect(children, hasLength(3));
      expect((children![0] as TextSpan).text, 'Title');
      expect((children[0] as TextSpan).style?.fontWeight, FontWeight.w700);
      expect((children[1] as TextSpan).text, '\n');
      expect((children[2] as TextSpan).text, 'Body copy follows.');
    },
  );

  testWidgets('markdown file links show only the label in accent color', (
    tester,
  ) async {
    final detailApi = FakeThreadDetailBridgeApi(
      detailScriptByThreadId: {
        'thread-123': [_thread123Detail()],
      },
      timelineScriptByThreadId: {
        'thread-123': [
          <ThreadTimelineEntryDto>[
            _timelineEvent(
              id: 'evt-link',
              kind: BridgeEventKind.messageDelta,
              summary: 'Assistant output',
              payload: {
                'type': 'agentMessage',
                'text':
                    'See [apps/mobile/pubspec.yaml](/Users/lubomirmolin/PhpstormProjects/vibe-bridge-companion/apps/mobile/pubspec.yaml#L33) for details.',
              },
              occurredAt: '2026-03-18T10:02:00Z',
            ),
          ],
        ],
      },
    );

    await _pumpThreadDetailApp(
      tester,
      detailApi: detailApi,
      threadId: 'thread-123',
    );
    await tester.pumpAndSettle();

    await _scrollUntilVisible(
      tester,
      find.byKey(const Key('thread-message-text-0')),
    );
    expect(
      find.textContaining('/Users/lubomirmolin/PhpstormProjects'),
      findsNothing,
    );

    final textFinder = find.byKey(const Key('thread-message-text-0'));
    expect(textFinder, findsWidgets);
    final selectableTextFinder = find.descendant(
      of: textFinder.first,
      matching: find.byType(SelectableText),
    );
    expect(selectableTextFinder, findsOneWidget);
    final messageText = tester.widget<SelectableText>(selectableTextFinder);
    final rootSpan = messageText.textSpan;
    expect(rootSpan, isNotNull);
    final children = rootSpan!.children;
    expect(children, hasLength(3));
    expect((children![0] as TextSpan).text, 'See ');
    expect((children[1] as TextSpan).text, 'apps/mobile/pubspec.yaml');
    expect((children[1] as TextSpan).style?.color, AppTheme.emerald);
    expect((children[2] as TextSpan).text, ' for details.');
  });

  testWidgets(
    'markdown file links with wrapped targets still render as emerald labels',
    (tester) async {
      final detailApi = FakeThreadDetailBridgeApi(
        detailScriptByThreadId: {
          'thread-123': [_thread123Detail()],
        },
        timelineScriptByThreadId: {
          'thread-123': [
            <ThreadTimelineEntryDto>[
              _timelineEvent(
                id: 'evt-link-wrapped',
                kind: BridgeEventKind.messageDelta,
                summary: 'Assistant output',
                payload: {
                  'type': 'agentMessage',
                  'text':
                      'State comes from [PairingEntryViewModel.swift]((/Users/lubomirmolin/PhpstormProjects/codex-mobile-companion/apps/mac-shell/Sources/ViewModel/PairingEntryViewModel.swift#L107)), which starts supervision on launch.',
                },
                occurredAt: '2026-03-18T10:02:00Z',
              ),
            ],
          ],
        },
      );

      await _pumpThreadDetailApp(
        tester,
        detailApi: detailApi,
        threadId: 'thread-123',
      );
      await tester.pumpAndSettle();

      await _scrollUntilVisible(
        tester,
        find.byKey(const Key('thread-message-text-0')),
      );

      expect(
        find.textContaining('/Users/lubomirmolin/PhpstormProjects'),
        findsNothing,
      );

      final textFinder = find.byKey(const Key('thread-message-text-0'));
      final selectableTextFinder = find.descendant(
        of: textFinder.first,
        matching: find.byType(SelectableText),
      );
      final messageText = tester.widget<SelectableText>(selectableTextFinder);
      final rootSpan = messageText.textSpan;
      expect(rootSpan, isNotNull);
      final children = rootSpan!.children;
      expect(children, hasLength(3));
      expect((children![0] as TextSpan).text, 'State comes from ');
      expect((children[1] as TextSpan).text, 'PairingEntryViewModel.swift');
      expect((children[1] as TextSpan).style?.color, AppTheme.emerald);
      expect(
        (children[2] as TextSpan).text,
        ', which starts supervision on launch.',
      );
    },
  );

  testWidgets('markdown bullet lists render as separate list rows', (
    tester,
  ) async {
    final detailApi = FakeThreadDetailBridgeApi(
      detailScriptByThreadId: {
        'thread-123': [_thread123Detail(status: ThreadStatus.completed)],
      },
      timelineScriptByThreadId: {
        'thread-123': [
          <ThreadTimelineEntryDto>[
            _timelineEvent(
              id: 'evt-list',
              kind: BridgeEventKind.messageDelta,
              summary: 'Assistant output',
              payload: {
                'type': 'agentMessage',
                'text':
                    'If you want, I can draft:\n- a 5-6 sentence responsible disclosure note\n- a fuller bug report with title, severity, impact, PoC, and remediation',
              },
              occurredAt: '2026-03-18T10:02:00Z',
            ),
          ],
        ],
      },
    );

    await _pumpThreadDetailApp(
      tester,
      detailApi: detailApi,
      threadId: 'thread-123',
    );
    await tester.pumpAndSettle();

    await _scrollUntilVisible(
      tester,
      find.byKey(const Key('thread-message-text-0')),
    );

    expect(find.byKey(const Key('thread-message-text-0')), findsWidgets);
    expect(find.byKey(const Key('thread-message-list-1')), findsOneWidget);
    expect(
      find.byKey(const Key('thread-message-list-1-item-0-marker')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<Text>(
            find.byKey(const Key('thread-message-list-1-item-0-marker')),
          )
          .data,
      '•',
    );

    final firstItemFinder = find.byKey(
      const Key('thread-message-list-1-item-0-text'),
    );
    final secondItemFinder = find.byKey(
      const Key('thread-message-list-1-item-1-text'),
    );
    expect(firstItemFinder, findsWidgets);
    expect(secondItemFinder, findsWidgets);

    final firstSelectable = find.descendant(
      of: firstItemFinder,
      matching: find.byType(SelectableText),
    );
    final secondSelectable = find.descendant(
      of: secondItemFinder,
      matching: find.byType(SelectableText),
    );
    expect(firstSelectable, findsOneWidget);
    expect(secondSelectable, findsOneWidget);
    expect(
      tester.widget<SelectableText>(firstSelectable).data,
      'a 5-6 sentence responsible disclosure note',
    );
    expect(
      tester.widget<SelectableText>(secondSelectable).data,
      'a fuller bug report with title, severity, impact, PoC, and remediation',
    );
  });

  testWidgets(
    'thread detail hides lifecycle and security noise from the conversation timeline',
    (tester) async {
      final detailApi = FakeThreadDetailBridgeApi(
        detailScriptByThreadId: {
          'thread-123': [_thread123Detail(status: ThreadStatus.completed)],
        },
        timelineScriptByThreadId: {
          'thread-123': [
            <ThreadTimelineEntryDto>[
              _timelineEvent(
                id: 'evt-status',
                kind: BridgeEventKind.threadStatusChanged,
                summary: 'Thread lifecycle',
                payload: {'status': 'idle', 'reason': 'upstream_sync'},
                occurredAt: '2026-03-18T10:00:00Z',
              ),
              _timelineEvent(
                id: 'evt-security',
                kind: BridgeEventKind.securityAudit,
                summary: 'Security event',
                payload: {'outcome': 'allowed', 'reason': 'policy_allow'},
                occurredAt: '2026-03-18T10:00:01Z',
              ),
              _timelineEvent(
                id: 'evt-user',
                kind: BridgeEventKind.messageDelta,
                summary: 'User prompt',
                payload: {
                  'type': 'userMessage',
                  'content': [
                    {'text': 'reply test123'},
                  ],
                },
                occurredAt: '2026-03-18T10:00:02Z',
              ),
            ],
          ],
        },
      );

      await _pumpThreadDetailApp(
        tester,
        detailApi: detailApi,
        threadId: 'thread-123',
      );
      await tester.pumpAndSettle();

      expect(find.text('reply test123'), findsOneWidget);
      expect(find.text('Thread lifecycle'), findsNothing);
      expect(find.text('Security event'), findsNothing);
      expect(find.text('policy_allow'), findsNothing);
    },
  );

  testWidgets('message attachments render inline images', (tester) async {
    const transparentPngDataUrl =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9WnR6GsAAAAASUVORK5CYII=';

    final detailApi = FakeThreadDetailBridgeApi(
      detailScriptByThreadId: {
        'thread-123': [_thread123Detail()],
      },
      timelineScriptByThreadId: {
        'thread-123': [
          <ThreadTimelineEntryDto>[
            _timelineEvent(
              id: 'evt-image',
              kind: BridgeEventKind.messageDelta,
              summary: 'Attached image',
              payload: {
                'type': 'userMessage',
                'content': [
                  {'type': 'text', 'text': 'Can you inspect this screenshot?'},
                  {'type': 'image', 'image_url': transparentPngDataUrl},
                ],
              },
              occurredAt: '2026-03-18T10:02:00Z',
            ),
          ],
        ],
      },
    );

    await _pumpThreadDetailApp(
      tester,
      detailApi: detailApi,
      threadId: 'thread-123',
    );
    await tester.pumpAndSettle();

    await _scrollUntilVisible(
      tester,
      find.byKey(const Key('thread-message-image-0')),
    );
    expect(find.byKey(const Key('thread-message-image-0')), findsOneWidget);
  });

  testWidgets('network images reserve space before the frame resolves', (
    tester,
  ) async {
    const unresolvedImageUrl = 'https://example.invalid/thread-image.png';

    final detailApi = FakeThreadDetailBridgeApi(
      detailScriptByThreadId: {
        'thread-123': [_thread123Detail()],
      },
      timelineScriptByThreadId: {
        'thread-123': [
          <ThreadTimelineEntryDto>[
            _timelineEvent(
              id: 'evt-network-image',
              kind: BridgeEventKind.messageDelta,
              summary: 'Attached image',
              payload: {
                'type': 'userMessage',
                'content': [
                  {'type': 'text', 'text': 'Check this remote image'},
                  {'type': 'image', 'image_url': unresolvedImageUrl},
                ],
              },
              occurredAt: '2026-03-18T10:02:00Z',
            ),
          ],
        ],
      },
    );

    await _pumpThreadDetailApp(
      tester,
      detailApi: detailApi,
      threadId: 'thread-123',
    );

    final imageFinder = find.byKey(const Key('thread-message-image-0'));
    await _scrollUntilVisible(tester, imageFinder);

    final initialHeight = tester.getSize(imageFinder).height;
    await tester.pump(const Duration(milliseconds: 250));
    final settledHeight = tester.getSize(imageFinder).height;

    expect(initialHeight, greaterThan(180));
    expect(settledHeight, initialHeight);
  });

  testWidgets('message swipe settles cleanly without a persistent timestamp', (
    tester,
  ) async {
    final detailApi = FakeThreadDetailBridgeApi(
      detailScriptByThreadId: {
        'thread-123': [_thread123Detail()],
      },
      timelineScriptByThreadId: {
        'thread-123': [
          <ThreadTimelineEntryDto>[
            _timelineEvent(
              id: 'evt-swipe-padding-1',
              kind: BridgeEventKind.messageDelta,
              summary: 'Assistant output',
              payload: {'delta': 'Padding event one'},
              occurredAt: '2026-03-18T10:01:00Z',
            ),
            _timelineEvent(
              id: 'evt-swipe-padding-2',
              kind: BridgeEventKind.messageDelta,
              summary: 'Assistant output',
              payload: {'delta': 'Padding event two'},
              occurredAt: '2026-03-18T10:01:30Z',
            ),
            _timelineEvent(
              id: 'evt-swipe-timestamp',
              kind: BridgeEventKind.messageDelta,
              summary: 'User prompt',
              payload: {
                'type': 'userMessage',
                'content': [
                  {'text': 'Timestamp reveal test'},
                ],
              },
              occurredAt: '2026-03-18T10:02:00Z',
            ),
          ],
        ],
      },
    );

    await _pumpThreadDetailApp(
      tester,
      detailApi: detailApi,
      threadId: 'thread-123',
    );
    await tester.pumpAndSettle();

    final messageCard = find.byKey(
      const Key('thread-message-card-evt-swipe-timestamp'),
    );
    final timestamp = find.byKey(
      const Key('thread-message-timestamp-evt-swipe-timestamp'),
    );

    await _scrollUntilVisible(tester, messageCard);
    expect(timestamp, findsNothing);

    final dragStart = tester.getTopLeft(messageCard) + const Offset(16, 14);
    final gesture = await tester.startGesture(dragStart);
    await gesture.moveBy(const Offset(-220, 0));
    await tester.pump();

    expect(timestamp, findsNothing);

    await gesture.up();
    await tester.pumpAndSettle();

    expect(timestamp, findsNothing);
  });

  testWidgets('access mode badge is not shown in the header', (tester) async {
    final detailApi = FakeThreadDetailBridgeApi(
      detailScriptByThreadId: {
        'thread-123': [_thread123Detail()],
      },
      timelineScriptByThreadId: {
        'thread-123': [<ThreadTimelineEntryDto>[]],
      },
    );

    await _pumpThreadDetailApp(
      tester,
      detailApi: detailApi,
      threadId: 'thread-123',
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('thread-detail-access-mode-badge')),
      findsNothing,
    );
    expect(find.text('Approval Gated Mode'), findsNothing);
  });

  testWidgets('bottom bounce does not reopen collapsed git header controls', (
    tester,
  ) async {
    final timeline = List<ThreadTimelineEntryDto>.generate(
      36,
      (index) => _timelineEvent(
        id: 'evt-scroll-$index',
        kind: BridgeEventKind.messageDelta,
        summary: 'Assistant output',
        payload: {'delta': 'Scrollable event $index'},
        occurredAt:
            '2026-03-18T10:${(index % 60).toString().padLeft(2, '0')}:00Z',
      ),
    );
    final detailApi = FakeThreadDetailBridgeApi(
      detailScriptByThreadId: {
        'thread-123': [_thread123Detail()],
      },
      timelineScriptByThreadId: {
        'thread-123': [timeline],
      },
    );

    await _pumpThreadDetailApp(
      tester,
      detailApi: detailApi,
      threadId: 'thread-123',
    );
    await tester.pumpAndSettle();

    final scrollable = find.byType(Scrollable).first;
    final branchButton = find.byKey(const Key('git-header-branch-button'));

    await tester.drag(scrollable, const Offset(0, 480));
    await tester.pumpAndSettle();
    expect(branchButton, findsOneWidget);

    await tester.fling(scrollable, const Offset(0, -1800), 5000);
    await tester.pumpAndSettle();

    expect(branchButton, findsNothing);
  });

  testWidgets('status-only changed file rows are hidden from the timeline', (
    tester,
  ) async {
    final detailApi = FakeThreadDetailBridgeApi(
      detailScriptByThreadId: {
        'thread-123': [_thread123Detail()],
      },
      timelineScriptByThreadId: {
        'thread-123': [
          <ThreadTimelineEntryDto>[
            _timelineEvent(
              id: 'evt-status-only',
              kind: BridgeEventKind.commandDelta,
              summary: 'Command output',
              payload: {
                'output': '''
Command: /bin/zsh -lc "git status --short"
Output:
 M apps/mobile/lib/features/threads/presentation/thread_detail_page.dart
 M apps/mobile/test/features/threads/thread_detail_page_test.dart
''',
              },
              occurredAt: '2026-03-18T10:02:00Z',
            ),
          ],
        ],
      },
    );

    await _pumpThreadDetailApp(
      tester,
      detailApi: detailApi,
      threadId: 'thread-123',
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Edited thread_detail_page.dart'), findsNothing);
    expect(
      find.textContaining(
        'apps/mobile/lib/features/threads/presentation/thread_detail_page.dart',
      ),
      findsNothing,
    );
    expect(
      find.textContaining(
        'apps/mobile/test/features/threads/thread_detail_page_test.dart',
      ),
      findsNothing,
    );
  });

  testWidgets('internal tool commands like write_stdin are hidden', (
    tester,
  ) async {
    final detailApi = FakeThreadDetailBridgeApi(
      detailScriptByThreadId: {
        'thread-123': [_thread123Detail()],
      },
      timelineScriptByThreadId: {
        'thread-123': [
          <ThreadTimelineEntryDto>[
            _timelineEvent(
              id: 'evt-tool-noise',
              kind: BridgeEventKind.commandDelta,
              summary: 'Called write_stdin',
              payload: {'command': 'write_stdin'},
              occurredAt: '2026-03-18T10:02:00Z',
            ),
          ],
        ],
      },
    );

    await _pumpThreadDetailApp(
      tester,
      detailApi: detailApi,
      threadId: 'thread-123',
    );
    await tester.pumpAndSettle();

    expect(find.text('\$ Unknown command'), findsNothing);
    expect(find.text('write_stdin'), findsNothing);
  });

  testWidgets('MCP tool invocations show their tool id instead of unknown', (
    tester,
  ) async {
    final detailApi = FakeThreadDetailBridgeApi(
      detailScriptByThreadId: {
        'thread-123': [_thread123Detail()],
      },
      timelineScriptByThreadId: {
        'thread-123': [
          <ThreadTimelineEntryDto>[
            _timelineEvent(
              id: 'evt-playwright-resize',
              kind: BridgeEventKind.commandDelta,
              summary: 'Called mcp__playwright__browser_resize',
              payload: {'command': 'mcp__playwright__browser_resize'},
              occurredAt: '2026-03-22T10:55:39Z',
            ),
          ],
        ],
      },
    );

    await _pumpThreadDetailApp(
      tester,
      detailApi: detailApi,
      threadId: 'thread-123',
    );
    await tester.pumpAndSettle();

    expect(find.text('\$ Unknown command'), findsNothing);
    expect(find.text('mcp__playwright__browser_resize'), findsOneWidget);
  });

  testWidgets('read-only sed commands render as read snippets with line ranges', (
    tester,
  ) async {
    final detailApi = FakeThreadDetailBridgeApi(
      detailScriptByThreadId: {
        'thread-123': [_thread123Detail()],
      },
      timelineScriptByThreadId: {
        'thread-123': [
          <ThreadTimelineEntryDto>[
            _timelineEvent(
              id: 'evt-read-sed',
              kind: BridgeEventKind.commandDelta,
              summary: 'Command output',
              payload: {
                'output':
                    'Command: /bin/zsh -lc "sed -n \'520,760p\' downloaded-templates/styles/_custom.scss"\n'
                    'Process exited with code 0\n'
                    'Output:\n'
                    '.bf-cart-btn-secondary {\n'
                    '  background: #fff;\n'
                    '}\n',
              },
              occurredAt: '2026-03-22T10:55:39Z',
            ),
          ],
        ],
      },
    );

    await _pumpThreadDetailApp(
      tester,
      detailApi: detailApi,
      threadId: 'thread-123',
    );
    await tester.pumpAndSettle();

    expect(find.text('\$ Unknown command'), findsNothing);
    expect(find.text("Read _custom.scss:520-760"), findsOneWidget);
    expect(find.text('.bf-cart-btn-secondary {'), findsNothing);
  });

  testWidgets('exec_command invocations render as terminal activity', (
    tester,
  ) async {
    final detailApi = FakeThreadDetailBridgeApi(
      detailScriptByThreadId: {
        'thread-123': [_thread123Detail()],
      },
      timelineScriptByThreadId: {
        'thread-123': [
          <ThreadTimelineEntryDto>[
            _timelineEvent(
              id: 'evt-exec-invocation',
              kind: BridgeEventKind.commandDelta,
              summary: 'Called exec_command',
              payload: {
                'command': 'exec_command',
                'arguments':
                    '{"cmd":"flutter test --concurrency=5","workdir":"/Users/lubomirmolin/PhpstormProjects/vibe-bridge-companion/apps/mobile","yield_time_ms":1000}',
              },
              occurredAt: '2026-03-18T10:02:00Z',
            ),
          ],
        ],
      },
    );

    await _pumpThreadDetailApp(
      tester,
      detailApi: detailApi,
      threadId: 'thread-123',
    );
    await tester.pumpAndSettle();

    await _scrollUntilVisible(
      tester,
      find.byKey(const Key('thread-terminal-background-summary')),
    );
    expect(
      find.byKey(const Key('thread-terminal-background-summary')),
      findsOneWidget,
    );
    expect(find.textContaining('flutter test --concurrency=5'), findsOneWidget);
  });

  testWidgets('apply_patch file changes render as a structured diff card', (
    tester,
  ) async {
    final detailApi = FakeThreadDetailBridgeApi(
      detailScriptByThreadId: {
        'thread-123': [_thread123Detail()],
      },
      timelineScriptByThreadId: {
        'thread-123': [
          <ThreadTimelineEntryDto>[
            _timelineEvent(
              id: 'evt-apply-patch',
              kind: BridgeEventKind.commandDelta,
              summary: 'Edited file',
              payload: {
                'output': '''
*** Begin Patch
*** Update File: /Users/lubomirmolin/PhpstormProjects/vibe-bridge-companion/apps/mobile/lib/features/threads/presentation/thread_detail_page.dart
@@
-    return oldValue;
+    return newValue;
*** End Patch
''',
              },
              occurredAt: '2026-03-18T10:02:00Z',
            ),
          ],
        ],
      },
    );

    await _pumpThreadDetailApp(
      tester,
      detailApi: detailApi,
      threadId: 'thread-123',
    );
    await tester.pumpAndSettle();

    await _scrollUntilVisible(
      tester,
      find.byKey(
        const Key('thread-file-change-toggle-thread_detail_page.dart'),
      ),
    );
    await tester.tap(
      find.byKey(
        const Key('thread-file-change-toggle-thread_detail_page.dart'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('\$ Unknown command'), findsNothing);
    expect(
      find.byKey(const Key('thread-diff-file-thread_detail_page.dart')),
      findsOneWidget,
    );
    expect(find.text('@@'), findsNothing);
    expect(find.text('+1'), findsOneWidget);
    expect(find.text('-1'), findsOneWidget);
    expect(find.text('Modified'), findsOneWidget);
  });

  testWidgets('multi-file diffs render one visible card per edited file', (
    tester,
  ) async {
    final detailApi = FakeThreadDetailBridgeApi(
      detailScriptByThreadId: {
        'thread-123': [_thread123Detail()],
      },
      timelineScriptByThreadId: {
        'thread-123': [
          <ThreadTimelineEntryDto>[
            _timelineEvent(
              id: 'evt-multi-file-diff',
              kind: BridgeEventKind.commandDelta,
              summary: 'Edited files',
              payload: {
                'output': '''
diff --git a/apps/mobile/lib/main.dart b/apps/mobile/lib/main.dart
index 1111111..2222222 100644
--- a/apps/mobile/lib/main.dart
+++ b/apps/mobile/lib/main.dart
@@ -1,1 +1,1 @@
-oldMainValue
+newMainValue
diff --git a/apps/mobile/lib/features/threads/presentation/thread_detail_page.dart b/apps/mobile/lib/features/threads/presentation/thread_detail_page.dart
index 3333333..4444444 100644
--- a/apps/mobile/lib/features/threads/presentation/thread_detail_page.dart
+++ b/apps/mobile/lib/features/threads/presentation/thread_detail_page.dart
@@ -2,1 +2,1 @@
-oldDetailValue
+newDetailValue
''',
              },
              occurredAt: '2026-03-18T10:02:00Z',
            ),
          ],
        ],
      },
    );

    await _pumpThreadDetailApp(
      tester,
      detailApi: detailApi,
      threadId: 'thread-123',
    );
    await tester.pumpAndSettle();

    final mainToggle = find.byKey(
      const Key('thread-file-change-toggle-main.dart'),
    );
    final detailToggle = find.byKey(
      const Key('thread-file-change-toggle-thread_detail_page.dart'),
    );

    await _scrollUntilVisible(tester, mainToggle);
    expect(mainToggle, findsOneWidget);
    expect(detailToggle, findsOneWidget);

    await tester.tap(mainToggle);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('thread-diff-file-main.dart')), findsOneWidget);
    expect(detailToggle, findsOneWidget);
  });

  testWidgets(
    'expanded file change cards stay expanded after scrolling away and back',
    (tester) async {
      final timeline = <ThreadTimelineEntryDto>[
        for (var index = 0; index < 24; index += 1)
          _timelineEvent(
            id: 'evt-before-$index',
            kind: BridgeEventKind.messageDelta,
            summary: 'Assistant output',
            payload: {'delta': 'Before filler $index'},
            occurredAt: '2026-03-18T10:${index.toString().padLeft(2, '0')}:00Z',
          ),
        _timelineEvent(
          id: 'evt-sticky-file-change',
          kind: BridgeEventKind.commandDelta,
          summary: 'Edited file',
          payload: {
            'output': '''
*** Begin Patch
*** Update File: /Users/lubomirmolin/PhpstormProjects/vibe-bridge-companion/apps/mobile/lib/features/threads/presentation/thread_detail_page.dart
@@
-    return oldValue;
+    return newValue;
*** End Patch
''',
          },
          occurredAt: '2026-03-18T11:30:00Z',
        ),
      ];
      final detailApi = FakeThreadDetailBridgeApi(
        detailScriptByThreadId: {
          'thread-123': [_thread123Detail(status: ThreadStatus.completed)],
        },
        timelineScriptByThreadId: {
          'thread-123': [timeline],
        },
      );

      await _pumpThreadDetailApp(
        tester,
        detailApi: detailApi,
        threadId: 'thread-123',
        initialVisibleTimelineEntries: timeline.length,
      );
      await tester.pumpAndSettle();

      const toggleKey = Key(
        'thread-file-change-toggle-thread_detail_page.dart',
      );
      const diffKey = Key('thread-diff-file-thread_detail_page.dart');
      final scrollable = find.byKey(const Key('thread-detail-scroll-view'));

      expect(find.byKey(toggleKey), findsOneWidget);
      await tester.tap(find.byKey(toggleKey));
      await tester.pumpAndSettle();

      expect(find.byKey(diffKey), findsOneWidget);

      await tester.fling(scrollable, const Offset(0, 2800), 6000);
      await tester.pumpAndSettle();
      expect(find.text('Before filler 0'), findsOneWidget);

      await tester.fling(scrollable, const Offset(0, -2800), 6000);
      await tester.pumpAndSettle();

      expect(find.byKey(toggleKey), findsOneWidget);
      expect(find.byKey(diffKey), findsOneWidget);
    },
  );

  testWidgets('structured diffs show one result-side line number column', (
    tester,
  ) async {
    final detailApi = FakeThreadDetailBridgeApi(
      detailScriptByThreadId: {
        'thread-123': [_thread123Detail()],
      },
      timelineScriptByThreadId: {
        'thread-123': [
          <ThreadTimelineEntryDto>[
            _timelineEvent(
              id: 'evt-git-diff-lines',
              kind: BridgeEventKind.commandDelta,
              summary: 'Edited file',
              payload: {
                'output': '''
diff --git a/apps/mobile/lib/l10n/en.json b/apps/mobile/lib/l10n/en.json
index 1111111..2222222 100644
--- a/apps/mobile/lib/l10n/en.json
+++ b/apps/mobile/lib/l10n/en.json
@@ -10,3 +10,4 @@
 "alpha": "A",
 "beta": "B",
+"gamma": "C",
 "delta": "D",
''',
              },
              occurredAt: '2026-03-18T10:02:00Z',
            ),
          ],
        ],
      },
    );

    await _pumpThreadDetailApp(
      tester,
      detailApi: detailApi,
      threadId: 'thread-123',
    );
    await tester.pumpAndSettle();

    final toggle = find.byKey(const Key('thread-file-change-toggle-en.json'));
    await _scrollUntilVisible(tester, toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    final lineTen = find.byWidgetPredicate(
      (widget) =>
          widget is Text &&
          widget.data == '10' &&
          widget.textAlign == TextAlign.right,
    );
    expect(lineTen, findsOneWidget);
  });

  testWidgets('delete-only file changes render as deleted file summaries', (
    tester,
  ) async {
    final detailApi = FakeThreadDetailBridgeApi(
      detailScriptByThreadId: {
        'thread-123': [_thread123Detail()],
      },
      timelineScriptByThreadId: {
        'thread-123': [
          <ThreadTimelineEntryDto>[
            _timelineEvent(
              id: 'evt-delete-file',
              kind: BridgeEventKind.fileChange,
              summary: 'Deleted file',
              payload: {
                'change': '''
*** Begin Patch
*** Delete File: /Users/lubomirmolin/PhpstormProjects/vibe-bridge-companion/apps/mobile/test/features/threads/thread_live_timeline_regression_test.dart
*** End Patch
''',
                'resolved_unified_diff': '''
diff --git a/apps/mobile/test/features/threads/thread_live_timeline_regression_test.dart b/apps/mobile/test/features/threads/thread_live_timeline_regression_test.dart
--- a/apps/mobile/test/features/threads/thread_live_timeline_regression_test.dart
+++ /dev/null
@@ -1,3 +0,0 @@
-alpha
-beta
-gamma
''',
              },
              occurredAt: '2026-03-18T10:02:00Z',
            ),
          ],
        ],
      },
    );

    await _pumpThreadDetailApp(
      tester,
      detailApi: detailApi,
      threadId: 'thread-123',
    );
    await tester.pumpAndSettle();

    expect(find.text('\$ Unknown command'), findsNothing);
    final toggle = find.byKey(
      const Key(
        'thread-file-change-toggle-thread_live_timeline_regression_test.dart',
      ),
    );
    await _scrollUntilVisible(tester, toggle);
    expect(toggle, findsOneWidget);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.text('Deleted'), findsOneWidget);
  });

  testWidgets('background terminal summaries render without raw JSON', (
    tester,
  ) async {
    final detailApi = FakeThreadDetailBridgeApi(
      detailScriptByThreadId: {
        'thread-123': [_thread123Detail()],
      },
      timelineScriptByThreadId: {
        'thread-123': [
          <ThreadTimelineEntryDto>[
            _timelineEvent(
              id: 'evt-exec-command',
              kind: BridgeEventKind.commandDelta,
              summary: 'Background terminal finished',
              payload: {
                'output':
                    'Command: dart format apps/mobile/lib/features/threads/presentation/thread_detail_page.dart\n'
                    'Output:\n'
                    'Background terminal finished with dart format apps/mobile/lib/features/threads/presentation/thread_detail_page.dart\n'
                    'Working directory: /Users/lubomirmolin/PhpstormProjects/vibe-bridge-companion',
              },
              occurredAt: '2026-03-18T10:02:00Z',
            ),
          ],
        ],
      },
    );

    await _pumpThreadDetailApp(
      tester,
      detailApi: detailApi,
      threadId: 'thread-123',
    );
    await tester.pumpAndSettle();

    await _scrollUntilVisible(
      tester,
      find.byKey(const Key('thread-terminal-background-summary')),
    );
    expect(find.text('\$ Unknown command'), findsNothing);
    expect(
      find.byKey(const Key('thread-terminal-background-summary')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const Key('thread-terminal-background-summary')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('thread-terminal-background-details')),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'Working directory: /Users/lubomirmolin/PhpstormProjects/vibe-bridge-companion',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('yield_time_ms'), findsNothing);
  });

  testWidgets(
    'read-only inspection commands collapse into a bundled work summary',
    (tester) async {
      final detailApi = FakeThreadDetailBridgeApi(
        detailScriptByThreadId: {
          'thread-123': [_thread123Detail()],
        },
        timelineScriptByThreadId: {
          'thread-123': [
            <ThreadTimelineEntryDto>[
              _timelineEvent(
                id: 'evt-background-main',
                kind: BridgeEventKind.commandDelta,
                summary: 'Background terminal finished',
                payload: {
                  'output':
                      'Command: dart format apps/mobile/test/features/threads/thread_detail_page_test.dart\n'
                      'Wall time: 49.2 seconds\n'
                      'Output:\n'
                      'Background terminal finished with dart format apps/mobile/test/features/threads/thread_detail_page_test.dart',
                },
                occurredAt: '2026-03-18T10:02:00Z',
              ),
              _timelineEvent(
                id: 'evt-read-1',
                kind: BridgeEventKind.commandDelta,
                summary: 'Background terminal finished',
                payload: {'output': 'Background terminal finished'},
                occurredAt: '2026-03-18T10:02:01Z',
                annotations: _explorationAnnotations(
                  explorationKind: ThreadTimelineExplorationKind.read,
                  entryLabel: 'Read thread_activity_item.dart',
                ),
              ),
              _timelineEvent(
                id: 'evt-read-2',
                kind: BridgeEventKind.commandDelta,
                summary: 'Background terminal finished',
                payload: {'output': 'Background terminal finished'},
                occurredAt: '2026-03-18T10:02:02Z',
                annotations: _explorationAnnotations(
                  explorationKind: ThreadTimelineExplorationKind.read,
                  entryLabel: 'Read parsed_command_output.dart',
                ),
              ),
              _timelineEvent(
                id: 'evt-search-1',
                kind: BridgeEventKind.commandDelta,
                summary: 'Background terminal finished',
                payload: {'output': 'Background terminal finished'},
                occurredAt: '2026-03-18T10:02:03Z',
                annotations: _explorationAnnotations(
                  explorationKind: ThreadTimelineExplorationKind.search,
                  entryLabel: 'Search',
                ),
              ),
            ],
          ],
        },
      );

      await _pumpThreadDetailApp(
        tester,
        detailApi: detailApi,
        threadId: 'thread-123',
      );
      await tester.pumpAndSettle();

      await _scrollUntilVisible(
        tester,
        find.byKey(const Key('thread-work-summary-title')),
      );
      expect(
        find.byKey(const Key('thread-work-summary-title')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('thread-work-summary-subtitle')),
        findsOneWidget,
      );
      expect(find.text('Worked for 49s'), findsOneWidget);
      expect(find.text('4 actions'), findsOneWidget);
      expect(find.text('Explored 2 files, 1 search'), findsNothing);
      expect(
        find.textContaining('Background terminal finished with nl -ba'),
        findsNothing,
      );
      expect(
        find.textContaining('Background terminal finished with sed -n'),
        findsNothing,
      );
      expect(
        find.textContaining('Background terminal finished with rg -n'),
        findsNothing,
      );
      expect(
        find.textContaining('Read thread_activity_item.dart'),
        findsNothing,
      );
      expect(
        find.textContaining('Read parsed_command_output.dart'),
        findsNothing,
      );

      await tester.tap(find.byKey(const Key('thread-work-summary-title')));
      await tester.pumpAndSettle();

      expect(find.text('Explored 2 files, 1 search'), findsOneWidget);
      expect(
        find.byKey(const Key('thread-worked-for-summary')),
        findsOneWidget,
      );
    },
  );

  testWidgets('worked-for bundle stays expanded when a live work item extends it', (
    tester,
  ) async {
    final detailApi = FakeThreadDetailBridgeApi(
      detailScriptByThreadId: {
        'thread-123': [_thread123Detail()],
      },
      timelineScriptByThreadId: {
        'thread-123': [
          <ThreadTimelineEntryDto>[
            _timelineEvent(
              id: 'evt-background-main',
              kind: BridgeEventKind.commandDelta,
              summary: 'Background terminal finished',
              payload: {
                'output':
                    'Command: dart format apps/mobile/test/features/threads/thread_detail_page_test.dart\n'
                    'Wall time: 49.2 seconds\n'
                    'Output:\n'
                    'Background terminal finished with dart format apps/mobile/test/features/threads/thread_detail_page_test.dart',
              },
              occurredAt: '2026-03-18T10:02:00Z',
            ),
            _timelineEvent(
              id: 'evt-read-1',
              kind: BridgeEventKind.commandDelta,
              summary: 'Background terminal finished',
              payload: {'output': 'Background terminal finished'},
              occurredAt: '2026-03-18T10:02:01Z',
              annotations: _explorationAnnotations(
                explorationKind: ThreadTimelineExplorationKind.read,
                entryLabel: 'Read thread_activity_item.dart',
              ),
            ),
            _timelineEvent(
              id: 'evt-read-2',
              kind: BridgeEventKind.commandDelta,
              summary: 'Background terminal finished',
              payload: {'output': 'Background terminal finished'},
              occurredAt: '2026-03-18T10:02:02Z',
              annotations: _explorationAnnotations(
                explorationKind: ThreadTimelineExplorationKind.read,
                entryLabel: 'Read parsed_command_output.dart',
              ),
            ),
            _timelineEvent(
              id: 'evt-search-1',
              kind: BridgeEventKind.commandDelta,
              summary: 'Background terminal finished',
              payload: {'output': 'Background terminal finished'},
              occurredAt: '2026-03-18T10:02:03Z',
              annotations: _explorationAnnotations(
                explorationKind: ThreadTimelineExplorationKind.search,
                entryLabel: 'Search',
              ),
            ),
          ],
        ],
      },
    );
    final liveStream = FakeThreadLiveStream();

    await _pumpThreadDetailApp(
      tester,
      detailApi: detailApi,
      threadId: 'thread-123',
      liveStream: liveStream,
    );
    await tester.pumpAndSettle();

    await _scrollUntilVisible(
      tester,
      find.byKey(const Key('thread-work-summary-title')),
    );
    expect(find.text('Worked for 49s'), findsOneWidget);
    expect(find.text('4 actions'), findsOneWidget);

    await tester.tap(find.byKey(const Key('thread-work-summary-title')));
    await tester.pumpAndSettle();

    expect(find.text('Explored 2 files, 1 search'), findsOneWidget);

    liveStream.emit(
      BridgeEventEnvelope<Map<String, dynamic>>(
        contractVersion: contractVersion,
        eventId: 'evt-background-followup',
        threadId: 'thread-123',
        kind: BridgeEventKind.commandDelta,
        occurredAt: '2026-03-18T10:02:04Z',
        payload: {
          'output':
              'Command: rg -n "Worked for" apps/mobile/lib/features/threads/presentation/thread_detail_page_timeline.dart\n'
              'Wall time: 3.8 seconds\n'
              'Output:\n'
              'Background terminal finished with rg -n "Worked for" apps/mobile/lib/features/threads/presentation/thread_detail_page_timeline.dart',
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Worked for 53s'), findsOneWidget);
    expect(find.text('5 actions'), findsOneWidget);
    expect(find.text('Explored 2 files, 1 search'), findsOneWidget);
  });

  testWidgets('older history keeps loading until a new grouped block appears', (
    tester,
  ) async {
    final detailApi = FakeThreadDetailBridgeApi(
      detailScriptByThreadId: {
        'thread-123': [_thread123Detail()],
      },
      timelineScriptByThreadId: {
        'thread-123': [
          [
            _timelineEvent(
              id: 'evt-old-msg',
              kind: BridgeEventKind.messageDelta,
              summary: 'Oldest visible after hydration',
              payload: {'delta': 'Oldest event before exploration'},
              occurredAt: '2026-03-18T09:59:00Z',
            ),
            _timelineEvent(
              id: 'evt-read-1',
              kind: BridgeEventKind.commandDelta,
              summary: 'Background terminal finished',
              payload: {
                'output':
                    'Command: nl -ba apps/mobile/lib/features/threads/domain/thread_activity_item.dart\n'
                    'Output:\n'
                    'Background terminal finished with nl -ba apps/mobile/lib/features/threads/domain/thread_activity_item.dart',
              },
              occurredAt: '2026-03-18T10:01:00Z',
              annotations: _explorationAnnotations(
                explorationKind: ThreadTimelineExplorationKind.read,
                entryLabel: 'Read thread_activity_item.dart',
              ),
            ),
            _timelineEvent(
              id: 'evt-read-2',
              kind: BridgeEventKind.commandDelta,
              summary: 'Background terminal finished',
              payload: {
                'output':
                    'Command: sed -n \'1,120p\' apps/mobile/lib/features/threads/domain/parsed_command_output.dart\n'
                    'Output:\n'
                    'Background terminal finished with sed -n \'1,120p\' apps/mobile/lib/features/threads/domain/parsed_command_output.dart',
              },
              occurredAt: '2026-03-18T10:02:00Z',
              annotations: _explorationAnnotations(
                explorationKind: ThreadTimelineExplorationKind.read,
                entryLabel: 'Read parsed_command_output.dart',
              ),
            ),
            _timelineEvent(
              id: 'evt-read-3',
              kind: BridgeEventKind.commandDelta,
              summary: 'Background terminal finished',
              payload: {
                'output':
                    'Command: head -n 40 apps/mobile/lib/features/threads/presentation/thread_detail_page.dart\n'
                    'Output:\n'
                    'Background terminal finished with head -n 40 apps/mobile/lib/features/threads/presentation/thread_detail_page.dart',
              },
              occurredAt: '2026-03-18T10:02:30Z',
              annotations: _explorationAnnotations(
                explorationKind: ThreadTimelineExplorationKind.read,
                entryLabel: 'Read thread_detail_page.dart',
              ),
            ),
            _timelineEvent(
              id: 'evt-read-4',
              kind: BridgeEventKind.commandDelta,
              summary: 'Background terminal finished',
              payload: {
                'output':
                    'Command: rg -n "thread-detail" apps/mobile/lib/features/threads\n'
                    'Output:\n'
                    'Background terminal finished with rg -n "thread-detail" apps/mobile/lib/features/threads',
              },
              occurredAt: '2026-03-18T10:02:45Z',
              annotations: _explorationAnnotations(
                explorationKind: ThreadTimelineExplorationKind.search,
                entryLabel: 'Search',
              ),
            ),
            _timelineEvent(
              id: 'evt-msg-1',
              kind: BridgeEventKind.messageDelta,
              summary: 'Recent event one',
              payload: {'delta': 'Recent event A'},
              occurredAt: '2026-03-18T10:03:00Z',
            ),
            _timelineEvent(
              id: 'evt-msg-2',
              kind: BridgeEventKind.messageDelta,
              summary: 'Recent event two',
              payload: {'delta': 'Recent event B'},
              occurredAt: '2026-03-18T10:04:00Z',
            ),
          ],
        ],
      },
    );

    await _pumpThreadDetailApp(
      tester,
      detailApi: detailApi,
      threadId: 'thread-123',
      initialVisibleTimelineEntries: 3,
    );
    await tester.pumpAndSettle();

    expect(find.text('Oldest event before exploration'), findsNothing);
    expect(find.text('1 search'), findsOneWidget);

    await tester.drag(
      find.byKey(const Key('thread-detail-scroll-view')),
      const Offset(0, 800),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('Oldest event before exploration'), findsOneWidget);
    expect(find.text('Explored 3 files, 1 search'), findsOneWidget);
    expect(
      find.textContaining('Background terminal finished with nl -ba'),
      findsNothing,
    );
    expect(find.text('New messages'), findsNothing);
    expect(detailApi.timelineFetchCount, 3);
  });

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

    await tester.enterText(
      find.byKey(const Key('turn-composer-input')),
      'Draft release notes for today\'s bridge changes.',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('turn-composer-submit')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(detailApi.startTurnPromptsByThreadId['thread-456'], [
      'Draft release notes for today\'s bridge changes.',
    ]);
    expect(find.text('Running'), findsOneWidget);
  });

  testWidgets(
    'idle composer shows a local sending bubble until the canonical user event arrives',
    (tester) async {
      final startTurnCompleter = Completer<TurnMutationResult>();
      final detailApi = FakeThreadDetailBridgeApi(
        detailScriptByThreadId: {
          'thread-456': [_thread456Detail()],
        },
        timelineScriptByThreadId: {
          'thread-456': [<ThreadTimelineEntryDto>[]],
        },
        startTurnScriptByThreadId: {
          'thread-456': [startTurnCompleter.future],
        },
      );
      final liveStream = FakeThreadLiveStream();
      const prompt = 'Compare the latest rollout against the local bridge.';

      await _pumpThreadDetailApp(
        tester,
        detailApi: detailApi,
        threadId: 'thread-456',
        liveStream: liveStream,
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ThreadDetailPage)),
      );
      const args = ThreadDetailControllerArgs(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
        threadId: 'thread-456',
        initialVisibleTimelineEntries: 20,
      );

      await tester.enterText(
        find.byKey(const Key('turn-composer-input')),
        prompt,
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('turn-composer-submit')));
      await tester.pump();

      expect(
        container
            .read(threadDetailControllerProvider(args))
            .pendingLocalUserPrompts
            .length,
        1,
      );
      expect(find.text('Sending'), findsOneWidget);

      startTurnCompleter.complete(
        _turnMutationResult(
          threadId: 'thread-456',
          operation: 'turn_start',
          status: ThreadStatus.running,
          message: 'Turn started and streaming is active',
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      liveStream.emit(
        const BridgeEventEnvelope<Map<String, dynamic>>(
          contractVersion: contractVersion,
          eventId: 'evt-canonical-user-prompt',
          threadId: 'thread-456',
          kind: BridgeEventKind.messageDelta,
          occurredAt: '2026-03-18T09:31:00Z',
          payload: {
            'type': 'userMessage',
            'role': 'user',
            'source': 'user',
            'delta': prompt,
            'replace': true,
          },
        ),
      );
      await tester.pump();

      final reconciledState = container.read(
        threadDetailControllerProvider(args),
      );
      expect(reconciledState.pendingLocalUserPrompts, isEmpty);
      expect(
        reconciledState.items
            .where(
              (item) =>
                  item.type == ThreadActivityItemType.userPrompt &&
                  item.body == prompt,
            )
            .length,
        1,
      );
      expect(find.text('Sending'), findsNothing);
    },
  );

  testWidgets(
    'idle composer drops the local sending bubble after snapshot catch-up if the live user event is missed',
    (tester) async {
      final startTurnCompleter = Completer<TurnMutationResult>();
      final refreshedDetail = ThreadDetailDto(
        contractVersion: contractVersion,
        threadId: 'thread-456',
        title: 'Investigate reconnect dedup',
        status: ThreadStatus.completed,
        workspace: '/workspace/codex-runtime-tools',
        repository: 'codex-runtime-tools',
        branch: 'develop',
        createdAt: '2026-03-18T08:45:00Z',
        updatedAt: '2026-03-18T09:31:01Z',
        source: 'cli',
        accessMode: AccessMode.controlWithApprovals,
        lastTurnSummary: 'Caught up from snapshot refresh',
      );
      const prompt = 'Summarize the bridge race in 3 bullet points.';
      final detailApi = FakeThreadDetailBridgeApi(
        detailScriptByThreadId: {
          'thread-456': [_thread456Detail(), refreshedDetail],
        },
        timelineScriptByThreadId: {
          'thread-456': [
            <ThreadTimelineEntryDto>[],
            <ThreadTimelineEntryDto>[
              _timelineEvent(
                id: 'evt-canonical-user-prompt',
                kind: BridgeEventKind.messageDelta,
                summary: prompt,
                payload: <String, dynamic>{
                  'type': 'userMessage',
                  'role': 'user',
                  'source': 'user',
                  'delta': prompt,
                  'replace': true,
                },
                occurredAt: '2026-03-18T09:31:00Z',
              ),
            ],
          ],
        },
        startTurnScriptByThreadId: {
          'thread-456': [startTurnCompleter.future],
        },
      );
      final liveStream = FakeThreadLiveStream();

      await _pumpThreadDetailApp(
        tester,
        detailApi: detailApi,
        threadId: 'thread-456',
        liveStream: liveStream,
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ThreadDetailPage)),
      );
      const args = ThreadDetailControllerArgs(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
        threadId: 'thread-456',
        initialVisibleTimelineEntries: 20,
      );

      await tester.enterText(
        find.byKey(const Key('turn-composer-input')),
        prompt,
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('turn-composer-submit')));
      await tester.pump();

      expect(
        container
            .read(threadDetailControllerProvider(args))
            .pendingLocalUserPrompts
            .length,
        1,
      );
      expect(find.text('Sending'), findsOneWidget);

      startTurnCompleter.complete(
        _turnMutationResult(
          threadId: 'thread-456',
          operation: 'turn_start',
          status: ThreadStatus.running,
          message: 'Turn started and streaming is active',
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      liveStream.emit(
        const BridgeEventEnvelope<Map<String, dynamic>>(
          contractVersion: contractVersion,
          eventId: 'evt-status-completed',
          threadId: 'thread-456',
          kind: BridgeEventKind.threadStatusChanged,
          occurredAt: '2026-03-18T09:31:01Z',
          payload: <String, dynamic>{
            'status': 'completed',
            'reason': 'task_complete',
          },
        ),
      );
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();

      final refreshedState = container.read(
        threadDetailControllerProvider(args),
      );
      expect(refreshedState.pendingLocalUserPrompts, isEmpty);
      expect(
        refreshedState.items
            .where(
              (item) =>
                  item.type == ThreadActivityItemType.userPrompt &&
                  item.body == prompt,
            )
            .length,
        1,
      );
      expect(find.text('Sending'), findsNothing);
    },
  );

  testWidgets(
    'pending approval prompts submit during active turn and clear on resolved event',
    (tester) async {
      final detailApi = FakeThreadDetailBridgeApi(
        detailScriptByThreadId: {
          'thread-123': [_thread123Detail(status: ThreadStatus.running)],
        },
        timelineScriptByThreadId: {
          'thread-123': [<ThreadTimelineEntryDto>[]],
        },
      );
      final liveStream = FakeThreadLiveStream();

      await _pumpThreadDetailApp(
        tester,
        detailApi: detailApi,
        threadId: 'thread-123',
        liveStream: liveStream,
      );

      liveStream.emit(
        const BridgeEventEnvelope<Map<String, dynamic>>(
          contractVersion: contractVersion,
          eventId: 'evt-user-input-pending',
          threadId: 'thread-123',
          kind: BridgeEventKind.userInputRequested,
          occurredAt: '2026-03-31T09:00:00Z',
          payload: {
            'request_id': 'provider-approval-1',
            'title': 'Approve command execution?',
            'detail': 'Command: git status',
            'questions': [
              {
                'question_id': 'approval_decision',
                'prompt': 'Choose an action',
                'options': [
                  {
                    'option_id': 'allow_once',
                    'label': 'Allow once',
                    'description': 'Approve this action one time.',
                    'is_recommended': true,
                  },
                  {
                    'option_id': 'allow_for_session',
                    'label': 'Allow for session',
                    'description': 'Approve now and remember for this session.',
                    'is_recommended': false,
                  },
                  {
                    'option_id': 'deny',
                    'label': 'Deny',
                    'description': 'Deny this action and interrupt the turn.',
                    'is_recommended': false,
                  },
                ],
              },
            ],
            'state': 'pending',
          },
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Approve command execution?'), findsOneWidget);
      expect(
        find.byKey(const Key('turn-composer-approval-card')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('turn-composer-input')), findsNothing);
      expect(find.byKey(const Key('turn-composer-plan-submit')), findsNothing);

      await tester.tap(
        find.byKey(const Key('turn-composer-approval-option-allow_once')),
      );
      await tester.pumpAndSettle();

      expect(detailApi.respondToUserInputCalls, hasLength(1));
      final responseCall = detailApi.respondToUserInputCalls.single;
      expect(responseCall.threadId, 'thread-123');
      expect(responseCall.requestId, 'provider-approval-1');
      expect(responseCall.answers, hasLength(1));
      expect(responseCall.answers.single.questionId, 'approval_decision');
      expect(responseCall.answers.single.optionId, 'allow_once');

      liveStream.emit(
        const BridgeEventEnvelope<Map<String, dynamic>>(
          contractVersion: contractVersion,
          eventId: 'evt-user-input-resolved',
          threadId: 'thread-123',
          kind: BridgeEventKind.userInputRequested,
          occurredAt: '2026-03-31T09:00:01Z',
          payload: {'request_id': 'provider-approval-1', 'state': 'resolved'},
        ),
      );
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();

      expect(find.text('Approve command execution?'), findsNothing);
    },
  );

  testWidgets(
    'composer input stays multiline and collapses leading actions on focus',
    (tester) async {
      final detailApi = FakeThreadDetailBridgeApi(
        detailScriptByThreadId: {
          'thread-456': [_thread456Detail()],
        },
        timelineScriptByThreadId: {
          'thread-456': [<ThreadTimelineEntryDto>[]],
        },
      );

      await _pumpThreadDetailApp(
        tester,
        detailApi: detailApi,
        threadId: 'thread-456',
      );

      final input = tester.widget<TextField>(
        find.byKey(const Key('turn-composer-input')),
      );

      expect(input.maxLines, 4);
      expect(input.textCapitalization, TextCapitalization.sentences);
      expect(input.textInputAction, TextInputAction.send);
      expect(
        find.byKey(const Key('turn-composer-attach-button')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('thread-detail-settings-toggle')),
        findsOneWidget,
      );

      await tester.showKeyboard(find.byKey(const Key('turn-composer-input')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('turn-composer-attach-button')),
        findsNothing,
      );
      expect(find.byKey(const Key('turn-composer-submit')), findsOneWidget);
    },
  );

  testWidgets('picking an image only attaches it until submit is pressed', (
    tester,
  ) async {
    final detailApi = FakeThreadDetailBridgeApi(
      detailScriptByThreadId: {
        'thread-456': [_thread456Detail()],
      },
      timelineScriptByThreadId: {
        'thread-456': [<ThreadTimelineEntryDto>[]],
      },
    );
    final image = await _createTestImageFile('picked-image.png');

    await _pumpThreadDetailApp(
      tester,
      detailApi: detailApi,
      threadId: 'thread-456',
      pickImagesOverride: () async => <XFile>[image],
    );

    await tester.tap(find.byKey(const Key('turn-composer-attach-button')));
    await _pumpForTransientUiWork(tester);

    expect(
      detailApi.startTurnPromptsByThreadId.containsKey('thread-456'),
      isFalse,
    );
    expect(
      detailApi.startTurnImagesByThreadId.containsKey('thread-456'),
      isFalse,
    );

    await tester.tap(find.byKey(const Key('turn-composer-submit')));
    await _pumpForTransientUiWork(tester);

    expect(detailApi.startTurnPromptsByThreadId['thread-456'], ['']);
    expect(
      detailApi.startTurnImagesByThreadId['thread-456']?.single.single,
      startsWith('data:image/png;base64,'),
    );
  });

  testWidgets('initial attached images still auto-submit on first load', (
    tester,
  ) async {
    final detailApi = FakeThreadDetailBridgeApi(
      detailScriptByThreadId: {
        'thread-456': [_thread456Detail()],
      },
      timelineScriptByThreadId: {
        'thread-456': [<ThreadTimelineEntryDto>[]],
      },
    );
    final image = await _createTestImageFile('initial-image.png');

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appSecureStoreProvider.overrideWithValue(InMemorySecureStore()),
          threadListBridgeApiProvider.overrideWithValue(
            FakeThreadListBridgeApi(scriptedResults: [_threadSummaries()]),
          ),
          approvalBridgeApiProvider.overrideWithValue(EmptyApprovalBridgeApi()),
          threadDetailBridgeApiProvider.overrideWithValue(detailApi),
          settingsBridgeApiProvider.overrideWithValue(FakeSettingsBridgeApi()),
          threadLiveStreamProvider.overrideWithValue(FakeThreadLiveStream()),
          threadCacheRepositoryProvider.overrideWithValue(
            _newCacheRepository(),
          ),
        ],
        child: MaterialApp(
          home: ThreadDetailPage(
            bridgeApiBaseUrl: _bridgeApiBaseUrl,
            threadId: 'thread-456',
            initialAttachedImages: <XFile>[image],
          ),
        ),
      ),
    );
    await _pumpForTransientUiWork(tester, iterations: 8);

    expect(detailApi.startTurnPromptsByThreadId['thread-456'], ['']);
    expect(
      detailApi.startTurnImagesByThreadId['thread-456']?.single.single,
      startsWith('data:image/png;base64,'),
    );
  });

  testWidgets('composer model sheet updates model and intelligence summary', (
    tester,
  ) async {
    final detailApi = FakeThreadDetailBridgeApi(
      detailScriptByThreadId: {
        'thread-456': [_thread456Detail()],
      },
      timelineScriptByThreadId: {
        'thread-456': [<ThreadTimelineEntryDto>[]],
      },
    );

    await _pumpThreadDetailApp(
      tester,
      detailApi: detailApi,
      threadId: 'thread-456',
    );

    await _openComposerModelSheet(tester);

    expect(find.text('GPT-5 · Medium'), findsNothing);
    expect(find.text('Models'), findsOneWidget);
    expect(find.text('Intelligence'), findsOneWidget);
    expect(find.text('Approval'), findsOneWidget);

    await tester.tap(
      find.byKey(const Key('turn-composer-model-option-o4-mini')),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const Key('turn-composer-reasoning-option-High')),
    );
    await tester.tap(
      find.byKey(const Key('turn-composer-reasoning-option-High')),
    );
    await tester.pumpAndSettle();
    await _closeModalSheet(tester);
    await _openComposerModelSheet(tester);

    expect(
      find.descendant(
        of: find.byKey(const Key('turn-composer-model-option-o4-mini')),
        matching: find.byType(PhosphorIcon),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('turn-composer-reasoning-option-High')),
        matching: find.byType(PhosphorIcon),
      ),
      findsOneWidget,
    );
  });

  testWidgets('composer model sheet prefers bridge-provided models', (
    tester,
  ) async {
    final detailApi = FakeThreadDetailBridgeApi(
      detailScriptByThreadId: {
        'thread-456': [_thread456Detail()],
      },
      timelineScriptByThreadId: {
        'thread-456': [<ThreadTimelineEntryDto>[]],
      },
      modelCatalog: const ModelCatalogDto(
        contractVersion: contractVersion,
        models: <ModelOptionDto>[
          ModelOptionDto(
            id: 'gpt-5.4',
            model: 'gpt-5.4',
            displayName: 'GPT-5.4',
            description: 'Sharper reasoning',
            isDefault: true,
            defaultReasoningEffort: 'high',
            supportedReasoningEfforts: <ReasoningEffortOptionDto>[
              ReasoningEffortOptionDto(reasoningEffort: 'medium'),
              ReasoningEffortOptionDto(reasoningEffort: 'high'),
            ],
          ),
        ],
      ),
    );

    await _pumpThreadDetailApp(
      tester,
      detailApi: detailApi,
      threadId: 'thread-456',
    );

    await _openComposerModelSheet(tester);

    expect(find.text('GPT-5.4'), findsOneWidget);
    expect(find.text('GPT-5 Mini'), findsNothing);
    expect(
      find.byKey(const Key('turn-composer-model-option-gpt-5.4')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('turn-composer-reasoning-option-High')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('turn-composer-reasoning-option-Low')),
      findsNothing,
    );
  });

  testWidgets('running indicator cancel button stops the active turn', (
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

    expect(find.byKey(const Key('turn-composer-submit')), findsOneWidget);
    await tester.tap(find.byKey(const Key('turn-interrupt-button')));
    await tester.pumpAndSettle();

    expect(detailApi.interruptTurnCallsByThreadId['thread-123'], 1);
    expect(find.text('Interrupted'), findsOneWidget);
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
            message: 'bridge rejected prompt payload.',
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
    await tester.pump();
    await tester.tap(find.byKey(const Key('turn-composer-submit')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('bridge rejected prompt payload.'), findsOneWidget);

    await tester.tap(find.byKey(const Key('turn-composer-submit')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('bridge rejected prompt payload.'), findsNothing);
    expect(find.text('Running'), findsOneWidget);
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
  });

  testWidgets(
    'active turn keeps send button visible and shows cancel in the running indicator',
    (tester) async {
      final detailApi = FakeThreadDetailBridgeApi(
        detailScriptByThreadId: {
          'thread-123': [_thread123Detail()],
        },
        timelineScriptByThreadId: {
          'thread-123': [<ThreadTimelineEntryDto>[]],
        },
      );

      await _pumpThreadDetailApp(
        tester,
        detailApi: detailApi,
        threadId: 'thread-123',
      );

      final input = tester.widget<TextField>(
        find.byKey(const Key('turn-composer-input')),
      );

      expect(input.enabled, isTrue);
      expect(find.byKey(const Key('turn-interrupt-button')), findsOneWidget);
      expect(find.byKey(const Key('turn-composer-submit')), findsOneWidget);
      expect(find.text('Thinking'), findsOneWidget);
    },
  );

  testWidgets('running thread uses steering instruction when submitting text', (
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
    );

    await _pumpThreadDetailApp(
      tester,
      detailApi: detailApi,
      threadId: 'thread-123',
    );

    await tester.pumpAndSettle();
    final composerInput = find.byKey(const Key('turn-composer-input'));
    await tester.showKeyboard(composerInput);
    await tester.enterText(composerInput, 'Continue with the next subtask.');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();

    expect(detailApi.startTurnPromptsByThreadId['thread-123'], isNull);
    expect(detailApi.steerTurnInstructionsByThreadId['thread-123'], [
      'Continue with the next subtask.',
    ]);
  });

  testWidgets('running indicator reflects file reading activity', (
    tester,
  ) async {
    final detailApi = FakeThreadDetailBridgeApi(
      detailScriptByThreadId: {
        'thread-123': [_thread123Detail()],
      },
      timelineScriptByThreadId: {
        'thread-123': [
          <ThreadTimelineEntryDto>[
            _timelineEvent(
              id: 'evt-read',
              kind: BridgeEventKind.commandDelta,
              summary: 'Called exec_command',
              payload: {'command': 'sed -n 1,120p lib/main.dart'},
              occurredAt: '2026-03-18T10:06:00Z',
              annotations: _explorationAnnotations(
                explorationKind: ThreadTimelineExplorationKind.read,
                entryLabel: 'Read lib/main.dart',
              ),
            ),
          ],
        ],
      },
    );

    await _pumpThreadDetailApp(
      tester,
      detailApi: detailApi,
      threadId: 'thread-123',
    );

    expect(
      find.byKey(const Key('thread-running-indicator-card')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('thread-running-scramble')), findsOneWidget);
    expect(find.text('Reading files'), findsOneWidget);
  });

  testWidgets('running indicator reflects file editing activity', (
    tester,
  ) async {
    final detailApi = FakeThreadDetailBridgeApi(
      detailScriptByThreadId: {
        'thread-123': [_thread123Detail()],
      },
      timelineScriptByThreadId: {
        'thread-123': [
          <ThreadTimelineEntryDto>[
            _timelineEvent(
              id: 'evt-edit',
              kind: BridgeEventKind.fileChange,
              summary: 'Edited file',
              payload: {
                'path': 'lib/main.dart',
                'summary': 'Adjusted parser mapping',
              },
              occurredAt: '2026-03-18T10:06:00Z',
            ),
          ],
        ],
      },
    );

    await _pumpThreadDetailApp(
      tester,
      detailApi: detailApi,
      threadId: 'thread-123',
    );

    expect(find.text('Editing files'), findsOneWidget);
  });

  testWidgets(
    'bridge resolves git status and enables git mutations while showing thread context',
    (tester) async {
      final detailApi = FakeThreadDetailBridgeApi(
        detailScriptByThreadId: {
          'thread-123': [_thread123Detail()],
        },
        timelineScriptByThreadId: {
          'thread-123': [<ThreadTimelineEntryDto>[]],
        },
      );

      await _pumpThreadDetailApp(
        tester,
        detailApi: detailApi,
        threadId: 'thread-123',
      );

      await _openGitBranchSheet(tester);
      expect(find.text('Repository: vibe-bridge-companion'), findsOneWidget);
      expect(find.text('Branch: master'), findsOneWidget);
      expect(find.text('Remote: origin'), findsOneWidget);
      expect(find.text('Status: Clean • Ahead 0 • Behind 0'), findsOneWidget);

      final switchButton = tester.widget<FilledButton>(
        find.byKey(const Key('git-branch-switch-button')),
      );
      expect(switchButton.onPressed, isNotNull);
      await _closeModalSheet(tester);

      await _openGitSyncSheet(tester);
      final pullButton = tester.widget<OutlinedButton>(
        find.byKey(const Key('git-pull-button')),
      );
      final pushButton = tester.widget<OutlinedButton>(
        find.byKey(const Key('git-push-button')),
      );
      expect(pullButton.onPressed, isNotNull);
      expect(pushButton.onPressed, isNotNull);
      expect(detailApi.gitStatusFetchCountByThreadId['thread-123'], 1);
      expect(detailApi.branchSwitchRequestsByThreadId['thread-123'], isNull);
      expect(detailApi.pullCallsByThreadId['thread-123'], isNull);
      expect(detailApi.pushCallsByThreadId['thread-123'], isNull);
    },
  );

  testWidgets('full-control mode applies branch switch results immediately', (
    tester,
  ) async {
    final detailApi = FakeThreadDetailBridgeApi(
      detailScriptByThreadId: {
        'thread-123': [_thread123Detail(accessMode: AccessMode.fullControl)],
      },
      timelineScriptByThreadId: {
        'thread-123': [<ThreadTimelineEntryDto>[]],
      },
      gitStatusScriptByThreadId: {
        'thread-123': [_gitStatus(threadId: 'thread-123', branch: 'master')],
      },
      branchSwitchScriptByThreadId: {
        'thread-123': [
          _gitMutationResult(
            threadId: 'thread-123',
            operation: 'git_branch_switch',
            message: 'Switched branch to release/2026',
            repository: 'vibe-bridge-companion',
            branch: 'release/2026',
            remote: 'origin',
            threadStatus: ThreadStatus.idle,
          ),
        ],
      },
    );

    await _pumpThreadDetailApp(
      tester,
      detailApi: detailApi,
      threadId: 'thread-123',
      settingsApi: FakeSettingsBridgeApi(accessMode: AccessMode.fullControl),
    );

    await _openGitBranchSheet(tester);
    await tester.enterText(
      find.byKey(const Key('git-branch-input')),
      'release/2026',
    );
    await tester.tap(find.byKey(const Key('git-branch-switch-button')));
    await tester.pumpAndSettle();

    expect(detailApi.branchSwitchRequestsByThreadId['thread-123'], [
      'release/2026',
    ]);
    expect(find.text('Switched branch to release/2026'), findsOneWidget);

    await _openGitBranchSheet(tester);
    expect(find.text('Branch: release/2026'), findsOneWidget);
  });

  testWidgets('open-on-host is surfaced as unavailable in this build', (
    tester,
  ) async {
    final detailApi = FakeThreadDetailBridgeApi(
      detailScriptByThreadId: {
        'thread-123': [_thread123Detail(status: ThreadStatus.completed)],
      },
      timelineScriptByThreadId: {
        'thread-123': [<ThreadTimelineEntryDto>[]],
      },
    );

    await _pumpThreadDetailApp(
      tester,
      detailApi: detailApi,
      threadId: 'thread-123',
    );

    await tester.tap(find.byKey(const Key('open-on-mac-button')));
    await tester.pumpAndSettle();
    expect(detailApi.openOnMacCallsByThreadId['thread-123'], isNull);
    expect(find.byKey(const Key('open-on-mac-error-message')), findsOneWidget);
    expect(
      find.text('Open-on-host is unavailable in this build.'),
      findsOneWidget,
    );
  });

  testWidgets('desktop integration toggle updates open-on-host affordances', (
    tester,
  ) async {
    final detailApi = FakeThreadDetailBridgeApi(
      detailScriptByThreadId: {
        'thread-123': [_thread123Detail()],
      },
      timelineScriptByThreadId: {
        'thread-123': [<ThreadTimelineEntryDto>[]],
      },
      gitStatusScriptByThreadId: {
        'thread-123': [_gitStatus(threadId: 'thread-123')],
      },
    );

    await _pumpThreadDetailApp(
      tester,
      detailApi: detailApi,
      threadId: 'thread-123',
    );

    var openButton = tester.widget<FilledButton>(
      find.byKey(const Key('open-on-mac-button')),
    );
    expect(openButton.onPressed, isNotNull);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ThreadDetailPage)),
    );

    await container
        .read(desktopIntegrationControllerProvider.notifier)
        .setEnabled(false);
    await tester.pumpAndSettle();

    openButton = tester.widget<FilledButton>(
      find.byKey(const Key('open-on-mac-button')),
    );
    expect(openButton.onPressed, isNull);
    expect(
      find.byKey(const Key('desktop-integration-disabled-message')),
      findsOneWidget,
    );

    await container
        .read(desktopIntegrationControllerProvider.notifier)
        .setEnabled(true);
    await tester.pumpAndSettle();

    openButton = tester.widget<FilledButton>(
      find.byKey(const Key('open-on-mac-button')),
    );
    expect(openButton.onPressed, isNotNull);
    expect(
      find.byKey(const Key('desktop-integration-disabled-message')),
      findsNothing,
    );
  });

  testWidgets(
    'changing access mode from settings still gates turn controls and git mutations',
    (tester) async {
      final detailApi = FakeThreadDetailBridgeApi(
        detailScriptByThreadId: {
          'thread-123': [_thread123Detail()],
        },
        timelineScriptByThreadId: {
          'thread-123': [<ThreadTimelineEntryDto>[]],
        },
      );
      await _pumpThreadDetailApp(
        tester,
        detailApi: detailApi,
        threadId: 'thread-123',
      );

      final container = ProviderScope.containerOf(
        tester.element(find.byType(ThreadDetailPage)),
      );
      container
              .read(runtimeAccessModeProvider(_bridgeApiBaseUrl).notifier)
              .state =
          AccessMode.readOnly;
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('turn-interrupt-button')), findsOneWidget);
      await tester.tap(find.byKey(const Key('turn-interrupt-button')));
      await tester.pumpAndSettle();

      await _openGitSyncSheet(tester);
      final pullAfter = tester.widget<OutlinedButton>(
        find.byKey(const Key('git-pull-button')),
      );
      final openOnMacAfter = tester.widget<FilledButton>(
        find.byKey(const Key('open-on-mac-button')),
      );
      expect(detailApi.interruptTurnCallsByThreadId['thread-123'], isNull);
      expect(pullAfter.onPressed, isNull);
      expect(openOnMacAfter.onPressed, isNotNull);
      expect(find.text('Read-only mode blocks git mutations.'), findsWidgets);
    },
  );

  testWidgets('bridge keeps blank branch switch disabled', (tester) async {
    final detailApi = FakeThreadDetailBridgeApi(
      detailScriptByThreadId: {
        'thread-123': [_thread123Detail()],
      },
      timelineScriptByThreadId: {
        'thread-123': [<ThreadTimelineEntryDto>[]],
      },
    );

    await _pumpThreadDetailApp(
      tester,
      detailApi: detailApi,
      threadId: 'thread-123',
    );

    await _openGitBranchSheet(tester);
    await tester.enterText(find.byKey(const Key('git-branch-input')), '   ');
    await tester.tap(find.byKey(const Key('git-branch-switch-button')));
    await tester.pumpAndSettle();

    expect(detailApi.branchSwitchRequestsByThreadId['thread-123'], isNull);
    expect(find.text('Enter a branch name.'), findsOneWidget);
  });

  testWidgets('branch sheet owns the commit action in session detail', (
    tester,
  ) async {
    final detailApi = FakeThreadDetailBridgeApi(
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
            accessMode: AccessMode.fullControl,
            lastTurnSummary: 'Idle',
          ),
        ],
      },
      timelineScriptByThreadId: {
        'thread-123': [<ThreadTimelineEntryDto>[]],
      },
    );

    await _pumpThreadDetailApp(
      tester,
      detailApi: detailApi,
      threadId: 'thread-123',
      settingsApi: FakeSettingsBridgeApi(accessMode: AccessMode.fullControl),
    );

    expect(find.byKey(const Key('git-header-commit-button')), findsNothing);

    await _openGitBranchSheet(tester);
    expect(find.byKey(const Key('git-branch-commit-button')), findsOneWidget);
    final commitButton = tester.widget<FilledButton>(
      find.byKey(const Key('git-branch-commit-button')),
    );
    expect(commitButton.onPressed, isNotNull);

    await tester.tap(find.byKey(const Key('git-branch-commit-button')));
    await tester.pumpAndSettle();

    expect(detailApi.startCommitCallsByThreadId['thread-123'], 1);
    expect(find.byKey(const Key('git-branch-commit-button')), findsNothing);
  });

  testWidgets('approval-required git pull surfaces the bridge message', (
    tester,
  ) async {
    final approval = ApprovalRecordDto(
      contractVersion: contractVersion,
      approvalId: 'approval-1',
      threadId: 'thread-123',
      action: 'git_pull',
      target: 'origin',
      reason: 'dangerous_action_requires_approval',
      status: ApprovalStatus.pending,
      requestedAt: '2026-03-18T11:00:00Z',
      resolvedAt: null,
      repository: _gitStatus(threadId: 'thread-123').repository,
      gitStatus: _gitStatus(threadId: 'thread-123').status,
    );
    final detailApi = FakeThreadDetailBridgeApi(
      detailScriptByThreadId: {
        'thread-123': [_thread123Detail()],
      },
      timelineScriptByThreadId: {
        'thread-123': [<ThreadTimelineEntryDto>[]],
      },
      pullScriptByThreadId: {
        'thread-123': [
          ThreadGitApprovalRequiredException(
            message: 'Dangerous action was gated pending explicit approval',
            operation: 'git_pull',
            outcome: 'approval_required',
            approval: approval,
          ),
        ],
      },
    );

    await _pumpThreadDetailApp(
      tester,
      detailApi: detailApi,
      threadId: 'thread-123',
    );

    await _openGitSyncSheet(tester);
    await tester.tap(find.byKey(const Key('git-pull-button')));
    await tester.pumpAndSettle();

    expect(detailApi.pullCallsByThreadId['thread-123'], 1);
    expect(
      find.text('Dangerous action was gated pending explicit approval'),
      findsOneWidget,
    );
  });

  testWidgets('non-repository context disables git mutations safely', (
    tester,
  ) async {
    final detailApi = FakeThreadDetailBridgeApi(
      detailScriptByThreadId: {
        'thread-no-repo': [
          const ThreadDetailDto(
            contractVersion: contractVersion,
            threadId: 'thread-no-repo',
            title: 'Thread without git context',
            status: ThreadStatus.idle,
            workspace: '/workspace/non-repo',
            repository: 'unknown-repository',
            branch: 'unknown',
            createdAt: '2026-03-18T09:45:00Z',
            updatedAt: '2026-03-18T10:00:00Z',
            source: 'cli',
            accessMode: AccessMode.controlWithApprovals,
            lastTurnSummary: 'Idle',
          ),
        ],
      },
      timelineScriptByThreadId: {
        'thread-no-repo': [<ThreadTimelineEntryDto>[]],
      },
      gitStatusScriptByThreadId: {
        'thread-no-repo': [
          _gitStatus(
            threadId: 'thread-no-repo',
            workspace: '/workspace/non-repo',
            repository: 'unknown-repository',
            branch: 'unknown',
            remote: 'local',
          ),
        ],
      },
    );

    await _pumpThreadDetailApp(
      tester,
      detailApi: detailApi,
      threadId: 'thread-no-repo',
    );

    expect(
      find.byKey(const Key('git-controls-unavailable-message')),
      findsOneWidget,
    );

    await _openGitBranchSheet(tester);
    final switchButton = tester.widget<FilledButton>(
      find.byKey(const Key('git-branch-switch-button')),
    );
    await _closeModalSheet(tester);
    await _openGitSyncSheet(tester);
    final pullButton = tester.widget<OutlinedButton>(
      find.byKey(const Key('git-pull-button')),
    );
    final pushButton = tester.widget<OutlinedButton>(
      find.byKey(const Key('git-push-button')),
    );

    expect(switchButton.onPressed, isNull);
    expect(pullButton.onPressed, isNull);
    expect(pushButton.onPressed, isNull);
  });

  testWidgets(
    'raw non-repository git status errors are downgraded into unavailable controls',
    (tester) async {
      final detailApi = FakeThreadDetailBridgeApi(
        detailScriptByThreadId: {
          'thread-no-repo': [
            const ThreadDetailDto(
              contractVersion: contractVersion,
              threadId: 'thread-no-repo',
              title: 'Thread without git context',
              status: ThreadStatus.idle,
              workspace: '/workspace/non-repo',
              repository: 'workspace',
              branch: 'unknown',
              createdAt: '2026-03-18T09:45:00Z',
              updatedAt: '2026-03-18T10:00:00Z',
              source: 'cli',
              accessMode: AccessMode.controlWithApprovals,
              lastTurnSummary: 'Idle',
            ),
          ],
        },
        timelineScriptByThreadId: {
          'thread-no-repo': [<ThreadTimelineEntryDto>[]],
        },
        gitStatusScriptByThreadId: {
          'thread-no-repo': [
            const ThreadGitBridgeException(
              message:
                  'fatal: not a git repository (or any of the parent directories): .git',
            ),
          ],
        },
      );

      await _pumpThreadDetailApp(
        tester,
        detailApi: detailApi,
        threadId: 'thread-no-repo',
      );

      expect(
        find.byKey(const Key('git-controls-unavailable-message')),
        findsOneWidget,
      );
      expect(
        find.text('Git controls are unavailable for this thread.'),
        findsOneWidget,
      );
      expect(find.textContaining('fatal: not a git repository'), findsNothing);
    },
  );

  testWidgets('switching threads retargets git actions to new context', (
    tester,
  ) async {
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

    await _pumpThreadListApp(
      tester,
      listApi: listApi,
      detailApi: detailApi,
      liveStream: FakeThreadLiveStream(),
    );

    await tester.tap(find.byKey(const Key('thread-summary-card-thread-123')));
    await tester.pumpAndSettle();

    await _openGitBranchSheet(tester);
    expect(find.text('Repository: vibe-bridge-companion'), findsOneWidget);
    await _closeModalSheet(tester);

    await _tapThreadDetailBackButton(tester);
    await tester.tap(find.byKey(const Key('thread-summary-card-thread-456')));
    await tester.pumpAndSettle();

    await _openGitBranchSheet(tester);
    expect(find.text('Repository: codex-runtime-tools'), findsOneWidget);
    await _closeModalSheet(tester);
    await _openGitSyncSheet(tester);
    final pullButton = tester.widget<OutlinedButton>(
      find.byKey(const Key('git-pull-button')),
    );

    expect(detailApi.pullCallsByThreadId['thread-123'], isNull);
    expect(detailApi.pullCallsByThreadId['thread-456'], isNull);
    expect(pullButton.onPressed, isNotNull);
  });

  testWidgets('bridge surfaces git mutation failures after attempted pull', (
    tester,
  ) async {
    final detailApi = FakeThreadDetailBridgeApi(
      detailScriptByThreadId: {
        'thread-123': [_thread123Detail()],
      },
      timelineScriptByThreadId: {
        'thread-123': [<ThreadTimelineEntryDto>[]],
      },
      pullScriptByThreadId: {
        'thread-123': [
          const ThreadGitMutationBridgeException(
            message: 'Pull failed: remote rejected the update.',
          ),
        ],
      },
    );

    await _pumpThreadDetailApp(
      tester,
      detailApi: detailApi,
      threadId: 'thread-123',
    );

    await _openGitSyncSheet(tester);
    await tester.tap(find.byKey(const Key('git-pull-button')));
    await tester.pumpAndSettle();

    expect(detailApi.pullCallsByThreadId['thread-123'], 1);
    expect(
      find.text('Pull failed: remote rejected the update.'),
      findsOneWidget,
    );
  });

  testWidgets(
    'live stream updates detail and syncs lifecycle status back to list',
    (tester) async {
      final listApi = FakeThreadListBridgeApi(
        scriptedResults: [_threadSummaries()],
      );
      final detailApi = FakeThreadDetailBridgeApi(
        detailScriptByThreadId: {
          'thread-123': [_thread123Detail(status: ThreadStatus.completed)],
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

      await _scrollUntilVisible(
        tester,
        find.text('Streaming chunk from live output.'),
      );
      expect(find.text('Streaming chunk from live output.'), findsWidgets);

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

      await _tapThreadDetailBackButton(tester);

      expect(find.text('COMPLETED'), findsOneWidget);
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
    expect(find.byKey(const Key('load-earlier-history')), findsNothing);

    await tester.drag(
      find.byKey(const Key('thread-detail-scroll-view')),
      const Offset(0, 800),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('Oldest event'), findsOneWidget);
    expect(find.text('Older event'), findsOneWidget);
    expect(find.text('New messages'), findsNothing);
    final oldestY = tester.getTopLeft(find.text('Oldest event')).dy;
    final olderY = tester.getTopLeft(find.text('Older event')).dy;
    expect(oldestY, lessThan(olderY));
  });

  testWidgets(
    'new live messages still surface the badge when scrolled away from the bottom',
    (tester) async {
      final timeline = List<ThreadTimelineEntryDto>.generate(
        64,
        (index) => _timelineEvent(
          id: 'evt-live-$index',
          kind: BridgeEventKind.messageDelta,
          summary: 'Assistant output $index',
          payload: {'delta': 'Existing event $index'},
          occurredAt:
              '2026-03-18T09:${(index % 60).toString().padLeft(2, '0')}:00Z',
        ),
      );
      final detailApi = FakeThreadDetailBridgeApi(
        detailScriptByThreadId: {
          'thread-123': [_thread123Detail()],
        },
        timelineScriptByThreadId: {
          'thread-123': [timeline],
        },
      );
      final liveStream = FakeThreadLiveStream();

      await _pumpThreadDetailApp(
        tester,
        detailApi: detailApi,
        threadId: 'thread-123',
        liveStream: liveStream,
      );
      await tester.pumpAndSettle();

      final scrollPosition = _threadDetailScrollPosition(tester);
      scrollPosition.jumpTo(scrollPosition.minScrollExtent);
      await tester.pump();
      await tester.pumpAndSettle();

      liveStream.emit(
        const BridgeEventEnvelope<Map<String, dynamic>>(
          contractVersion: contractVersion,
          eventId: 'evt-live-new',
          threadId: 'thread-123',
          kind: BridgeEventKind.messageDelta,
          occurredAt: '2026-03-18T10:30:00Z',
          payload: {'type': 'agentMessage', 'text': 'Newest streamed event'},
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('thread-detail-new-message-button')),
        findsOneWidget,
      );
      expect(find.text('New messages'), findsNothing);
      expect(find.text('Newest streamed event'), findsNothing);
    },
  );

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
      await _scrollUntilVisible(tester, find.text('Visible on thread 123'));
      expect(find.text('Visible on thread 123'), findsOneWidget);

      await _tapThreadDetailBackButton(tester);
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
      await _scrollUntilVisible(tester, find.text('Visible on thread 456'));
      expect(find.text('Visible on thread 456'), findsWidgets);
    },
  );

  testWidgets(
    'open thread detail streams an upstream turn started outside mobile',
    (tester) async {
      final detailApi = FakeThreadDetailBridgeApi(
        detailScriptByThreadId: {
          'thread-123': [_thread123Detail(status: ThreadStatus.idle)],
        },
        timelineScriptByThreadId: {
          'thread-123': [<ThreadTimelineEntryDto>[]],
        },
      );
      final liveStream = FakeThreadLiveStream();

      await _pumpThreadDetailApp(
        tester,
        detailApi: detailApi,
        threadId: 'thread-123',
        liveStream: liveStream,
      );
      await tester.pumpAndSettle();

      expect(find.text('Idle'), findsOneWidget);

      liveStream.emit(
        const BridgeEventEnvelope<Map<String, dynamic>>(
          contractVersion: contractVersion,
          eventId: 'evt-upstream-running',
          threadId: 'thread-123',
          kind: BridgeEventKind.threadStatusChanged,
          occurredAt: '2026-03-18T10:30:00Z',
          payload: {'status': 'running', 'reason': 'upstream_notification'},
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Running'), findsOneWidget);

      liveStream.emit(
        const BridgeEventEnvelope<Map<String, dynamic>>(
          contractVersion: contractVersion,
          eventId: 'evt-upstream-msg-1',
          threadId: 'thread-123',
          kind: BridgeEventKind.messageDelta,
          occurredAt: '2026-03-18T10:30:01Z',
          payload: {
            'type': 'agentMessage',
            'text': 'Streaming from a turn started in Codex.app',
          },
        ),
      );
      await tester.pumpAndSettle();

      await _scrollUntilVisible(
        tester,
        find.text('Streaming from a turn started in Codex.app'),
      );
      expect(
        find.text('Streaming from a turn started in Codex.app'),
        findsWidgets,
      );

      liveStream.emit(
        const BridgeEventEnvelope<Map<String, dynamic>>(
          contractVersion: contractVersion,
          eventId: 'evt-upstream-completed',
          threadId: 'thread-123',
          kind: BridgeEventKind.threadStatusChanged,
          occurredAt: '2026-03-18T10:30:02Z',
          payload: {'status': 'completed', 'reason': 'upstream_notification'},
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Completed'), findsOneWidget);
    },
  );

  testWidgets(
    'terminal live status refresh reloads timeline items that arrive after Claude turn completion',
    (tester) async {
      final detailApi = FakeThreadDetailBridgeApi(
        detailScriptByThreadId: {
          'thread-123': [
            _thread123Detail(status: ThreadStatus.running),
            _thread123Detail(status: ThreadStatus.completed),
          ],
        },
        timelineScriptByThreadId: {
          'thread-123': [
            <ThreadTimelineEntryDto>[],
            [
              _timelineEvent(
                id: 'evt-claude-file-change',
                kind: BridgeEventKind.fileChange,
                summary: 'Edited files via Edit',
                payload: {
                  'path': 'apps/mobile/lib/live_approval_probe.dart',
                  'change': 'updated by Claude tool call',
                },
                occurredAt: '2026-03-18T10:30:03Z',
              ),
            ],
          ],
        },
      );
      final liveStream = FakeThreadLiveStream();

      await _pumpThreadDetailApp(
        tester,
        detailApi: detailApi,
        threadId: 'thread-123',
        liveStream: liveStream,
      );
      await tester.pumpAndSettle();

      expect(find.text('updated by Claude tool call'), findsNothing);
      expect(detailApi.timelineFetchCount, 1);

      liveStream.emit(
        const BridgeEventEnvelope<Map<String, dynamic>>(
          contractVersion: contractVersion,
          eventId: 'evt-upstream-completed-with-tools',
          threadId: 'thread-123',
          kind: BridgeEventKind.threadStatusChanged,
          occurredAt: '2026-03-18T10:30:02Z',
          payload: {'status': 'completed', 'reason': 'upstream_notification'},
        ),
      );
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();

      final args = ThreadDetailControllerArgs(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
        threadId: 'thread-123',
        initialVisibleTimelineEntries: 20,
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ThreadDetailPage)),
      );

      expect(find.text('Completed'), findsOneWidget);
      expect(detailApi.timelineFetchCount, greaterThanOrEqualTo(2));
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      var foundFileChange = false;
      while (DateTime.now().isBefore(deadline)) {
        final controllerState = container.read(
          threadDetailControllerProvider(args),
        );
        foundFileChange = controllerState.visibleItems.any(
          (item) =>
              item.type == ThreadActivityItemType.fileChange &&
              item.body.contains('updated by Claude tool call'),
        );
        if (foundFileChange) {
          break;
        }
        await tester.pump(const Duration(milliseconds: 100));
      }

      final latestControllerState = container.read(
        threadDetailControllerProvider(args),
      );
      final visibleBodies = latestControllerState.items
          .map((item) => '${item.type.name}:${item.body}')
          .join(' || ');
      expect(foundFileChange, isTrue, reason: visibleBodies);
    },
  );

  testWidgets(
    'live message updates replace the existing activity card when the event id stays stable',
    (tester) async {
      final detailApi = FakeThreadDetailBridgeApi(
        detailScriptByThreadId: {
          'thread-123': [_thread123Detail()],
        },
        timelineScriptByThreadId: {
          'thread-123': [<ThreadTimelineEntryDto>[]],
        },
      );
      final liveStream = FakeThreadLiveStream();

      await _pumpThreadDetailApp(
        tester,
        detailApi: detailApi,
        threadId: 'thread-123',
        liveStream: liveStream,
      );
      await tester.pumpAndSettle();

      liveStream.emit(
        const BridgeEventEnvelope<Map<String, dynamic>>(
          contractVersion: contractVersion,
          eventId: 'evt-stable-stream',
          threadId: 'thread-123',
          kind: BridgeEventKind.messageDelta,
          occurredAt: '2026-03-18T10:30:00Z',
          payload: {'type': 'agentMessage', 'text': 'Hel'},
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Hel'), findsOneWidget);
      expect(
        find.byKey(const Key('thread-message-card-evt-stable-stream')),
        findsOneWidget,
      );

      liveStream.emit(
        const BridgeEventEnvelope<Map<String, dynamic>>(
          contractVersion: contractVersion,
          eventId: 'evt-stable-stream',
          threadId: 'thread-123',
          kind: BridgeEventKind.messageDelta,
          occurredAt: '2026-03-18T10:30:01Z',
          payload: {
            'type': 'agentMessage',
            'text': 'Hello from the updated streamed message',
          },
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Hel'), findsNothing);
      expect(
        find.text('Hello from the updated streamed message'),
        findsWidgets,
      );
      expect(
        find.byKey(const Key('thread-message-card-evt-stable-stream')),
        findsOneWidget,
      );
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
      autoOpenPreviouslySelectedThread: true,
      cacheRepository: cacheRepository,
    );

    expect(
      find.byKey(const Key('thread-detail-metadata-scroll')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('thread-detail-title')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('thread-detail-title'))).data,
      'Investigate reconnect dedup',
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('thread-detail-metadata-scroll')),
        matching: find.text('codex-runtime-tools'),
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'timeline unavailability preserves loaded detail until retry succeeds',
    (tester) async {
      final listApi = FakeThreadListBridgeApi(
        scriptedResults: [_threadSummaries()],
      );
      final detailApi = FakeThreadDetailBridgeApi(
        detailScriptByThreadId: {
          'thread-123': [_thread123Detail()],
        },
        timelineScriptByThreadId: {
          'thread-123': [
            const ThreadDetailBridgeException(
              message: 'Thread was archived remotely.',
              isUnavailable: true,
            ),
            <ThreadTimelineEntryDto>[],
          ],
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

      expect(find.text('Unavailable'), findsNothing);
      expect(find.byKey(const Key('thread-detail-title')), findsOneWidget);
    },
  );

  testWidgets('offline mode without a loaded thread shows the bridge error', (
    tester,
  ) async {
    final cacheRepository = _newCacheRepository();
    await cacheRepository.saveThreadList(_threadSummaries());

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
          approvalBridgeApiProvider.overrideWithValue(EmptyApprovalBridgeApi()),
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

    expect(find.text('Implement shared contracts'), findsNothing);
    expect(
      find.text('Cannot reach the bridge. Check your private route.'),
      findsWidgets,
    );
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets(
    'offline mode without a loaded thread keeps the full header layout disabled',
    (tester) async {
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
            threadCacheRepositoryProvider.overrideWithValue(
              _newCacheRepository(),
            ),
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

      expect(find.byKey(const Key('thread-detail-title')), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('thread-detail-title'))).data,
        'Session Details',
      );
      expect(
        find.byKey(const Key('thread-detail-metadata-scroll')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('git-header-branch-button')), findsOneWidget);
      expect(find.byKey(const Key('git-header-sync-button')), findsOneWidget);
      expect(find.byKey(const Key('open-on-mac-button')), findsOneWidget);

      final branchButton = tester.widget<ButtonStyleButton>(
        find.byKey(const Key('git-header-branch-button')),
      );
      final syncButton = tester.widget<ButtonStyleButton>(
        find.byKey(const Key('git-header-sync-button')),
      );
      final openOnMacButton = tester.widget<ButtonStyleButton>(
        find.byKey(const Key('open-on-mac-button')),
      );

      expect(branchButton.onPressed, isNull);
      expect(syncButton.onPressed, isNull);
      expect(openOnMacButton.onPressed, isNull);
    },
  );

  testWidgets('disconnect reconnects and keeps items deduplicated', (
    tester,
  ) async {
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

    expect(
      find.byKey(const Key('thread-message-card-evt-live-1')),
      findsOneWidget,
    );

    await tester.fling(
      find.byType(Scrollable).first,
      const Offset(0, 600),
      1000,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    liveStream.emitError('thread-123');
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 250));

    expect(
      find.byKey(const Key('thread-message-card-evt-live-1')),
      findsOneWidget,
    );
  });

  testWidgets(
    'reconnect deduplicates a replayed assistant reply with a new event id',
    (tester) async {
      final detailApi = FakeThreadDetailBridgeApi(
        detailScriptByThreadId: {
          'thread-123': [_thread123Detail(), _thread123Detail()],
        },
        timelineScriptByThreadId: {
          'thread-123': [
            <ThreadTimelineEntryDto>[],
            [
              _timelineEvent(
                id: 'evt-replayed-hello',
                kind: BridgeEventKind.messageDelta,
                summary: 'Hello.',
                payload: {'delta': 'Hello.'},
                occurredAt: '2026-03-18T10:01:30Z',
              ),
            ],
          ],
        },
      );
      final liveStream = FakeThreadLiveStream();

      await _pumpThreadDetailApp(
        tester,
        detailApi: detailApi,
        threadId: 'thread-123',
        liveStream: liveStream,
      );
      await tester.pumpAndSettle();

      liveStream.emit(
        const BridgeEventEnvelope<Map<String, dynamic>>(
          contractVersion: contractVersion,
          eventId: 'evt-live-hello',
          threadId: 'thread-123',
          kind: BridgeEventKind.messageDelta,
          occurredAt: '2026-03-18T10:01:00Z',
          payload: {'type': 'agentMessage', 'text': 'Hello.'},
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Hello.'), findsOneWidget);
      expect(
        find.byKey(const Key('thread-message-card-evt-live-hello')),
        findsOneWidget,
      );

      liveStream.emitError('thread-123');
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.text('Hello.'), findsOneWidget);
      expect(
        find.byKey(const Key('thread-message-card-evt-live-hello')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('thread-message-card-evt-replayed-hello')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'speech preflight shows a dialog when Parakeet is not installed',
    (tester) async {
      final detailApi = FakeThreadDetailBridgeApi(
        detailScriptByThreadId: {
          'thread-123': [_thread123Detail(status: ThreadStatus.completed)],
        },
        timelineScriptByThreadId: {
          'thread-123': [<ThreadTimelineEntryDto>[]],
        },
        speechStatusScript: [
          const SpeechModelStatusDto(
            contractVersion: contractVersion,
            provider: 'fluid_audio',
            modelId: 'parakeet-tdt-0.6b-v3-coreml',
            state: SpeechModelState.notInstalled,
          ),
        ],
      );

      await _pumpThreadDetailApp(
        tester,
        detailApi: detailApi,
        threadId: 'thread-123',
      );

      await _focusComposer(tester);
      await _pressSpeechToggle(tester);

      expect(
        find.byKey(const Key('speech-unavailable-dialog')),
        findsOneWidget,
      );
      expect(find.text('Install Parakeet'), findsOneWidget);
      expect(find.textContaining('desktop host shell'), findsOneWidget);
      expect(detailApi.transcribeAudioCallCount, 0);
      expect(find.byKey(const Key('speech-loading')), findsNothing);
    },
  );

  testWidgets('speech toggle stays hidden until the composer is focused', (
    tester,
  ) async {
    final detailApi = FakeThreadDetailBridgeApi(
      detailScriptByThreadId: {
        'thread-123': [_thread123Detail(status: ThreadStatus.completed)],
      },
      timelineScriptByThreadId: {
        'thread-123': [<ThreadTimelineEntryDto>[]],
      },
      speechStatusScript: [
        const SpeechModelStatusDto(
          contractVersion: contractVersion,
          provider: 'fluid_audio',
          modelId: 'parakeet-tdt-0.6b-v3-coreml',
          state: SpeechModelState.ready,
        ),
      ],
    );

    await _pumpThreadDetailApp(
      tester,
      detailApi: detailApi,
      threadId: 'thread-123',
    );

    expect(find.byKey(const Key('turn-composer-speech-toggle')), findsNothing);

    await _focusComposer(tester);

    expect(
      find.byKey(const Key('turn-composer-speech-toggle')),
      findsOneWidget,
    );
  });

  testWidgets('speech preflight shows a dialog when speech is unsupported', (
    tester,
  ) async {
    final detailApi = FakeThreadDetailBridgeApi(
      detailScriptByThreadId: {
        'thread-123': [_thread123Detail(status: ThreadStatus.completed)],
      },
      timelineScriptByThreadId: {
        'thread-123': [<ThreadTimelineEntryDto>[]],
      },
      speechStatusScript: [
        const SpeechModelStatusDto(
          contractVersion: contractVersion,
          provider: 'fluid_audio',
          modelId: 'parakeet-tdt-0.6b-v3-coreml',
          state: SpeechModelState.unsupported,
          lastError:
              'Speech transcription is only available from the desktop host runtime.',
        ),
      ],
    );

    await _pumpThreadDetailApp(
      tester,
      detailApi: detailApi,
      threadId: 'thread-123',
    );

    await _focusComposer(tester);
    await _pressSpeechToggle(tester);

    expect(find.byKey(const Key('speech-unavailable-dialog')), findsOneWidget);
    expect(find.text('Speech unavailable'), findsOneWidget);
    expect(
      find.text(
        'Speech transcription is only available from the desktop host runtime.',
      ),
      findsOneWidget,
    );
    expect(detailApi.transcribeAudioCallCount, 0);
  });

  testWidgets(
    'speech transcription failure for missing Parakeet clears loading and shows a dialog',
    (tester) async {
      final detailApi = FakeThreadDetailBridgeApi(
        detailScriptByThreadId: {
          'thread-123': [_thread123Detail(status: ThreadStatus.completed)],
        },
        timelineScriptByThreadId: {
          'thread-123': [<ThreadTimelineEntryDto>[]],
        },
        speechStatusScript: [
          const SpeechModelStatusDto(
            contractVersion: contractVersion,
            provider: 'fluid_audio',
            modelId: 'parakeet-tdt-0.6b-v3-coreml',
            state: SpeechModelState.ready,
          ),
          const SpeechModelStatusDto(
            contractVersion: contractVersion,
            provider: 'fluid_audio',
            modelId: 'parakeet-tdt-0.6b-v3-coreml',
            state: SpeechModelState.ready,
          ),
          const SpeechModelStatusDto(
            contractVersion: contractVersion,
            provider: 'fluid_audio',
            modelId: 'parakeet-tdt-0.6b-v3-coreml',
            state: SpeechModelState.notInstalled,
          ),
        ],
        speechTranscriptionError: const ThreadSpeechBridgeException(
          message: 'Parakeet is not installed on this host yet.',
          code: 'speech_not_installed',
        ),
      );

      await _pumpThreadDetailApp(
        tester,
        detailApi: detailApi,
        threadId: 'thread-123',
        speechCaptureOverride: _FakeSpeechCapture(),
      );

      await _focusComposer(tester);
      await _pressSpeechToggle(tester);

      expect(find.textContaining('Recording voice message'), findsOneWidget);

      await _pressSpeechToggle(tester);

      expect(detailApi.transcribeAudioCallCount, 1);
      expect(find.byKey(const Key('speech-loading')), findsNothing);
      expect(
        find.byKey(const Key('speech-unavailable-dialog')),
        findsOneWidget,
      );
      expect(find.text('Install Parakeet'), findsOneWidget);
    },
  );

  testWidgets(
    'speech helper failures clear loading and show the unavailable dialog',
    (tester) async {
      final detailApi = FakeThreadDetailBridgeApi(
        detailScriptByThreadId: {
          'thread-123': [_thread123Detail(status: ThreadStatus.completed)],
        },
        timelineScriptByThreadId: {
          'thread-123': [<ThreadTimelineEntryDto>[]],
        },
        speechStatusScript: [
          const SpeechModelStatusDto(
            contractVersion: contractVersion,
            provider: 'fluid_audio',
            modelId: 'parakeet-tdt-0.6b-v3-coreml',
            state: SpeechModelState.ready,
          ),
          const SpeechModelStatusDto(
            contractVersion: contractVersion,
            provider: 'fluid_audio',
            modelId: 'parakeet-tdt-0.6b-v3-coreml',
            state: SpeechModelState.ready,
          ),
          const SpeechModelStatusDto(
            contractVersion: contractVersion,
            provider: 'fluid_audio',
            modelId: 'parakeet-tdt-0.6b-v3-coreml',
            state: SpeechModelState.failed,
            lastError: 'The host speech helper is unavailable right now.',
          ),
        ],
        speechTranscriptionError: const ThreadSpeechBridgeException(
          message: 'The host speech helper is unavailable right now.',
          code: 'speech_helper_unavailable',
        ),
      );

      await _pumpThreadDetailApp(
        tester,
        detailApi: detailApi,
        threadId: 'thread-123',
        speechCaptureOverride: _FakeSpeechCapture(),
      );

      await _focusComposer(tester);
      await _pressSpeechToggle(tester);
      await _pressSpeechToggle(tester);

      expect(detailApi.transcribeAudioCallCount, 1);
      expect(find.byKey(const Key('speech-loading')), findsNothing);
      expect(
        find.byKey(const Key('speech-unavailable-dialog')),
        findsOneWidget,
      );
      expect(find.text('Speech unavailable'), findsOneWidget);
      expect(
        find.text('The host speech helper is unavailable right now.'),
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
  bool autoOpenPreviouslySelectedThread = false,
  ApprovalBridgeApi? approvalApi,
  ThreadCacheRepository? cacheRepository,
  SettingsBridgeApi? settingsApi,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appSecureStoreProvider.overrideWithValue(InMemorySecureStore()),
        threadListBridgeApiProvider.overrideWithValue(listApi),
        approvalBridgeApiProvider.overrideWithValue(
          approvalApi ?? EmptyApprovalBridgeApi(),
        ),
        threadDetailBridgeApiProvider.overrideWithValue(detailApi),
        settingsBridgeApiProvider.overrideWithValue(
          settingsApi ?? FakeSettingsBridgeApi(),
        ),
        threadLiveStreamProvider.overrideWithValue(liveStream),
        threadCacheRepositoryProvider.overrideWithValue(
          cacheRepository ?? _newCacheRepository(),
        ),
      ],
      child: MaterialApp(
        home: ThreadListPage(
          bridgeApiBaseUrl: _bridgeApiBaseUrl,
          autoOpenPreviouslySelectedThread: autoOpenPreviouslySelectedThread,
        ),
      ),
    ),
  );

  await tester.pumpAndSettle();
}

Future<void> _pumpThreadDetailApp(
  WidgetTester tester, {
  required ThreadDetailBridgeApi detailApi,
  required String threadId,
  int initialVisibleTimelineEntries = 20,
  ThreadListBridgeApi? listApi,
  ThreadLiveStream? liveStream,
  ApprovalBridgeApi? approvalApi,
  ThreadCacheRepository? cacheRepository,
  SettingsBridgeApi? settingsApi,
  InMemorySecureStore? store,
  Future<List<XFile>> Function()? pickImagesOverride,
  SpeechCapture? speechCaptureOverride,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appSecureStoreProvider.overrideWithValue(
          store ?? InMemorySecureStore(),
        ),
        threadListBridgeApiProvider.overrideWithValue(
          listApi ??
              FakeThreadListBridgeApi(scriptedResults: [_threadSummaries()]),
        ),
        approvalBridgeApiProvider.overrideWithValue(
          approvalApi ?? EmptyApprovalBridgeApi(),
        ),
        threadDetailBridgeApiProvider.overrideWithValue(detailApi),
        settingsBridgeApiProvider.overrideWithValue(
          settingsApi ?? FakeSettingsBridgeApi(),
        ),
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
          initialVisibleTimelineEntries: initialVisibleTimelineEntries,
          pickImagesOverride: pickImagesOverride,
          speechCaptureOverride: speechCaptureOverride,
        ),
      ),
    ),
  );

  await tester.pump();
  await _pumpForTransientUiWork(tester, iterations: 4);
}

Future<void> _scrollUntilVisible(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isNotEmpty) {
    return;
  }

  final candidates = <Finder>[
    find.byKey(const Key('thread-detail-scroll-view')),
    find.byType(Scrollable).first,
  ];

  for (final candidate in candidates) {
    if (candidate.evaluate().isEmpty) {
      continue;
    }

    try {
      await tester.scrollUntilVisible(finder, 240, scrollable: candidate);
      await tester.pumpAndSettle();
      if (finder.evaluate().isNotEmpty) {
        return;
      }
    } catch (_) {
      // Try the next scrollable candidate.
    }
  }

  throw StateError('Could not scroll finder into view: $finder');
}

String _timelineBlockKeyForTest(ThreadTimelineBlock block) {
  if (block.item != null) {
    return 'activity:${block.item!.eventId}';
  }

  if (block.workSummary != null) {
    return 'work-summary:${block.workSummary!.anchorEventId}';
  }

  final exploration = block.exploration;
  if (exploration != null) {
    return 'exploration:${exploration.sourceEventIds.join("|")}';
  }

  return 'timeline-block';
}

ScrollPosition _threadDetailScrollPosition(WidgetTester tester) {
  final scrollable = find
      .descendant(
        of: find.byKey(const Key('thread-detail-scroll-view')),
        matching: find.byType(Scrollable),
      )
      .first;
  return tester.state<ScrollableState>(scrollable).position;
}

Future<void> _tapThreadDetailBackButton(WidgetTester tester) async {
  final backButton = find.byKey(const Key('thread-detail-back-button'));
  if (backButton.evaluate().isEmpty) {
    await tester.pumpAndSettle();
    return;
  }

  await tester.tap(backButton);
  await tester.pumpAndSettle();
}

Future<void> _openGitBranchSheet(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('git-header-branch-button')));
  await tester.pumpAndSettle();
}

Future<void> _openGitSyncSheet(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('git-header-sync-button')));
  await tester.pumpAndSettle();
}

Future<void> _openComposerModelSheet(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('thread-detail-settings-toggle')));
  await tester.pumpAndSettle();
}

Future<void> _pumpForTransientUiWork(
  WidgetTester tester, {
  int iterations = 4,
}) async {
  for (var index = 0; index < iterations; index++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}

Future<void> _pumpUntilCondition(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) {
      return;
    }
    await tester.pump(const Duration(milliseconds: 16));
  }

  throw TestFailure('Timed out waiting for test condition.');
}

Future<XFile> _createTestImageFile(String fileName) async {
  return XFile.fromData(
    base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wn2X1EAAAAASUVORK5CYII=',
    ),
    mimeType: 'image/png',
    name: fileName,
  );
}

Future<void> _focusComposer(WidgetTester tester) async {
  await tester.showKeyboard(find.byKey(const Key('turn-composer-input')));
  await tester.pumpAndSettle();
}

Future<void> _pressSpeechToggle(WidgetTester tester) async {
  final buttonFinder = find.byKey(const Key('turn-composer-speech-toggle'));
  if (buttonFinder.evaluate().isEmpty) {
    await tester.tap(find.byKey(const Key('turn-composer-input')).first);
    await tester.pumpAndSettle();
  }
  await tester.tap(find.byKey(const Key('turn-composer-speech-toggle')).first);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pumpAndSettle();
}

Future<void> _closeModalSheet(WidgetTester tester) async {
  final navigatorState = tester.state<NavigatorState>(
    find.byType(Navigator).first,
  );
  navigatorState.pop();
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

class _HangingSelectedThreadCacheRepository implements ThreadCacheRepository {
  @override
  Future<CachedThreadListSnapshot?> readThreadList() async => null;

  @override
  Future<String?> readSelectedThreadId() async => null;

  @override
  Future<void> saveSelectedThreadId(String threadId) {
    return Completer<void>().future;
  }

  @override
  Future<void> saveThreadList(List<ThreadSummaryDto> threads) async {}
}

const _bridgeApiBaseUrl = 'https://bridge.ts.net';
const _realThreadFixtureDetailPath =
    'test/features/threads/fixtures/real_thread_019d_detail.json';
const _realThreadFixtureTimelinePath =
    'test/features/threads/fixtures/real_thread_019d_timeline_limit_80.json';
const _realThreadFixtureOlderTimelinePath =
    'test/features/threads/fixtures/real_thread_019d_timeline_before_558_limit_80.json';
const _realThreadFixtureSearchExplorationTimelinePath =
    'test/features/threads/fixtures/real_thread_019d_timeline_before_478_limit_80.json';
const _fixCodexThreadStatusFixtureTimelinePath =
    'test/features/threads/fixtures/real_thread_fix_codex_status_timeline_limit_80.json';
const _fixCodexThreadStatusFixtureOlderTimelinePath =
    'test/features/threads/fixtures/real_thread_fix_codex_status_timeline_before_1760_limit_80.json';
const _fixCodexThreadStatusFixtureOldestTimelinePath =
    'test/features/threads/fixtures/real_thread_fix_codex_status_timeline_before_1680_limit_80.json';

_RealThreadFixture _loadRealThreadFixture() {
  final detailRaw = File(_realThreadFixtureDetailPath).readAsStringSync();
  final timelineRaw = File(_realThreadFixtureTimelinePath).readAsStringSync();

  final detailEnvelope = jsonDecode(detailRaw) as Map<String, dynamic>;
  final timelineJson = jsonDecode(timelineRaw) as Map<String, dynamic>;

  final detailJson = detailEnvelope['thread'];
  if (detailJson is! Map<String, dynamic>) {
    throw const FormatException(
      'Real thread detail fixture is missing thread.',
    );
  }

  return _RealThreadFixture(
    detail: ThreadDetailDto.fromJson(detailJson),
    timelinePage: ThreadTimelinePageDto.fromJson(timelineJson),
  );
}

ThreadTimelinePageDto _loadRealThreadOlderTimelineFixture() {
  final timelineRaw = File(
    _realThreadFixtureOlderTimelinePath,
  ).readAsStringSync();
  final timelineJson = jsonDecode(timelineRaw) as Map<String, dynamic>;
  return ThreadTimelinePageDto.fromJson(timelineJson);
}

ThreadTimelinePageDto _loadRealThreadSearchExplorationTimelineFixture() {
  final timelineRaw = File(
    _realThreadFixtureSearchExplorationTimelinePath,
  ).readAsStringSync();
  final timelineJson = jsonDecode(timelineRaw) as Map<String, dynamic>;
  return ThreadTimelinePageDto.fromJson(timelineJson);
}

ThreadTimelinePageDto _loadFixCodexThreadStatusLatestTimelineFixture() {
  final timelineRaw = File(
    _fixCodexThreadStatusFixtureTimelinePath,
  ).readAsStringSync();
  final timelineJson = jsonDecode(timelineRaw) as Map<String, dynamic>;
  return ThreadTimelinePageDto.fromJson(timelineJson);
}

ThreadTimelinePageDto _loadFixCodexThreadStatusOlderTimelineFixture() {
  final timelineRaw = File(
    _fixCodexThreadStatusFixtureOlderTimelinePath,
  ).readAsStringSync();
  final timelineJson = jsonDecode(timelineRaw) as Map<String, dynamic>;
  return ThreadTimelinePageDto.fromJson(timelineJson);
}

ThreadTimelinePageDto _loadFixCodexThreadStatusOldestTimelineFixture() {
  final timelineRaw = File(
    _fixCodexThreadStatusFixtureOldestTimelinePath,
  ).readAsStringSync();
  final timelineJson = jsonDecode(timelineRaw) as Map<String, dynamic>;
  return ThreadTimelinePageDto.fromJson(timelineJson);
}

class _RealThreadFixture {
  const _RealThreadFixture({required this.detail, required this.timelinePage});

  final ThreadDetailDto detail;
  final ThreadTimelinePageDto timelinePage;

  List<ThreadTimelineEntryDto> get timelineEntries => timelinePage.entries;
}

class _HistoryRequest {
  const _HistoryRequest({required this.before, required this.limit});

  final String? before;
  final int limit;
}

class _ScriptedTimelinePageThreadDetailBridgeApi
    implements ThreadDetailBridgeApi {
  _ScriptedTimelinePageThreadDetailBridgeApi({
    required this.detail,
    required Map<String?, ThreadTimelinePageDto> pagesByBefore,
    this.delaysByBefore = const <String?, Duration>{},
  }) : _pagesByBefore = Map<String?, ThreadTimelinePageDto>.from(pagesByBefore);

  final ThreadDetailDto detail;
  final Map<String?, ThreadTimelinePageDto> _pagesByBefore;
  final Map<String?, Duration> delaysByBefore;
  final List<_HistoryRequest> historyRequests = <_HistoryRequest>[];
  int completedHistoryRequests = 0;

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
  }) {
    throw const ThreadSpeechBridgeException(message: 'Speech is unused here.');
  }

  @override
  Future<ThreadSnapshotDto> createThread({
    required String bridgeApiBaseUrl,
    required String workspace,
    required ProviderKind provider,
    String? model,
  }) {
    throw UnimplementedError('Thread creation is unused in this test.');
  }

  @override
  Future<ThreadDetailDto> fetchThreadDetail({
    required String bridgeApiBaseUrl,
    required String threadId,
  }) async {
    return detail;
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
    final entries =
        _pagesByBefore.values
            .expand((page) => page.entries)
            .toList(growable: false)
          ..sort((left, right) => left.occurredAt.compareTo(right.occurredAt));
    return entries;
  }

  @override
  Future<ThreadTimelinePageDto> fetchThreadTimelinePage({
    required String bridgeApiBaseUrl,
    required String threadId,
    String? before,
    int limit = 50,
  }) async {
    historyRequests.add(_HistoryRequest(before: before, limit: limit));
    final delay = delaysByBefore[before];
    if (delay != null) {
      await Future<void>.delayed(delay);
    }

    final page = _pagesByBefore[before];
    if (page == null) {
      throw StateError('Missing scripted page for before="$before".');
    }

    completedHistoryRequests += 1;
    return page;
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
  }) async {
    return _turnMutationResult(
      threadId: threadId,
      operation: 'turn_start',
      status: ThreadStatus.running,
      message: 'Turn started and streaming is active',
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
  }) async {
    return _turnMutationResult(
      threadId: threadId,
      operation: 'turn_respond',
      status: ThreadStatus.running,
      message: 'Pending input accepted',
    );
  }

  @override
  Future<TurnMutationResult> steerTurn({
    required String bridgeApiBaseUrl,
    required String threadId,
    required String instruction,
  }) async {
    return _turnMutationResult(
      threadId: threadId,
      operation: 'turn_steer',
      status: ThreadStatus.running,
      message: 'Steer instruction applied to active turn',
    );
  }

  @override
  Future<TurnMutationResult> interruptTurn({
    required String bridgeApiBaseUrl,
    required String threadId,
    String? turnId,
  }) async {
    return _turnMutationResult(
      threadId: threadId,
      operation: 'turn_interrupt',
      status: ThreadStatus.idle,
      message: 'Turn interrupted',
    );
  }

  @override
  Future<TurnMutationResult> startCommitAction({
    required String bridgeApiBaseUrl,
    required String threadId,
    String? model,
    String? effort,
  }) async {
    return _turnMutationResult(
      threadId: threadId,
      operation: 'turn_commit',
      status: ThreadStatus.running,
      message: 'Commit started',
    );
  }

  @override
  Future<GitStatusResponseDto> fetchGitStatus({
    required String bridgeApiBaseUrl,
    required String threadId,
  }) async {
    return _gitStatus(
      threadId: threadId,
      workspace: detail.workspace,
      repository: detail.repository,
      branch: detail.branch,
      remote: 'origin',
    );
  }

  @override
  Future<MutationResultResponseDto> switchBranch({
    required String bridgeApiBaseUrl,
    required String threadId,
    required String branch,
  }) async {
    return _gitMutationResult(
      threadId: threadId,
      operation: 'git_branch_switch',
      message: 'Switched branch to $branch',
      repository: detail.repository,
      branch: branch,
      remote: 'origin',
      workspace: detail.workspace,
      dirty: false,
      aheadBy: 0,
      behindBy: 0,
    );
  }

  @override
  Future<MutationResultResponseDto> pullRepository({
    required String bridgeApiBaseUrl,
    required String threadId,
    String? remote,
  }) async {
    return _gitMutationResult(
      threadId: threadId,
      operation: 'git_pull',
      message: 'Pulled latest changes',
      repository: detail.repository,
      branch: detail.branch,
      remote: remote ?? 'origin',
      workspace: detail.workspace,
      dirty: false,
      aheadBy: 0,
      behindBy: 0,
    );
  }

  @override
  Future<MutationResultResponseDto> pushRepository({
    required String bridgeApiBaseUrl,
    required String threadId,
    String? remote,
  }) async {
    return _gitMutationResult(
      threadId: threadId,
      operation: 'git_push',
      message: 'Pushed local commits',
      repository: detail.repository,
      branch: detail.branch,
      remote: remote ?? 'origin',
      workspace: detail.workspace,
      dirty: false,
      aheadBy: 0,
      behindBy: 0,
    );
  }

  @override
  Future<OpenOnMacResponseDto> openOnMac({
    required String bridgeApiBaseUrl,
    required String threadId,
  }) async {
    return _openOnMacResponse(threadId: threadId);
  }
}

List<ThreadSummaryDto> _threadSummaries() {
  return const [
    ThreadSummaryDto(
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
      status: ThreadStatus.idle,
      workspace: '/workspace/codex-runtime-tools',
      repository: 'codex-runtime-tools',
      branch: 'develop',
      updatedAt: '2026-03-18T09:30:00Z',
    ),
  ];
}

ThreadDetailDto _thread123Detail({
  String threadId = 'thread-123',
  AccessMode accessMode = AccessMode.controlWithApprovals,
  ThreadStatus status = ThreadStatus.running,
}) {
  return ThreadDetailDto(
    contractVersion: contractVersion,
    threadId: threadId,
    title: 'Implement shared contracts',
    status: status,
    workspace: '/workspace/vibe-bridge-companion',
    repository: 'vibe-bridge-companion',
    branch: 'master',
    createdAt: '2026-03-18T09:45:00Z',
    updatedAt: '2026-03-18T10:00:00Z',
    source: 'cli',
    accessMode: accessMode,
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

List<ThreadTimelineEntryDto> _structuredPlanTimelineEvents() {
  return [
    _timelineEvent(
      id: 'evt-plan-1',
      kind: BridgeEventKind.planDelta,
      summary: 'Plan updated',
      payload: {
        'type': 'plan',
        'text':
            '1 out of 3 tasks completed\n1. Inspect bridge payload\n2. Add Flutter card\n3. Run targeted tests',
        'steps': [
          {'step': 'Inspect bridge payload', 'status': 'completed'},
          {'step': 'Add Flutter card', 'status': 'in_progress'},
          {'step': 'Run targeted tests', 'status': 'pending'},
        ],
        'completed_count': 1,
        'total_count': 3,
      },
      occurredAt: '2026-03-18T10:03:00Z',
    ),
  ];
}

ThreadTimelineEntryDto _timelineEvent({
  required String id,
  required BridgeEventKind kind,
  required String summary,
  required Map<String, dynamic> payload,
  required String occurredAt,
  ThreadTimelineAnnotationsDto? annotations,
}) {
  return ThreadTimelineEntryDto(
    eventId: id,
    kind: kind,
    occurredAt: occurredAt,
    summary: summary,
    payload: payload,
    annotations: annotations,
  );
}

ThreadTimelineAnnotationsDto _explorationAnnotations({
  required ThreadTimelineExplorationKind explorationKind,
  required String entryLabel,
}) {
  return ThreadTimelineAnnotationsDto(
    groupKind: ThreadTimelineGroupKind.exploration,
    explorationKind: explorationKind,
    entryLabel: entryLabel,
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

GitStatusResponseDto _gitStatus({
  required String threadId,
  String workspace = '/workspace/vibe-bridge-companion',
  String repository = 'vibe-bridge-companion',
  String branch = 'master',
  String remote = 'origin',
  bool dirty = false,
  int aheadBy = 0,
  int behindBy = 0,
}) {
  return GitStatusResponseDto(
    contractVersion: contractVersion,
    threadId: threadId,
    repository: RepositoryContextDto(
      workspace: workspace,
      repository: repository,
      branch: branch,
      remote: remote,
    ),
    status: GitStatusDto(dirty: dirty, aheadBy: aheadBy, behindBy: behindBy),
  );
}

MutationResultResponseDto _gitMutationResult({
  required String threadId,
  required String operation,
  required String message,
  required String repository,
  required String branch,
  required String remote,
  String workspace = '/workspace/vibe-bridge-companion',
  bool dirty = false,
  int aheadBy = 0,
  int behindBy = 0,
  ThreadStatus threadStatus = ThreadStatus.running,
  String outcome = 'success',
}) {
  return MutationResultResponseDto(
    contractVersion: contractVersion,
    threadId: threadId,
    operation: operation,
    outcome: outcome,
    message: message,
    threadStatus: threadStatus,
    repository: RepositoryContextDto(
      workspace: workspace,
      repository: repository,
      branch: branch,
      remote: remote,
    ),
    status: GitStatusDto(dirty: dirty, aheadBy: aheadBy, behindBy: behindBy),
  );
}

OpenOnMacResponseDto _openOnMacResponse({
  required String threadId,
  String? message,
}) {
  return OpenOnMacResponseDto(
    contractVersion: contractVersion,
    threadId: threadId,
    attemptedUrl: 'codex://thread/$threadId',
    message:
        message ??
        'Requested Codex.app to open the matching shared thread. Desktop refresh is best effort; mobile remains fully usable.',
    bestEffort: true,
  );
}

class PendingUserInputResponseCall {
  const PendingUserInputResponseCall({
    required this.threadId,
    required this.requestId,
    required this.answers,
    required this.freeText,
    required this.model,
    required this.effort,
  });

  final String threadId;
  final String requestId;
  final List<UserInputAnswerDto> answers;
  final String? freeText;
  final String? model;
  final String? effort;
}

class FakeThreadDetailBridgeApi implements ThreadDetailBridgeApi {
  FakeThreadDetailBridgeApi({
    required Map<String, List<Object>> detailScriptByThreadId,
    required Map<String, List<Object>> timelineScriptByThreadId,
    Map<String, ThreadDetailDto>? timelineThreadByThreadId,
    ModelCatalogDto? modelCatalog,
    List<Object>? createThreadScript,
    Map<String, List<Object>>? startTurnScriptByThreadId,
    Map<String, List<Object>>? steerTurnScriptByThreadId,
    Map<String, List<Object>>? interruptTurnScriptByThreadId,
    Map<String, List<Object>>? startCommitScriptByThreadId,
    Map<String, List<Object>>? gitStatusScriptByThreadId,
    Map<String, List<Object>>? branchSwitchScriptByThreadId,
    Map<String, List<Object>>? pullScriptByThreadId,
    Map<String, List<Object>>? pushScriptByThreadId,
    Map<String, List<Object>>? openOnMacScriptByThreadId,
    Map<String, List<Object>>? threadUsageScriptByThreadId,
    List<Object>? speechStatusScript,
    this.speechTranscriptionResult,
    this.speechTranscriptionError,
    this.onGitApprovalRequired,
  }) : _detailScriptByThreadId = detailScriptByThreadId,
       _timelineScriptByThreadId = timelineScriptByThreadId,
       _timelineThreadByThreadId = timelineThreadByThreadId ?? {},
       _modelCatalog =
           modelCatalog ?? fallbackModelCatalogForProvider(ProviderKind.codex),
       _createThreadScript = createThreadScript ?? <Object>[],
       _startTurnScriptByThreadId = startTurnScriptByThreadId ?? {},
       _steerTurnScriptByThreadId = steerTurnScriptByThreadId ?? {},
       _interruptTurnScriptByThreadId = interruptTurnScriptByThreadId ?? {},
       _startCommitScriptByThreadId = startCommitScriptByThreadId ?? {},
       _gitStatusScriptByThreadId = gitStatusScriptByThreadId ?? {},
       _branchSwitchScriptByThreadId = branchSwitchScriptByThreadId ?? {},
       _pullScriptByThreadId = pullScriptByThreadId ?? {},
       _pushScriptByThreadId = pushScriptByThreadId ?? {},
       _openOnMacScriptByThreadId = openOnMacScriptByThreadId ?? {},
       _threadUsageScriptByThreadId = threadUsageScriptByThreadId ?? {},
       _speechStatusScript = speechStatusScript ?? <Object>[];

  final Map<String, List<Object>> _detailScriptByThreadId;
  final Map<String, List<Object>> _timelineScriptByThreadId;
  final Map<String, ThreadDetailDto> _timelineThreadByThreadId;
  final ModelCatalogDto _modelCatalog;
  final List<Object> _createThreadScript;
  final Map<String, List<Object>> _startTurnScriptByThreadId;
  final Map<String, List<Object>> _steerTurnScriptByThreadId;
  final Map<String, List<Object>> _interruptTurnScriptByThreadId;
  final Map<String, List<Object>> _startCommitScriptByThreadId;
  final Map<String, List<Object>> _gitStatusScriptByThreadId;
  final Map<String, List<Object>> _branchSwitchScriptByThreadId;
  final Map<String, List<Object>> _pullScriptByThreadId;
  final Map<String, List<Object>> _pushScriptByThreadId;
  final Map<String, List<Object>> _openOnMacScriptByThreadId;
  final Map<String, List<Object>> _threadUsageScriptByThreadId;
  final List<Object> _speechStatusScript;
  final SpeechTranscriptionResultDto? speechTranscriptionResult;
  final ThreadSpeechBridgeException? speechTranscriptionError;
  final void Function(ApprovalRecordDto approval)? onGitApprovalRequired;
  int detailFetchCount = 0;
  int timelineFetchCount = 0;
  int createThreadCallCount = 0;
  int transcribeAudioCallCount = 0;
  final List<String> createdThreadWorkspaces = <String>[];
  final List<String?> createdThreadModels = <String?>[];
  final Map<String, List<String>> startTurnPromptsByThreadId =
      <String, List<String>>{};
  final Map<String, List<List<String>>> startTurnImagesByThreadId =
      <String, List<List<String>>>{};
  final Map<String, List<String>> steerTurnInstructionsByThreadId =
      <String, List<String>>{};
  final Map<String, int> interruptTurnCallsByThreadId = <String, int>{};
  final Map<String, int> startCommitCallsByThreadId = <String, int>{};
  final Map<String, int> gitStatusFetchCountByThreadId = <String, int>{};
  final Map<String, List<String>> branchSwitchRequestsByThreadId =
      <String, List<String>>{};
  final Map<String, int> pullCallsByThreadId = <String, int>{};
  final Map<String, int> pushCallsByThreadId = <String, int>{};
  final Map<String, int> openOnMacCallsByThreadId = <String, int>{};
  final List<PendingUserInputResponseCall> respondToUserInputCalls =
      <PendingUserInputResponseCall>[];

  @override
  Future<ModelCatalogDto> fetchModelCatalog({
    required String bridgeApiBaseUrl,
    required ProviderKind provider,
  }) async {
    return _modelCatalog;
  }

  @override
  Future<SpeechModelStatusDto> fetchSpeechStatus({
    required String bridgeApiBaseUrl,
  }) async {
    if (_speechStatusScript.isEmpty) {
      return const SpeechModelStatusDto(
        contractVersion: contractVersion,
        provider: 'fluid_audio',
        modelId: 'parakeet-tdt-0.6b-v3-coreml',
        state: SpeechModelState.unsupported,
      );
    }

    final scriptedResult = _speechStatusScript.first;
    if (_speechStatusScript.length > 1) {
      _speechStatusScript.removeAt(0);
    }

    if (scriptedResult is SpeechModelStatusDto) {
      return scriptedResult;
    }
    if (scriptedResult is ThreadSpeechBridgeException) {
      throw scriptedResult;
    }

    throw StateError(
      'Unsupported speech-status scripted result: $scriptedResult',
    );
  }

  @override
  Future<SpeechTranscriptionResultDto> transcribeAudio({
    required String bridgeApiBaseUrl,
    required List<int> audioBytes,
    String fileName = 'voice-message.wav',
  }) async {
    transcribeAudioCallCount += 1;
    if (speechTranscriptionError != null) {
      throw speechTranscriptionError!;
    }
    if (speechTranscriptionResult != null) {
      return speechTranscriptionResult!;
    }
    throw const ThreadSpeechBridgeException(message: 'Speech is unused here.');
  }

  @override
  Future<ThreadSnapshotDto> createThread({
    required String bridgeApiBaseUrl,
    required String workspace,
    required ProviderKind provider,
    String? model,
  }) async {
    createThreadCallCount += 1;
    createdThreadWorkspaces.add(workspace);
    createdThreadModels.add(model);

    if (_createThreadScript.isEmpty) {
      return ThreadSnapshotDto(
        contractVersion: contractVersion,
        thread: const ThreadDetailDto(
          contractVersion: contractVersion,
          threadId: 'thread-created',
          title: 'New Thread',
          status: ThreadStatus.idle,
          workspace: '/workspace/vibe-bridge-companion',
          repository: 'vibe-bridge-companion',
          branch: 'main',
          createdAt: '2026-03-18T12:00:00Z',
          updatedAt: '2026-03-18T12:00:00Z',
          source: 'cli',
          accessMode: AccessMode.controlWithApprovals,
          lastTurnSummary: '',
        ),
        entries: const <ThreadTimelineEntryDto>[],
        approvals: const <ApprovalSummaryDto>[],
      );
    }

    final scriptedResult = _createThreadScript.first;
    if (_createThreadScript.length > 1) {
      _createThreadScript.removeAt(0);
    }

    if (scriptedResult is ThreadSnapshotDto) {
      return scriptedResult;
    }
    if (scriptedResult is ThreadCreateBridgeException) {
      throw scriptedResult;
    }

    throw StateError(
      'Unsupported create-thread scripted result: $scriptedResult',
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
    final script = _threadUsageScriptByThreadId[threadId];
    if (script == null || script.isEmpty) {
      throw const ThreadUsageBridgeException(
        message: 'Usage is unavailable in this test.',
      );
    }

    final scriptedResult = _nextResult(_threadUsageScriptByThreadId, threadId);
    if (scriptedResult is ThreadUsageDto) {
      return scriptedResult;
    }
    if (scriptedResult is ThreadUsageBridgeException) {
      throw scriptedResult;
    }

    throw StateError('Unsupported usage scripted result: $scriptedResult');
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
    if (scriptedResult is Future<List<ThreadTimelineEntryDto>>) {
      return await scriptedResult;
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
    final thread =
        _timelineThreadByThreadId[threadId] ?? _peekThreadDetail(threadId);
    if (thread == null) {
      final detailError = _peekThreadDetailError(threadId);
      if (detailError != null) {
        throw detailError;
      }
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
      thread: thread,
      entries: pageEntries,
      nextBefore: hasMoreBefore ? entries[startIndex].eventId : null,
      hasMoreBefore: hasMoreBefore,
    );
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
  }) async {
    startTurnPromptsByThreadId
        .putIfAbsent(threadId, () => <String>[])
        .add(prompt);
    startTurnImagesByThreadId
        .putIfAbsent(threadId, () => <List<String>>[])
        .add(List<String>.unmodifiable(images));

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
    if (scriptedResult is Future<TurnMutationResult>) {
      return await scriptedResult;
    }
    if (scriptedResult is ThreadTurnBridgeException) {
      throw scriptedResult;
    }

    throw StateError('Unsupported start-turn scripted result: $scriptedResult');
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
  }) async {
    respondToUserInputCalls.add(
      PendingUserInputResponseCall(
        threadId: threadId,
        requestId: requestId,
        answers: List<UserInputAnswerDto>.unmodifiable(answers),
        freeText: freeText,
        model: model,
        effort: effort,
      ),
    );
    return _turnMutationResult(
      threadId: threadId,
      operation: 'turn_respond',
      status: ThreadStatus.running,
      message: 'Pending input accepted',
    );
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
    String? turnId,
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

  @override
  Future<TurnMutationResult> startCommitAction({
    required String bridgeApiBaseUrl,
    required String threadId,
    String? model,
    String? effort,
  }) async {
    startCommitCallsByThreadId.update(
      threadId,
      (count) => count + 1,
      ifAbsent: () => 1,
    );

    final scriptedResult = _nextOptionalResult(
      _startCommitScriptByThreadId,
      threadId,
    );
    if (scriptedResult is TurnMutationResult) {
      return scriptedResult;
    }
    if (scriptedResult is ThreadTurnBridgeException) {
      throw scriptedResult;
    }
    if (scriptedResult != null) {
      throw StateError(
        'Unsupported start-commit scripted result: $scriptedResult',
      );
    }

    return _turnMutationResult(
      threadId: threadId,
      operation: 'commit',
      status: ThreadStatus.running,
      message: 'Commit started and streaming is active',
    );
  }

  @override
  Future<GitStatusResponseDto> fetchGitStatus({
    required String bridgeApiBaseUrl,
    required String threadId,
  }) async {
    gitStatusFetchCountByThreadId.update(
      threadId,
      (count) => count + 1,
      ifAbsent: () => 1,
    );

    final scriptedResult = _nextOptionalResult(
      _gitStatusScriptByThreadId,
      threadId,
    );
    if (scriptedResult == null) {
      return _defaultGitStatusForThread(threadId);
    }
    if (scriptedResult is GitStatusResponseDto) {
      return scriptedResult;
    }
    if (scriptedResult is ThreadGitBridgeException) {
      throw scriptedResult;
    }

    throw StateError('Unsupported git-status scripted result: $scriptedResult');
  }

  @override
  Future<MutationResultResponseDto> switchBranch({
    required String bridgeApiBaseUrl,
    required String threadId,
    required String branch,
  }) async {
    branchSwitchRequestsByThreadId
        .putIfAbsent(threadId, () => <String>[])
        .add(branch);

    final scriptedResult = _nextOptionalResult(
      _branchSwitchScriptByThreadId,
      threadId,
    );
    if (scriptedResult is MutationResultResponseDto) {
      return scriptedResult;
    }
    if (scriptedResult is ThreadGitApprovalRequiredException) {
      onGitApprovalRequired?.call(scriptedResult.approval);
      throw scriptedResult;
    }
    if (scriptedResult is ThreadGitMutationBridgeException) {
      throw scriptedResult;
    }
    if (scriptedResult != null) {
      throw StateError(
        'Unsupported branch-switch scripted result: $scriptedResult',
      );
    }

    final context = _defaultGitStatusForThread(threadId).repository;
    return _gitMutationResult(
      threadId: threadId,
      operation: 'git_branch_switch',
      message: 'Switched branch to $branch',
      repository: context.repository,
      branch: branch,
      remote: context.remote,
      workspace: context.workspace,
      dirty: false,
      aheadBy: 0,
      behindBy: 0,
    );
  }

  @override
  Future<MutationResultResponseDto> pullRepository({
    required String bridgeApiBaseUrl,
    required String threadId,
    String? remote,
  }) async {
    pullCallsByThreadId.update(
      threadId,
      (count) => count + 1,
      ifAbsent: () => 1,
    );

    final scriptedResult = _nextOptionalResult(_pullScriptByThreadId, threadId);
    if (scriptedResult is MutationResultResponseDto) {
      return scriptedResult;
    }
    if (scriptedResult is ThreadGitApprovalRequiredException) {
      onGitApprovalRequired?.call(scriptedResult.approval);
      throw scriptedResult;
    }
    if (scriptedResult is ThreadGitMutationBridgeException) {
      throw scriptedResult;
    }
    if (scriptedResult != null) {
      throw StateError('Unsupported pull scripted result: $scriptedResult');
    }

    final status = _defaultGitStatusForThread(threadId);
    final repository = status.repository;
    final resolvedRemote = remote == null || remote.trim().isEmpty
        ? repository.remote
        : remote.trim();
    return _gitMutationResult(
      threadId: threadId,
      operation: 'git_pull',
      message:
          'Pulled latest changes from $resolvedRemote for ${repository.branch}',
      repository: repository.repository,
      branch: repository.branch,
      remote: resolvedRemote,
      workspace: repository.workspace,
      dirty: status.status.dirty,
      aheadBy: status.status.aheadBy,
      behindBy: 0,
    );
  }

  @override
  Future<MutationResultResponseDto> pushRepository({
    required String bridgeApiBaseUrl,
    required String threadId,
    String? remote,
  }) async {
    pushCallsByThreadId.update(
      threadId,
      (count) => count + 1,
      ifAbsent: () => 1,
    );

    final scriptedResult = _nextOptionalResult(_pushScriptByThreadId, threadId);
    if (scriptedResult is MutationResultResponseDto) {
      return scriptedResult;
    }
    if (scriptedResult is ThreadGitApprovalRequiredException) {
      onGitApprovalRequired?.call(scriptedResult.approval);
      throw scriptedResult;
    }
    if (scriptedResult is ThreadGitMutationBridgeException) {
      throw scriptedResult;
    }
    if (scriptedResult != null) {
      throw StateError('Unsupported push scripted result: $scriptedResult');
    }

    final status = _defaultGitStatusForThread(threadId);
    final repository = status.repository;
    final resolvedRemote = remote == null || remote.trim().isEmpty
        ? repository.remote
        : remote.trim();
    return _gitMutationResult(
      threadId: threadId,
      operation: 'git_push',
      message:
          'Pushed local commits to $resolvedRemote for ${repository.branch}',
      repository: repository.repository,
      branch: repository.branch,
      remote: resolvedRemote,
      workspace: repository.workspace,
      dirty: status.status.dirty,
      aheadBy: 0,
      behindBy: status.status.behindBy,
    );
  }

  @override
  Future<OpenOnMacResponseDto> openOnMac({
    required String bridgeApiBaseUrl,
    required String threadId,
  }) async {
    openOnMacCallsByThreadId.update(
      threadId,
      (count) => count + 1,
      ifAbsent: () => 1,
    );

    final scriptedResult = _nextOptionalResult(
      _openOnMacScriptByThreadId,
      threadId,
    );

    if (scriptedResult is OpenOnMacResponseDto) {
      return scriptedResult;
    }
    if (scriptedResult is ThreadOpenOnMacBridgeException) {
      throw scriptedResult;
    }
    if (scriptedResult != null) {
      throw StateError(
        'Unsupported open-on-host scripted result: $scriptedResult',
      );
    }

    return _openOnMacResponse(threadId: threadId);
  }

  GitStatusResponseDto _defaultGitStatusForThread(String threadId) {
    final detail = _peekThreadDetail(threadId);
    if (detail == null) {
      return _gitStatus(threadId: threadId);
    }

    return _gitStatus(
      threadId: threadId,
      workspace: detail.workspace,
      repository: detail.repository,
      branch: detail.branch,
      remote: 'origin',
    );
  }

  ThreadDetailDto? _peekThreadDetail(String threadId) {
    final script = _detailScriptByThreadId[threadId];
    if (script == null) {
      return null;
    }

    for (final entry in script) {
      if (entry is ThreadDetailDto) {
        return entry;
      }
    }

    return null;
  }

  ThreadDetailBridgeException? _peekThreadDetailError(String threadId) {
    final script = _detailScriptByThreadId[threadId];
    if (script == null) {
      return null;
    }

    for (final entry in script) {
      if (entry is ThreadDetailBridgeException) {
        return entry;
      }
    }

    return null;
  }

  Object? _nextOptionalResult(
    Map<String, List<Object>> scriptByThreadId,
    String threadId,
  ) {
    final script = scriptByThreadId[threadId];
    if (script == null || script.isEmpty) {
      return null;
    }

    return _nextResult(scriptByThreadId, threadId);
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

class _FakeSpeechCapture implements SpeechCapture {
  _FakeSpeechCapture();

  bool _started = false;

  @override
  Stream<SpeechCaptureAmplitude> amplitudeStream(Duration interval) {
    return const Stream<SpeechCaptureAmplitude>.empty();
  }

  @override
  Future<void> dispose() async {}

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<void> start() async {
    _started = true;
  }

  @override
  Future<SpeechCaptureResult> stop() async {
    if (!_started) {
      throw const SpeechCaptureException(
        message: 'No audio was captured for transcription.',
        code: 'speech_invalid_audio',
      );
    }
    return SpeechCaptureResult(
      bytes: Uint8List.fromList(<int>[
        0x52,
        0x49,
        0x46,
        0x46,
        0x00,
        0x00,
        0x00,
        0x00,
        0x57,
        0x41,
        0x56,
        0x45,
      ]),
    );
  }
}

class MutableApprovalBridgeApi implements ApprovalBridgeApi {
  MutableApprovalBridgeApi({
    required this.accessMode,
    List<ApprovalRecordDto> approvals = const <ApprovalRecordDto>[],
  }) : _approvalsById = {
         for (final approval in approvals) approval.approvalId: approval,
       };

  final AccessMode accessMode;
  final Map<String, ApprovalRecordDto> _approvalsById;

  void upsertApproval(ApprovalRecordDto approval) {
    _approvalsById[approval.approvalId] = approval;
  }

  @override
  Future<AccessMode> fetchAccessMode({required String bridgeApiBaseUrl}) async {
    return accessMode;
  }

  @override
  Future<List<ApprovalRecordDto>> fetchApprovals({
    required String bridgeApiBaseUrl,
  }) async {
    final approvals = _approvalsById.values.toList(growable: false)
      ..sort((left, right) => right.requestedAt.compareTo(left.requestedAt));
    return approvals;
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

class EmptyApprovalBridgeApi implements ApprovalBridgeApi {
  @override
  Future<AccessMode> fetchAccessMode({required String bridgeApiBaseUrl}) async {
    return AccessMode.fullControl;
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

class FakeSettingsBridgeApi implements SettingsBridgeApi {
  FakeSettingsBridgeApi({
    this.accessMode = AccessMode.controlWithApprovals,
    this.securityEvents = const <SecurityEventRecordDto>[],
  });

  AccessMode accessMode;
  final List<SecurityEventRecordDto> securityEvents;

  @override
  Future<AccessMode> fetchAccessMode({required String bridgeApiBaseUrl}) async {
    return accessMode;
  }

  @override
  Future<List<SecurityEventRecordDto>> fetchSecurityEvents({
    required String bridgeApiBaseUrl,
  }) async {
    return securityEvents;
  }

  @override
  Future<AccessMode> setAccessMode({
    required String bridgeApiBaseUrl,
    required AccessMode accessMode,
    String? phoneId,
    String? bridgeId,
    String? sessionToken,
    String? localSessionKind,
    String actor = 'mobile-device',
  }) async {
    this.accessMode = accessMode;
    return accessMode;
  }
}
