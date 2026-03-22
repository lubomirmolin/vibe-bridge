import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:codex_mobile_companion/features/approvals/data/approval_bridge_api.dart';
import 'package:codex_mobile_companion/features/settings/application/desktop_integration_controller.dart';
import 'package:codex_mobile_companion/features/settings/application/runtime_access_mode.dart';
import 'package:codex_mobile_companion/features/settings/data/settings_bridge_api.dart';
import 'package:codex_mobile_companion/features/threads/application/thread_detail_controller.dart';
import 'package:codex_mobile_companion/features/threads/data/thread_cache_repository.dart';
import 'package:codex_mobile_companion/features/threads/data/thread_detail_bridge_api.dart';
import 'package:codex_mobile_companion/features/threads/data/thread_list_bridge_api.dart';
import 'package:codex_mobile_companion/features/threads/data/thread_live_stream.dart';
import 'package:codex_mobile_companion/features/threads/domain/thread_activity_item.dart';
import 'package:codex_mobile_companion/features/threads/presentation/thread_detail_page.dart';
import 'package:codex_mobile_companion/features/threads/presentation/thread_list_page.dart';
import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:codex_mobile_companion/foundation/storage/secure_store.dart';
import 'package:codex_mobile_companion/foundation/storage/secure_store_provider.dart';
import 'package:codex_mobile_companion/foundation/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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
      expect(
        find.byKey(const Key('thread-detail-metadata-scroll')),
        findsOneWidget,
      );
      expect(find.text('codex-mobile-companion'), findsOneWidget);
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

  testWidgets(
    'thread list header plus opens draft detail and submits first prompt through a created thread',
    (tester) async {
      final createdThread = ThreadDetailDto(
        contractVersion: contractVersion,
        threadId: 'thread-new',
        title: 'Fresh session',
        status: ThreadStatus.idle,
        workspace: '/workspace/codex-mobile-companion',
        repository: 'codex-mobile-companion',
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
            'thread-list-workspace-option-/workspace/codex-mobile-companion',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('thread-draft-title')), findsOneWidget);
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
      await tester.pumpAndSettle();

      expect(detailApi.createThreadCallCount, 1);
      expect(
        detailApi.createdThreadWorkspaces,
        contains('/workspace/codex-mobile-companion'),
      );
      expect(
        detailApi.startTurnPromptsByThreadId['thread-new'],
        equals(<String>['Plan the release']),
      );
      expect(find.text('Fresh session'), findsOneWidget);
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
        workspace: '/workspace/codex-mobile-companion',
        repository: 'codex-mobile-companion',
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
            'thread-list-workspace-option-/workspace/codex-mobile-companion',
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

      expect(find.text('Fresh session'), findsOneWidget);
      expect(detailApi.createThreadCallCount, 1);
      expect(
        detailApi.startTurnPromptsByThreadId['thread-new'],
        equals(<String>['Plan the release']),
      );
    },
  );

  testWidgets(
    'real-thread initial 80-entry slice keeps latest context and meaningful command/file activity visible',
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
      final latestCommand = find.textContaining('kill -9 16121 16103');

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

      await _scrollUntilVisible(tester, latestCommand);
      await _scrollUntilVisible(tester, latestMessage);

      expect(latestMessage, findsOneWidget);
      expect(latestCommand, findsOneWidget);
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

      final commandY = tester.getTopLeft(latestCommand).dy;
      final messageY = tester.getTopLeft(latestMessage).dy;
      expect(commandY, lessThan(messageY));
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
        find.byKey(const Key('thread-explored-files-summary')),
      );

      expect(find.text('write_stdin'), findsNothing);
      expect(
        find.byKey(const Key('thread-explored-files-summary')),
        findsOneWidget,
      );
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
        find.byKey(const Key('thread-explored-files-summary')),
      );

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
          'thread-123': [_thread123Detail()],
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
        'thread-123': [_thread123Detail()],
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
    expect((children[1] as TextSpan).style?.fontStyle, FontStyle.italic);
    expect((children[2] as TextSpan).text, ' Next step.');
  });

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
                    'See [apps/mobile/pubspec.yaml](/Users/lubomirmolin/PhpstormProjects/codex-mobile-companion/apps/mobile/pubspec.yaml#L33) for details.',
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
    'thread detail hides lifecycle and security noise from the conversation timeline',
    (tester) async {
      final detailApi = FakeThreadDetailBridgeApi(
        detailScriptByThreadId: {
          'thread-123': [_thread123Detail()],
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
                    '{"cmd":"flutter test --concurrency=5","workdir":"/Users/lubomirmolin/PhpstormProjects/codex-mobile-companion/apps/mobile","yield_time_ms":1000}',
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
*** Update File: /Users/lubomirmolin/PhpstormProjects/codex-mobile-companion/apps/mobile/lib/features/threads/presentation/thread_detail_page.dart
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
*** Delete File: /Users/lubomirmolin/PhpstormProjects/codex-mobile-companion/apps/mobile/test/features/threads/thread_live_timeline_regression_test.dart
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
                    'Working directory: /Users/lubomirmolin/PhpstormProjects/codex-mobile-companion',
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
        'Working directory: /Users/lubomirmolin/PhpstormProjects/codex-mobile-companion',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('yield_time_ms'), findsNothing);
  });

  testWidgets(
    'read-only inspection commands collapse into an exploration summary',
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
        find.byKey(const Key('thread-explored-files-summary')),
      );
      expect(
        find.byKey(const Key('thread-explored-files-summary')),
        findsOneWidget,
      );
      expect(find.text('Explored 2 files, 1 search'), findsOneWidget);
      expect(
        find.byKey(const Key('thread-worked-for-summary')),
        findsOneWidget,
      );
      expect(find.text('Worked for 49s'), findsOneWidget);
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
        findsOneWidget,
      );
      expect(
        find.textContaining('Read parsed_command_output.dart'),
        findsOneWidget,
      );
    },
  );

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
    await tester.pumpAndSettle();

    expect(detailApi.startTurnPromptsByThreadId['thread-456'], [
      'Draft release notes for today\'s bridge changes.',
    ]);
    expect(find.text('Running'), findsOneWidget);
  });

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
      expect(input.textInputAction, TextInputAction.newline);
      expect(
        find.byKey(const Key('turn-composer-attach-button')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('turn-composer-model-button')),
        findsOneWidget,
      );

      await tester.showKeyboard(find.byKey(const Key('turn-composer-input')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('turn-composer-attach-button')),
        findsNothing,
      );
      expect(find.byKey(const Key('turn-composer-model-button')), findsNothing);
      expect(find.byKey(const Key('turn-composer-submit')), findsOneWidget);
    },
  );

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

  testWidgets('active composer primary button stops the active turn', (
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
    await tester.pumpAndSettle();

    expect(find.text('bridge rejected prompt payload.'), findsOneWidget);

    await tester.tap(find.byKey(const Key('turn-composer-submit')));
    await tester.pumpAndSettle();

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
    'active turn disables composer input while stop action is shown',
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
    },
  );

  testWidgets(
    'bridge disables git mutations while still showing thread context',
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
      expect(find.text('Repository: codex-mobile-companion'), findsOneWidget);
      expect(find.text('Branch: master'), findsOneWidget);
      expect(find.text('Remote: unknown'), findsOneWidget);
      expect(find.text('Resolving git status'), findsOneWidget);
      expect(
        find.text('Git controls are unavailable in this build.'),
        findsWidgets,
      );

      final switchButton = tester.widget<FilledButton>(
        find.byKey(const Key('git-branch-switch-button')),
      );
      await tester.enterText(
        find.byKey(const Key('git-branch-input')),
        '  release/2026  ',
      );
      expect(switchButton.onPressed, isNull);
      await _closeModalSheet(tester);

      await _openGitSyncSheet(tester);
      final pullButton = tester.widget<OutlinedButton>(
        find.byKey(const Key('git-pull-button')),
      );
      final pushButton = tester.widget<OutlinedButton>(
        find.byKey(const Key('git-push-button')),
      );
      expect(pullButton.onPressed, isNull);
      expect(pushButton.onPressed, isNull);
      expect(
        find.text('Git controls are unavailable in this build.'),
        findsWidgets,
      );
      expect(detailApi.branchSwitchRequestsByThreadId['thread-123'], isNull);
      expect(detailApi.pullCallsByThreadId['thread-123'], isNull);
      expect(detailApi.pushCallsByThreadId['thread-123'], isNull);
    },
  );

  testWidgets('full-control mode does not bypass bridge git disablement', (
    tester,
  ) async {
    final detailApi = FakeThreadDetailBridgeApi(
      detailScriptByThreadId: {
        'thread-123': [_thread123Detail(accessMode: AccessMode.fullControl)],
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

    await _openGitBranchSheet(tester);
    expect(
      find.text('Git controls are unavailable in this build.'),
      findsWidgets,
    );
    final switchButton = tester.widget<FilledButton>(
      find.byKey(const Key('git-branch-switch-button')),
    );
    expect(switchButton.onPressed, isNull);
    await _closeModalSheet(tester);

    await _openGitSyncSheet(tester);
    final pullButton = tester.widget<OutlinedButton>(
      find.byKey(const Key('git-pull-button')),
    );
    final pushButton = tester.widget<OutlinedButton>(
      find.byKey(const Key('git-push-button')),
    );
    expect(
      find.text('Git controls are unavailable in this build.'),
      findsWidgets,
    );
    expect(pullButton.onPressed, isNull);
    expect(pushButton.onPressed, isNull);
    expect(detailApi.branchSwitchRequestsByThreadId['thread-123'], isNull);
    expect(detailApi.pullCallsByThreadId['thread-123'], isNull);
    expect(detailApi.pushCallsByThreadId['thread-123'], isNull);
  });

  testWidgets('open-on-Mac is surfaced as unavailable in this build', (
    tester,
  ) async {
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

    await tester.tap(find.byKey(const Key('open-on-mac-button')));
    await tester.pumpAndSettle();
    expect(detailApi.openOnMacCallsByThreadId['thread-123'], isNull);
    expect(find.byKey(const Key('open-on-mac-error-message')), findsOneWidget);
    expect(
      find.text('Open-on-Mac is unavailable in this build.'),
      findsOneWidget,
    );
  });

  testWidgets('desktop integration toggle updates open-on-Mac affordances', (
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
    'changing access mode from settings still gates turn controls in this build',
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
      expect(
        find.text('Git controls are unavailable in this build.'),
        findsWidgets,
      );
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
    final switchButton = tester.widget<FilledButton>(
      find.byKey(const Key('git-branch-switch-button')),
    );

    expect(
      find.text('Git controls are unavailable in this build.'),
      findsWidgets,
    );
    expect(switchButton.onPressed, isNull);
    expect(detailApi.branchSwitchRequestsByThreadId['thread-123'], isNull);
  });

  testWidgets('git mutation buttons stay disabled in this build', (
    tester,
  ) async {
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

    expect(
      find.text('Git controls are unavailable in this build.'),
      findsWidgets,
    );
    expect(switchButton.onPressed, isNull);
    expect(pullButton.onPressed, isNull);
    expect(pushButton.onPressed, isNull);
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
    expect(find.text('Repository: codex-mobile-companion'), findsOneWidget);
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
    expect(pullButton.onPressed, isNull);
  });

  testWidgets('bridge never attempts failing git mutations', (tester) async {
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

    await _openGitSyncSheet(tester);
    final pullButton = tester.widget<OutlinedButton>(
      find.byKey(const Key('git-pull-button')),
    );
    expect(pullButton.onPressed, isNull);
    expect(detailApi.pullCallsByThreadId['thread-123'], isNull);
    expect(
      find.text('Git controls are unavailable in this build.'),
      findsWidgets,
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

      await _scrollUntilVisible(
        tester,
        find.text('Streaming chunk from live output.'),
      );
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
        24,
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

      await tester.drag(
        find.byKey(const Key('thread-detail-scroll-view')),
        const Offset(0, 900),
      );
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

      expect(find.text('New messages'), findsOneWidget);
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
      expect(find.text('Visible on thread 456'), findsOneWidget);
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
        findsOneWidget,
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
      cacheRepository: cacheRepository,
    );

    expect(
      find.byKey(const Key('thread-detail-metadata-scroll')),
      findsOneWidget,
    );
    expect(find.text('codex-runtime-tools'), findsOneWidget);
    expect(find.text('Investigate reconnect dedup'), findsOneWidget);
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
      expect(find.text('Implement shared contracts'), findsOneWidget);
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
      findsOneWidget,
    );
    expect(find.text('Retry'), findsOneWidget);
  });

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
}

