import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
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

import 'support/live_codex_turn_wait.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'real bridge Codex thread keeps controller assistant text aligned with the bridge after a second completed turn',
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

      await _submitPrompt(tester, prompt: _buildFirstProbePrompt());

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
        expectedPrompt: _buildFirstProbePrompt(),
        expectedUserPromptCount: 1,
        failOnExcessUserPromptCount: true,
      );

      final firstPrompt = _buildFirstProbePrompt();
      final secondPrompt = _buildSecondProbePrompt();

      await _waitForCanonicalTimelineAlignment(
        tester,
        threadApi: threadApi,
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        threadId: createdThreadId,
        expectedUserPrompts: [firstPrompt],
        minimumAssistantMessageCount: 1,
      );

      await _submitPrompt(tester, prompt: secondPrompt);

      await waitForCodexTurnCompletion(
        tester,
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        threadId: createdThreadId,
        promptLabel: 'second',
        expectedPrompt: secondPrompt,
        expectedUserPromptCount: 2,
        failOnExcessUserPromptCount: true,
      );

      final alignment = await _waitForCanonicalTimelineAlignment(
        tester,
        threadApi: threadApi,
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        threadId: createdThreadId,
        expectedUserPrompts: [firstPrompt, secondPrompt],
        minimumAssistantMessageCount: 2,
      );

      expect(
        _hasNearDuplicateAssistantMessages(
          alignment.controllerAssistantMessages,
        ),
        isFalse,
        reason:
            'Controller assistant timeline contains near-duplicate streamed '
            'outputs (${alignment.controllerAssistantMessages.join(' || ')}).',
      );
      expect(
        _hasNearDuplicateAssistantMessages(alignment.timelineAssistantMessages),
        isFalse,
        reason:
            'Bridge timeline contains near-duplicate streamed outputs '
            '(${alignment.timelineAssistantMessages.join(' || ')}).',
      );

      debugPrint(
        'LIVE_CODEX_DUPLICATE_TEXT_RESULT '
        'thread_id=$createdThreadId '
        'workspace=$workspacePath '
        'assistant_count=${alignment.controllerAssistantMessages.length} '
        'controller_assistant="${alignment.controllerAssistantMessages.map(_singleLinePreview).join(' || ')}"',
      );
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}

const String _defaultFirstProbePrompt =
    'Inspect only apps/mobile/lib/app_startup_page.dart and '
    'apps/mobile/android/app/src/main/res/drawable/launch_background.xml. '
    'Reply in exactly 2 short sentences about how splash handoff works. '
    'Do not edit files, do not use apply_patch, and do not ask for approval.';

const String _defaultSecondProbePrompt =
    'Inspect only packages/codex_ui/lib/src/widgets/animated_bridge_background.dart. '
    'Reply in exactly 2 short sentences about whether that bridge artwork is reusable for Android splash work. '
    'Do not edit files, do not use apply_patch, and do not ask for approval.';

String _buildFirstProbePrompt() {
  const configured = String.fromEnvironment(
    'LIVE_CODEX_THREAD_CREATION_PROMPT_ONE',
  );
  if (configured.isNotEmpty) {
    return configured;
  }
  return _defaultFirstProbePrompt;
}

