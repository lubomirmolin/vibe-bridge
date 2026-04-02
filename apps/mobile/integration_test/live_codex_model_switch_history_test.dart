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

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'real bridge Codex model switching is recorded in thread history',
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
      final modelCatalog = await threadApi.fetchModelCatalog(
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        provider: ProviderKind.codex,
      );
      final secondModelOption = modelCatalog.models.firstWhere(
        (model) => model.isDefault,
        orElse: () => modelCatalog.models.first,
      );
      final firstModelOption = modelCatalog.models.firstWhere(
        (model) => model.id != secondModelOption.id,
        orElse: () {
          fail('Need at least two Codex models to validate model switching.');
        },
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

      final firstModel = firstModelOption.id;
      final secondModel = secondModelOption.id;
      const firstPrompt =
          'Reply with exactly MINI. Do not use tools and do not ask for approval.';
      const secondPrompt =
          'Reply with exactly FULL. Do not use tools and do not ask for approval.';

      await _openComposerModelSheet(tester);
      await _selectComposerModel(tester, firstModel);
      await _closeComposerModelSheet(tester);
      await _submitPrompt(tester, prompt: firstPrompt);

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
        promptLabel: 'first',
        expectedPrompt: firstPrompt,
        expectedUserPromptCount: 1,
      );

      await _openComposerModelSheet(tester);
      await _selectComposerModel(tester, secondModel);
      await _closeComposerModelSheet(tester);
      await _submitPrompt(tester, prompt: secondPrompt);

      await waitForCodexTurnCompletion(
        tester,
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        threadId: createdThreadId,
        promptLabel: 'second',
        expectedPrompt: secondPrompt,
        expectedUserPromptCount: 2,
      );
      await _waitForThreadControllerToSettle(
        tester,
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        threadId: createdThreadId,
      );

      final historyPage = await threadApi.fetchThreadTimelinePage(
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        threadId: createdThreadId,
        limit: 300,
      );
      final modelHistory = historyPage.entries
          .where(
            (entry) =>
                entry.kind == BridgeEventKind.threadStatusChanged &&
                (entry.payload['reason'] as String?) == 'turn_started',
          )
          .map(
            (entry) => (
              model: (entry.payload['model'] as String?)?.trim() ?? '',
              reasoning:
                  (entry.payload['reasoning_effort'] as String?)?.trim() ?? '',
            ),
          )
          .where((entry) => entry.model.isNotEmpty)
          .toList(growable: false);

      expect(
        modelHistory.length,
        greaterThanOrEqualTo(2),
        reason: 'Expected at least two turn_started model entries.',
      );

      final lastTwoModels = modelHistory
          .sublist(modelHistory.length - 2)
          .map((entry) => entry.model)
          .toList(growable: false);
      expect(lastTwoModels, equals(<String>[firstModel, secondModel]));
      expect(
        modelHistory
            .sublist(modelHistory.length - 2)
            .every((entry) => entry.reasoning.isNotEmpty),
        isTrue,
      );

      debugPrint(
        'LIVE_CODEX_MODEL_SWITCH_RESULT '
        'thread_id=$createdThreadId '
        'models=${lastTwoModels.join(",")}',
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
    fail(
      'This live bridge integration test only supports Android devices. '
      'Run it with `flutter drive --driver=test_driver/integration_test.dart --target=integration_test/live_codex_model_switch_history_test.dart -d <android-device-id>`.',
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

Future<void> _selectComposerModel(WidgetTester tester, String modelId) async {
  final optionFinder = find.byKey(Key('turn-composer-model-option-$modelId'));
  await _pumpUntilFound(
    tester,
    optionFinder,
    timeout: const Duration(seconds: 8),
  );
  await tester.tap(optionFinder);
  await tester.pumpAndSettle();
}

Future<void> _closeComposerModelSheet(WidgetTester tester) async {
  final closeFinder = find.byKey(const Key('turn-composer-model-sheet-close'));
  if (closeFinder.evaluate().isNotEmpty) {
    await tester.tap(closeFinder);
    await tester.pumpAndSettle();
  }
}

Future<void> _submitPrompt(
  WidgetTester tester, {
  required String prompt,
}) async {
  await tester.enterText(find.byKey(const Key('turn-composer-input')), prompt);
  await tester.pump();
  await tester.tap(find.byKey(const Key('turn-composer-submit')));
  await tester.pump();
  _tryHideTestKeyboard(tester);
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

Future<void> _waitForThreadControllerToSettle(
  WidgetTester tester, {
  required String bridgeApiBaseUrl,
  required String threadId,
  Duration timeout = const Duration(seconds: 20),
}) async {
  final container = ProviderScope.containerOf(
    tester.element(find.byType(MaterialApp)),
  );
  final args = ThreadDetailControllerArgs(
    bridgeApiBaseUrl: bridgeApiBaseUrl,
    threadId: threadId,
  );
  final deadline = DateTime.now().add(timeout);

  while (DateTime.now().isBefore(deadline)) {
    final state = container.read(threadDetailControllerProvider(args));
    if (!state.isLoading &&
        state.thread != null &&
        state.thread!.threadId == threadId &&
        !state.isTurnActive &&
        !state.isComposerMutationInFlight) {
      return;
    }
    await tester.pump(const Duration(milliseconds: 150));
  }

  fail('Timed out waiting for thread controller to settle for $threadId.');
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
  fail('Timed out waiting for $finder.');
}

void _tryHideTestKeyboard(WidgetTester tester) {
  final focusedScope = FocusManager.instance.primaryFocus;
  focusedScope?.unfocus();
  try {
    tester.testTextInput.hide();
  } catch (_) {
    // Physical-device runs may not register a fake test text input.
  }
}
