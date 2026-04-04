import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vibe_bridge/features/threads/data/thread_detail_bridge_api.dart';
import 'package:vibe_bridge/features/threads/data/thread_list_bridge_api.dart';
import 'package:vibe_bridge/features/threads/presentation/thread_detail_page.dart';
import 'package:vibe_bridge/foundation/contracts/bridge_contracts.dart';
import 'package:vibe_bridge/foundation/storage/secure_store.dart';
import 'package:vibe_bridge/foundation/storage/secure_store_provider.dart';

import 'support/live_codex_turn_wait.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'real bridge Codex larger existing thread accepts a new prompt without flashing Send failed',
    (tester) async {
      final bridgeApiBaseUrl = _resolveBridgeApiBaseUrl();
      await _requireAndroidLoopbackDevice(bridgeApiBaseUrl);

      final workspacePath = _resolveWorkspacePath();
      final threadApi = HttpThreadDetailBridgeApi();
      final threadListApi = HttpThreadListBridgeApi();

      final candidate = await _pickLargeExistingThread(
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
            home: ThreadDetailPage(
              bridgeApiBaseUrl: bridgeApiBaseUrl,
              threadId: candidate.thread.threadId,
            ),
          ),
        ),
      );

      await _pumpUntilFound(
        tester,
        find.byKey(const Key('thread-detail-title')),
        timeout: const Duration(seconds: 25),
      );
      await _pumpUntilFound(
        tester,
        find.byKey(const Key('turn-composer-input')),
        timeout: const Duration(seconds: 12),
      );
      await tester.pump(const Duration(seconds: 2));

      final prompt = _buildProbePrompt();
      final diagnostics = _LargeThreadSendDiagnostics(
        candidateThreadId: candidate.thread.threadId,
        candidateTitle: candidate.thread.title,
        candidateEntryCount: candidate.entryCount,
        candidateHasMoreBefore: candidate.hasMoreBefore,
      );

      await tester.enterText(
        find.byKey(const Key('turn-composer-input')),
        prompt,
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('turn-composer-submit')));
      await tester.pump();
      _tryHideTestKeyboard(tester);

      final completionDeadline = DateTime.now().add(const Duration(minutes: 4));
      while (DateTime.now().isBefore(completionDeadline)) {
        await tester.pump(const Duration(milliseconds: 250));

        diagnostics.recordUi(
          sawSending: find.text('Sending').evaluate().isNotEmpty,
          sawSendFailed: find.text('Send failed').evaluate().isNotEmpty,
        );

        final snapshot = await fetchThreadSnapshotJson(
          bridgeApiBaseUrl: bridgeApiBaseUrl,
          threadId: candidate.thread.threadId,
        );
        diagnostics.recordBridgeSnapshot(
          snapshot: snapshot,
          normalizedPrompt: _normalizeText(prompt),
        );

        final bridgeAcceptedPrompt =
            diagnostics.bridgePromptSeenAt != null ||
            diagnostics.bridgeAssistantSeenAt != null;
        if (bridgeAcceptedPrompt && diagnostics.firstUiSendFailedAt != null) {
          diagnostics.uiFailedDespiteBridgeAcceptance = true;
        }

        if (_snapshotShowsCompletedPrompt(snapshot, prompt)) {
          diagnostics.completedAt ??= DateTime.now();
          break;
        }
      }

      await _waitForPromptCompletionOnExistingThread(
        tester,
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        threadId: candidate.thread.threadId,
        promptLabel: 'large-thread',
        expectedPrompt: prompt,
      );

      debugPrint(
        'LIVE_CODEX_LARGE_THREAD_SEND_RESULT '
        'thread_id=${candidate.thread.threadId} '
        'entry_count=${candidate.entryCount} '
        'has_more_before=${candidate.hasMoreBefore} '
        'ui_sending=${diagnostics.firstUiSendingAt != null} '
        'ui_send_failed=${diagnostics.firstUiSendFailedAt != null} '
        'bridge_prompt_seen=${diagnostics.bridgePromptSeenAt != null} '
        'bridge_assistant_seen=${diagnostics.bridgeAssistantSeenAt != null} '
        'ui_failed_despite_bridge_acceptance='
        '${diagnostics.uiFailedDespiteBridgeAcceptance} '
        'details=${jsonEncode(diagnostics.toJson())}',
      );

      expect(diagnostics.bridgePromptSeenAt, isNotNull);
      expect(diagnostics.bridgeAssistantSeenAt, isNotNull);
      expect(
        diagnostics.uiFailedDespiteBridgeAcceptance,
        isFalse,
        reason:
            'The bridge accepted and completed the prompt on a larger reopened thread, '
            'but the mobile UI still surfaced a transient "Send failed" state.',
      );
      expect(
        diagnostics.firstUiSendFailedAt,
        isNull,
        reason:
            'A reopened larger thread should never flash "Send failed" for a prompt '
            'that the bridge records canonically.',
      );
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

