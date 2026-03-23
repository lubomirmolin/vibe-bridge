import 'dart:async';

import 'package:codex_mobile_companion/features/threads/data/thread_diff_bridge_api.dart';
import 'package:codex_mobile_companion/features/threads/data/thread_live_stream.dart';
import 'package:codex_mobile_companion/features/threads/presentation/thread_git_diff_page.dart';
import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
}) {
  return ProviderScope(
    overrides: <Override>[
      threadDiffBridgeApiProvider.overrideWithValue(bridgeApi),
      threadLiveStreamProvider.overrideWithValue(liveStream),
    ],
    child: const MaterialApp(
      home: Scaffold(
        body: ThreadGitDiffPane(
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
