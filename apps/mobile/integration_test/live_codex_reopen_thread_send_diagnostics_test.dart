import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
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
    'real bridge Codex reopen-thread send does not show a transient failed state after the bridge accepted the prompt',
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

      final seededThreadId = await _seedExistingThread(
        threadApi: threadApi,
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

      final threadCardFinder = find.byKey(
        Key('thread-summary-card-$seededThreadId'),
      );
      await _pumpUntilFound(
        tester,
        threadCardFinder,
        timeout: const Duration(seconds: 25),
      );

      await tester.tap(threadCardFinder);
      await tester.pumpAndSettle();

      await _pumpUntilFound(
        tester,
        find.byKey(const Key('thread-detail-title')),
        timeout: const Duration(seconds: 20),
      );
      await _pumpUntilFound(
        tester,
        find.byKey(const Key('turn-composer-input')),
        timeout: const Duration(seconds: 8),
      );

      final reopenPrompt = _buildReopenPrompt();
      final diagnostics = _SendDiagnostics();

      await tester.enterText(
        find.byKey(const Key('turn-composer-input')),
        reopenPrompt,
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('turn-composer-submit')));
      await tester.pump();
      _tryHideTestKeyboard(tester);

      final submitStartedAt = DateTime.now();
      final completionDeadline = DateTime.now().add(const Duration(minutes: 3));
      while (DateTime.now().isBefore(completionDeadline)) {
        await tester.pump(const Duration(milliseconds: 200));

        diagnostics.recordUi(
          sawSending: find.text('Sending').evaluate().isNotEmpty,
          sawSendFailed: find.text('Send failed').evaluate().isNotEmpty,
        );

        final snapshot = await fetchThreadSnapshotJson(
          bridgeApiBaseUrl: bridgeApiBaseUrl,
          threadId: seededThreadId,
        );
        diagnostics.recordBridgeSnapshot(
          snapshot: snapshot,
          normalizedPrompt: _normalizeText(reopenPrompt),
        );

        final bridgeAcceptedPrompt =
            diagnostics.bridgePromptSeenAt != null ||
            diagnostics.bridgeAssistantSeenAt != null;
        if (bridgeAcceptedPrompt && diagnostics.firstUiSendFailedAt != null) {
          diagnostics.uiFailedDespiteBridgeAcceptance = true;
        }

        if (_snapshotShowsCompletedSecondTurn(snapshot, reopenPrompt)) {
          diagnostics.completedAt ??= DateTime.now();
          break;
        }
      }

      await waitForCodexTurnCompletion(
        tester,
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        threadId: seededThreadId,
        promptLabel: 'reopen-diagnostics',
        expectedPrompt: reopenPrompt,
        expectedUserPromptCount: 2,
      );

      final elapsedMs = DateTime.now()
          .difference(submitStartedAt)
          .inMilliseconds;
      debugPrint(
        'LIVE_CODEX_REOPEN_SEND_DIAGNOSTICS '
        'thread_id=$seededThreadId '
        'ui_sending=${diagnostics.firstUiSendingAt != null} '
        'ui_send_failed=${diagnostics.firstUiSendFailedAt != null} '
        'bridge_prompt_seen=${diagnostics.bridgePromptSeenAt != null} '
        'bridge_assistant_seen=${diagnostics.bridgeAssistantSeenAt != null} '
        'ui_failed_despite_bridge_acceptance='
        '${diagnostics.uiFailedDespiteBridgeAcceptance} '
        'elapsed_ms=$elapsedMs '
        'details=${jsonEncode(diagnostics.toJson())}',
      );

      expect(diagnostics.bridgePromptSeenAt, isNotNull);
      expect(diagnostics.bridgeAssistantSeenAt, isNotNull);
      expect(
        diagnostics.uiFailedDespiteBridgeAcceptance,
        isFalse,
        reason:
            'The bridge accepted and completed the prompt, but the mobile UI still '
            'surfaced a transient "Send failed" state while reopening an existing thread.',
      );
      expect(
        diagnostics.firstUiSendFailedAt,
        isNull,
        reason:
            'The reopened-thread send flow should never flash "Send failed" for a prompt '
            'that the bridge later records canonically.',
      );
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}

