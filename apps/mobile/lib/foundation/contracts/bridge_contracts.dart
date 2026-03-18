const String contractVersion = '2026-03-17';

enum ThreadStatus { idle, running, completed, interrupted, failed }

enum AccessMode { readOnly, controlWithApprovals, fullControl }

enum ApprovalStatus { pending, approved, rejected }

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
    orElse: () =>
        throw FormatException('Unknown ThreadStatus wire value "$wireValue".'),
  );
}

AccessMode accessModeFromWire(String wireValue) {
  return AccessMode.values.firstWhere(
    (mode) => mode.wireValue == wireValue,
    orElse: () =>
        throw FormatException('Unknown AccessMode wire value "$wireValue".'),
  );
}

ApprovalStatus approvalStatusFromWire(String wireValue) {
  return ApprovalStatus.values.firstWhere(
    (status) => status.name == wireValue,
    orElse: () => throw FormatException(
      'Unknown ApprovalStatus wire value "$wireValue".',
    ),
  );
}

class RepositoryContextDto {
  const RepositoryContextDto({
    required this.workspace,
    required this.repository,
    required this.branch,
    required this.remote,
  });

  final String workspace;
  final String repository;
  final String branch;
  final String remote;

  factory RepositoryContextDto.fromJson(Map<String, dynamic> json) {
    return RepositoryContextDto(
      workspace: json['workspace'] as String,
      repository: json['repository'] as String,
      branch: json['branch'] as String,
      remote: json['remote'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'workspace': workspace,
      'repository': repository,
      'branch': branch,
      'remote': remote,
    };
  }
}

class GitStatusDto {
  const GitStatusDto({
    required this.dirty,
    required this.aheadBy,
    required this.behindBy,
  });

  final bool dirty;
  final int aheadBy;
  final int behindBy;

  factory GitStatusDto.fromJson(Map<String, dynamic> json) {
    return GitStatusDto(
      dirty: json['dirty'] as bool,
      aheadBy: json['ahead_by'] as int,
      behindBy: json['behind_by'] as int,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'dirty': dirty,
      'ahead_by': aheadBy,
      'behind_by': behindBy,
    };
  }
}

class GitStatusResponseDto {
  const GitStatusResponseDto({
    required this.contractVersion,
    required this.threadId,
    required this.repository,
    required this.status,
  });

  final String contractVersion;
  final String threadId;
  final RepositoryContextDto repository;
  final GitStatusDto status;

  factory GitStatusResponseDto.fromJson(Map<String, dynamic> json) {
    final repository = json['repository'];
    if (repository is! Map<String, dynamic>) {
      throw const FormatException(
        'Missing or invalid "repository" object in git status response.',
      );
    }

    final status = json['status'];
    if (status is! Map<String, dynamic>) {
      throw const FormatException(
        'Missing or invalid "status" object in git status response.',
      );
    }

    return GitStatusResponseDto(
      contractVersion: json['contract_version'] as String,
      threadId: json['thread_id'] as String,
      repository: RepositoryContextDto.fromJson(repository),
      status: GitStatusDto.fromJson(status),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'contract_version': contractVersion,
      'thread_id': threadId,
      'repository': repository.toJson(),
      'status': status.toJson(),
    };
  }
}

class ApprovalRecordDto {
  const ApprovalRecordDto({
    required this.contractVersion,
    required this.approvalId,
    required this.threadId,
    required this.action,
    required this.target,
    required this.reason,
    required this.status,
    required this.requestedAt,
    required this.resolvedAt,
    required this.repository,
    required this.gitStatus,
  });

  final String contractVersion;
  final String approvalId;
  final String threadId;
  final String action;
  final String target;
  final String reason;
  final ApprovalStatus status;
  final String requestedAt;
  final String? resolvedAt;
  final RepositoryContextDto repository;
  final GitStatusDto gitStatus;

  bool get isPending => status == ApprovalStatus.pending;

  factory ApprovalRecordDto.fromJson(Map<String, dynamic> json) {
    final repository = json['repository'];
    if (repository is! Map<String, dynamic>) {
      throw const FormatException(
        'Missing or invalid "repository" object in approval record.',
      );
    }

    final gitStatus = json['git_status'];
    if (gitStatus is! Map<String, dynamic>) {
      throw const FormatException(
        'Missing or invalid "git_status" object in approval record.',
      );
    }

    return ApprovalRecordDto(
      contractVersion: json['contract_version'] as String,
      approvalId: json['approval_id'] as String,
      threadId: json['thread_id'] as String,
      action: json['action'] as String,
      target: json['target'] as String,
      reason: json['reason'] as String,
      status: approvalStatusFromWire(json['status'] as String),
      requestedAt: json['requested_at'] as String,
      resolvedAt: json['resolved_at'] as String?,
      repository: RepositoryContextDto.fromJson(repository),
      gitStatus: GitStatusDto.fromJson(gitStatus),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'contract_version': contractVersion,
      'approval_id': approvalId,
      'thread_id': threadId,
      'action': action,
      'target': target,
      'reason': reason,
      'status': status.name,
      'requested_at': requestedAt,
      'resolved_at': resolvedAt,
      'repository': repository.toJson(),
      'git_status': gitStatus.toJson(),
    };
  }
}

class MutationResultResponseDto {
  const MutationResultResponseDto({
    required this.contractVersion,
    required this.threadId,
    required this.operation,
    required this.outcome,
    required this.message,
    required this.threadStatus,
    required this.repository,
    required this.status,
  });

