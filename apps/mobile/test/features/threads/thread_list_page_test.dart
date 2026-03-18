import 'dart:async';

import 'package:codex_mobile_companion/features/threads/data/thread_list_bridge_api.dart';
import 'package:codex_mobile_companion/features/threads/presentation/thread_list_page.dart';
import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'shows loading then populated thread rows with status and context',
    (tester) async {
      final completer = Completer<List<ThreadSummaryDto>>();
      final bridgeApi = FakeThreadListBridgeApi(
        scriptedResults: [completer.future],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [threadListBridgeApiProvider.overrideWithValue(bridgeApi)],
          child: const MaterialApp(
            home: ThreadListPage(bridgeApiBaseUrl: 'https://bridge.ts.net'),
          ),
        ),
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Loading threads…'), findsOneWidget);

      completer.complete(_sampleThreads());
      await tester.pumpAndSettle();

      expect(find.text('Implement shared contracts'), findsOneWidget);
      expect(find.text('Investigate reconnect dedup'), findsOneWidget);
      expect(find.text('Running'), findsOneWidget);
      expect(find.text('Completed'), findsOneWidget);
      expect(
        find.textContaining('codex-mobile-companion • master'),
        findsOneWidget,
      );
      expect(
        find.textContaining('/workspace/codex-runtime-tools'),
        findsOneWidget,
      );
    },
  );

  testWidgets('shows an explicit empty state when no threads exist', (
    tester,
  ) async {
    final bridgeApi = FakeThreadListBridgeApi(
      scriptedResults: [<ThreadSummaryDto>[]],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [threadListBridgeApiProvider.overrideWithValue(bridgeApi)],
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
        overrides: [threadListBridgeApiProvider.overrideWithValue(bridgeApi)],
        child: const MaterialApp(
          home: ThreadListPage(bridgeApiBaseUrl: 'https://bridge.ts.net'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Couldn’t load threads'), findsOneWidget);
    expect(
      find.text('Cannot reach the bridge. Check your private route.'),
      findsOneWidget,
    );
    expect(find.text('Retry'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(find.text('Implement shared contracts'), findsOneWidget);
    expect(find.text('Couldn’t load threads'), findsNothing);
    expect(bridgeApi.fetchCallCount, 2);
  });

  testWidgets('search narrows and clearing search restores full list', (
    tester,
  ) async {
    final bridgeApi = FakeThreadListBridgeApi(
      scriptedResults: [_sampleThreads()],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [threadListBridgeApiProvider.overrideWithValue(bridgeApi)],
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
