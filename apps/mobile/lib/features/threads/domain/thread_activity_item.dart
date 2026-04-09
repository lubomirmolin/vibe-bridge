import 'dart:convert';

import 'package:vibe_bridge/foundation/contracts/bridge_contracts.dart';
import 'package:vibe_bridge/features/threads/domain/parsed_command_output.dart';

enum ThreadActivityItemType {
  userPrompt,
  assistantOutput,
  planUpdate,
  terminalOutput,
  fileChange,
  lifecycleUpdate,
  approvalRequest,
  securityEvent,
  generic,
}

enum ThreadActivityPresentationGroupKind { exploration }

enum ThreadActivityPresentationEntryKind { read, search, generic }

class ThreadActivityPresentation {
  const ThreadActivityPresentation({
    required this.groupKind,
    required this.entryKind,
    this.entryLabel,
  });

  final ThreadActivityPresentationGroupKind groupKind;
  final ThreadActivityPresentationEntryKind entryKind;
  final String? entryLabel;

  factory ThreadActivityPresentation.fromAnnotations(
    ThreadTimelineAnnotationsDto annotations,
  ) {
    return ThreadActivityPresentation(
      groupKind: switch (annotations.groupKind) {
        ThreadTimelineGroupKind.exploration =>
          ThreadActivityPresentationGroupKind.exploration,
        null => ThreadActivityPresentationGroupKind.exploration,
      },
      entryKind: switch (annotations.explorationKind) {
        ThreadTimelineExplorationKind.read =>
          ThreadActivityPresentationEntryKind.read,
        ThreadTimelineExplorationKind.search =>
          ThreadActivityPresentationEntryKind.search,
        null => ThreadActivityPresentationEntryKind.generic,
      },
      entryLabel: annotations.entryLabel,
    );
  }
}

enum ThreadPlanStepStatus { pending, inProgress, completed, unknown }

enum ThreadActivityLocalMessageState { none, sending, failed }

class ThreadPlanStep {
  const ThreadPlanStep({required this.step, required this.status});

  final String step;
  final ThreadPlanStepStatus status;
}

class ThreadPlanSnapshot {
  const ThreadPlanSnapshot({
    required this.steps,
    required this.completedCount,
    required this.totalCount,
    this.explanation,
  });

  final List<ThreadPlanStep> steps;
  final int completedCount;
  final int totalCount;
  final String? explanation;

  bool get hasSteps => steps.isNotEmpty;

  String get progressLabel {
    final taskLabel = totalCount == 1 ? 'task' : 'tasks';
    return '$completedCount out of $totalCount $taskLabel completed';
  }

  String renderText() {
    if (!hasSteps) {
      return explanation ?? '';
    }

    final lines = <String>[
      progressLabel,
      for (var index = 0; index < steps.length; index++)
        '${index + 1}. ${steps[index].step}',
    ];
    return lines.join('\n');
  }

  factory ThreadPlanSnapshot.fromPayload(Map<String, dynamic> payload) {
    final rawSteps = payload['steps'];
    final steps = <ThreadPlanStep>[
      if (rawSteps is List)
        for (final entry in rawSteps)
          if (entry is Map<String, dynamic>)
            if (_optionalString(entry, 'step') case final String step)
              ThreadPlanStep(
                step: step,
                status: _threadPlanStepStatusFromWire(
                  _optionalString(entry, 'status'),
                ),
              ),
    ];

    final completedCount =
        (payload['completed_count'] as num?)?.toInt() ??
        steps
            .where((entry) => entry.status == ThreadPlanStepStatus.completed)
            .length;
    final totalCount =
        (payload['total_count'] as num?)?.toInt() ?? steps.length;
    final explanation = _optionalString(payload, 'explanation');

    return ThreadPlanSnapshot(
      steps: List<ThreadPlanStep>.unmodifiable(steps),
      completedCount: completedCount,
      totalCount: totalCount,
      explanation: explanation,
    );
  }
}

class ThreadActivityItem {
  const ThreadActivityItem({
    required this.eventId,
    required this.kind,
    required this.type,
    required this.occurredAt,
    required this.title,
    required this.body,
    required this.payload,
    this.clientMessageId,
    this.messageImageUrls = const <String>[],
    this.presentation,
    this.parsedCommandOutput,
    this.plan,
    this.startsNewVisualGroup = false,
    this.localMessageState = ThreadActivityLocalMessageState.none,
    this.localErrorMessage,
  });

