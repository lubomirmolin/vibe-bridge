import 'dart:async';

import 'package:vibe_bridge/features/threads/data/thread_diff_bridge_api.dart';
import 'package:vibe_bridge/features/threads/data/thread_live_stream.dart';
import 'package:vibe_bridge/features/threads/presentation/thread_git_diff_page.dart';
import 'package:vibe_bridge/foundation/contracts/bridge_contracts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('embedded diff pane keeps the back button hidden', (
    tester,
  ) async {
    final bridgeApi = FakeThreadDiffBridgeApi(
      diffsByMode: <ThreadGitDiffMode, ThreadGitDiffDto>{
        ThreadGitDiffMode.workspace: _buildDiffDto(
          mode: ThreadGitDiffMode.workspace,
          files: const <GitDiffFileSummaryDto>[],
          unifiedDiff: '',
        ),
      },
    );

    await tester.pumpWidget(
      _buildTestApp(
        bridgeApi: bridgeApi,
        liveStream: FakeThreadLiveStream(),
        child: ThreadGitDiffPane(
          bridgeApiBaseUrl: 'http://127.0.0.1:33210',
          threadId: 'thread-123',
          onClose: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('thread-git-diff-back-button')), findsNothing);
  });

  testWidgets('full-screen diff page shows the back button', (tester) async {
    final bridgeApi = FakeThreadDiffBridgeApi(
      diffsByMode: <ThreadGitDiffMode, ThreadGitDiffDto>{
        ThreadGitDiffMode.workspace: _buildDiffDto(
          mode: ThreadGitDiffMode.workspace,
          files: const <GitDiffFileSummaryDto>[],
          unifiedDiff: '',
        ),
      },
    );

    await tester.pumpWidget(
      _buildTestApp(
        bridgeApi: bridgeApi,
        liveStream: FakeThreadLiveStream(),
        child: const ThreadGitDiffPage(
          bridgeApiBaseUrl: 'http://127.0.0.1:33210',
          threadId: 'thread-123',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('thread-git-diff-back-button')),
      findsOneWidget,
    );
  });

  testWidgets('renders all parsed diff files in one stacked document', (
    tester,
  ) async {
    final bridgeApi = FakeThreadDiffBridgeApi(
      diffsByMode: <ThreadGitDiffMode, ThreadGitDiffDto>{
        ThreadGitDiffMode.workspace: _buildDiffDto(
          mode: ThreadGitDiffMode.workspace,
          files: const <GitDiffFileSummaryDto>[
            GitDiffFileSummaryDto(
              path: 'lib/first.dart',
              oldPath: 'lib/first.dart',
              newPath: 'lib/first.dart',
              changeType: GitDiffChangeType.modified,
              additions: 1,
              deletions: 1,
              isBinary: false,
            ),
            GitDiffFileSummaryDto(
              path: 'lib/second.dart',
              oldPath: 'lib/second.dart',
              newPath: 'lib/second.dart',
              changeType: GitDiffChangeType.modified,
              additions: 1,
              deletions: 1,
              isBinary: false,
            ),
          ],
          unifiedDiff: '''
diff --git a/lib/first.dart b/lib/first.dart
index 1111111..2222222 100644
--- a/lib/first.dart
+++ b/lib/first.dart
@@ -1 +1 @@
-oldFirst
+newFirst
diff --git a/lib/second.dart b/lib/second.dart
index 3333333..4444444 100644
--- a/lib/second.dart
+++ b/lib/second.dart
@@ -1 +1 @@
-oldSecond
+newSecond
''',
        ),
      },
    );

    await tester.pumpWidget(
      _buildTestApp(bridgeApi: bridgeApi, liveStream: FakeThreadLiveStream()),
    );
    await tester.pumpAndSettle();

    expect(find.text('first.dart'), findsOneWidget);
    expect(find.text('second.dart'), findsOneWidget);
    expect(_findRichTextContaining('newFirst'), findsOneWidget);
    expect(_findRichTextContaining('newSecond'), findsOneWidget);
  });

  testWidgets('changed rows span the full diff width instead of text width', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(480, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final bridgeApi = FakeThreadDiffBridgeApi(
      diffsByMode: <ThreadGitDiffMode, ThreadGitDiffDto>{
        ThreadGitDiffMode.workspace: _buildDiffDto(
          mode: ThreadGitDiffMode.workspace,
          files: const <GitDiffFileSummaryDto>[
            GitDiffFileSummaryDto(
              path: 'lib/highlight.dart',
              oldPath: 'lib/highlight.dart',
              newPath: 'lib/highlight.dart',
              changeType: GitDiffChangeType.modified,
              additions: 2,
              deletions: 0,
              isBinary: false,
            ),
          ],
          unifiedDiff: '''
diff --git a/lib/highlight.dart b/lib/highlight.dart
index 1111111..2222222 100644
--- a/lib/highlight.dart
+++ b/lib/highlight.dart
@@ -1,0 +1,2 @@
+tiny
+thisIsAnIntentionallyVeryLongChangedLineThatShouldDriveTheSharedRowWidthAcrossTheWholeCodePane
''',
        ),
      },
    );

    await tester.pumpWidget(
      _buildTestApp(bridgeApi: bridgeApi, liveStream: FakeThreadLiveStream()),
    );
    await tester.pumpAndSettle();

    final firstRow = find.byKey(const Key('thread-diff-line-highlight.dart-0'));
    final secondRow = find.byKey(
      const Key('thread-diff-line-highlight.dart-1'),
    );

    expect(firstRow, findsOneWidget);
    expect(secondRow, findsOneWidget);
    expect(tester.getSize(firstRow).width, tester.getSize(secondRow).width);
  });

  testWidgets('builds off-screen diff files lazily as the list scrolls', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(480, 420));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final files = List<GitDiffFileSummaryDto>.generate(40, (index) {
      final path = 'lib/file_$index.dart';
      return GitDiffFileSummaryDto(
        path: path,
        oldPath: path,
        newPath: path,
        changeType: GitDiffChangeType.modified,
        additions: 1,
        deletions: 1,
        isBinary: false,
      );
    });
    final unifiedDiff = List<String>.generate(40, (index) {
      final path = 'lib/file_$index.dart';
      return '''
diff --git a/$path b/$path
index 1111111..2222222 100644
--- a/$path
+++ b/$path
@@ -1 +1 @@
-old$index
+new$index
''';
    }).join();
    final bridgeApi = FakeThreadDiffBridgeApi(
      diffsByMode: <ThreadGitDiffMode, ThreadGitDiffDto>{
        ThreadGitDiffMode.workspace: _buildDiffDto(
          mode: ThreadGitDiffMode.workspace,
          files: files,
          unifiedDiff: unifiedDiff,
        ),
      },
    );

    await tester.pumpWidget(
      _buildTestApp(bridgeApi: bridgeApi, liveStream: FakeThreadLiveStream()),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('thread-git-diff-file-file_0.dart')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('thread-git-diff-file-file_39.dart')),
      findsNothing,
    );

    await tester.scrollUntilVisible(
      find.byKey(const Key('thread-git-diff-file-file_39.dart')),
      500,
      scrollable: find
          .descendant(
            of: find.byKey(const Key('thread-git-diff-list')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('thread-git-diff-file-file_39.dart')),
      findsOneWidget,
    );
  });

  testWidgets(
    'clears stale workspace diff when latest thread change is empty',
    (tester) async {
      final bridgeApi = FakeThreadDiffBridgeApi(
        diffsByMode: <ThreadGitDiffMode, ThreadGitDiffDto>{
          ThreadGitDiffMode.workspace: _buildDiffDto(
            mode: ThreadGitDiffMode.workspace,
            files: const <GitDiffFileSummaryDto>[
              GitDiffFileSummaryDto(
                path: 'lib/workspace.dart',
                oldPath: 'lib/workspace.dart',
                newPath: 'lib/workspace.dart',
                changeType: GitDiffChangeType.modified,
                additions: 1,
                deletions: 1,
                isBinary: false,
              ),
            ],
            unifiedDiff: '''
diff --git a/lib/workspace.dart b/lib/workspace.dart
index 1111111..2222222 100644
--- a/lib/workspace.dart
+++ b/lib/workspace.dart
@@ -1 +1 @@
-oldWorkspace
+workspaceOnly
''',
          ),
          ThreadGitDiffMode.latestThreadChange: _buildDiffDto(
            mode: ThreadGitDiffMode.latestThreadChange,
            files: const <GitDiffFileSummaryDto>[],
            unifiedDiff: '',
          ),
        },
      );

      await tester.pumpWidget(
        _buildTestApp(bridgeApi: bridgeApi, liveStream: FakeThreadLiveStream()),
      );
      await tester.pumpAndSettle();

      expect(_findRichTextContaining('workspaceOnly'), findsOneWidget);

      await tester.tap(find.text('Latest thread change'));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(
        find.text('This thread does not have a resolved diff yet.'),
        findsOneWidget,
      );
      expect(_findRichTextContaining('workspaceOnly'), findsNothing);
    },
  );
}