class _LargeThreadCandidate {
  const _LargeThreadCandidate({
    required this.thread,
    required this.entryCount,
    required this.hasMoreBefore,
    required this.promptCount,
  });

  final ThreadSummaryDto thread;
  final int entryCount;
  final bool hasMoreBefore;
  final int promptCount;
}

class _LargeThreadSendDiagnostics {
  _LargeThreadSendDiagnostics({
    required this.candidateThreadId,
    required this.candidateTitle,
    required this.candidateEntryCount,
    required this.candidateHasMoreBefore,
  });

  final String candidateThreadId;
  final String candidateTitle;
  final int candidateEntryCount;
  final bool candidateHasMoreBefore;
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
      'candidate_thread_id': candidateThreadId,
      'candidate_title': candidateTitle,
      'candidate_entry_count': candidateEntryCount,
      'candidate_has_more_before': candidateHasMoreBefore,
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

Future<_LargeThreadCandidate> _pickLargeExistingThread({
  required HttpThreadDetailBridgeApi threadApi,
  required HttpThreadListBridgeApi threadListApi,
  required String bridgeApiBaseUrl,
  required String workspacePath,
}) async {
  final threads = await threadListApi.fetchThreads(
    bridgeApiBaseUrl: bridgeApiBaseUrl,
  );

  final candidates = threads
      .where(
        (thread) =>
            thread.provider == ProviderKind.codex &&
            thread.workspace.trim() == workspacePath &&
            thread.status != ThreadStatus.running,
      )
      .take(12)
      .toList(growable: false);

  _LargeThreadCandidate? bestCandidate;
  var bestScore = -1;

  for (final thread in candidates) {
    final page = await threadApi.fetchThreadTimelinePage(
      bridgeApiBaseUrl: bridgeApiBaseUrl,
      threadId: thread.threadId,
      limit: 250,
    );
    final promptCount = page.entries
        .where(
          (entry) =>
              entry.kind == BridgeEventKind.messageDelta &&
              ((entry.payload['role'] as String?)?.trim() == 'user'),
        )
        .length;
    final score =
        page.entries.length +
        (page.hasMoreBefore ? 10000 : 0) +
        (promptCount * 10);

    final nextCandidate = _LargeThreadCandidate(
      thread: thread,
      entryCount: page.entries.length,
      hasMoreBefore: page.hasMoreBefore,
      promptCount: promptCount,
    );

    if (score > bestScore) {
      bestScore = score;
      bestCandidate = nextCandidate;
    }
  }

  if (bestCandidate == null) {
    fail('Could not find an existing Codex thread to probe.');
  }

  if (!bestCandidate.hasMoreBefore && bestCandidate.entryCount < 80) {
    fail(
      'No sufficiently large existing Codex thread was available. '
      'best_thread=${bestCandidate.thread.threadId} '
      'entry_count=${bestCandidate.entryCount} '
      'prompt_count=${bestCandidate.promptCount}',
    );
  }

  return bestCandidate;
}

Future<void> _waitForPromptCompletionOnExistingThread(
  WidgetTester tester, {
  required String bridgeApiBaseUrl,
  required String threadId,
  required String promptLabel,
  required String expectedPrompt,
  Duration timeout = const Duration(minutes: 4),
}) async {
  final deadline = DateTime.now().add(timeout);
  String? lastStatus;
  var lastAssistantMessagesAfterPrompt = 0;
  var lastSawPrompt = false;

  while (DateTime.now().isBefore(deadline)) {
    final snapshot = await fetchThreadSnapshotJson(
      bridgeApiBaseUrl: bridgeApiBaseUrl,
      threadId: threadId,
    );
    final thread = snapshot['thread'];
    if (thread is! Map<String, dynamic>) {
      fail('Expected thread payload for $threadId, got $thread');
    }

    final rawStatus = (thread['status'] as String?)?.trim() ?? '';
    lastStatus = rawStatus;
    if (rawStatus == ThreadStatus.failed.wireValue) {
      fail('Codex thread $threadId failed during the $promptLabel turn.');
    }
    if (rawStatus == ThreadStatus.interrupted.wireValue) {
      fail(
        'Codex thread $threadId was interrupted during the $promptLabel turn.',
      );
    }

    final signals = _PromptSnapshotSignals.fromSnapshotEntries(
      snapshot['entries'] as List<dynamic>? ?? const [],
      expectedPrompt: expectedPrompt,
    );
    lastSawPrompt = signals.sawPrompt;
    lastAssistantMessagesAfterPrompt = signals.assistantMessagesAfterPrompt;

    final settledThreadStatus =
        rawStatus == ThreadStatus.completed.wireValue ||
        rawStatus == ThreadStatus.idle.wireValue;
    if (signals.sawPrompt &&
        signals.assistantMessagesAfterPrompt > 0 &&
        settledThreadStatus) {
      return;
    }

    await tester.pump(const Duration(milliseconds: 400));
  }

  fail(
    'Timed out waiting for Codex thread $threadId to complete its $promptLabel turn. '
    'last_status=$lastStatus '
    'saw_prompt=$lastSawPrompt '
    'assistant_messages_after_prompt=$lastAssistantMessagesAfterPrompt',
  );
}

class _PromptSnapshotSignals {
  const _PromptSnapshotSignals({
    required this.sawPrompt,
    required this.assistantMessagesAfterPrompt,
  });