  final String eventId;
  final BridgeEventKind kind;
  final ThreadActivityItemType type;
  final String occurredAt;
  final String title;
  final String body;
  final Map<String, dynamic> payload;
  final String? clientMessageId;
  final List<String> messageImageUrls;
  final ThreadActivityPresentation? presentation;
  final ParsedCommandOutput? parsedCommandOutput;
  final ThreadPlanSnapshot? plan;
  final bool startsNewVisualGroup;
  final ThreadActivityLocalMessageState localMessageState;
  final String? localErrorMessage;

  factory ThreadActivityItem.fromTimelineEntry(ThreadTimelineEntryDto entry) {
    return ThreadActivityItem._fromEvent(
      eventId: entry.eventId,
      kind: entry.kind,
      occurredAt: entry.occurredAt,
      summary: entry.summary,
      payload: entry.payload,
      annotations: entry.annotations,
    );
  }

  factory ThreadActivityItem.fromLiveEvent(
    BridgeEventEnvelope<Map<String, dynamic>> event,
  ) {
    return ThreadActivityItem._fromEvent(
      eventId: event.eventId,
      kind: event.kind,
      occurredAt: event.occurredAt,
      summary: _extractSummary(event.kind, event.payload),
      payload: event.payload,
      annotations: event.annotations,
    );
  }

  factory ThreadActivityItem._fromEvent({
    required String eventId,
    required BridgeEventKind kind,
    required String occurredAt,
    required String summary,
    required Map<String, dynamic> payload,
    ThreadTimelineAnnotationsDto? annotations,
  }) {
    final type = _mapType(kind, payload);
    final plan = type == ThreadActivityItemType.planUpdate
        ? _extractPlanSnapshot(payload)
        : null;
    final title = _titleForType(type);
    final body = _bodyForType(type, kind, payload, summary, plan: plan);
    final messageImageUrls = _extractMessageImageUrls(payload);
    final presentation = _extractPresentation(annotations);

    ParsedCommandOutput? parsedCommandOutput;
    if (type == ThreadActivityItemType.terminalOutput ||
        type == ThreadActivityItemType.fileChange) {
      parsedCommandOutput = ParsedCommandOutput.parse(body);
    }

    return ThreadActivityItem(
      eventId: eventId,
      kind: kind,
      type: type,
      occurredAt: occurredAt,
      title: title,
      body: body,
      payload: payload,
      clientMessageId: _optionalString(payload, 'client_message_id'),
      messageImageUrls: messageImageUrls,
      presentation: presentation,
      parsedCommandOutput: parsedCommandOutput,
      plan: plan,
    );
  }

  factory ThreadActivityItem.localUserPrompt({
    required String eventId,
    required String occurredAt,
    required String body,
    String? clientMessageId,
    List<String> messageImageUrls = const <String>[],
    ThreadActivityLocalMessageState localMessageState =
        ThreadActivityLocalMessageState.sending,
    String? localErrorMessage,
  }) {
    return ThreadActivityItem(
      eventId: eventId,
      kind: BridgeEventKind.messageDelta,
      type: ThreadActivityItemType.userPrompt,
      occurredAt: occurredAt,
      title: _titleForType(ThreadActivityItemType.userPrompt),
      body: body,
      payload: <String, dynamic>{
        'type': 'message',
        'role': 'user',
        'text': body,
        ...?clientMessageId == null
            ? null
            : <String, dynamic>{'client_message_id': clientMessageId},
        'images': messageImageUrls,
      },
      clientMessageId: clientMessageId,
      messageImageUrls: messageImageUrls,
      localMessageState: localMessageState,
      localErrorMessage: localErrorMessage,
    );
  }

  ThreadActivityItem copyWith({
    bool? startsNewVisualGroup,
    ThreadActivityLocalMessageState? localMessageState,
    String? localErrorMessage,
    bool clearLocalErrorMessage = false,
  }) {
    return ThreadActivityItem(
      eventId: eventId,
      kind: kind,
      type: type,
      occurredAt: occurredAt,
      title: title,
      body: body,
      payload: payload,
      clientMessageId: clientMessageId,
      messageImageUrls: messageImageUrls,
      presentation: presentation,
      parsedCommandOutput: parsedCommandOutput,
      plan: plan,
      startsNewVisualGroup: startsNewVisualGroup ?? this.startsNewVisualGroup,
      localMessageState: localMessageState ?? this.localMessageState,
      localErrorMessage: clearLocalErrorMessage
          ? null
          : (localErrorMessage ?? this.localErrorMessage),
    );
  }
}

