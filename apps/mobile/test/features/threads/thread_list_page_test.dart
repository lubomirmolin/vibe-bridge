import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:codex_mobile_companion/features/approvals/data/approval_bridge_api.dart';
import 'package:codex_mobile_companion/features/threads/application/thread_list_controller.dart';
import 'package:codex_mobile_companion/features/threads/data/thread_cache_repository.dart';
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
          const Key('thread-folder-group-/workspace/codex-mobile-companion'),
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
          home: ThreadListPage(bridgeApiBaseUrl: 'https://bridge.ts.net'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No threads yet'), findsOneWidget);
    expect(
      find.text('Start a turn on your Mac, then pull to refresh this list.'),
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
          home: ThreadListPage(bridgeApiBaseUrl: 'https://bridge.ts.net'),
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
          home: ThreadListPage(bridgeApiBaseUrl: 'https://bridge.ts.net'),
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
          home: ThreadListPage(bridgeApiBaseUrl: 'https://bridge.ts.net'),
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
        const Key('thread-folder-group-/workspace/codex-mobile-companion'),
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
          const Key('thread-folder-group-/workspace/codex-mobile-companion'),
        ),
        matching: find.text('Investigate reconnect dedup'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(
          const Key('thread-folder-group-/workspace/codex-mobile-companion'),
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
        const Key('thread-folder-group-/workspace/codex-mobile-companion'),
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
        const Key('thread-folder-toggle-/workspace/codex-mobile-companion'),
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
            'thread-list-workspace-option-/workspace/codex-mobile-companion',
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

List<ThreadSummaryDto> _sampleThreads() {
  return const [
    ThreadSummaryDto(
      contractVersion: contractVersion,
      threadId: 'thread-123',
      title: 'Implement shared contracts',
      status: ThreadStatus.running,
      workspace: '/workspace/codex-mobile-companion',
      repository: 'codex-mobile-companion',
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
      workspace: '/workspace/codex-mobile-companion',
      repository: 'codex-mobile-companion',
      branch: 'master',
      updatedAt: '2026-03-17T18:00:00Z',
    ),
    ThreadSummaryDto(
      contractVersion: contractVersion,
      threadId: 'thread-456',
      title: 'Investigate reconnect dedup',
      status: ThreadStatus.completed,
      workspace: '/workspace/codex-mobile-companion',
      repository: 'codex-mobile-companion',
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
      workspace: '/workspace/codex-mobile-companion',
      repository: 'codex-mobile-companion',
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