Future<void> _pumpThreadListApp(
  WidgetTester tester, {
  required ThreadListBridgeApi listApi,
  required ThreadDetailBridgeApi detailApi,
  required ThreadLiveStream liveStream,
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
  int initialVisibleTimelineEntries = 20,
  ThreadListBridgeApi? listApi,
  ThreadLiveStream? liveStream,
  ApprovalBridgeApi? approvalApi,
  ThreadCacheRepository? cacheRepository,
  SettingsBridgeApi? settingsApi,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appSecureStoreProvider.overrideWithValue(InMemorySecureStore()),
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
        ),
      ),
    ),
  );

  await tester.pumpAndSettle();
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

Future<void> _tapThreadDetailBackButton(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('thread-detail-back-button')));
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
  await tester.tap(find.byKey(const Key('turn-composer-model-button')));
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

class _RealThreadFixture {
  const _RealThreadFixture({required this.detail, required this.timelinePage});

  final ThreadDetailDto detail;
  final ThreadTimelinePageDto timelinePage;

  List<ThreadTimelineEntryDto> get timelineEntries => timelinePage.entries;
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

ThreadDetailDto _thread123Detail({
  AccessMode accessMode = AccessMode.controlWithApprovals,
}) {
  return ThreadDetailDto(
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
  String workspace = '/workspace/codex-mobile-companion',
  String repository = 'codex-mobile-companion',
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
  String workspace = '/workspace/codex-mobile-companion',
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
    Map<String, List<Object>>? gitStatusScriptByThreadId,
    Map<String, List<Object>>? branchSwitchScriptByThreadId,
    Map<String, List<Object>>? pullScriptByThreadId,
    Map<String, List<Object>>? pushScriptByThreadId,
    Map<String, List<Object>>? openOnMacScriptByThreadId,
    this.onGitApprovalRequired,
  }) : _detailScriptByThreadId = detailScriptByThreadId,
       _timelineScriptByThreadId = timelineScriptByThreadId,
       _timelineThreadByThreadId = timelineThreadByThreadId ?? {},
       _modelCatalog = modelCatalog ?? fallbackModelCatalog,
       _createThreadScript = createThreadScript ?? <Object>[],
       _startTurnScriptByThreadId = startTurnScriptByThreadId ?? {},
       _steerTurnScriptByThreadId = steerTurnScriptByThreadId ?? {},
       _interruptTurnScriptByThreadId = interruptTurnScriptByThreadId ?? {},
       _gitStatusScriptByThreadId = gitStatusScriptByThreadId ?? {},
       _branchSwitchScriptByThreadId = branchSwitchScriptByThreadId ?? {},
       _pullScriptByThreadId = pullScriptByThreadId ?? {},
       _pushScriptByThreadId = pushScriptByThreadId ?? {},
       _openOnMacScriptByThreadId = openOnMacScriptByThreadId ?? {};

