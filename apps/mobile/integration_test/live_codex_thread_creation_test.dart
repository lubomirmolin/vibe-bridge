import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vibe_bridge/features/threads/application/thread_detail_controller.dart';
import 'package:vibe_bridge/features/threads/application/thread_list_controller.dart';
import 'package:vibe_bridge/features/threads/data/thread_detail_bridge_api.dart';
import 'package:vibe_bridge/features/threads/data/thread_list_bridge_api.dart';
import 'package:vibe_bridge/features/threads/presentation/thread_list_page.dart';
import 'package:vibe_bridge/foundation/contracts/bridge_contracts.dart';
import 'package:vibe_bridge/foundation/storage/secure_store.dart';
import 'package:vibe_bridge/foundation/storage/secure_store_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'real bridge Codex thread creation settles and completes the first turn',
    (tester) async {
      await _requireAndroidEmulator();

      final bridgeApiBaseUrl = _resolveBridgeApiBaseUrl();
      final workspacePath = _resolveWorkspacePath();
      final threadApi = HttpThreadDetailBridgeApi();
      final threadListApi = HttpThreadListBridgeApi();

      await _ensureWorkspaceAvailable(
        threadApi: threadApi,
        threadListApi: threadListApi,
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        workspacePath: workspacePath,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appSecureStoreProvider.overrideWithValue(InMemorySecureStore()),
          ],
          child: MaterialApp(
            home: ThreadListPage(
              bridgeApiBaseUrl: bridgeApiBaseUrl,
              autoOpenPreviouslySelectedThread: false,
            ),
          ),
        ),
      );

      await _pumpUntilFound(
        tester,
        find.byKey(const Key('thread-list-create-button')),
        timeout: const Duration(seconds: 20),
      );

      await tester.tap(find.byKey(const Key('thread-list-create-button')));
      await tester.pumpAndSettle();

      await _selectWorkspaceForDraft(tester, workspacePath: workspacePath);
      await _pumpUntilFound(
        tester,
        find.byKey(const Key('thread-draft-title')),
        timeout: const Duration(seconds: 12),
      );

      await tester.enterText(
        find.byKey(const Key('turn-composer-input')),
        _buildCodexProbePrompt(),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('turn-composer-submit')));
      await tester.pump();
      _tryHideTestKeyboard(tester);
      await tester.pumpAndSettle();

      final createdThreadId = await _waitForSelectedThreadId(
        tester,
        bridgeApiBaseUrl,
        expectedPrefix: 'codex:',
        timeout: const Duration(seconds: 25),
      );

      await _waitForThreadControllerToSettle(
        tester,
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        threadId: createdThreadId,
      );
      await _waitForCodexTurnCompletion(
        tester,
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        threadId: createdThreadId,
      );

      expect(
        find.byKey(const Key('thread-detail-session-content')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('thread-detail-title')), findsOneWidget);

      debugPrint(
        'LIVE_CODEX_THREAD_CREATION_RESULT '
        'thread_id=$createdThreadId '
        'workspace=$workspacePath',
      );
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );
}

String _buildCodexProbePrompt() {
  return 'Reply with the exact word READY. '
      'Do not use tools, do not edit files, and do not ask for approval.';
}

String _resolveBridgeApiBaseUrl() {
  const configured = String.fromEnvironment(
    'LIVE_CODEX_THREAD_CREATION_BRIDGE_BASE_URL',
  );
  if (configured.isNotEmpty) {
    return configured;
  }

  return 'http://10.0.2.2:3110';
}

String _resolveWorkspacePath() {
  const configured = String.fromEnvironment(
    'LIVE_CODEX_THREAD_CREATION_WORKSPACE',
  );
  if (configured.isNotEmpty) {
    return configured;
  }

  return '/Users/lubomirmolin/PhpstormProjects/codex-mobile-companion';
}

Future<void> _requireAndroidEmulator() async {
  if (!Platform.isAndroid) {
    fail(
      'This live bridge integration test only supports Android emulators. '
      'Run it with `flutter drive --driver=test_driver/integration_test.dart --target=integration_test/live_codex_thread_creation_test.dart -d <android-emulator-id>`.',
    );
  }

  final androidInfo = await DeviceInfoPlugin().androidInfo;
  if (androidInfo.isPhysicalDevice) {
    fail(
      'This live bridge integration test only supports Android emulators. '
      'Physical Android devices cannot reach the default emulator bridge host '
      '`http://10.0.2.2:3110`.',
    );
  }
}

Future<void> _ensureWorkspaceAvailable({
  required HttpThreadDetailBridgeApi threadApi,
  required HttpThreadListBridgeApi threadListApi,
  required String bridgeApiBaseUrl,
  required String workspacePath,
}) async {
  final threads = await threadListApi.fetchThreads(
    bridgeApiBaseUrl: bridgeApiBaseUrl,
  );
  final hasWorkspace = threads.any(
    (thread) => thread.workspace.trim() == workspacePath,
  );
  if (hasWorkspace) {
    return;
  }

  await threadApi.createThread(
    bridgeApiBaseUrl: bridgeApiBaseUrl,
    workspace: workspacePath,
    provider: ProviderKind.codex,
  );
}