Widget _buildTestApp({
  required ThreadDiffBridgeApi bridgeApi,
  required ThreadLiveStream liveStream,
  Widget? child,
}) {
  return ProviderScope(
    overrides: <Override>[
      threadDiffBridgeApiProvider.overrideWithValue(bridgeApi),
      threadLiveStreamProvider.overrideWithValue(liveStream),
    ],
    child: MaterialApp(
      home: Scaffold(
        body:
            child ??
            const ThreadGitDiffPane(
              bridgeApiBaseUrl: 'http://127.0.0.1:33210',
              threadId: 'thread-123',
            ),
      ),
    ),
  );
}

ThreadGitDiffDto _buildDiffDto({
  required ThreadGitDiffMode mode,
  required List<GitDiffFileSummaryDto> files,
  required String unifiedDiff,
}) {
  return ThreadGitDiffDto(
    contractVersion: contractVersion,
    thread: const ThreadDetailDto(
      contractVersion: contractVersion,
      threadId: 'thread-123',
      title: 'Git diff test',
      status: ThreadStatus.idle,
      workspace: '/workspace/repo',
      repository: 'repo',
      branch: 'main',
      createdAt: '2026-03-23T08:00:00.000Z',
      updatedAt: '2026-03-23T08:00:00.000Z',
      source: 'vscode',
      accessMode: AccessMode.controlWithApprovals,
      lastTurnSummary: 'summary',
    ),
    repository: const ThreadGitStatusDto(
      workspace: '/workspace/repo',
      repository: 'repo',
      branch: 'main',
      dirty: true,
      aheadBy: 0,
      behindBy: 0,
    ),
    mode: mode,
    files: files,
    unifiedDiff: unifiedDiff,
    fetchedAt: '2026-03-23T08:00:00.000Z',
  );
}

