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
import 'package:vibe_bridge/features/threads/domain/thread_activity_item.dart';
import 'package:vibe_bridge/features/threads/presentation/thread_list_page.dart';
import 'package:vibe_bridge/foundation/contracts/bridge_contracts.dart';
import 'package:vibe_bridge/foundation/storage/secure_store.dart';
import 'package:vibe_bridge/foundation/storage/secure_store_provider.dart';

const String _probeFilePath = 'apps/mobile/lib/live_approval_probe.dart';
const String _probeColorBlue = 'Color(0xFF2563EB)';
const String _probeColorOrange = 'Color(0xFFF97316)';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'real bridge Claude Code edit shows provider approval and resumes after in-app selection',
    (tester) async {
      final bridgeApiBaseUrl = _resolveBridgeApiBaseUrl();
      await _requireAndroidLoopbackDevice(bridgeApiBaseUrl);
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
        _buildProbePrompt(),
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

      await _pumpUntilFound(
        tester,
        find.byKey(const Key('turn-composer-approval-card')),
        timeout: const Duration(seconds: 90),
      );
      expect(find.byKey(const Key('turn-composer-input')), findsNothing);
      expect(find.byKey(const Key('turn-composer-submit')), findsNothing);
      await _approvePendingProviderPrompt(
        tester,
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        threadId: createdThreadId,
      );

      await _waitForProbeFileChange(
        tester: tester,
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        threadId: createdThreadId,
        probeFilePath: _probeFilePath,
      );
      await _waitForTimelineFileChangeItem(
        tester,
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        threadId: createdThreadId,
        probeFilePath: _probeFilePath,
      );

      debugPrint(
        'LIVE_CLAUDE_APPROVAL_EDIT_RESULT '
        'thread_id=$createdThreadId '
        'workspace=$workspacePath '
        'probe_file=$_probeFilePath',
      );
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );
}

