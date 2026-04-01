import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
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
    'real bridge Claude Code thread generates a non-placeholder title',
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

      await _openComposerModelSheet(tester);
      await _pumpUntilFound(
        tester,
        find.byKey(const Key('turn-composer-provider-option-claude_code')),
      );
      await tester.tap(
        find.byKey(const Key('turn-composer-provider-option-claude_code')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('turn-composer-model-sheet-close')),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('turn-composer-input')),
        _buildTitleProbePrompt(),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('turn-composer-submit')));
      await tester.pump();
      _tryHideTestKeyboard(tester);
      await tester.pumpAndSettle();

      final createdThreadId = await _waitForSelectedThreadId(
        tester,
        bridgeApiBaseUrl,
        expectedPrefix: 'claude:',
        timeout: const Duration(seconds: 25),
      );

      final generatedTitle = await _waitForGeneratedThreadTitle(
        tester: tester,
        threadListApi: threadListApi,
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        threadId: createdThreadId,
      );

      await _pumpUntilThreadDetailTitle(
        tester,
        expectedTitle: generatedTitle,
        timeout: const Duration(seconds: 30),
      );

      expect(generatedTitle.length, lessThanOrEqualTo(80));
      expect(generatedTitle.toLowerCase(), contains('titl'));
      expect(
        generatedTitle.toLowerCase(),
        anyOf(contains('mobile'), contains('triage')),
      );

      debugPrint(
        'LIVE_CLAUDE_TITLE_RESULT '
        'thread_id=$createdThreadId '
        'title=$generatedTitle '
        'workspace=$workspacePath',
      );
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

String _buildTitleProbePrompt() {
  return 'Explain why thread titles help mobile triage. '
      'Do not use tools, do not edit files, and do not ask for approval.';
}

String _resolveBridgeApiBaseUrl() {
  const configured = String.fromEnvironment(
    'LIVE_CLAUDE_APPROVAL_BRIDGE_BASE_URL',
  );
  if (configured.isNotEmpty) {
    return configured;
  }

  return 'http://10.0.2.2:3110';
}

String _resolveWorkspacePath() {
  const configured = String.fromEnvironment('LIVE_CLAUDE_APPROVAL_WORKSPACE');
  if (configured.isNotEmpty) {
    return configured;
  }

  return '/Users/lubomirmolin/PhpstormProjects/codex-mobile-companion';
}

Future<void> _requireAndroidEmulator() async {
  if (!Platform.isAndroid) {
    fail(
      'This live bridge integration test only supports Android emulators. '
      'Run it with `flutter drive --driver=test_driver/integration_test.dart --target=integration_test/live_claude_code_title_generation_test.dart -d <android-emulator-id>`.',
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

Future<void> _openComposerModelSheet(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('thread-detail-settings-toggle')));
  await tester.pumpAndSettle();
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

Future<String> _waitForGeneratedThreadTitle({
  required WidgetTester tester,
  required HttpThreadListBridgeApi threadListApi,
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

    final rawStatus = thread['status'];
    if (rawStatus == ThreadStatus.failed.wireValue) {
      fail('Claude Code thread $threadId failed before generating a title.');
    }

    if (snapshot['pending_user_input'] != null) {
      fail(
        'Claude Code thread $threadId unexpectedly requested approval during title generation.',
      );
    }

    final snapshotTitle = (thread['title'] as String?)?.trim() ?? '';
    final threads = await threadListApi.fetchThreads(
      bridgeApiBaseUrl: bridgeApiBaseUrl,
    );
    final matchingSummary = threads.where(
      (thread) => thread.threadId == threadId,
    );
    final summaryTitle = matchingSummary.isEmpty
        ? ''
        : matchingSummary.first.title.trim();

    if (!_isPlaceholderThreadTitle(snapshotTitle) &&
        snapshotTitle == summaryTitle) {
      return snapshotTitle;
    }

    await tester.pump(const Duration(milliseconds: 400));
  }

  fail('Timed out waiting for Claude Code to publish a generated title.');
}

bool _isPlaceholderThreadTitle(String title) {
  final normalized = title.trim().toLowerCase();
  return normalized.isEmpty ||
      normalized == 'untitled thread' ||
      normalized == 'new thread' ||
      normalized == 'fresh session';
}

Future<void> _pumpUntilThreadDetailTitle(
  WidgetTester tester, {
  required String expectedTitle,
  Duration timeout = const Duration(seconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);

  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    final titleFinder = find.byKey(const Key('thread-detail-title'));
    if (titleFinder.evaluate().isEmpty) {
      continue;
    }
    final renderedTitle = tester.widget<Text>(titleFinder).data?.trim() ?? '';
    if (renderedTitle == expectedTitle) {
      return;
    }
  }

  fail('Timed out waiting for thread detail title `$expectedTitle`.');
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
    final body = await response.transform(SystemEncoding().decoder).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      fail(
        'Snapshot request for $threadId failed with status ${response.statusCode}: $body',
      );
    }
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      fail('Expected snapshot JSON object for $threadId, got: $decoded');
    }
    return decoded;
  } finally {
    client.close();
  }
}

Uri _buildBridgeUri(String baseUrl, String routePath) {
  final baseUri = Uri.parse(baseUrl);
  final normalizedBasePath = baseUri.path.endsWith('/')
      ? baseUri.path.substring(0, baseUri.path.length - 1)
      : baseUri.path;
  final normalizedRoute = routePath.startsWith('/') ? routePath : '/$routePath';
  final fullPath =
      '${normalizedBasePath.isEmpty ? '' : normalizedBasePath}$normalizedRoute';
  return baseUri.replace(path: fullPath, queryParameters: null);
}

void _tryHideTestKeyboard(WidgetTester tester) {
  try {
    tester.testTextInput.hide();
  } catch (_) {
    // The integration harness may not have a registered fake keyboard.
  }
}

Future<void> _pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 12),
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