  final String contractVersion;
  final String threadId;
  final String operation;
  final String outcome;
  final String message;
  final ThreadStatus threadStatus;
  final RepositoryContextDto repository;
  final GitStatusDto status;

  factory MutationResultResponseDto.fromJson(Map<String, dynamic> json) {
    final repository = json['repository'];
    if (repository is! Map<String, dynamic>) {
      throw const FormatException(
        'Missing or invalid "repository" object in mutation result.',
      );
    }

    final status = json['status'];
    if (status is! Map<String, dynamic>) {
      throw const FormatException(
        'Missing or invalid "status" object in mutation result.',
      );
    }

    return MutationResultResponseDto(
      contractVersion: json['contract_version'] as String,
      threadId: json['thread_id'] as String,
      operation: json['operation'] as String,
      outcome: json['outcome'] as String,
      message: json['message'] as String,
      threadStatus: threadStatusFromWire(json['thread_status'] as String),
      repository: RepositoryContextDto.fromJson(repository),
      status: GitStatusDto.fromJson(status),
    );
  }
}

class ApprovalResolutionResponseDto {
  const ApprovalResolutionResponseDto({
    required this.contractVersion,
    required this.approval,
    required this.mutationResult,
  });

  final String contractVersion;
  final ApprovalRecordDto approval;
  final MutationResultResponseDto? mutationResult;

  factory ApprovalResolutionResponseDto.fromJson(Map<String, dynamic> json) {
    final approvalJson = json['approval'];
    if (approvalJson is! Map<String, dynamic>) {
      throw const FormatException(
        'Missing or invalid "approval" object in resolution response.',
      );
    }

    final mutationResultJson = json['mutation_result'];

    return ApprovalResolutionResponseDto(
      contractVersion: json['contract_version'] as String,
      approval: ApprovalRecordDto.fromJson(approvalJson),
      mutationResult: mutationResultJson is Map<String, dynamic>
          ? MutationResultResponseDto.fromJson(mutationResultJson)
          : null,
    );
  }
}

BridgeEventKind bridgeEventKindFromWire(String wireValue) {
  return BridgeEventKind.values.firstWhere(
    (kind) => kind.wireValue == wireValue,
    orElse: () => throw FormatException(
      'Unknown BridgeEventKind wire value "$wireValue".',
    ),
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

class ThreadDetailDto {
  const ThreadDetailDto({
    required this.contractVersion,
    required this.threadId,
    required this.title,
    required this.status,
    required this.workspace,
    required this.repository,
    required this.branch,
    required this.createdAt,
    required this.updatedAt,
    required this.source,
    required this.accessMode,
    required this.lastTurnSummary,
  });

  final String contractVersion;
  final String threadId;
  final String title;
  final ThreadStatus status;
  final String workspace;
  final String repository;
  final String branch;
  final String createdAt;
  final String updatedAt;
  final String source;
  final AccessMode accessMode;
  final String lastTurnSummary;

  factory ThreadDetailDto.fromJson(Map<String, dynamic> json) {
    return ThreadDetailDto(
      contractVersion: json['contract_version'] as String,
      threadId: json['thread_id'] as String,
      title: json['title'] as String,
      status: threadStatusFromWire(json['status'] as String),
      workspace: json['workspace'] as String,
      repository: json['repository'] as String,
      branch: json['branch'] as String,
      createdAt: json['created_at'] as String,
      updatedAt: json['updated_at'] as String,
      source: json['source'] as String,
      accessMode: accessModeFromWire(json['access_mode'] as String),
      lastTurnSummary: json['last_turn_summary'] as String,
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
      'created_at': createdAt,
      'updated_at': updatedAt,
      'source': source,
      'access_mode': accessMode.wireValue,
      'last_turn_summary': lastTurnSummary,
    };
  }
}

class ThreadTimelineEntryDto {
  const ThreadTimelineEntryDto({
    required this.eventId,
    required this.kind,
    required this.occurredAt,
    required this.summary,
    required this.payload,
  });

  final String eventId;
  final BridgeEventKind kind;
  final String occurredAt;
  final String summary;
  final Map<String, dynamic> payload;

  factory ThreadTimelineEntryDto.fromJson(Map<String, dynamic> json) {
    final payload = json['payload'];
    if (payload is! Map<String, dynamic>) {
      throw const FormatException(
        'Missing or invalid "payload" in timeline event.',
      );
    }

    return ThreadTimelineEntryDto(
      eventId: json['event_id'] as String,
      kind: bridgeEventKindFromWire(json['kind'] as String),
      occurredAt: json['occurred_at'] as String,
      summary: json['summary'] as String,
      payload: payload,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'event_id': eventId,
      'kind': kind.wireValue,
      'occurred_at': occurredAt,
      'summary': summary,
      'payload': payload,
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