  final bool sawPrompt;
  final int assistantMessagesAfterPrompt;

  factory _PromptSnapshotSignals.fromSnapshotEntries(
    List<dynamic> entries, {
    required String expectedPrompt,
  }) {
    final normalizedExpectedPrompt = _normalizeText(expectedPrompt);
    var sawPrompt = false;
    var assistantMessagesAfterPrompt = 0;

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

      if (isUserMessage && normalizedText == normalizedExpectedPrompt) {
        sawPrompt = true;
        assistantMessagesAfterPrompt = 0;
        continue;
      }

      if (sawPrompt && isAssistantMessage) {
        assistantMessagesAfterPrompt += 1;
      }
    }

    return _PromptSnapshotSignals(
      sawPrompt: sawPrompt,
      assistantMessagesAfterPrompt: assistantMessagesAfterPrompt,
    );
  }
}

bool _snapshotShowsCompletedPrompt(
  Map<String, dynamic> snapshot,
  String expectedPrompt,
) {
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
  var promptReached = false;
  var assistantAfterPrompt = 0;

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
      promptReached = true;
      assistantAfterPrompt = 0;
      continue;
    }

    if (promptReached && isAssistantMessage) {
      assistantAfterPrompt += 1;
    }
  }

  return promptReached && assistantAfterPrompt > 0;
}

String _buildProbePrompt() {
  final token = DateTime.now().millisecondsSinceEpoch;
  return 'Reply with exactly LARGE_THREAD_OK_$token. '
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
      'Run it with `flutter drive --driver=test_driver/integration_test.dart --target=integration_test/live_codex_large_thread_send_test.dart -d <android-device-id>`.',
    );
  }

  final androidInfo = await DeviceInfoPlugin().androidInfo;
  if (androidInfo.isPhysicalDevice &&
      !_usesLoopbackBridgeUrl(bridgeApiBaseUrl)) {
    fail(
      'This live bridge integration test only supports physical Android devices '
      'when the bridge URL is loopback-backed via `adb reverse`, for example '
      '`http://127.0.0.1:3110`.',
    );
  }
}

bool _usesLoopbackBridgeUrl(String bridgeApiBaseUrl) {
  final uri = Uri.tryParse(bridgeApiBaseUrl);
  final host = uri?.host.trim().toLowerCase() ?? '';
  return host == '127.0.0.1' || host == 'localhost';
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
