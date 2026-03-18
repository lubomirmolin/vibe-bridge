import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';

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

class ThreadActivityItem {
  const ThreadActivityItem({
    required this.eventId,
    required this.kind,
    required this.type,
    required this.occurredAt,
    required this.title,
    required this.body,
    required this.payload,
  });

  final String eventId;
  final BridgeEventKind kind;
  final ThreadActivityItemType type;
  final String occurredAt;
  final String title;
  final String body;
  final Map<String, dynamic> payload;

  factory ThreadActivityItem.fromTimelineEntry(ThreadTimelineEntryDto entry) {
    return ThreadActivityItem._fromEvent(
      eventId: entry.eventId,
      kind: entry.kind,
      occurredAt: entry.occurredAt,
      summary: entry.summary,
      payload: entry.payload,
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
    );
  }

  factory ThreadActivityItem._fromEvent({
    required String eventId,
    required BridgeEventKind kind,
    required String occurredAt,
    required String summary,
    required Map<String, dynamic> payload,
  }) {
    final type = _mapType(kind, payload);
    final title = _titleForType(type);
    final body = _bodyForType(type, kind, payload, summary);

    return ThreadActivityItem(
      eventId: eventId,
      kind: kind,
      type: type,
      occurredAt: occurredAt,
      title: title,
      body: body,
      payload: payload,
    );
  }
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
    case BridgeEventKind.commandDelta:
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
  String fallbackSummary,
) {
  switch (type) {
    case ThreadActivityItemType.userPrompt:
    case ThreadActivityItemType.assistantOutput:
      return _extractMessageText(payload) ?? fallbackSummary;
    case ThreadActivityItemType.planUpdate:
      return _extractPlanText(payload) ?? fallbackSummary;
    case ThreadActivityItemType.terminalOutput:
      final command = _optionalString(payload, 'command') ??
          _optionalString(payload, 'action');
      final delta = _optionalString(payload, 'delta') ??
          _optionalString(payload, 'output') ??
          _optionalString(payload, 'text');
      if (command != null && delta != null) {
        return '`$command`\n$delta';
      }
      return delta ?? command ?? fallbackSummary;
    case ThreadActivityItemType.fileChange:
      final path = _optionalString(payload, 'path') ??
          _optionalString(payload, 'file') ??
          _optionalString(payload, 'file_path') ??
          _optionalString(payload, 'target');
      final summary = _optionalString(payload, 'summary') ??
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
      return _optionalString(payload, 'reason') ?? fallbackSummary;
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

String _extractSummary(BridgeEventKind kind, Map<String, dynamic> payload) {
  return _extractMessageText(payload) ??
      _extractPlanText(payload) ??
      _optionalString(payload, 'summary') ??
      _optionalString(payload, 'delta') ??
      _optionalString(payload, 'message') ??
      kind.wireValue;
}

String? _extractMessageText(Map<String, dynamic> payload) {
  final delta = _optionalString(payload, 'delta');
  if (delta != null) {
    return delta;
  }

  final text = _optionalString(payload, 'text');
  if (text != null) {
    return text;
  }

  final content = payload['content'];
  if (content is List) {
    for (final item in content) {
      if (item is Map<String, dynamic>) {
        final contentText = _optionalString(item, 'text');
        if (contentText != null) {
          return contentText;
        }
      }
    }
  }

  return null;
}

String? _extractPlanText(Map<String, dynamic> payload) {
  return _optionalString(payload, 'delta') ??
      _optionalString(payload, 'instruction') ??
      _optionalString(payload, 'text') ??
      _optionalString(payload, 'phase');
}

String? _optionalString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    return null;
  }
  return value.trim();
}
