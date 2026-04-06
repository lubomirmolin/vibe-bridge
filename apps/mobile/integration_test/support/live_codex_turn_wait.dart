import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vibe_bridge/foundation/contracts/bridge_contracts.dart';

Future<void> waitForCodexTurnCompletion(
  WidgetTester tester, {
  required String bridgeApiBaseUrl,
  required String threadId,
  required String promptLabel,
  required String expectedPrompt,
  required int expectedUserPromptCount,
  bool failOnExcessUserPromptCount = false,
  Future<void> Function()? onPendingUserInput,
  Duration timeout = const Duration(minutes: 3),
}) async {
  final deadline = DateTime.now().add(timeout);
  final normalizedExpectedPrompt = _normalizeText(expectedPrompt);
  String? lastStatus;
  List<String> lastUserPrompts = const [];
  var lastAssistantMessagesAfterPrompt = 0;
  var lastSawTerminalStatusAfterPrompt = false;

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
    if (snapshot['pending_user_input'] != null) {
      if (onPendingUserInput != null) {
        await onPendingUserInput();
        await tester.pump(const Duration(milliseconds: 300));
        continue;
      }
      fail(
        'Codex thread $threadId unexpectedly requested user input during the $promptLabel turn.',
      );
    }

    final signals = _SnapshotTurnSignals.fromSnapshotEntries(
      snapshot['entries'] as List<dynamic>? ?? const [],
      expectedUserPromptCount: expectedUserPromptCount,
    );
    lastUserPrompts = signals.userPrompts;
    lastAssistantMessagesAfterPrompt = signals.assistantMessagesAfterPrompt;
    lastSawTerminalStatusAfterPrompt = signals.hasTerminalStatusAfterPrompt;

    final sawExpectedPrompt =
        signals.userPrompts.length >= expectedUserPromptCount &&
        signals.userPrompts[expectedUserPromptCount - 1] ==
            normalizedExpectedPrompt;

    if (failOnExcessUserPromptCount &&
        signals.userPrompts.length > expectedUserPromptCount) {
      fail(
        'Codex thread $threadId observed too many user prompts during the $promptLabel turn. '
        'expected=$expectedUserPromptCount '
        'observed=${signals.userPrompts.length} '
        'prompts="${signals.userPrompts.join(' || ')}"',
      );
    }

    final settledThreadStatus =
        rawStatus == ThreadStatus.completed.wireValue ||
        rawStatus == ThreadStatus.idle.wireValue;

    if (sawExpectedPrompt &&
        signals.assistantMessagesAfterPrompt > 0 &&
        (signals.hasTerminalStatusAfterPrompt || settledThreadStatus)) {
      return;
    }

    await tester.pump(const Duration(milliseconds: 400));
  }

  fail(
    'Timed out waiting for Codex thread $threadId to complete its $promptLabel turn. '
    'last_status=$lastStatus '
    'expected_user_prompt_count=$expectedUserPromptCount '
    'observed_user_prompts="${lastUserPrompts.join(' || ')}" '
    'assistant_messages_after_prompt=$lastAssistantMessagesAfterPrompt '
    'terminal_status_after_prompt=$lastSawTerminalStatusAfterPrompt',
  );
}

Future<Map<String, dynamic>> fetchThreadSnapshotJson({
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

class _SnapshotTurnSignals {
  const _SnapshotTurnSignals({
    required this.userPrompts,
    required this.assistantMessagesAfterPrompt,
    required this.hasTerminalStatusAfterPrompt,
  });

  final List<String> userPrompts;
  final int assistantMessagesAfterPrompt;
  final bool hasTerminalStatusAfterPrompt;

  factory _SnapshotTurnSignals.fromSnapshotEntries(
    List<dynamic> entries, {
    required int expectedUserPromptCount,
  }) {
    final userPrompts = <String>[];
    var assistantMessagesAfterPrompt = 0;
    var hasTerminalStatusAfterPrompt = false;
    var promptReached = false;

    for (final entry in entries) {
      if (entry is! Map<String, dynamic>) {
        continue;
      }

      final kind = entry['kind'] as String?;
      final payload = entry['payload'];
      if (payload is! Map<String, dynamic>) {
        continue;
      }

      if (kind == 'message_delta') {
        final role = (payload['role'] as String?)?.trim();
        if (_payloadContainsHiddenMessage(payload)) {
          continue;
        }
        final text = _extractMessageText(payload);
        if (text.isEmpty) {
          continue;
        }

        if (role == 'user') {
          userPrompts.add(text);
          if (userPrompts.length >= expectedUserPromptCount) {
            promptReached = true;
            assistantMessagesAfterPrompt = 0;
            hasTerminalStatusAfterPrompt = false;
          }
          continue;
        }

        if (promptReached && role == 'assistant') {
          assistantMessagesAfterPrompt += 1;
        }
        continue;
      }

      if (promptReached && kind == 'thread_status_changed') {
        final status = (payload['status'] as String?)?.trim();
        if (status == ThreadStatus.completed.wireValue ||
            status == ThreadStatus.interrupted.wireValue ||
            status == ThreadStatus.failed.wireValue) {
          hasTerminalStatusAfterPrompt = true;
        }
      }
    }

    return _SnapshotTurnSignals(
      userPrompts: userPrompts,
      assistantMessagesAfterPrompt: assistantMessagesAfterPrompt,
      hasTerminalStatusAfterPrompt: hasTerminalStatusAfterPrompt,
    );
  }
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
    final text = part['text'];
    if (text is String && text.trim().isNotEmpty) {
      buffer.write(text);
    }
  }
  return _normalizeText(buffer.toString());
}

String _normalizeText(String text) {
  return text.replaceAll(RegExp(r'\s+'), ' ').trim();
}

bool _payloadContainsHiddenMessage(Map<String, dynamic> payload) {
  final primaryText = _extractMessageText(payload);
  return _isHiddenMessage(primaryText);
}

bool _isHiddenMessage(String message) {
  final trimmed = message.trim();
  return trimmed.startsWith('# AGENTS.md instructions for ') ||
      trimmed.startsWith('<permissions instructions>') ||
      trimmed.startsWith('<app-context>') ||
      trimmed.startsWith('<environment_context>') ||
      trimmed.startsWith('<collaboration_mode>') ||
      trimmed.startsWith('<turn_aborted>') ||
      trimmed.startsWith('You are running in mobile plan intake mode.') ||
      trimmed.startsWith('You are continuing a mobile planning workflow.') ||
      trimmed.contains('<codex-plan-questions>');
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