ThreadActivityPresentation? _extractPresentation(
  ThreadTimelineAnnotationsDto? annotations,
) {
  if (annotations?.groupKind == null) {
    return null;
  }

  return ThreadActivityPresentation.fromAnnotations(annotations!);
}

ThreadActivityItemType _mapType(
  BridgeEventKind kind,
  Map<String, dynamic> payload,
) {
  switch (kind) {
    case BridgeEventKind.messageDelta:
      return _isUserMessagePayload(payload)
          ? ThreadActivityItemType.userPrompt
          : ThreadActivityItemType.assistantOutput;
    case BridgeEventKind.planDelta:
      return ThreadActivityItemType.planUpdate;
    case BridgeEventKind.userInputRequested:
      return ThreadActivityItemType.generic;
    case BridgeEventKind.commandDelta:
      if (_isCommandPayloadLikelyFileChange(payload)) {
        return ThreadActivityItemType.fileChange;
      }
      return ThreadActivityItemType.terminalOutput;
    case BridgeEventKind.fileChange:
      return ThreadActivityItemType.fileChange;
    case BridgeEventKind.threadStatusChanged:
      return ThreadActivityItemType.lifecycleUpdate;
    case BridgeEventKind.approvalRequested:
      return ThreadActivityItemType.approvalRequest;
    case BridgeEventKind.securityAudit:
      return ThreadActivityItemType.securityEvent;
  }
}

bool _isCommandPayloadLikelyFileChange(Map<String, dynamic> payload) {
  final output = _optionalString(payload, 'output');
  if (output != null && output.isNotEmpty) {
    if (output.contains('[diff_block_start]') ||
        output.contains('*** Begin Patch') ||
        output.contains('*** Update File:') ||
        output.contains('diff --git ') ||
        output.contains('Success. Updated the following files:')) {
      return true;
    }

    if (RegExp(
      r'^(?:\s?[MADRCU?]{1,2})\s+.+$',
      multiLine: true,
    ).hasMatch(output)) {
      return true;
    }
  }

  final arguments = _optionalString(payload, 'arguments');
  if (arguments != null && arguments.isNotEmpty) {
    if (arguments.contains('git diff') ||
        arguments.contains('git status') ||
        arguments.contains('apply_patch') ||
        arguments.contains('*** Begin Patch')) {
      return true;
    }
  }

  return false;
}

bool _isUserMessagePayload(Map<String, dynamic> payload) {
  final role = payload['role'];
  if (role is String && role.toLowerCase() == 'user') {
    return true;
  }

  final source = payload['source'];
  if (source is String && source.toLowerCase() == 'user') {
    return true;
  }

  final type = payload['type'];
  if (type is String && type == 'userMessage') {
    return true;
  }

  return false;
}

String _titleForType(ThreadActivityItemType type) {
  switch (type) {
    case ThreadActivityItemType.userPrompt:
      return 'User prompt';
    case ThreadActivityItemType.assistantOutput:
      return 'Assistant output';
    case ThreadActivityItemType.planUpdate:
      return 'Plan update';
    case ThreadActivityItemType.terminalOutput:
      return 'Terminal output';
    case ThreadActivityItemType.fileChange:
      return 'File change';
    case ThreadActivityItemType.lifecycleUpdate:
      return 'Thread lifecycle';
    case ThreadActivityItemType.approvalRequest:
      return 'Approval requested';
    case ThreadActivityItemType.securityEvent:
      return 'Security event';
    case ThreadActivityItemType.generic:
      return 'Event';
  }
}

