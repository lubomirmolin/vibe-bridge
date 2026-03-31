import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:vibe_bridge/features/approvals/data/approval_bridge_api.dart';
import 'package:vibe_bridge/features/threads/application/thread_list_controller.dart';
import 'package:vibe_bridge/features/threads/data/thread_cache_repository.dart';
import 'package:vibe_bridge/features/threads/data/thread_detail_bridge_api.dart';
import 'package:vibe_bridge/features/threads/data/thread_list_bridge_api.dart';
import 'package:vibe_bridge/features/threads/data/thread_live_stream.dart';
import 'package:vibe_bridge/features/threads/presentation/thread_list_page.dart';
import 'package:vibe_bridge/foundation/contracts/bridge_contracts.dart';
import 'package:vibe_bridge/foundation/layout/adaptive_layout.dart';
import 'package:vibe_bridge/foundation/storage/secure_store.dart';
import 'package:vibe_bridge/foundation/storage/secure_store_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'wide layout keeps list visible beside an empty detail placeholder',
    (tester) async {
      await _setDisplaySize(tester, const Size(1400, 900));
      final cacheRepository = _newCacheRepository();
      final bridgeApi = FakeThreadListBridgeApi(
        scriptedResults: [_sampleThreads()],
      );

      await _pumpThreadListPage(
        tester,
        bridgeApi: bridgeApi,
        cacheRepository: cacheRepository,
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('thread-list-wide-placeholder')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('thread-wide-left-pane')), findsOneWidget);
      expect(find.text('Implement shared contracts'), findsOneWidget);
    },
  );

  testWidgets(
    'wide layout opens thread detail inline without removing the list',
    (tester) async {
      await _setDisplaySize(tester, const Size(1400, 900));
      final cacheRepository = _newCacheRepository();
      final bridgeApi = FakeThreadListBridgeApi(
        scriptedResults: [_sampleThreads()],
      );
      final detailApi = FakeThreadDetailBridgeApi(
        detailScriptByThreadId: {
          'thread-123': [_thread123Detail()],
        },
        timelineScriptByThreadId: {
          'thread-123': [<ThreadTimelineEntryDto>[]],
        },
      );

      await _pumpThreadListPage(
        tester,
        bridgeApi: bridgeApi,
        detailApi: detailApi,
        cacheRepository: cacheRepository,
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('thread-summary-card-thread-123')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('thread-detail-title')), findsOneWidget);
      expect(find.byKey(const Key('thread-wide-left-pane')), findsOneWidget);
      expect(find.byKey(const Key('thread-detail-back-button')), findsNothing);
    },
  );

  testWidgets('wide layout opens draft detail inline from create action', (
    tester,
  ) async {
    await _setDisplaySize(tester, const Size(1400, 900));
    final cacheRepository = _newCacheRepository();
    final bridgeApi = FakeThreadListBridgeApi(
      scriptedResults: [_sampleThreads()],
    );

    await _pumpThreadListPage(
      tester,
      bridgeApi: bridgeApi,
      cacheRepository: cacheRepository,
    );
    await tester.pumpAndSettle();

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
    expect(find.byKey(const Key('thread-draft-back-button')), findsNothing);
  });

  testWidgets('wide layout can collapse the list and reopen it from detail', (
    tester,
  ) async {
    await _setDisplaySize(tester, const Size(1400, 900));
    final cacheRepository = _newCacheRepository();
    final bridgeApi = FakeThreadListBridgeApi(
      scriptedResults: [_sampleThreads()],
    );

    await _pumpThreadListPage(
      tester,
      bridgeApi: bridgeApi,
      cacheRepository: cacheRepository,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('thread-summary-card-thread-123')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('thread-detail-sidebar-toggle')));
    await tester.pumpAndSettle();

    expect(
      tester.getSize(find.byKey(const Key('thread-wide-left-pane'))).width,
      0,
    );

    await tester.tap(find.byKey(const Key('thread-detail-sidebar-toggle')));
    await tester.pumpAndSettle();

    expect(
      tester.getSize(find.byKey(const Key('thread-wide-left-pane'))).width,
      greaterThan(0),
    );
    expect(
      find.byKey(const Key('thread-summary-card-thread-123')),
      findsOneWidget,
    );
  });

  testWidgets('wide layout sidebar can be resized by dragging the handle', (
    tester,
  ) async {
    await _setDisplaySize(tester, const Size(1400, 900));
    final cacheRepository = _newCacheRepository();
    final bridgeApi = FakeThreadListBridgeApi(
      scriptedResults: [_sampleThreads()],
    );

    await _pumpThreadListPage(
      tester,
      bridgeApi: bridgeApi,
      cacheRepository: cacheRepository,
    );
    await tester.pumpAndSettle();

    final sidebarFinder = find.byKey(const Key('thread-wide-left-pane'));
    final handleFinder = find.byKey(
      const Key('thread-wide-sidebar-resize-handle'),
    );

    final initialWidth = tester.getSize(sidebarFinder).width;

    await tester.drag(handleFinder, const Offset(96, 0));
    await tester.pumpAndSettle();

    final expandedWidth = tester.getSize(sidebarFinder).width;
    expect(expandedWidth, greaterThan(initialWidth));

    await tester.drag(handleFinder, const Offset(-160, 0));
    await tester.pumpAndSettle();

    final reducedWidth = tester.getSize(sidebarFinder).width;
    expect(reducedWidth, lessThan(expandedWidth));
    expect(reducedWidth, greaterThan(0));
  });

  testWidgets('resizing active threads expands the session detail content', (
    tester,
  ) async {
    await _setDisplaySize(tester, const Size(1400, 900));
    final cacheRepository = _newCacheRepository();
    final bridgeApi = FakeThreadListBridgeApi(
      scriptedResults: [_sampleThreads()],
    );
    final detailApi = FakeThreadDetailBridgeApi(
      detailScriptByThreadId: {
        'thread-123': [_thread123Detail()],
      },
      timelineScriptByThreadId: {
        'thread-123': [<ThreadTimelineEntryDto>[]],
      },
    );

    await _pumpThreadListPage(
      tester,
      bridgeApi: bridgeApi,
      detailApi: detailApi,
      cacheRepository: cacheRepository,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('thread-summary-card-thread-123')));
    await tester.pumpAndSettle();

    final detailContentFinder = find.byKey(
      const Key('thread-detail-session-content'),
    );
    final handleFinder = find.byKey(
      const Key('thread-wide-sidebar-resize-handle'),
    );
    final initialWidth = tester.getSize(detailContentFinder).width;

    await tester.drag(handleFinder, const Offset(-160, 0));
    await tester.pumpAndSettle();

    final expandedWidth = tester.getSize(detailContentFinder).width;
    expect(expandedWidth, greaterThan(initialWidth));
  });

  testWidgets(
    'closing diff restores the prior sidebar visibility instead of forcing it open',
    (tester) async {
      await _setDisplaySize(tester, const Size(1400, 900));
      final cacheRepository = _newCacheRepository();
      final bridgeApi = FakeThreadListBridgeApi(
        scriptedResults: [_sampleThreads()],
      );
      final detailApi = FakeThreadDetailBridgeApi(
        detailScriptByThreadId: {
          'thread-123': [_thread123Detail()],
        },
        timelineScriptByThreadId: {
          'thread-123': [<ThreadTimelineEntryDto>[]],
        },
      );

      await _pumpThreadListPage(
        tester,
        bridgeApi: bridgeApi,
        detailApi: detailApi,
        cacheRepository: cacheRepository,
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('thread-summary-card-thread-123')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('thread-detail-sidebar-toggle')));
      await tester.pumpAndSettle();

      expect(
        tester.getSize(find.byKey(const Key('thread-wide-left-pane'))).width,
        0,
      );

      await tester.tap(find.byKey(const Key('thread-detail-diff-toggle')));
      await tester.pumpAndSettle();

      expect(
        tester
            .getSize(find.byKey(const Key('thread-wide-right-diff-pane')))
            .width,
        greaterThan(0),
      );
      expect(
        tester.getSize(find.byKey(const Key('thread-wide-left-pane'))).width,
        0,
      );

      await tester.tap(find.byKey(const Key('thread-detail-diff-toggle')));
      await tester.pumpAndSettle();

      expect(
        tester
            .getSize(find.byKey(const Key('thread-wide-right-diff-pane')))
            .width,
        0,
      );
      expect(
        tester.getSize(find.byKey(const Key('thread-wide-left-pane'))).width,
        0,
      );
    },
  );

  testWidgets('wide layout diff pane can be resized by dragging the handle', (
    tester,
  ) async {
    await _setDisplaySize(tester, const Size(1400, 900));
    final cacheRepository = _newCacheRepository();
    final bridgeApi = FakeThreadListBridgeApi(
      scriptedResults: [_sampleThreads()],
    );
    final detailApi = FakeThreadDetailBridgeApi(
      detailScriptByThreadId: {
        'thread-123': [_thread123Detail()],
      },
      timelineScriptByThreadId: {
        'thread-123': [<ThreadTimelineEntryDto>[]],
      },
    );

    await _pumpThreadListPage(
      tester,
      bridgeApi: bridgeApi,
      detailApi: detailApi,
      cacheRepository: cacheRepository,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('thread-summary-card-thread-123')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('thread-detail-diff-toggle')));
    await tester.pumpAndSettle();

    final diffFinder = find.byKey(const Key('thread-wide-right-diff-pane'));
    final handleFinder = find.byKey(
      const Key('thread-wide-diff-resize-handle'),
    );
    final initialWidth = tester.getSize(diffFinder).width;

    await tester.drag(handleFinder, const Offset(-96, 0));
    await tester.pumpAndSettle();

    final expandedWidth = tester.getSize(diffFinder).width;
    expect(expandedWidth, greaterThan(initialWidth));

    await tester.drag(handleFinder, const Offset(160, 0));
    await tester.pumpAndSettle();

    final reducedWidth = tester.getSize(diffFinder).width;
    expect(reducedWidth, lessThan(expandedWidth));
    expect(reducedWidth, greaterThan(0));
  });

  testWidgets('narrow layout still pushes to the full-screen detail route', (
    tester,
  ) async {
    await _setDisplaySize(tester, const Size(430, 900));
    final cacheRepository = _newCacheRepository();
    final bridgeApi = FakeThreadListBridgeApi(
      scriptedResults: [_sampleThreads()],
    );
    final detailApi = FakeThreadDetailBridgeApi(
      detailScriptByThreadId: {
        'thread-123': [_thread123Detail()],
      },
      timelineScriptByThreadId: {
        'thread-123': [<ThreadTimelineEntryDto>[]],
      },
    );

    await _pumpThreadListPage(
      tester,
      bridgeApi: bridgeApi,
      detailApi: detailApi,
      cacheRepository: cacheRepository,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('thread-summary-card-thread-123')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('thread-detail-title')), findsOneWidget);
    expect(find.byKey(const Key('thread-detail-back-button')), findsOneWidget);
    expect(find.byKey(const Key('thread-wide-left-pane')), findsNothing);
  });

  testWidgets(
    'detail route returns to wide split view when the display becomes wide',
    (tester) async {
      await _setDisplaySize(tester, const Size(430, 900));
      final cacheRepository = _newCacheRepository();
      final bridgeApi = FakeThreadListBridgeApi(
        scriptedResults: [_sampleThreads()],
      );
      final detailApi = FakeThreadDetailBridgeApi(
        detailScriptByThreadId: {
          'thread-123': [_thread123Detail(), _thread123Detail()],
        },
        timelineScriptByThreadId: {
          'thread-123': [
            <ThreadTimelineEntryDto>[],
            <ThreadTimelineEntryDto>[],
          ],
        },
      );

      await _pumpThreadListPage(
        tester,
        bridgeApi: bridgeApi,
        detailApi: detailApi,
        cacheRepository: cacheRepository,
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('thread-summary-card-thread-123')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('thread-detail-back-button')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('thread-wide-left-pane')), findsNothing);

      await _setDisplaySize(tester, const Size(1400, 900));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('thread-detail-title')), findsOneWidget);
      expect(find.byKey(const Key('thread-detail-back-button')), findsNothing);
      expect(find.byKey(const Key('thread-wide-left-pane')), findsOneWidget);
      expect(
        find.byKey(const Key('thread-summary-card-thread-123')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'narrow layout keeps active threads header aligned with detail header',
    (tester) async {
      await _setDisplaySize(tester, const Size(430, 900));
      final cacheRepository = _newCacheRepository();
      final bridgeApi = FakeThreadListBridgeApi(
        scriptedResults: [_sampleThreads()],
      );
      final detailApi = FakeThreadDetailBridgeApi(
        detailScriptByThreadId: {
          'thread-123': [_thread123Detail()],
        },
        timelineScriptByThreadId: {
          'thread-123': [<ThreadTimelineEntryDto>[]],
        },
      );

      await _pumpThreadListPage(
        tester,
        bridgeApi: bridgeApi,
        detailApi: detailApi,
        cacheRepository: cacheRepository,
      );
      await tester.pumpAndSettle();

      final listBackCenter = tester.getCenter(
        find.byKey(const Key('thread-list-back-button')),
      );
      final listTitleTopLeft = tester.getTopLeft(
        find.byKey(const Key('thread-list-title')),
      );
      final listTitle = tester.widget<Text>(
        find.byKey(const Key('thread-list-title')),
      );

      await tester.tap(find.byKey(const Key('thread-summary-card-thread-123')));
      await tester.pumpAndSettle();

      final detailBackCenter = tester.getCenter(
        find.byKey(const Key('thread-detail-back-button')),
      );
      final detailTitleTopLeft = tester.getTopLeft(
        find.byKey(const Key('thread-detail-title')),
      );
      final detailTitle = tester.widget<Text>(
        find.byKey(const Key('thread-detail-title')),
      );

      expect(detailBackCenter.dx, closeTo(listBackCenter.dx, 0.1));
      expect(detailBackCenter.dy, closeTo(listBackCenter.dy, 0.1));
      expect(detailTitleTopLeft.dx, closeTo(listTitleTopLeft.dx, 0.1));
      expect(detailTitleTopLeft.dy, closeTo(listTitleTopLeft.dy, 0.1));
      expect(detailTitle.style?.fontSize, listTitle.style?.fontSize);
      expect(detailTitle.style?.fontWeight, listTitle.style?.fontWeight);
    },
  );

  testWidgets('thread list header border appears only after scrolling', (
    tester,
  ) async {
    await _setDisplaySize(tester, const Size(430, 640));
    final cacheRepository = _newCacheRepository();
    final bridgeApi = FakeThreadListBridgeApi(
      scriptedResults: [_manyThreadGroups()],
    );

    await _pumpThreadListPage(
      tester,
      bridgeApi: bridgeApi,
      cacheRepository: cacheRepository,
    );
    await tester.pumpAndSettle();

    BoxDecoration headerDecoration() {
      final container = tester.widget<Container>(
        find.byKey(const Key('thread-list-header')),
      );
      return container.decoration! as BoxDecoration;
    }

    expect(headerDecoration().border, isNull);

    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();

    final border = headerDecoration().border! as Border;
    expect(border.bottom.color, Colors.white10);
  });

  test('adaptive layout treats a vertical hinge as a wide split workspace', () {
    const layout = AdaptiveLayoutInfo(
      windowSize: Size(1280, 900),
      verticalFoldBounds: Rect.fromLTWH(420, 0, 48, 900),
    );

    expect(layout.isWideLayout, isTrue);
    expect(layout.hasSeparatingFold, isTrue);
  });

  testWidgets(
    'shows loading then populated thread rows with status and context',
    (tester) async {
      final completer = Completer<List<ThreadSummaryDto>>();
      final cacheRepository = _newCacheRepository();
      final bridgeApi = FakeThreadListBridgeApi(
        scriptedResults: [completer.future],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            threadListBridgeApiProvider.overrideWithValue(bridgeApi),
            approvalBridgeApiProvider.overrideWithValue(
              EmptyApprovalBridgeApi(),
            ),
            threadLiveStreamProvider.overrideWithValue(FakeThreadLiveStream()),
            threadCacheRepositoryProvider.overrideWithValue(cacheRepository),
          ],
          child: const MaterialApp(
            home: ThreadListPage(bridgeApiBaseUrl: 'https://bridge.ts.net'),
          ),
        ),
      );

      await tester.pump();
      expect(find.text('Implement shared contracts'), findsNothing);

      completer.complete(_sampleThreads());
      await tester.pumpAndSettle();

      expect(find.text('Implement shared contracts'), findsOneWidget);
      expect(find.text('Investigate reconnect dedup'), findsOneWidget);
      expect(find.text('ACTIVE'), findsOneWidget);
      expect(find.text('COMPLETED'), findsOneWidget);
      expect(
        find.byKey(
          const Key('thread-folder-group-/workspace/vibe-bridge-companion'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('thread-summary-card-thread-456')),
          matching: find.text('develop'),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('thread summary cards fill the available group width', (
    tester,
  ) async {
    await _setDisplaySize(tester, const Size(430, 900));
    final cacheRepository = _newCacheRepository();
    final bridgeApi = FakeThreadListBridgeApi(
      scriptedResults: [_sampleThreads()],
    );

    await _pumpThreadListPage(
      tester,
      bridgeApi: bridgeApi,
      cacheRepository: cacheRepository,
    );
    await tester.pumpAndSettle();

    final groupWidth = tester
        .getSize(
          find.byKey(
            const Key('thread-folder-group-/workspace/vibe-bridge-companion'),
          ),
        )
        .width;
    final cardWidth = tester
        .getSize(find.byKey(const Key('thread-summary-card-thread-123')))
        .width;

    expect(cardWidth, closeTo(groupWidth, 0.1));
  });

  testWidgets('shows an explicit empty state when no threads exist', (
    tester,
  ) async {
    final cacheRepository = _newCacheRepository();
    final bridgeApi = FakeThreadListBridgeApi(
      scriptedResults: [<ThreadSummaryDto>[]],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          threadListBridgeApiProvider.overrideWithValue(bridgeApi),
          approvalBridgeApiProvider.overrideWithValue(EmptyApprovalBridgeApi()),
          threadLiveStreamProvider.overrideWithValue(FakeThreadLiveStream()),
          threadCacheRepositoryProvider.overrideWithValue(cacheRepository),
        ],
        child: const MaterialApp(
          home: ThreadListPage(
            bridgeApiBaseUrl: 'https://bridge.ts.net',
            autoOpenPreviouslySelectedThread: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No threads yet'), findsOneWidget);
    expect(
      find.text(
        'Start a turn on your connected host bridge, then pull to refresh this list.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('shows retryable error state and recovers on retry', (
    tester,
  ) async {
    final cacheRepository = _newCacheRepository();
    final bridgeApi = FakeThreadListBridgeApi(
      scriptedResults: [
        const ThreadListBridgeException(
          'Cannot reach the bridge. Check your private route.',
        ),
        _sampleThreads(),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          threadListBridgeApiProvider.overrideWithValue(bridgeApi),
          approvalBridgeApiProvider.overrideWithValue(EmptyApprovalBridgeApi()),
          threadLiveStreamProvider.overrideWithValue(FakeThreadLiveStream()),
          threadCacheRepositoryProvider.overrideWithValue(cacheRepository),
        ],
        child: const MaterialApp(
          home: ThreadListPage(
            bridgeApiBaseUrl: 'https://bridge.ts.net',
            autoOpenPreviouslySelectedThread: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text("Couldn't load threads"), findsOneWidget);
    expect(
      find.text('Cannot reach the bridge. Check your private route.'),
      findsOneWidget,
    );
    expect(find.text('Retry'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(find.text('Implement shared contracts'), findsOneWidget);
    expect(find.text("Couldn't load threads"), findsNothing);
    expect(bridgeApi.fetchCallCount, 2);
  });

  testWidgets(
    'successful thread fetch still renders when cache persistence fails',
    (tester) async {
      final bridgeApi = FakeThreadListBridgeApi(
        scriptedResults: [_sampleThreads()],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            threadListBridgeApiProvider.overrideWithValue(bridgeApi),
            approvalBridgeApiProvider.overrideWithValue(
              EmptyApprovalBridgeApi(),
            ),
            threadLiveStreamProvider.overrideWithValue(FakeThreadLiveStream()),
            threadCacheRepositoryProvider.overrideWithValue(
              ThrowingThreadCacheRepository(
                onSaveThreadList: () => throw Exception('cache write failed'),
              ),
            ),
          ],
          child: const MaterialApp(
            home: ThreadListPage(
              bridgeApiBaseUrl: 'https://bridge.ts.net',
              autoOpenPreviouslySelectedThread: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Implement shared contracts'), findsOneWidget);
      expect(find.text("Couldn't load threads"), findsNothing);
    },
  );

  testWidgets('search narrows and clearing search restores full list', (
    tester,
  ) async {
    final cacheRepository = _newCacheRepository();
    final bridgeApi = FakeThreadListBridgeApi(
      scriptedResults: [_sampleThreads()],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          threadListBridgeApiProvider.overrideWithValue(bridgeApi),
          approvalBridgeApiProvider.overrideWithValue(EmptyApprovalBridgeApi()),
          threadLiveStreamProvider.overrideWithValue(FakeThreadLiveStream()),
          threadCacheRepositoryProvider.overrideWithValue(cacheRepository),
        ],
        child: const MaterialApp(
          home: ThreadListPage(
            bridgeApiBaseUrl: 'https://bridge.ts.net',
            autoOpenPreviouslySelectedThread: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Implement shared contracts'), findsOneWidget);
    expect(find.text('Investigate reconnect dedup'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('thread-search-input')),
      'runtime-tools',
    );
    await tester.pumpAndSettle();

    expect(find.text('Investigate reconnect dedup'), findsOneWidget);
    expect(find.text('Implement shared contracts'), findsNothing);

    await tester.enterText(find.byKey(const Key('thread-search-input')), '');
    await tester.pumpAndSettle();

    expect(find.text('Implement shared contracts'), findsOneWidget);
    expect(find.text('Investigate reconnect dedup'), findsOneWidget);
  });

  testWidgets(
    'offline bridge keeps cached thread list readable with stale state',
    (tester) async {
      final cacheRepository = _newCacheRepository();
      await cacheRepository.saveThreadList(_sampleThreads());

      final bridgeApi = FakeThreadListBridgeApi(
        scriptedResults: [
          const ThreadListBridgeException(
            'Cannot reach the bridge. Check your private route.',
            isConnectivityError: true,
          ),
        ],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            threadListBridgeApiProvider.overrideWithValue(bridgeApi),
            approvalBridgeApiProvider.overrideWithValue(
              EmptyApprovalBridgeApi(),
            ),
            threadLiveStreamProvider.overrideWithValue(FakeThreadLiveStream()),
            threadCacheRepositoryProvider.overrideWithValue(cacheRepository),
          ],
          child: const MaterialApp(
            home: ThreadListPage(bridgeApiBaseUrl: 'https://bridge.ts.net'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Implement shared contracts'), findsOneWidget);
      expect(find.text('Investigate reconnect dedup'), findsOneWidget);
      expect(
        find.textContaining('Bridge is offline. Showing cached threads.'),
        findsOneWidget,
      );
      expect(find.text("Couldn't load threads"), findsNothing);
    },
  );

  testWidgets('off-screen live status updates sync into thread list', (
    tester,
  ) async {
    final cacheRepository = _newCacheRepository();
    final bridgeApi = FakeThreadListBridgeApi(
      scriptedResults: [_sampleThreads()],
    );
    final liveStream = FakeThreadLiveStream();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          threadListBridgeApiProvider.overrideWithValue(bridgeApi),
          approvalBridgeApiProvider.overrideWithValue(EmptyApprovalBridgeApi()),
          threadLiveStreamProvider.overrideWithValue(liveStream),
          threadCacheRepositoryProvider.overrideWithValue(cacheRepository),
        ],
        child: const MaterialApp(
          home: ThreadListPage(
            bridgeApiBaseUrl: 'https://bridge.ts.net',
            autoOpenPreviouslySelectedThread: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byKey(const Key('thread-summary-card-thread-456')),
        matching: find.text('COMPLETED'),
      ),
      findsOneWidget,
    );

    liveStream.emit(
      BridgeEventEnvelope<Map<String, dynamic>>(
        contractVersion: contractVersion,
        eventId: 'evt-list-live-1',
        threadId: 'thread-456',
        kind: BridgeEventKind.threadStatusChanged,
        occurredAt: '2026-03-18T11:01:00Z',
        payload: {'status': 'running', 'reason': 'turn_started'},
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byKey(const Key('thread-summary-card-thread-456')),
        matching: find.text('ACTIVE'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('saved selected thread auto-opens detail on thread list load', (
    tester,
  ) async {
    final cacheRepository = _newCacheRepository();
    await cacheRepository.saveSelectedThreadId('thread-123');

    final listApi = FakeThreadListBridgeApi(
      scriptedResults: [_sampleThreads()],
    );
    final detailApi = FakeThreadDetailBridgeApi(
      detailScriptByThreadId: {
        'thread-123': [_thread123Detail()],
      },
      timelineScriptByThreadId: {
        'thread-123': [<ThreadTimelineEntryDto>[]],
      },
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appSecureStoreProvider.overrideWithValue(InMemorySecureStore()),
          threadListBridgeApiProvider.overrideWithValue(listApi),
          approvalBridgeApiProvider.overrideWithValue(EmptyApprovalBridgeApi()),
          threadDetailBridgeApiProvider.overrideWithValue(detailApi),
          threadLiveStreamProvider.overrideWithValue(FakeThreadLiveStream()),
          threadCacheRepositoryProvider.overrideWithValue(cacheRepository),
        ],
        child: const MaterialApp(
          home: ThreadListPage(
            bridgeApiBaseUrl: 'https://bridge.ts.net',
            autoOpenPreviouslySelectedThread: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (var attempt = 0; attempt < 10; attempt += 1) {
      if (detailApi.fetchThreadDetailCallCount > 0) {
        break;
      }
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.byKey(const Key('thread-detail-title')), findsOneWidget);
    expect(detailApi.fetchThreadDetailCallCount, 1);
    expect(detailApi.lastFetchedThreadId, 'thread-123');
  });

  testWidgets(
    'stale thread-list reload does not overwrite newer detail-synced metadata',
    (tester) async {
      final realDetail = _loadRealThreadDetailFixture();
      final staleSummary = ThreadSummaryDto(
        contractVersion: contractVersion,
        threadId: realDetail.threadId,
        title: 'Stale cached title',
        status: ThreadStatus.running,
        workspace: '/Users/lubomirmolin/PhpstormProjects/old-workspace',
        repository: 'old-workspace',
        branch: 'feature/stale-row',
        updatedAt: '2026-03-20T21:39:00Z',
      );

      final bridgeApi = FakeThreadListBridgeApi(
        scriptedResults: [
          [staleSummary],
          [staleSummary],
        ],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            threadListBridgeApiProvider.overrideWithValue(bridgeApi),
            approvalBridgeApiProvider.overrideWithValue(
              EmptyApprovalBridgeApi(),
            ),
            threadLiveStreamProvider.overrideWithValue(FakeThreadLiveStream()),
            threadCacheRepositoryProvider.overrideWithValue(
              _newCacheRepository(),
            ),
          ],
          child: const MaterialApp(
            home: ThreadListPage(bridgeApiBaseUrl: 'https://bridge.ts.net'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(ThreadListPage)),
      );
      final controller = container.read(
        threadListControllerProvider('https://bridge.ts.net').notifier,
      );

      controller.syncThreadDetail(realDetail);
      await tester.pumpAndSettle();

      expect(find.text(realDetail.title), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(Key('thread-summary-card-${realDetail.threadId}')),
          matching: find.text('COMPLETED'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(Key('thread-summary-card-${realDetail.threadId}')),
          matching: find.text(realDetail.branch),
        ),
        findsOneWidget,
      );

      await controller.loadThreads();
      await tester.pumpAndSettle();

      expect(find.text(realDetail.title), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(Key('thread-summary-card-${realDetail.threadId}')),
          matching: find.text('COMPLETED'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(Key('thread-summary-card-${realDetail.threadId}')),
          matching: find.text(realDetail.branch),
        ),
        findsOneWidget,
      );
      expect(find.text('Stale cached title'), findsNothing);
      expect(find.text('feature/stale-row'), findsNothing);
    },
  );

  testWidgets(
    'thread-list reload replaces placeholder titles with fetched generated titles',
    (tester) async {
      const placeholderSummary = ThreadSummaryDto(
        contractVersion: contractVersion,
        threadId: 'thread-123',
        title: 'New Thread',
        status: ThreadStatus.running,
        workspace: '/Users/lubomirmolin/PhpstormProjects/vibe-bridge-companion',
        repository: 'vibe-bridge-companion',
        branch: 'main',
        updatedAt: '2026-03-20T21:40:00Z',
      );
      const generatedSummary = ThreadSummaryDto(
        contractVersion: contractVersion,
        threadId: 'thread-123',
        title: 'Implement shared contracts',
        status: ThreadStatus.running,
        workspace: '/Users/lubomirmolin/PhpstormProjects/vibe-bridge-companion',
        repository: 'vibe-bridge-companion',
        branch: 'main',
        updatedAt: '2026-03-20T21:39:00Z',
      );

      final bridgeApi = FakeThreadListBridgeApi(
        scriptedResults: [
          [placeholderSummary],
          [generatedSummary],
        ],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            threadListBridgeApiProvider.overrideWithValue(bridgeApi),
            approvalBridgeApiProvider.overrideWithValue(
              EmptyApprovalBridgeApi(),
            ),
            threadLiveStreamProvider.overrideWithValue(FakeThreadLiveStream()),
            threadCacheRepositoryProvider.overrideWithValue(
              _newCacheRepository(),
            ),
          ],
          child: const MaterialApp(
            home: ThreadListPage(bridgeApiBaseUrl: 'https://bridge.ts.net'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('New Thread'), findsOneWidget);

      final container = ProviderScope.containerOf(
        tester.element(find.byType(ThreadListPage)),
      );
      final controller = container.read(
        threadListControllerProvider('https://bridge.ts.net').notifier,
      );

      await controller.loadThreads();
      await tester.pumpAndSettle();

      expect(find.text('Implement shared contracts'), findsOneWidget);
      expect(find.text('New Thread'), findsNothing);
    },
  );

  testWidgets('groups threads by workspace folder and keeps matches scoped', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(430, 1400);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final cacheRepository = _newCacheRepository();
    final bridgeApi = FakeThreadListBridgeApi(
      scriptedResults: [_groupedThreads()],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          threadListBridgeApiProvider.overrideWithValue(bridgeApi),
          approvalBridgeApiProvider.overrideWithValue(EmptyApprovalBridgeApi()),
          threadLiveStreamProvider.overrideWithValue(FakeThreadLiveStream()),
          threadCacheRepositoryProvider.overrideWithValue(cacheRepository),
        ],
        child: const MaterialApp(
          home: ThreadListPage(bridgeApiBaseUrl: 'https://bridge.ts.net'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(
        const Key('thread-folder-group-/workspace/vibe-bridge-companion'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('thread-folder-group-/workspace/portable-client')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(
          const Key('thread-folder-group-/workspace/vibe-bridge-companion'),
        ),
        matching: find.text('Investigate reconnect dedup'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(
          const Key('thread-folder-group-/workspace/vibe-bridge-companion'),
        ),
        matching: find.text('Implement shared contracts'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('thread-folder-group-/workspace/portable-client')),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const Key('thread-search-input')),
      'portable',
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(
        const Key('thread-folder-group-/workspace/vibe-bridge-companion'),
      ),
      findsNothing,
    );
    expect(
      find.byKey(const Key('thread-folder-group-/workspace/portable-client')),
      findsOneWidget,
    );
    expect(find.text('Add remote config to setup flow'), findsOneWidget);
    expect(find.text('Implement shared contracts'), findsNothing);
  });

  testWidgets('workspace groups can collapse and search re-expands matches', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(430, 1400);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final cacheRepository = _newCacheRepository();
    final bridgeApi = FakeThreadListBridgeApi(
      scriptedResults: [_groupedThreads()],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          threadListBridgeApiProvider.overrideWithValue(bridgeApi),
          approvalBridgeApiProvider.overrideWithValue(EmptyApprovalBridgeApi()),
          threadLiveStreamProvider.overrideWithValue(FakeThreadLiveStream()),
          threadCacheRepositoryProvider.overrideWithValue(cacheRepository),
        ],
        child: const MaterialApp(
          home: ThreadListPage(bridgeApiBaseUrl: 'https://bridge.ts.net'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Implement shared contracts'), findsOneWidget);

    await tester.tap(
      find.byKey(
        const Key('thread-folder-toggle-/workspace/vibe-bridge-companion'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Implement shared contracts'), findsNothing);
    expect(find.text('Investigate reconnect dedup'), findsNothing);
    expect(find.text('Add remote config to setup flow'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('thread-search-input')),
      'shared contracts',
    );
    await tester.pumpAndSettle();

    expect(find.text('Implement shared contracts'), findsOneWidget);
  });

  testWidgets(
    'workspace groups show three threads by default and expand on demand',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(430, 1400);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final cacheRepository = _newCacheRepository();
      final bridgeApi = FakeThreadListBridgeApi(
        scriptedResults: [_overflowGroupedThreads()],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            threadListBridgeApiProvider.overrideWithValue(bridgeApi),
            approvalBridgeApiProvider.overrideWithValue(
              EmptyApprovalBridgeApi(),
            ),
            threadLiveStreamProvider.overrideWithValue(FakeThreadLiveStream()),
            threadCacheRepositoryProvider.overrideWithValue(cacheRepository),
          ],
          child: const MaterialApp(
            home: ThreadListPage(bridgeApiBaseUrl: 'https://bridge.ts.net'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Implement shared contracts'), findsOneWidget);
      expect(find.text('Investigate reconnect dedup'), findsOneWidget);
      expect(find.text('Ship bridge offline banner'), findsOneWidget);
      expect(find.text('Tune timeline chunking'), findsNothing);
      expect(
        find.byKey(
          const Key('thread-group-show-more-/workspace/vibe-bridge-companion'),
        ),
        findsOneWidget,
      );
      expect(find.text('Show more'), findsOneWidget);

      await tester.tap(
        find.byKey(
          const Key('thread-group-show-more-/workspace/vibe-bridge-companion'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Tune timeline chunking'), findsOneWidget);
      expect(find.text('Show less'), findsOneWidget);
    },
  );

  testWidgets(
    'new thread workspace picker excludes groups without workspace paths',
    (tester) async {
      final cacheRepository = _newCacheRepository();
      final bridgeApi = FakeThreadListBridgeApi(
        scriptedResults: [_threadsWithMissingWorkspace()],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            threadListBridgeApiProvider.overrideWithValue(bridgeApi),
            approvalBridgeApiProvider.overrideWithValue(
              EmptyApprovalBridgeApi(),
            ),
            threadLiveStreamProvider.overrideWithValue(FakeThreadLiveStream()),
            threadCacheRepositoryProvider.overrideWithValue(cacheRepository),
          ],
          child: const MaterialApp(
            home: ThreadListPage(bridgeApiBaseUrl: 'https://bridge.ts.net'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('thread-list-create-button')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(
          const Key('thread-list-workspace-option-repository:workspace-less'),
        ),
        findsNothing,
      );
      expect(
        find.byKey(
          const Key(
            'thread-list-workspace-option-/workspace/vibe-bridge-companion',
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const Key('thread-list-workspace-option-/workspace/portable-client'),
        ),
        findsOneWidget,
      );
    },
  );
}

ThreadCacheRepository _newCacheRepository() {
  return SecureStoreThreadCacheRepository(
    secureStore: InMemorySecureStore(),
    nowUtc: () => DateTime.utc(2026, 3, 18, 10, 0),
  );
}

class ThrowingThreadCacheRepository implements ThreadCacheRepository {
  ThrowingThreadCacheRepository({this.onSaveThreadList});

  final Future<void> Function()? onSaveThreadList;

  @override
  Future<CachedThreadListSnapshot?> readThreadList() async {
    return null;
  }

  @override
  Future<String?> readSelectedThreadId() async {
    return null;
  }

  @override
  Future<void> saveSelectedThreadId(String threadId) async {}

  @override
  Future<void> saveThreadList(List<ThreadSummaryDto> threads) async {
    final handler = onSaveThreadList;
    if (handler != null) {
      await handler();
    }
  }
}

Future<void> _setDisplaySize(WidgetTester tester, Size size) async {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

Future<void> _pumpThreadListPage(
  WidgetTester tester, {
  required FakeThreadListBridgeApi bridgeApi,
  required ThreadCacheRepository cacheRepository,
  FakeThreadDetailBridgeApi? detailApi,
  FakeThreadLiveStream? liveStream,
  Widget Function(Widget child)? appBuilder,
}) async {
  final app = MaterialApp(
    home: ThreadListPage(bridgeApiBaseUrl: 'https://bridge.ts.net'),
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        threadListBridgeApiProvider.overrideWithValue(bridgeApi),
        approvalBridgeApiProvider.overrideWithValue(EmptyApprovalBridgeApi()),
        threadDetailBridgeApiProvider.overrideWithValue(
          detailApi ??
              FakeThreadDetailBridgeApi(
                detailScriptByThreadId: const {},
                timelineScriptByThreadId: const {},
              ),
        ),
        threadLiveStreamProvider.overrideWithValue(
          liveStream ?? FakeThreadLiveStream(),
        ),
        threadCacheRepositoryProvider.overrideWithValue(cacheRepository),
      ],
      child: appBuilder == null ? app : appBuilder(app),
    ),
  );
}

const _realThreadFixtureDetailPath =
    'test/features/threads/fixtures/real_thread_019d_detail.json';

ThreadDetailDto _loadRealThreadDetailFixture() {
  final detailRaw = File(_realThreadFixtureDetailPath).readAsStringSync();
  final detailEnvelope = jsonDecode(detailRaw) as Map<String, dynamic>;
  final detailJson = detailEnvelope['thread'];
  if (detailJson is! Map<String, dynamic>) {
    throw const FormatException(
      'Real thread detail fixture is missing thread.',
    );
  }

  return ThreadDetailDto.fromJson(detailJson);
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

List<ThreadSummaryDto> _sampleThreads() {
  return const [
    ThreadSummaryDto(
      contractVersion: contractVersion,
      threadId: 'thread-123',
      title: 'Implement shared contracts',
      status: ThreadStatus.running,
      workspace: '/workspace/vibe-bridge-companion',
      repository: 'vibe-bridge-companion',
      branch: 'master',
      updatedAt: '2026-03-17T18:00:00Z',
    ),
    ThreadSummaryDto(
      contractVersion: contractVersion,
      threadId: 'thread-456',
      title: 'Investigate reconnect dedup',
      status: ThreadStatus.completed,
      workspace: '/workspace/codex-runtime-tools',
      repository: 'codex-runtime-tools',
      branch: 'develop',
      updatedAt: '2026-03-17T17:30:00Z',
    ),
  ];
}

List<ThreadSummaryDto> _groupedThreads() {
  return const [
    ThreadSummaryDto(
      contractVersion: contractVersion,
      threadId: 'thread-123',
      title: 'Implement shared contracts',
      status: ThreadStatus.running,
      workspace: '/workspace/vibe-bridge-companion',
      repository: 'vibe-bridge-companion',
      branch: 'master',
      updatedAt: '2026-03-17T18:00:00Z',
    ),
    ThreadSummaryDto(
      contractVersion: contractVersion,
      threadId: 'thread-456',
      title: 'Investigate reconnect dedup',
      status: ThreadStatus.completed,
      workspace: '/workspace/vibe-bridge-companion',
      repository: 'vibe-bridge-companion',
      branch: 'develop',
      updatedAt: '2026-03-17T17:30:00Z',
    ),
    ThreadSummaryDto(
      contractVersion: contractVersion,
      threadId: 'thread-789',
      title: 'Add remote config to setup flow',
      status: ThreadStatus.idle,
      workspace: '/workspace/portable-client',
      repository: 'portable-client',
      branch: 'main',
      updatedAt: '2026-03-17T16:30:00Z',
    ),
  ];
}

List<ThreadSummaryDto> _threadsWithMissingWorkspace() {
  return const [
    ThreadSummaryDto(
      contractVersion: contractVersion,
      threadId: 'thread-001',
      title: 'Workspace metadata not available',
      status: ThreadStatus.idle,
      workspace: '',
      repository: 'workspace-less',
      branch: 'main',
      updatedAt: '2026-03-17T18:30:00Z',
    ),
    ThreadSummaryDto(
      contractVersion: contractVersion,
      threadId: 'thread-123',
      title: 'Implement shared contracts',
      status: ThreadStatus.running,
      workspace: '/workspace/vibe-bridge-companion',
      repository: 'vibe-bridge-companion',
      branch: 'master',
      updatedAt: '2026-03-17T18:00:00Z',
    ),
    ThreadSummaryDto(
      contractVersion: contractVersion,
      threadId: 'thread-789',
      title: 'Add remote config to setup flow',
      status: ThreadStatus.idle,
      workspace: '/workspace/portable-client',
      repository: 'portable-client',
      branch: 'main',
      updatedAt: '2026-03-17T16:30:00Z',
    ),
  ];
}

List<ThreadSummaryDto> _overflowGroupedThreads() {
  return const [
    ThreadSummaryDto(
      contractVersion: contractVersion,
      threadId: 'thread-123',
      title: 'Implement shared contracts',
      status: ThreadStatus.running,
      workspace: '/workspace/vibe-bridge-companion',
      repository: 'vibe-bridge-companion',
      branch: 'master',
      updatedAt: '2026-03-17T18:00:00Z',
    ),
    ThreadSummaryDto(
      contractVersion: contractVersion,
      threadId: 'thread-456',
      title: 'Investigate reconnect dedup',
      status: ThreadStatus.completed,
      workspace: '/workspace/vibe-bridge-companion',
      repository: 'vibe-bridge-companion',
      branch: 'develop',
      updatedAt: '2026-03-17T17:30:00Z',
    ),
    ThreadSummaryDto(
      contractVersion: contractVersion,
      threadId: 'thread-457',
      title: 'Ship bridge offline banner',
      status: ThreadStatus.idle,
      workspace: '/workspace/vibe-bridge-companion',
      repository: 'vibe-bridge-companion',
      branch: 'feature/offline-banner',
      updatedAt: '2026-03-17T17:00:00Z',
    ),
    ThreadSummaryDto(
      contractVersion: contractVersion,
      threadId: 'thread-458',
      title: 'Tune timeline chunking',
      status: ThreadStatus.failed,
      workspace: '/workspace/vibe-bridge-companion',
      repository: 'vibe-bridge-companion',
      branch: 'feature/timeline-chunking',
      updatedAt: '2026-03-17T16:30:00Z',
    ),
    ThreadSummaryDto(
      contractVersion: contractVersion,
      threadId: 'thread-789',
      title: 'Add remote config to setup flow',
      status: ThreadStatus.idle,
      workspace: '/workspace/portable-client',
      repository: 'portable-client',
      branch: 'main',
      updatedAt: '2026-03-17T16:00:00Z',
    ),
  ];
}

List<ThreadSummaryDto> _manyThreadGroups() {
  return List<ThreadSummaryDto>.generate(8, (index) {
    final number = index + 1;
    return ThreadSummaryDto(
      contractVersion: contractVersion,
      threadId: 'thread-$number',
      title: 'Thread $number',
      status: ThreadStatus.running,
      workspace: '/workspace/project-$number',
      repository: 'project-$number',
      branch: 'main',
      updatedAt: '2026-03-17T18:00:00Z',
    );
  });
}

class FakeThreadListBridgeApi implements ThreadListBridgeApi {
  FakeThreadListBridgeApi({required this.scriptedResults});

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
    if (scriptedResult is Future<List<ThreadSummaryDto>>) {
      return scriptedResult;
    }
    if (scriptedResult is List<ThreadSummaryDto>) {
      return scriptedResult;
    }
    if (scriptedResult is ThreadListBridgeException) {
      throw scriptedResult;
    }
    throw StateError('Unsupported scripted result type: $scriptedResult');
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
  int fetchThreadDetailCallCount = 0;
  String? lastFetchedThreadId;

  @override
  Future<ModelCatalogDto> fetchModelCatalog({
    required String bridgeApiBaseUrl,
  }) async {
    return fallbackModelCatalog;
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
    String? model,
  }) async {
    throw const ThreadCreateBridgeException(
      message: 'Thread creation is not used in thread-list tests.',
    );
  }

  @override
  Future<ThreadDetailDto> fetchThreadDetail({
    required String bridgeApiBaseUrl,
    required String threadId,
  }) async {
    fetchThreadDetailCallCount += 1;
    lastFetchedThreadId = threadId;
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
    final detail = _detailScriptByThreadId[threadId]?.first;
    if (detail is! ThreadDetailDto) {
      throw StateError('Missing scripted detail for thread "$threadId".');
    }

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
  Future<TurnMutationResult> startTurn({
    required String bridgeApiBaseUrl,
    required String threadId,
    required String prompt,
    TurnMode mode = TurnMode.act,
    List<String> images = const <String>[],
    String? model,
    String? effort,
  }) async {
    throw UnimplementedError();
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
    throw UnimplementedError();
  }

  @override
  Future<TurnMutationResult> steerTurn({
    required String bridgeApiBaseUrl,
    required String threadId,
    required String instruction,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<TurnMutationResult> interruptTurn({
    required String bridgeApiBaseUrl,
    required String threadId,
    String? turnId,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<TurnMutationResult> startCommitAction({
    required String bridgeApiBaseUrl,
    required String threadId,
    String? model,
    String? effort,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<OpenOnMacResponseDto> openOnMac({
    required String bridgeApiBaseUrl,
    required String threadId,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<GitStatusResponseDto> fetchGitStatus({
    required String bridgeApiBaseUrl,
    required String threadId,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<MutationResultResponseDto> switchBranch({
    required String bridgeApiBaseUrl,
    required String threadId,
    required String branch,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<MutationResultResponseDto> pullRepository({
    required String bridgeApiBaseUrl,
    required String threadId,
    String? remote,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<MutationResultResponseDto> pushRepository({
    required String bridgeApiBaseUrl,
    required String threadId,
    String? remote,
  }) async {
    throw UnimplementedError();
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

Object _nextResult(
  Map<String, List<Object>> scriptByThreadId,
  String threadId,
) {
  final results = scriptByThreadId[threadId];
  if (results == null || results.isEmpty) {
    throw StateError('Missing scripted result for thread "$threadId".');
  }

  final result = results.first;
  if (results.length > 1) {
    results.removeAt(0);
  }
  return result;
}