class FakeThreadDiffBridgeApi implements ThreadDiffBridgeApi {
  FakeThreadDiffBridgeApi({required this.diffsByMode});

  final Map<ThreadGitDiffMode, ThreadGitDiffDto> diffsByMode;

  @override
  Future<ThreadGitDiffDto> fetchThreadGitDiff({
    required String bridgeApiBaseUrl,
    required String threadId,
    required ThreadGitDiffMode mode,
    String? path,
  }) async {
    final diff = diffsByMode[mode];
    if (diff == null) {
      throw const ThreadGitDiffBridgeException(
        message: 'Missing fake git diff response.',
      );
    }
    return diff;
  }
}

class FakeThreadLiveStream implements ThreadLiveStream {
  @override
  Future<ThreadLiveSubscription> subscribe({
    required String bridgeApiBaseUrl,
    String? threadId,
  }) async {
    final controller =
        StreamController<BridgeEventEnvelope<Map<String, dynamic>>>();
    return ThreadLiveSubscription(
      events: controller.stream,
      close: () async {
        if (!controller.isClosed) {
          await controller.close();
        }
      },
    );
  }
}

Finder _findRichTextContaining(String text) {
  return find.byWidgetPredicate(
    (widget) => widget is RichText && widget.text.toPlainText().contains(text),
  );
}