String _bodyForType(
  ThreadActivityItemType type,
  BridgeEventKind kind,
  Map<String, dynamic> payload,
  String fallbackSummary, {
  ThreadPlanSnapshot? plan,
}) {
  switch (type) {
    case ThreadActivityItemType.userPrompt:
    case ThreadActivityItemType.assistantOutput:
      return _extractMessageText(payload) ?? '';
    case ThreadActivityItemType.planUpdate:
      if (plan != null && plan.hasSteps) {
        return plan.renderText();
      }
      return _extractPlanText(payload) ?? fallbackSummary;
    case ThreadActivityItemType.terminalOutput:
      final normalizedBackgroundTerminal = _normalizeBackgroundTerminalBody(
        payload,
        fallbackSummary,
      );
      if (normalizedBackgroundTerminal != null) {
        return normalizedBackgroundTerminal;
      }
      final command =
          _optionalString(payload, 'command') ??
          _optionalString(payload, 'action');
      final delta =
          _optionalString(payload, 'delta') ??
          _optionalString(payload, 'output') ??
          _optionalString(payload, 'text');
      if (command != null && delta != null) {
        return '`$command`\n$delta';
      }
      return delta ?? command ?? fallbackSummary;
    case ThreadActivityItemType.fileChange:
      final resolvedUnifiedDiff = _optionalString(
        payload,
        'resolved_unified_diff',
      );
      if (resolvedUnifiedDiff != null && resolvedUnifiedDiff.isNotEmpty) {
        return resolvedUnifiedDiff;
      }

      if (kind == BridgeEventKind.commandDelta) {
        final normalizedBackgroundTerminal = _normalizeBackgroundTerminalBody(
          payload,
          fallbackSummary,
        );
        if (normalizedBackgroundTerminal != null) {
          return normalizedBackgroundTerminal;
        }

        final output = _optionalString(payload, 'output');
        if (output != null && output.isNotEmpty) {
          return output;
        }
        final arguments = _optionalString(payload, 'arguments');
        if (arguments != null && arguments.isNotEmpty) {
          return arguments;
        }
      }

      final path =
          _optionalString(payload, 'path') ??
          _optionalString(payload, 'file') ??
          _optionalString(payload, 'file_path') ??
          _optionalString(payload, 'target');
      final summary =
          _optionalString(payload, 'summary') ??
          _optionalString(payload, 'change') ??
          _optionalString(payload, 'delta');
      if (path != null && summary != null) {
        return '$path\n$summary';
      }
      return summary ?? path ?? fallbackSummary;
    case ThreadActivityItemType.lifecycleUpdate:
      final status = _optionalString(payload, 'status');
      final reason = _optionalString(payload, 'reason');
      if (status != null && reason != null) {
        return 'Status: $status\nReason: $reason';
      }
      return status != null ? 'Status: $status' : fallbackSummary;
    case ThreadActivityItemType.approvalRequest:
      final action = _optionalString(payload, 'action');
      final target = _optionalString(payload, 'target');
      final status = _optionalString(payload, 'status');
      final reason = _optionalString(payload, 'reason');
      final details = <String>[
        if (action != null) 'Action: $action',
        if (target != null) 'Target: $target',
        if (status != null) 'Status: $status',
        if (reason != null) 'Reason: $reason',
      ];
      if (details.isNotEmpty) {
        return details.join('\n');
      }
      return fallbackSummary;
    case ThreadActivityItemType.securityEvent:
      final outcome = _optionalString(payload, 'outcome');
      final reason = _optionalString(payload, 'reason');
      if (outcome != null && reason != null) {
        return '$outcome\n$reason';
      }
      return reason ?? outcome ?? fallbackSummary;
    case ThreadActivityItemType.generic:
      return _extractSummary(kind, payload);
  }
}

ThreadPlanSnapshot? _extractPlanSnapshot(Map<String, dynamic> payload) {
  final rawSteps = payload['steps'];
  final hasStructuredSteps = rawSteps is List && rawSteps.isNotEmpty;
  final hasCounts =
      payload['completed_count'] is num || payload['total_count'] is num;
  final explanation = _optionalString(payload, 'explanation');

  if (!hasStructuredSteps && !hasCounts && explanation == null) {
    return null;
  }

  return ThreadPlanSnapshot.fromPayload(payload);
}

String? _normalizeBackgroundTerminalBody(
  Map<String, dynamic> payload,
  String fallbackSummary,
) {
  final invocation = _extractBackgroundTerminalInvocation(
    payload,
    fallbackSummary,
  );
  if (invocation == null) {
    return null;
  }

  final details = <String>[
    'Background terminal finished with ${invocation.cmd}',
    if (invocation.workdir != null && invocation.workdir!.isNotEmpty)
      'Working directory: ${invocation.workdir}',
  ];

  return 'Command: ${invocation.cmd}\nOutput:\n${details.join('\n')}';
}