String _buildProbePrompt() {
  return 'Edit only $_probeFilePath. '
      'Toggle liveApprovalProbeIconColor between $_probeColorBlue and $_probeColorOrange, '
      'choosing whichever value is not currently set. '
      'Do not modify any other files. '
      'Reply with the final color value you set.';
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

Future<void> _requireAndroidLoopbackDevice(String bridgeApiBaseUrl) async {
  if (!Platform.isAndroid) {
    fail(
      'This live bridge integration test only supports Android devices. '
      'Run it with `flutter test integration_test/live_claude_code_approval_edit_test.dart -d <android-device-id>`.',
    );
  }

  final androidInfo = await DeviceInfoPlugin().androidInfo;
  if (androidInfo.isPhysicalDevice &&
      !_usesLoopbackBridgeUrl(bridgeApiBaseUrl)) {
    fail(
      'This live bridge integration test only supports physical Android devices '
      'when the bridge URL is loopback-backed via `adb reverse`, for example '
      '`http://127.0.0.1:3310`.',
    );
  }
}

bool _usesLoopbackBridgeUrl(String bridgeApiBaseUrl) {
  final uri = Uri.tryParse(bridgeApiBaseUrl);
  final host = uri?.host.trim().toLowerCase() ?? '';
  return host == '127.0.0.1' || host == 'localhost';
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

Future<void> _waitForProbeFileChange({
  required WidgetTester tester,
  required String bridgeApiBaseUrl,
  required String threadId,
  required String probeFilePath,
  Duration timeout = const Duration(minutes: 2),
}) async {
  final deadline = DateTime.now().add(timeout);

  while (DateTime.now().isBefore(deadline)) {
    await _approveFollowupPromptIfVisible(
      tester,
      bridgeApiBaseUrl: bridgeApiBaseUrl,
      threadId: threadId,
    );

    final snapshot = await _fetchThreadSnapshotJson(
      bridgeApiBaseUrl: bridgeApiBaseUrl,
      threadId: threadId,
    );
    final entries = snapshot['entries'];
    if (entries is List<dynamic>) {
      for (final rawEntry in entries) {
        if (rawEntry is! Map<String, dynamic>) {
          continue;
        }
        final kind = rawEntry['kind'];
        if (kind != BridgeEventKind.fileChange.wireValue) {
          continue;
        }
        final payload = rawEntry['payload'];
        if (payload is! Map<String, dynamic>) {
          continue;
        }
        final path = _extractFileChangePath(payload);
        if (path is String && path.trim().endsWith(probeFilePath)) {
          return;
        }
      }
    }

    final thread = snapshot['thread'];
    if (thread is Map<String, dynamic>) {
      final rawStatus = thread['status'];
      if (rawStatus == ThreadStatus.failed.wireValue) {
        fail(
          'Claude Code thread $threadId failed before editing $probeFilePath.',
        );
      }
    }

    await tester.pump(const Duration(milliseconds: 400));
  }

  fail(
    'Timed out waiting for Claude Code to report a file change for $probeFilePath.',
  );
}

Future<void> _waitForTimelineFileChangeItem(
  WidgetTester tester, {
  required String bridgeApiBaseUrl,
  required String threadId,
  required String probeFilePath,
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
    final hasProbeFileChange = state.visibleItems.any((item) {
      if (item.type != ThreadActivityItemType.fileChange) {
        return false;
      }
      final path = _extractFileChangePath(item.payload);
      return path != null && path.trim().endsWith(probeFilePath);
    });
    if (hasProbeFileChange) {
      return;
    }
    await tester.pump(const Duration(milliseconds: 200));
  }

  fail(
    'Timed out waiting for the thread timeline to surface a file change for $probeFilePath.',
  );
}

String? _extractFileChangePath(Map<String, dynamic> payload) {
  final directPath =
      payload['path'] ?? payload['file_path'] ?? payload['filePath'];
  if (directPath is String && directPath.trim().isNotEmpty) {
    return directPath;
  }

  final input = payload['input'];
  if (input is Map<String, dynamic>) {
    final inputPath = input['path'] ?? input['file_path'] ?? input['filePath'];
    if (inputPath is String && inputPath.trim().isNotEmpty) {
      return inputPath;
    }
  }

  final toolUseResult = payload['tool_use_result'];
  if (toolUseResult is Map<String, dynamic>) {
    final resultPath =
        toolUseResult['path'] ??
        toolUseResult['file_path'] ??
        toolUseResult['filePath'];
    if (resultPath is String && resultPath.trim().isNotEmpty) {
      return resultPath;
    }
  }

  return null;
}

Future<void> _approvePendingProviderPrompt(
  WidgetTester tester, {
  required String bridgeApiBaseUrl,
  required String threadId,
  Duration timeout = const Duration(seconds: 20),
}) async {
  final optionFinder = find.byKey(
    const Key('turn-composer-approval-option-allow_for_session'),
  );
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (optionFinder.evaluate().isEmpty) {
      await _pumpUntilFound(tester, optionFinder, timeout: timeout);
    }

    _tryHideTestKeyboard(tester);
    await tester.pump(const Duration(milliseconds: 150));
    await tester.tap(optionFinder, warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 250));

    final snapshot = await _fetchThreadSnapshotJson(
      bridgeApiBaseUrl: bridgeApiBaseUrl,
      threadId: threadId,
    );
    if (snapshot['pending_user_input'] == null) {
      return;
    }
    await tester.pump(const Duration(milliseconds: 500));
  }

  fail('Timed out waiting for provider approval to resolve for $threadId.');
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

Future<void> _approveFollowupPromptIfVisible(
  WidgetTester tester, {
  required String bridgeApiBaseUrl,
  required String threadId,
}) async {
  final approvalOption = find.byKey(
    const Key('turn-composer-approval-option-allow_for_session'),
  );
  if (approvalOption.evaluate().isEmpty) {
    return;
  }

  await tester.tap(approvalOption, warnIfMissed: false);
  await tester.pump(const Duration(milliseconds: 250));

  final snapshot = await _fetchThreadSnapshotJson(
    bridgeApiBaseUrl: bridgeApiBaseUrl,
    threadId: threadId,
  );
  if (snapshot['pending_user_input'] != null) {
    await tester.pump(const Duration(milliseconds: 200));
  }
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