class _SendDiagnostics {
  DateTime? firstUiSendingAt;
  DateTime? firstUiSendFailedAt;
  DateTime? bridgePromptSeenAt;
  DateTime? bridgeAssistantSeenAt;
  DateTime? completedAt;
  bool uiFailedDespiteBridgeAcceptance = false;
  String? finalThreadStatus;
  int promptCount = 0;
  int assistantCountAfterPrompt = 0;

  void recordUi({required bool sawSending, required bool sawSendFailed}) {
    if (sawSending) {
      firstUiSendingAt ??= DateTime.now();
    }
    if (sawSendFailed) {
      firstUiSendFailedAt ??= DateTime.now();
    }
  }

  void recordBridgeSnapshot({
    required Map<String, dynamic> snapshot,
    required String normalizedPrompt,
  }) {
    final thread = snapshot['thread'];
    if (thread is Map<String, dynamic>) {
      finalThreadStatus = (thread['status'] as String?)?.trim();
    }

    final entries = snapshot['entries'];
    if (entries is! List<dynamic>) {
      return;
    }

    var matchedPromptCount = 0;
    var assistantMessagesAfterPrompt = 0;
    var promptReached = false;

    for (final rawEntry in entries) {
      if (rawEntry is! Map<String, dynamic>) {
        continue;
      }
      if (rawEntry['kind'] != 'message_delta') {
        continue;
      }
      final payload = rawEntry['payload'];
      if (payload is! Map<String, dynamic>) {
        continue;
      }

      final role = (payload['role'] as String?)?.trim();
      final type = (payload['type'] as String?)?.trim();
      final text = _extractMessageText(payload);
      if (text.isEmpty) {
        continue;
      }

      final normalizedText = _normalizeText(text);
      final isUserMessage = role == 'user' || type == 'userMessage';
      final isAssistantMessage = role == 'assistant' || type == 'agentMessage';

      if (isUserMessage && normalizedText == normalizedPrompt) {
        matchedPromptCount += 1;
        promptReached = true;
        bridgePromptSeenAt ??= DateTime.now();
        continue;
      }

      if (promptReached && isAssistantMessage) {
        assistantMessagesAfterPrompt += 1;
        bridgeAssistantSeenAt ??= DateTime.now();
      }
    }

    promptCount = matchedPromptCount;
    assistantCountAfterPrompt = assistantMessagesAfterPrompt;
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'first_ui_sending_at': firstUiSendingAt?.toIso8601String(),
      'first_ui_send_failed_at': firstUiSendFailedAt?.toIso8601String(),
      'bridge_prompt_seen_at': bridgePromptSeenAt?.toIso8601String(),
      'bridge_assistant_seen_at': bridgeAssistantSeenAt?.toIso8601String(),
      'completed_at': completedAt?.toIso8601String(),
      'final_thread_status': finalThreadStatus,
      'prompt_count': promptCount,
      'assistant_count_after_prompt': assistantCountAfterPrompt,
      'ui_failed_despite_bridge_acceptance': uiFailedDespiteBridgeAcceptance,
    };
  }
}

Future<String> _seedExistingThread({
  required HttpThreadDetailBridgeApi threadApi,
  required String bridgeApiBaseUrl,
  required String workspacePath,
}) async {
  final created = await threadApi.createThread(
    bridgeApiBaseUrl: bridgeApiBaseUrl,
    workspace: workspacePath,
    provider: ProviderKind.codex,
  );
  final threadId = created.thread.threadId.trim();
  expect(threadId, isNotEmpty);

  final warmupPrompt = _buildWarmupPrompt();
  await threadApi.startTurn(
    bridgeApiBaseUrl: bridgeApiBaseUrl,
    threadId: threadId,
    prompt: warmupPrompt,
  );

  final deadline = DateTime.now().add(const Duration(minutes: 3));
  while (DateTime.now().isBefore(deadline)) {
    final snapshot = await fetchThreadSnapshotJson(
      bridgeApiBaseUrl: bridgeApiBaseUrl,
      threadId: threadId,
    );
    if (_snapshotShowsCompletedFirstTurn(snapshot, warmupPrompt)) {
      return threadId;
    }
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }

  fail('Timed out seeding a completed thread for reopen diagnostics.');
}