Future<void> _selectWorkspaceForDraft(
  WidgetTester tester, {
  required String workspacePath,
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  final preferredOption = find.byKey(
    Key('thread-list-workspace-option-$workspacePath'),
  );

  while (DateTime.now().isBefore(deadline)) {
    if (find.byKey(const Key('thread-draft-title')).evaluate().isNotEmpty) {
      return;
    }

    if (preferredOption.evaluate().isNotEmpty) {
      await tester.tap(preferredOption);
      await tester.pumpAndSettle();
      return;
    }

    final anyWorkspaceOption = find.byWidgetPredicate((widget) {
      return widget.key is Key &&
          (widget.key as Key).toString().contains(
            'thread-list-workspace-option-',
          );
    });
    if (anyWorkspaceOption.evaluate().isNotEmpty) {
      await tester.tap(anyWorkspaceOption.first);
      await tester.pumpAndSettle();
      return;
    }

    await tester.pump(const Duration(milliseconds: 150));
  }

  fail('Timed out waiting for draft workspace selection or direct draft open.');
}

Future<String> _waitForSelectedThreadId(
  WidgetTester tester,
  String bridgeApiBaseUrl, {
  String? expectedPrefix,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final container = ProviderScope.containerOf(
    tester.element(find.byType(MaterialApp)),
  );
  final deadline = DateTime.now().add(timeout);

  while (DateTime.now().isBefore(deadline)) {
    final state = container.read(
      threadListControllerProvider(bridgeApiBaseUrl),
    );
    final selectedThreadId = state.selectedThreadId?.trim();
    if (selectedThreadId != null &&
        selectedThreadId.isNotEmpty &&
        (expectedPrefix == null ||
            selectedThreadId.startsWith(expectedPrefix))) {
      return selectedThreadId;
    }
    await tester.pump(const Duration(milliseconds: 150));
  }

  fail(
    'Timed out waiting for selected thread id'
    '${expectedPrefix == null ? '' : ' with prefix $expectedPrefix'}.',
  );
}

Future<void> _waitForThreadControllerToSettle(
  WidgetTester tester, {
  required String bridgeApiBaseUrl,
  required String threadId,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final args = ThreadDetailControllerArgs(
    bridgeApiBaseUrl: bridgeApiBaseUrl,
    threadId: threadId,
  );
  final container = ProviderScope.containerOf(
    tester.element(find.byType(MaterialApp)),
  );
  final deadline = DateTime.now().add(timeout);

  while (DateTime.now().isBefore(deadline)) {
    final state = container.read(threadDetailControllerProvider(args));
    if (!state.isLoading &&
        state.hasThread &&
        !state.isComposerMutationInFlight) {
      return;
    }
    await tester.pump(const Duration(milliseconds: 200));
  }

  final state = container.read(threadDetailControllerProvider(args));
  fail(
    'Timed out waiting for thread detail controller to settle for $threadId. '
    'isLoading=${state.isLoading} '
    'hasThread=${state.hasThread} '
    'isComposerMutationInFlight=${state.isComposerMutationInFlight} '
    'status=${state.thread?.status.wireValue}',
  );
}

Future<void> _waitForCodexTurnCompletion(
  WidgetTester tester, {
  required String bridgeApiBaseUrl,
  required String threadId,
  Duration timeout = const Duration(minutes: 2),
}) async {
  final deadline = DateTime.now().add(timeout);

  while (DateTime.now().isBefore(deadline)) {
    final snapshot = await _fetchThreadSnapshotJson(
      bridgeApiBaseUrl: bridgeApiBaseUrl,
      threadId: threadId,
    );
    final thread = snapshot['thread'];
    if (thread is! Map<String, dynamic>) {
      fail('Expected thread payload for $threadId, got $thread');
    }

    final rawStatus = (thread['status'] as String?)?.trim() ?? '';
    if (rawStatus == ThreadStatus.completed.wireValue) {
      return;
    }
    if (rawStatus == ThreadStatus.failed.wireValue) {
      fail('Codex thread $threadId failed during initial turn.');
    }
    if (rawStatus == ThreadStatus.interrupted.wireValue) {
      fail('Codex thread $threadId was interrupted during initial turn.');
    }

    if (snapshot['pending_user_input'] != null) {
      fail(
        'Codex thread $threadId unexpectedly requested user input during initial turn.',
      );
    }

    await tester.pump(const Duration(milliseconds: 400));
  }

  fail(
    'Timed out waiting for Codex thread $threadId to complete its first turn.',
  );
}

Future<Map<String, dynamic>> _fetchThreadSnapshotJson({
  required String bridgeApiBaseUrl,
  required String threadId,
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final request = await client.getUrl(
      _buildBridgeUri(bridgeApiBaseUrl, '/threads/$threadId/snapshot'),
    );
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final response = await request.close();
    final body = await utf8.decoder.bind(response).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      fail(
        'Snapshot request for $threadId failed with ${response.statusCode}: $body',
      );
    }
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      fail('Snapshot response for $threadId was not a JSON object: $decoded');
    }
    return decoded;
  } finally {
    client.close(force: true);
  }
}

Uri _buildBridgeUri(String baseUrl, String path) {
  final baseUri = Uri.parse(baseUrl);
  final normalizedBasePath = baseUri.path.endsWith('/')
      ? baseUri.path.substring(0, baseUri.path.length - 1)
      : baseUri.path;
  final normalizedPath = path.startsWith('/') ? path : '/$path';
  return baseUri.replace(
    path:
        '${normalizedBasePath.isEmpty ? '' : normalizedBasePath}$normalizedPath',
  );
}

Future<void> _pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isNotEmpty) {
      return;
    }
  }

  fail('Timed out waiting for finder: $finder');
}

void _tryHideTestKeyboard(WidgetTester tester) {
  final dynamic binding = tester.binding;
  try {
    binding.testTextInput.hide();
  } catch (_) {
    // Ignore keyboard teardown failures on emulator runs.
  }
}