_BackgroundTerminalInvocation? _extractBackgroundTerminalInvocation(
  Map<String, dynamic> payload,
  String fallbackSummary,
) {
  final toolName =
      _optionalString(payload, 'command') ?? _optionalString(payload, 'action');
  final arguments = payload['arguments'];
  final input = payload['input'];

  Map<String, dynamic>? decoded;
  if (arguments is Map<String, dynamic>) {
    decoded = arguments;
  } else if (arguments is String) {
    decoded = _tryDecodeJsonObject(arguments);
  }

  decoded ??= input is Map<String, dynamic>
      ? input
      : input is String
      ? _tryDecodeJsonObject(input)
      : null;

  final cmd =
      (decoded != null ? _optionalString(decoded, 'cmd') : null) ??
      _optionalString(payload, 'cmd');
  if (cmd == null || cmd.trim().isEmpty) {
    return null;
  }

  final isExecCommand =
      toolName == 'exec_command' ||
      fallbackSummary.toLowerCase().contains('exec_command');
  if (!isExecCommand && decoded == null) {
    return null;
  }

  return _BackgroundTerminalInvocation(
    cmd: cmd,
    workdir:
        (decoded != null ? _optionalString(decoded, 'workdir') : null) ??
        _optionalString(payload, 'workdir'),
  );
}

Map<String, dynamic>? _tryDecodeJsonObject(String raw) {
  final trimmed = raw.trim();
  if (!trimmed.startsWith('{') || !trimmed.endsWith('}')) {
    return null;
  }

  try {
    final decoded = jsonDecode(trimmed);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
  } catch (_) {
    return null;
  }

  return null;
}

class _BackgroundTerminalInvocation {
  const _BackgroundTerminalInvocation({required this.cmd, this.workdir});

  final String cmd;
  final String? workdir;
}

String _extractSummary(BridgeEventKind kind, Map<String, dynamic> payload) {
  return _extractMessageText(payload) ??
      _extractPlanText(payload) ??
      _optionalString(payload, 'summary') ??
      _optionalString(payload, 'delta') ??
      _optionalString(payload, 'message') ??
      kind.wireValue;
}

String? _extractMessageText(Map<String, dynamic> payload) {
  final text = _optionalString(payload, 'text');
  if (text != null) {
    return text;
  }

  final delta = _optionalString(payload, 'delta');
  if (delta != null) {
    return delta;
  }

  final content = payload['content'];
  if (content is List) {
    final texts = <String>[];
    for (final item in content) {
      if (item is Map<String, dynamic>) {
        final contentText = _optionalString(item, 'text');
        if (contentText != null) {
          texts.add(contentText);
        }
      }
    }
    if (texts.isNotEmpty) {
      return texts.join('\n');
    }
  }

  return null;
}

List<String> _extractMessageImageUrls(Map<String, dynamic> payload) {
  final urls = <String>[];

  final content = payload['content'];
  if (content is List) {
    for (final item in content) {
      if (item is! Map<String, dynamic>) {
        continue;
      }
      final itemType = item['type'];
      if (itemType is! String) {
        continue;
      }
      if (itemType == 'image' || itemType == 'input_image') {
        final imageUrl =
            _optionalString(item, 'image_url') ?? _optionalString(item, 'url');
        if (imageUrl != null) {
          urls.add(imageUrl);
        }
      }
    }
  }

  final images = payload['images'];
  if (images is List) {
    for (final item in images) {
      if (item is String && item.trim().isNotEmpty) {
        urls.add(item.trim());
      }
    }
  }

  return urls.toSet().toList(growable: false);
}

String? _extractPlanText(Map<String, dynamic> payload) {
  return _optionalString(payload, 'delta') ??
      _optionalString(payload, 'instruction') ??
      _optionalString(payload, 'text') ??
      _optionalString(payload, 'phase');
}

ThreadPlanStepStatus _threadPlanStepStatusFromWire(String? value) {
  switch (value) {
    case 'pending':
      return ThreadPlanStepStatus.pending;
    case 'in_progress':
      return ThreadPlanStepStatus.inProgress;
    case 'completed':
      return ThreadPlanStepStatus.completed;
    case null:
      return ThreadPlanStepStatus.pending;
    default:
      return ThreadPlanStepStatus.unknown;
  }
}

String? _optionalString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    return null;
  }
  return value.trim();
}
