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

import 'support/live_codex_turn_wait.dart';

const String _exactPrompt = '''
1. Make one per-thread reducer the only writer.
     Every source should enqueue RawThreadEvent { source, thread_id, turn_id, item_id, phase, payload }.
     Only one async task per thread is allowed to update projection state or publish UI events.
  2. Split live from authoritative.
     For each item, keep:

  - live_buffer
  - final_item
  - repair_snapshot
    item/agentMessage/delta updates live_buffer.
    item/completed sets final_item.
    Snapshots/archive only backfill missing data, never rewrite an active item.

  3. Define hard source precedence.
     During an active bridge-owned turn:

  - app-server delta: allowed for live text
  - app-server item/completed: authoritative
  - desktop IPC: supplemental only, must not rewrite message text
  - snapshot/reconcile: repair-only, no live text rewrites
    That removes “sent but no response” cases caused by competing sources.

  4. Turn outgoing user input into an explicit state machine.
     queued -> turn_start_acked -> user_item_seen -> first_assistant_signal -> completed/timeout
     If a send stalls, you know which transition failed instead of just “message got lost”.
  5. Remove Handle::block_on callback chains from the hot path.
     I can’t prove that is your Tokio stack overflow without the trace, but crates/bridge-core/src/server/state.rs is doing enough cross-thread / callback / block_on orchestration that I would treat it as the prime suspect. Push
     everything through channels instead. ~ do you think this is a good plan
''';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'real bridge Codex exact prompt probe completes first turn',
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

      await tester.enterText(
        find.byKey(const Key('turn-composer-input')),
        _exactPrompt,
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

      await waitForCodexTurnCompletion(
        tester,
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        threadId: createdThreadId,
        promptLabel: 'exact',
        expectedPrompt: _exactPrompt,
        expectedUserPromptCount: 1,
      );

      debugPrint(
        'LIVE_CODEX_EXACT_PROMPT_RESULT '
        'thread_id=$createdThreadId '
        'workspace=$workspacePath',
      );
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
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

Future<void> _requireAndroidLoopbackDevice(String bridgeApiBaseUrl) async {
  if (!Platform.isAndroid) {
    fail('This live bridge integration test only supports Android devices.');
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

Future<void> _pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 10),
  Duration step = const Duration(milliseconds: 100),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(step);
    if (finder.evaluate().isNotEmpty) {
      return;
    }
  }
  fail('Timed out waiting for ${finder.description}.');
}

void _tryHideTestKeyboard(WidgetTester tester) {
  try {
    tester.testTextInput.hide();
  } catch (_) {
    // Ignore keyboard teardown issues on physical devices.
  }
}