bool _snapshotShowsCompletedFirstTurn(
  Map<String, dynamic> snapshot,
  String expectedPrompt,
) {
  return _snapshotShowsCompletedTurn(
    snapshot: snapshot,
    expectedPrompt: expectedPrompt,
    expectedPromptCount: 1,
  );
}

bool _snapshotShowsCompletedSecondTurn(
  Map<String, dynamic> snapshot,
  String expectedPrompt,
) {
  return _snapshotShowsCompletedTurn(
    snapshot: snapshot,
    expectedPrompt: expectedPrompt,
    expectedPromptCount: 2,
  );
}

bool _snapshotShowsCompletedTurn({
  required Map<String, dynamic> snapshot,
  required String expectedPrompt,
  required int expectedPromptCount,
}) {
  final thread = snapshot['thread'];
  if (thread is! Map<String, dynamic>) {
    return false;
  }
  final status = (thread['status'] as String?)?.trim() ?? '';
  final settled =
      status == ThreadStatus.completed.wireValue ||
      status == ThreadStatus.idle.wireValue;
  if (!settled) {
    return false;
  }

  final entries = snapshot['entries'];
  if (entries is! List<dynamic>) {
    return false;
  }

  final normalizedPrompt = _normalizeText(expectedPrompt);
  var promptMatches = 0;
  var assistantAfterPrompt = 0;
  var promptReached = false;

  for (final rawEntry in entries) {
    if (rawEntry is! Map<String, dynamic>) {
      continue;
    }
    if (rawEntry['kind'] != 'message_delta') {
      continue;
    }
    final payload = rawEntry['payload'];
    if (payload is! Map<String, dynamic>) {
      continue;
    }

    final role = (payload['role'] as String?)?.trim();
    final type = (payload['type'] as String?)?.trim();
    final text = _extractMessageText(payload);
    if (text.isEmpty) {
      continue;
    }

    final normalizedText = _normalizeText(text);
    final isUserMessage = role == 'user' || type == 'userMessage';
    final isAssistantMessage = role == 'assistant' || type == 'agentMessage';

    if (isUserMessage && normalizedText == normalizedPrompt) {
      promptMatches += 1;
      if (promptMatches >= expectedPromptCount) {
        promptReached = true;
        assistantAfterPrompt = 0;
      }
      continue;
    }

    if (promptReached && isAssistantMessage) {
      assistantAfterPrompt += 1;
    }
  }

  return promptMatches >= expectedPromptCount && assistantAfterPrompt > 0;
}

String _buildWarmupPrompt() {
  return 'Reply with exactly WARMUP_OK. '
      'Do not use tools, do not edit files, and do not ask for approval.';
}

String _buildReopenPrompt() {
  return 'Reply with exactly REOPEN_OK. '
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

Future<void> _requireAndroidLoopbackDevice(String bridgeApiBaseUrl) async {
  if (!Platform.isAndroid) {
    fail(
      'This live bridge integration test only supports Android devices. '
      'Run it with `flutter drive --driver=test_driver/integration_test.dart --target=integration_test/live_codex_reopen_thread_send_diagnostics_test.dart -d <android-device-id>`.',
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

Future<void> _pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final endTime = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(endTime)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isNotEmpty) {
      return;
    }
  }

  throw TestFailure('Timed out waiting for $finder.');
}

String _extractMessageText(Map<String, dynamic> payload) {
  final delta = _normalizeText((payload['delta'] as String?) ?? '');
  if (delta.isNotEmpty) {
    return delta;
  }

  final text = _normalizeText((payload['text'] as String?) ?? '');
  if (text.isNotEmpty) {
    return text;
  }

  final content = payload['content'];
  if (content is! List<dynamic>) {
    return '';
  }

  final buffer = StringBuffer();
  for (final part in content) {
    if (part is! Map<String, dynamic>) {
      continue;
    }
    final partText = part['text'];
    if (partText is String && partText.trim().isNotEmpty) {
      buffer.write(partText);
    }
  }
  return _normalizeText(buffer.toString());
}

String _normalizeText(String text) {
  return text.replaceAll(RegExp(r'\s+'), ' ').trim();
}

void _tryHideTestKeyboard(WidgetTester tester) {
  final binding = tester.binding;
  final focusedEditable = binding.focusManager.primaryFocus;
  focusedEditable?.unfocus();
}
