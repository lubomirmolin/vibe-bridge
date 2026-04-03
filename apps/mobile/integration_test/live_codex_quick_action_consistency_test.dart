import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vibe_bridge/features/threads/data/thread_detail_bridge_api.dart';
import 'package:vibe_bridge/features/threads/data/thread_live_stream.dart';
import 'package:vibe_bridge/foundation/contracts/bridge_contracts.dart';
import 'package:vibe_bridge/foundation/network/bridge_transport_io.dart';

import 'support/live_codex_turn_wait.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'real bridge Codex commit quick action keeps live snapshot and history prompts aligned',
    (tester) async {
      final bridgeApiBaseUrl = _resolveBridgeApiBaseUrl();
      await _requireAndroidLoopbackDevice(bridgeApiBaseUrl);

      final threadApi = HttpThreadDetailBridgeApi();
      final threadId = await _createCodexThread(
        threadApi,
        bridgeApiBaseUrl: bridgeApiBaseUrl,
      );

      const firstPrompt =
          'Reply with READY. Do not use tools and do not ask for approval.';
      await threadApi.startTurn(
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        threadId: threadId,
        prompt: firstPrompt,
      );
      await waitForCodexTurnCompletion(
        tester,
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        threadId: threadId,
        promptLabel: 'first',
        expectedPrompt: firstPrompt,
        expectedUserPromptCount: 1,
      );

      final liveStream = HttpThreadLiveStream(
        transport: const IoBridgeTransport(),
      );
      final liveSubscription = await liveStream.subscribe(
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        threadId: threadId,
      );
      final rawEvents = <BridgeEventEnvelope<Map<String, dynamic>>>[];
      final rawEventSubscription = liveSubscription.events.listen(
        rawEvents.add,
      );

      try {
        await threadApi.startCommitAction(
          bridgeApiBaseUrl: bridgeApiBaseUrl,
          threadId: threadId,
        );
        await waitForCodexTurnCompletion(
          tester,
          bridgeApiBaseUrl: bridgeApiBaseUrl,
          threadId: threadId,
          promptLabel: 'commit',
          expectedPrompt: 'Commit',
          expectedUserPromptCount: 2,
        );
        await tester.pump(const Duration(seconds: 1));
      } finally {
        await rawEventSubscription.cancel();
        await liveSubscription.close();
      }

      final snapshot = await fetchThreadSnapshotJson(
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        threadId: threadId,
      );
      final history = await threadApi.fetchThreadTimeline(
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        threadId: threadId,
      );

      final snapshotPrompts = _extractUserPromptsFromSnapshot(
        snapshot['entries'] as List<dynamic>? ?? const <dynamic>[],
      );
      final historyPrompts = _extractUserPromptsFromTimeline(history);
      final livePrompts = _extractUserPromptsFromLiveEvents(rawEvents);

      expect(
        snapshotPrompts,
        equals(<String>[_normalizeText(firstPrompt), 'Commit']),
      );
      expect(
        historyPrompts,
        equals(<String>[_normalizeText(firstPrompt), 'Commit']),
      );
      expect(livePrompts.where((prompt) => prompt == 'Commit').length, 1);
      expect(_containsHiddenProtocolText(snapshotPrompts), isFalse);
      expect(_containsHiddenProtocolText(historyPrompts), isFalse);
      expect(_containsHiddenProtocolText(livePrompts), isFalse);
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );

  testWidgets(
    'real bridge Codex repeated commit quick actions keep exact visible prompt counts',
    (tester) async {
      final bridgeApiBaseUrl = _resolveBridgeApiBaseUrl();
      await _requireAndroidLoopbackDevice(bridgeApiBaseUrl);

      final threadApi = HttpThreadDetailBridgeApi();
      final threadId = await _createCodexThread(
        threadApi,
        bridgeApiBaseUrl: bridgeApiBaseUrl,
      );

      const firstPrompt =
          'Reply with READY. Do not use tools and do not ask for approval.';
      await threadApi.startTurn(
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        threadId: threadId,
        prompt: firstPrompt,
      );
      await waitForCodexTurnCompletion(
        tester,
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        threadId: threadId,
        promptLabel: 'first',
        expectedPrompt: firstPrompt,
        expectedUserPromptCount: 1,
      );

      await threadApi.startCommitAction(
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        threadId: threadId,
      );
      await waitForCodexTurnCompletion(
        tester,
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        threadId: threadId,
        promptLabel: 'commit-1',
        expectedPrompt: 'Commit',
        expectedUserPromptCount: 2,
      );

      await threadApi.startCommitAction(
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        threadId: threadId,
      );
      await waitForCodexTurnCompletion(
        tester,
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        threadId: threadId,
        promptLabel: 'commit-2',
        expectedPrompt: 'Commit',
        expectedUserPromptCount: 3,
      );

      final history = await threadApi.fetchThreadTimeline(
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        threadId: threadId,
      );
      final historyPrompts = _extractUserPromptsFromTimeline(history);

      expect(
        historyPrompts,
        equals(<String>[_normalizeText(firstPrompt), 'Commit', 'Commit']),
      );
      expect(historyPrompts.where((prompt) => prompt == 'Commit').length, 2);
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );

  testWidgets(
    'real bridge Codex mixed composer and commit turns keep visible prompt order exact',
    (tester) async {
      final bridgeApiBaseUrl = _resolveBridgeApiBaseUrl();
      await _requireAndroidLoopbackDevice(bridgeApiBaseUrl);

      final threadApi = HttpThreadDetailBridgeApi();
      final threadId = await _createCodexThread(
        threadApi,
        bridgeApiBaseUrl: bridgeApiBaseUrl,
      );

      const firstPrompt =
          'Reply with READY. Do not use tools and do not ask for approval.';
      const secondPrompt =
          'Reply with DONE. Do not use tools and do not ask for approval.';

      await threadApi.startTurn(
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        threadId: threadId,
        prompt: firstPrompt,
      );
      await waitForCodexTurnCompletion(
        tester,
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        threadId: threadId,
        promptLabel: 'first',
        expectedPrompt: firstPrompt,
        expectedUserPromptCount: 1,
      );

      await threadApi.startCommitAction(
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        threadId: threadId,
      );
      await waitForCodexTurnCompletion(
        tester,
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        threadId: threadId,
        promptLabel: 'commit',
        expectedPrompt: 'Commit',
        expectedUserPromptCount: 2,
      );

      await threadApi.startTurn(
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        threadId: threadId,
        prompt: secondPrompt,
      );
      await waitForCodexTurnCompletion(
        tester,
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        threadId: threadId,
        promptLabel: 'second',
        expectedPrompt: secondPrompt,
        expectedUserPromptCount: 3,
      );

      final snapshot = await fetchThreadSnapshotJson(
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        threadId: threadId,
      );
      final history = await threadApi.fetchThreadTimeline(
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        threadId: threadId,
      );

      final expectedPrompts = <String>[
        _normalizeText(firstPrompt),
        'Commit',
        _normalizeText(secondPrompt),
      ];
      expect(
        _extractUserPromptsFromSnapshot(
          snapshot['entries'] as List<dynamic>? ?? const <dynamic>[],
        ),
        equals(expectedPrompts),
      );
      expect(_extractUserPromptsFromTimeline(history), equals(expectedPrompts));
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );

  testWidgets(
    'real bridge Codex plan mode keeps visible request and visible follow-up summary prompts',
    (tester) async {
      final bridgeApiBaseUrl = _resolveBridgeApiBaseUrl();
      await _requireAndroidLoopbackDevice(bridgeApiBaseUrl);

      final threadApi = HttpThreadDetailBridgeApi();
      final threadId = await _createCodexThread(
        threadApi,
        bridgeApiBaseUrl: bridgeApiBaseUrl,
      );

      const planPrompt =
          'Plan how to validate bridge quick actions with the smallest stable test matrix.';
      await threadApi.startTurn(
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        threadId: threadId,
        prompt: planPrompt,
        mode: TurnMode.plan,
      );

      final pendingUserInput = await _waitForPendingUserInput(
        tester,
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        threadId: threadId,
        expectedVisiblePrompt: planPrompt,
      );
      final answers = pendingUserInput.questions
          .where((question) => question.options.isNotEmpty)
          .map(
            (question) => UserInputAnswerDto(
              questionId: question.questionId,
              optionId: question.options.first.optionId,
            ),
          )
          .toList(growable: false);
      const freeText = 'Keep history, snapshot, and live parity exact.';
      final expectedFollowupSummary = _renderPlanClarificationSummary(
        pendingUserInput,
        answers,
        freeText,
      );

      await threadApi.respondToUserInput(
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        threadId: threadId,
        requestId: pendingUserInput.requestId,
        answers: answers,
        freeText: freeText,
      );
      await waitForCodexTurnCompletion(
        tester,
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        threadId: threadId,
        promptLabel: 'plan-followup',
        expectedPrompt: expectedFollowupSummary,
        expectedUserPromptCount: 2,
      );

      final history = await threadApi.fetchThreadTimeline(
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        threadId: threadId,
      );
      final prompts = _extractUserPromptsFromTimeline(history);

      expect(
        prompts,
        equals(<String>[
          _normalizeText(planPrompt),
          _normalizeText(expectedFollowupSummary),
        ]),
      );
      expect(_containsHiddenProtocolText(prompts), isFalse);
    },
    timeout: const Timeout(Duration(minutes: 10)),
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
  const isolated = String.fromEnvironment('LIVE_CODEX_QUICK_ACTION_WORKSPACE');
  if (isolated.isNotEmpty) {
    return isolated;
  }

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
      'Run it with `flutter drive --driver=test_driver/integration_test.dart --target=integration_test/live_codex_quick_action_consistency_test.dart -d <android-device-id>`.',
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

Future<String> _createCodexThread(
  HttpThreadDetailBridgeApi threadApi, {
  required String bridgeApiBaseUrl,
}) async {
  final createdThread = await threadApi.createThread(
    bridgeApiBaseUrl: bridgeApiBaseUrl,
    workspace: _resolveWorkspacePath(),
    provider: ProviderKind.codex,
  );
  return createdThread.thread.threadId;
}

Future<PendingUserInputDto> _waitForPendingUserInput(
  WidgetTester tester, {
  required String bridgeApiBaseUrl,
  required String threadId,
  required String expectedVisiblePrompt,
  Duration timeout = const Duration(minutes: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final snapshot = await fetchThreadSnapshotJson(
      bridgeApiBaseUrl: bridgeApiBaseUrl,
      threadId: threadId,
    );
    final prompts = _extractUserPromptsFromSnapshot(
      snapshot['entries'] as List<dynamic>? ?? const <dynamic>[],
    );
    final pending = snapshot['pending_user_input'];
    if (prompts.length == 1 &&
        prompts.single == _normalizeText(expectedVisiblePrompt) &&
        pending is Map<String, dynamic>) {
      return PendingUserInputDto.fromJson(pending);
    }
    await tester.pump(const Duration(milliseconds: 400));
  }

  fail(
    'Timed out waiting for pending user input on $threadId after prompt '
    '"$expectedVisiblePrompt".',
  );
}

List<String> _extractUserPromptsFromSnapshot(List<dynamic> entries) {
  final prompts = <String>[];
  for (final entry in entries) {
    if (entry is! Map<String, dynamic>) {
      continue;
    }
    final kind = entry['kind'] as String?;
    if (kind != 'message_delta') {
      continue;
    }
    final payload = entry['payload'];
    if (payload is! Map<String, dynamic>) {
      continue;
    }
    if ((payload['role'] as String?)?.trim() != 'user') {
      continue;
    }
    final text = _extractPayloadText(payload);
    if (text.isNotEmpty) {
      prompts.add(text);
    }
  }
  return prompts;
}

List<String> _extractUserPromptsFromTimeline(
  List<ThreadTimelineEntryDto> entries,
) {
  return entries
      .where((entry) => entry.kind == BridgeEventKind.messageDelta)
      .where((entry) => (entry.payload['role'] as String?)?.trim() == 'user')
      .map((entry) => _extractPayloadText(entry.payload))
      .where((text) => text.isNotEmpty)
      .toList(growable: false);
}

List<String> _extractUserPromptsFromLiveEvents(
  List<BridgeEventEnvelope<Map<String, dynamic>>> events,
) {
  return events
      .where((event) => event.kind == BridgeEventKind.messageDelta)
      .where((event) => (event.payload['role'] as String?)?.trim() == 'user')
      .map((event) => _extractPayloadText(event.payload))
      .where((text) => text.isNotEmpty)
      .toList(growable: false);
}

String _extractPayloadText(Map<String, dynamic> payload) {
  final delta = _normalizeText((payload['delta'] as String?) ?? '');
  if (delta.isNotEmpty) {
    return delta;
  }
  final text = _normalizeText((payload['text'] as String?) ?? '');
  if (text.isNotEmpty) {
    return text;
  }
  final message = _normalizeText((payload['message'] as String?) ?? '');
  if (message.isNotEmpty) {
    return message;
  }
  final content = payload['content'];
  if (content is! List<dynamic>) {
    return '';
  }

  final buffer = StringBuffer();
  for (final item in content) {
    if (item is! Map<String, dynamic>) {
      continue;
    }
    final text = item['text'];
    if (text is String && text.trim().isNotEmpty) {
      buffer.write(text);
    }
  }
  return _normalizeText(buffer.toString());
}

String _renderPlanClarificationSummary(
  PendingUserInputDto questionnaire,
  List<UserInputAnswerDto> answers,
  String freeText,
) {
  final lines = <String>['Plan clarification'];
  for (final answer in answers) {
    final question = questionnaire.questions.firstWhere(
      (item) => item.questionId == answer.questionId,
      orElse: () => UserInputQuestionDto(
        questionId: answer.questionId,
        prompt: 'Question',
        options: const <UserInputOptionDto>[],
      ),
    );
    final option = question.options.firstWhere(
      (item) => item.optionId == answer.optionId,
      orElse: () => UserInputOptionDto(
        optionId: answer.optionId,
        label: 'Selected',
        description: '',
        isRecommended: false,
      ),
    );
    lines.add('- ${question.prompt}: ${option.label}');
  }
  if (freeText.trim().isNotEmpty) {
    lines.add('- Something else: ${freeText.trim()}');
  }
  return lines.join('\n');
}

String _normalizeText(String text) {
  return text.replaceAll(RegExp(r'\s+'), ' ').trim();
}

bool _containsHiddenProtocolText(List<String> prompts) {
  return prompts.any((prompt) {
    return prompt.contains('<app-context>') ||
        prompt.contains('<codex-plan-questions>') ||
        prompt.contains('You are running in mobile plan intake mode.') ||
        prompt.contains('You are continuing a mobile planning workflow.');
  });
}