String _buildSecondProbePrompt() {
  const configured = String.fromEnvironment(
    'LIVE_CODEX_THREAD_CREATION_PROMPT_TWO',
  );
  if (configured.isNotEmpty) {
    return configured;
  }
  return _defaultSecondProbePrompt;
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
      'Run it with `flutter drive --driver=test_driver/integration_test.dart --target=integration_test/live_codex_duplicate_text_test.dart -d <android-device-id>`.',
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

Future<void> _submitPrompt(
  WidgetTester tester, {
  required String prompt,
}) async {
  await _pumpUntilFound(
    tester,
    find.byKey(const Key('turn-composer-input')),
    timeout: const Duration(seconds: 20),
  );
  await _pumpUntilFound(
    tester,
    find.byKey(const Key('turn-composer-submit')),
    timeout: const Duration(seconds: 20),
  );

  await tester.enterText(find.byKey(const Key('turn-composer-input')), prompt);
  await tester.pump();
  await tester.tap(find.byKey(const Key('turn-composer-submit')));
  await tester.pump();
  _tryHideTestKeyboard(tester);
  await tester.pumpAndSettle();
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

Future<_TimelineAlignmentReport> _waitForCanonicalTimelineAlignment(
  WidgetTester tester, {
  required HttpThreadDetailBridgeApi threadApi,
  required String bridgeApiBaseUrl,
  required String threadId,
  required List<String> expectedUserPrompts,
  required int minimumAssistantMessageCount,
  Duration timeout = const Duration(seconds: 45),
}) async {
  final args = ThreadDetailControllerArgs(
    bridgeApiBaseUrl: bridgeApiBaseUrl,
    threadId: threadId,
  );
  final container = ProviderScope.containerOf(
    tester.element(find.byType(MaterialApp)),
  );
  final normalizedExpectedPrompts = expectedUserPrompts
      .map(_normalizeText)
      .toList(growable: false);
  final deadline = DateTime.now().add(timeout);
  _TimelineAlignmentReport? lastReport;

  while (DateTime.now().isBefore(deadline)) {
    final controllerState = container.read(
      threadDetailControllerProvider(args),
    );
    final timelinePage = await threadApi.fetchThreadTimelinePage(
      bridgeApiBaseUrl: bridgeApiBaseUrl,
      threadId: threadId,
      limit: 200,
    );

    final report = _TimelineAlignmentReport(
      controllerAssistantMessages: _extractControllerMessages(
        controllerState.items,
        type: ThreadActivityItemType.assistantOutput,
      ),
      controllerUserPrompts: _extractControllerMessages(
        controllerState.items,
        type: ThreadActivityItemType.userPrompt,
      ),
      timelineAssistantMessages: _extractTimelineMessages(
        timelinePage.entries,
        type: ThreadActivityItemType.assistantOutput,
      ),
      timelineUserPrompts: _extractTimelineMessages(
        timelinePage.entries,
        type: ThreadActivityItemType.userPrompt,
      ),
      controllerStatus: controllerState.thread?.status,
      controllerItemCount: controllerState.items.length,
      timelineEntryCount: timelinePage.entries.length,
    );
    lastReport = report;

    final promptsMatch =
        listEquals(report.controllerUserPrompts, normalizedExpectedPrompts) &&
        listEquals(report.timelineUserPrompts, normalizedExpectedPrompts);
    final assistantsMatch = listEquals(
      report.controllerAssistantMessages,
      report.timelineAssistantMessages,
    );
    final hasEnoughAssistantMessages =
        report.controllerAssistantMessages.length >=
        minimumAssistantMessageCount;
    final controllerSettled =
        report.controllerStatus != ThreadStatus.running &&
        !controllerState.isComposerMutationInFlight;

    if (promptsMatch &&
        assistantsMatch &&
        hasEnoughAssistantMessages &&
        controllerSettled) {
      return report;
    }

    await tester.pump(const Duration(milliseconds: 300));
  }

  final report = lastReport;
  if (report == null) {
    fail('No alignment report was captured for $threadId.');
  }

  fail(
    'Controller timeline did not align with bridge timeline for $threadId. '
    'controller_status=${report.controllerStatus?.wireValue} '
    'controller_items=${report.controllerItemCount} '
    'timeline_entries=${report.timelineEntryCount} '
    'controller_user="${report.controllerUserPrompts.join(' || ')}" '
    'timeline_user="${report.timelineUserPrompts.join(' || ')}" '
    'controller_assistant="${report.controllerAssistantMessages.join(' || ')}" '
    'timeline_assistant="${report.timelineAssistantMessages.join(' || ')}"',
  );
}

List<String> _extractControllerMessages(
  List<ThreadActivityItem> items, {
  required ThreadActivityItemType type,
}) {
  return items
      .where((item) => item.type == type)
      .map((item) => _normalizeText(item.body))
      .where((text) => text.isNotEmpty)
      .toList(growable: false);
}

List<String> _extractTimelineMessages(
  List<ThreadTimelineEntryDto> entries, {
  required ThreadActivityItemType type,
}) {
  return entries
      .map(ThreadActivityItem.fromTimelineEntry)
      .where((item) => item.type == type)
      .map((item) => _normalizeText(item.body))
      .where((text) => text.isNotEmpty)
      .toList(growable: false);
}

String _normalizeText(String text) {
  return text.replaceAll(RegExp(r'\s+'), ' ').trim();
}

String _singleLinePreview(String text) {
  final normalized = _normalizeText(text);
  if (normalized.length <= 100) {
    return normalized;
  }
  return '${normalized.substring(0, 100)}...';
}

bool _hasNearDuplicateAssistantMessages(List<String> messages) {
  for (var index = 1; index < messages.length; index += 1) {
    if (_areNearDuplicateAssistantMessages(
      messages[index - 1],
      messages[index],
    )) {
      return true;
    }
  }
  return false;
}

bool _areNearDuplicateAssistantMessages(String left, String right) {
  final normalizedLeft = _normalizeText(left);
  final normalizedRight = _normalizeText(right);
  if (normalizedLeft.isEmpty || normalizedRight.isEmpty) {
    return false;
  }
  if (normalizedLeft == normalizedRight) {
    return true;
  }

  final strippedLeft = normalizedLeft.replaceAll(RegExp(r'[.!?]+$'), '');
  final strippedRight = normalizedRight.replaceAll(RegExp(r'[.!?]+$'), '');
  if (strippedLeft.isNotEmpty && strippedLeft == strippedRight) {
    return true;
  }

  final shorter = normalizedLeft.length <= normalizedRight.length
      ? normalizedLeft
      : normalizedRight;
  final longer = normalizedLeft.length > normalizedRight.length
      ? normalizedLeft
      : normalizedRight;
  final lengthGap = longer.length - shorter.length;
  return lengthGap <= 2 && longer.startsWith(shorter);
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
    // Ignore keyboard teardown failures on device runs.
  }
}

class _TimelineAlignmentReport {
  const _TimelineAlignmentReport({
    required this.controllerAssistantMessages,
    required this.controllerUserPrompts,
    required this.timelineAssistantMessages,
    required this.timelineUserPrompts,
    required this.controllerStatus,
    required this.controllerItemCount,
    required this.timelineEntryCount,
  });

  final List<String> controllerAssistantMessages;
  final List<String> controllerUserPrompts;
  final List<String> timelineAssistantMessages;
  final List<String> timelineUserPrompts;
  final ThreadStatus? controllerStatus;
  final int controllerItemCount;
  final int timelineEntryCount;
}
