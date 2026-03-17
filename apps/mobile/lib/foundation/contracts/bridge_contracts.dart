const String contractVersion = '2026-03-17';

enum ThreadStatus { idle, running, completed, interrupted, failed }

enum AccessMode { readOnly, controlWithApprovals, fullControl }

enum BridgeEventKind {
  messageDelta,
  planDelta,
  commandDelta,
  fileChange,
  approvalRequested,
  threadStatusChanged,
  securityAudit,
}

extension ThreadStatusWire on ThreadStatus {
  String get wireValue {
    switch (this) {
      case ThreadStatus.idle:
        return 'idle';
      case ThreadStatus.running:
        return 'running';
      case ThreadStatus.completed:
        return 'completed';
      case ThreadStatus.interrupted:
        return 'interrupted';
      case ThreadStatus.failed:
        return 'failed';
    }
  }
}

extension AccessModeWire on AccessMode {
  String get wireValue {
    switch (this) {
      case AccessMode.readOnly:
        return 'read_only';
      case AccessMode.controlWithApprovals:
        return 'control_with_approvals';
      case AccessMode.fullControl:
        return 'full_control';
    }
  }
}

extension BridgeEventKindWire on BridgeEventKind {
  String get wireValue {
    switch (this) {
      case BridgeEventKind.messageDelta:
        return 'message_delta';
      case BridgeEventKind.planDelta:
        return 'plan_delta';
      case BridgeEventKind.commandDelta:
        return 'command_delta';
      case BridgeEventKind.fileChange:
        return 'file_change';
      case BridgeEventKind.approvalRequested:
        return 'approval_requested';
      case BridgeEventKind.threadStatusChanged:
        return 'thread_status_changed';
      case BridgeEventKind.securityAudit:
        return 'security_audit';
    }
  }
}

ThreadStatus threadStatusFromWire(String wireValue) {
  return ThreadStatus.values.firstWhere(
    (status) => status.wireValue == wireValue,
    orElse: () => ThreadStatus.idle,
  );
}

AccessMode accessModeFromWire(String wireValue) {
  return AccessMode.values.firstWhere(
    (mode) => mode.wireValue == wireValue,
    orElse: () => AccessMode.readOnly,
  );
}

BridgeEventKind bridgeEventKindFromWire(String wireValue) {
  return BridgeEventKind.values.firstWhere(
    (kind) => kind.wireValue == wireValue,
    orElse: () => BridgeEventKind.messageDelta,
  );
}

class ThreadSummaryDto {
  const ThreadSummaryDto({
    required this.contractVersion,
    required this.threadId,
    required this.title,
    required this.status,
    required this.workspace,
    required this.repository,
    required this.branch,
    required this.updatedAt,
  });

  final String contractVersion;
  final String threadId;
  final String title;
  final ThreadStatus status;
  final String workspace;
  final String repository;
  final String branch;
  final String updatedAt;

  factory ThreadSummaryDto.fromJson(Map<String, dynamic> json) {
    return ThreadSummaryDto(
      contractVersion: json['contract_version'] as String,
      threadId: json['thread_id'] as String,
      title: json['title'] as String,
      status: threadStatusFromWire(json['status'] as String),
      workspace: json['workspace'] as String,
      repository: json['repository'] as String,
      branch: json['branch'] as String,
      updatedAt: json['updated_at'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'contract_version': contractVersion,
      'thread_id': threadId,
      'title': title,
      'status': status.wireValue,
      'workspace': workspace,
      'repository': repository,
      'branch': branch,
      'updated_at': updatedAt,
    };
  }
}

class SecurityAuditEventDto {
  const SecurityAuditEventDto({
    required this.actor,
    required this.action,
    required this.target,
    required this.outcome,
    required this.reason,
  });

  final String actor;
  final String action;
  final String target;
  final String outcome;
  final String reason;

  factory SecurityAuditEventDto.fromJson(Map<String, dynamic> json) {
    return SecurityAuditEventDto(
      actor: json['actor'] as String,
      action: json['action'] as String,
      target: json['target'] as String,
      outcome: json['outcome'] as String,
      reason: json['reason'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'actor': actor,
      'action': action,
      'target': target,
      'outcome': outcome,
      'reason': reason,
    };
  }
}

class BridgeEventEnvelope<TPayload> {
  const BridgeEventEnvelope({
    required this.contractVersion,
    required this.eventId,
    required this.threadId,
    required this.kind,
    required this.occurredAt,
    required this.payload,
  });

  final String contractVersion;
  final String eventId;
  final String threadId;
  final BridgeEventKind kind;
  final String occurredAt;
  final TPayload payload;

  factory BridgeEventEnvelope.fromJson(
    Map<String, dynamic> json,
    TPayload Function(Map<String, dynamic> payload) payloadDecoder,
  ) {
    return BridgeEventEnvelope<TPayload>(
      contractVersion: json['contract_version'] as String,
      eventId: json['event_id'] as String,
      threadId: json['thread_id'] as String,
      kind: bridgeEventKindFromWire(json['kind'] as String),
      occurredAt: json['occurred_at'] as String,
      payload: payloadDecoder(json['payload'] as Map<String, dynamic>),
    );
  }

  Map<String, dynamic> toJson(
    Object? Function(TPayload payload) payloadEncoder,
  ) {
    return <String, dynamic>{
      'contract_version': contractVersion,
      'event_id': eventId,
      'thread_id': threadId,
      'kind': kind.wireValue,
      'occurred_at': occurredAt,
      'payload': payloadEncoder(payload),
    };
  }
}