  final Map<String, List<Object>> _detailScriptByThreadId;
  final Map<String, List<Object>> _timelineScriptByThreadId;
  final Map<String, ThreadDetailDto> _timelineThreadByThreadId;
  final ModelCatalogDto _modelCatalog;
  final List<Object> _createThreadScript;
  final Map<String, List<Object>> _startTurnScriptByThreadId;
  final Map<String, List<Object>> _steerTurnScriptByThreadId;
  final Map<String, List<Object>> _interruptTurnScriptByThreadId;
  final Map<String, List<Object>> _gitStatusScriptByThreadId;
  final Map<String, List<Object>> _branchSwitchScriptByThreadId;
  final Map<String, List<Object>> _pullScriptByThreadId;
  final Map<String, List<Object>> _pushScriptByThreadId;
  final Map<String, List<Object>> _openOnMacScriptByThreadId;
  final void Function(ApprovalRecordDto approval)? onGitApprovalRequired;
  int detailFetchCount = 0;
  int timelineFetchCount = 0;
  int createThreadCallCount = 0;
  final List<String> createdThreadWorkspaces = <String>[];
  final List<String?> createdThreadModels = <String?>[];
  final Map<String, List<String>> startTurnPromptsByThreadId =
      <String, List<String>>{};
  final Map<String, List<String>> steerTurnInstructionsByThreadId =
      <String, List<String>>{};
  final Map<String, int> interruptTurnCallsByThreadId = <String, int>{};
  final Map<String, int> gitStatusFetchCountByThreadId = <String, int>{};
  final Map<String, List<String>> branchSwitchRequestsByThreadId =
      <String, List<String>>{};
  final Map<String, int> pullCallsByThreadId = <String, int>{};
  final Map<String, int> pushCallsByThreadId = <String, int>{};
  final Map<String, int> openOnMacCallsByThreadId = <String, int>{};

  @override
  Future<ModelCatalogDto> fetchModelCatalog({
    required String bridgeApiBaseUrl,
  }) async {
    return _modelCatalog;
  }

  @override
  Future<ThreadSnapshotDto> createThread({
    required String bridgeApiBaseUrl,
    required String workspace,
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
          workspace: '/workspace/codex-mobile-companion',
          repository: 'codex-mobile-companion',
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
        'Unsupported open-on-Mac scripted result: $scriptedResult',
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
    required String phoneId,
    required String bridgeId,
    required String sessionToken,
    String actor = 'mobile-device',
  }) async {
    this.accessMode = accessMode;
    return accessMode;
  }
}
