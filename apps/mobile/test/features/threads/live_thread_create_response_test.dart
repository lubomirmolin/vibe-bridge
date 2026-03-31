import 'dart:io';

import 'package:vibe_bridge/features/threads/data/thread_detail_bridge_api.dart';
import 'package:vibe_bridge/features/threads/data/thread_list_bridge_api.dart';
import 'package:vibe_bridge/foundation/contracts/bridge_contracts.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'live create-thread returns a real snapshot from the bridge',
    () async {
      final previousOverrides = HttpOverrides.current;
      HttpOverrides.global = _PassthroughHttpOverrides();
      addTearDown(() {
        HttpOverrides.global = previousOverrides;
      });

      final bridgeApiBaseUrl = _resolveBridgeApiBaseUrl();
      final listApi = HttpThreadListBridgeApi();
      final detailApi = HttpThreadDetailBridgeApi();

      final threads = await listApi
          .fetchThreads(bridgeApiBaseUrl: bridgeApiBaseUrl)
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => throw TestFailure(
              'Timed out loading /threads from $bridgeApiBaseUrl.',
            ),
          );

      final workspace = threads
          .map((thread) => thread.workspace.trim())
          .firstWhere((workspace) => workspace.isNotEmpty, orElse: () => '');
      if (workspace.isEmpty) {
        fail('Live bridge did not expose any thread workspace to clone.');
      }

      final snapshot = await detailApi
          .createThread(
            bridgeApiBaseUrl: bridgeApiBaseUrl,
            workspace: workspace,
            provider: ProviderKind.codex,
          )
          .timeout(
            const Duration(seconds: 15),
            onTimeout: () => throw TestFailure(
              'Timed out waiting for POST /threads to return from '
              '$bridgeApiBaseUrl for workspace $workspace.',
            ),
          );

      final createdThreadId = snapshot.thread.threadId.trim();
      expect(createdThreadId, isNotEmpty);
      expect(snapshot.thread.workspace.trim(), workspace);
      expect(snapshot.thread.createdAt.trim(), isNotEmpty);
      expect(snapshot.thread.updatedAt.trim(), isNotEmpty);

      final detail = await detailApi
          .fetchThreadDetail(
            bridgeApiBaseUrl: bridgeApiBaseUrl,
            threadId: createdThreadId,
          )
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => throw TestFailure(
              'Timed out loading /threads/$createdThreadId/snapshot from '
              '$bridgeApiBaseUrl after createThread succeeded.',
            ),
          );
      expect(detail.threadId, createdThreadId);
      expect(detail.workspace.trim(), workspace);

      final timelinePage = await detailApi
          .fetchThreadTimelinePage(
            bridgeApiBaseUrl: bridgeApiBaseUrl,
            threadId: createdThreadId,
            limit: 1,
          )
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => throw TestFailure(
              'Timed out loading /threads/$createdThreadId/history from '
              '$bridgeApiBaseUrl after createThread succeeded.',
            ),
          );
      expect(timelinePage.thread.threadId, createdThreadId);

      debugPrint(
        'LIVE_THREAD_CREATE_RESPONSE '
        'bridge=$bridgeApiBaseUrl '
        'workspace=$workspace '
        'thread_id=$createdThreadId '
        'entry_count=${snapshot.entries.length} '
        'timeline_count=${timelinePage.entries.length}',
      );
    },
    skip: !_runLiveThreadCreateResponseTest(),
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

class _PassthroughHttpOverrides extends HttpOverrides {}

String _resolveBridgeApiBaseUrl() {
  const configured = String.fromEnvironment(
    'LIVE_THREAD_CREATE_BRIDGE_BASE_URL',
  );
  if (configured.isNotEmpty) {
    return configured;
  }

  if (Platform.isAndroid) {
    return 'http://10.0.2.2:3110';
  }

  return 'http://127.0.0.1:3110';
}

bool _runLiveThreadCreateResponseTest() {
  return const bool.fromEnvironment('RUN_LIVE_THREAD_CREATE_RESPONSE_TEST');
}
