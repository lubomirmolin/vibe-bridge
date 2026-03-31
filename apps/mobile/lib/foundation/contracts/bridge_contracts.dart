const String contractVersion = '2026-03-29';

enum ThreadStatus { idle, running, completed, interrupted, failed }

enum TurnMode { act, plan }

enum AccessMode { readOnly, controlWithApprovals, fullControl }

enum BridgeApiRouteKind { tailscale, localNetwork }

enum ProviderKind { codex, claudeCode }

enum ThreadClientKind {
  cli,
  vscode,
  remoteControl,
  desktopIpc,
  archive,
  bridge,
  unknown,
}

enum ApprovalStatus { pending, approved, rejected }

enum SpeechModelState {
  unsupported,
  notInstalled,
  installing,
  ready,
  busy,
  failed,
}

enum BridgeEventKind {
  messageDelta,
  planDelta,
  userInputRequested,
  commandDelta,
  fileChange,
  approvalRequested,
  threadStatusChanged,
  securityAudit,
}

enum ThreadGitDiffMode { workspace, latestThreadChange }

enum GitDiffChangeType {
  added,
  modified,
  deleted,
  renamed,
  copied,
  typeChanged,
  unmerged,
  unknown,
}

enum ThreadTimelineGroupKind { exploration }

enum ThreadTimelineExplorationKind { read, search }

ProviderKind providerKindFromWire(String wireValue) {
  switch (wireValue) {
    case 'codex':
      return ProviderKind.codex;
    case 'claude_code':
      return ProviderKind.claudeCode;
    default:
      throw FormatException('Unknown ProviderKind wire value "$wireValue".');
  }
}

extension ProviderKindWire on ProviderKind {
  String get wireValue {
    switch (this) {
      case ProviderKind.codex:
        return 'codex';
      case ProviderKind.claudeCode:
        return 'claude_code';
    }
  }
}

ThreadClientKind threadClientKindFromWire(String wireValue) {
  switch (wireValue) {
    case 'cli':
      return ThreadClientKind.cli;
    case 'vscode':
      return ThreadClientKind.vscode;
    case 'remote_control':
      return ThreadClientKind.remoteControl;
    case 'desktop_ipc':
      return ThreadClientKind.desktopIpc;
    case 'archive':
      return ThreadClientKind.archive;
    case 'bridge':
      return ThreadClientKind.bridge;
    case 'unknown':
      return ThreadClientKind.unknown;
    default:
      throw FormatException(
        'Unknown ThreadClientKind wire value "$wireValue".',
      );
  }
}

ThreadClientKind threadClientKindFromSource(String source) {
  switch (source) {
    case 'cli':
      return ThreadClientKind.cli;
    case 'vscode':
      return ThreadClientKind.vscode;
    case 'remote_control':
    case 'remote-control':
      return ThreadClientKind.remoteControl;
    case 'desktop_ipc':
    case 'codex_app_ipc':
      return ThreadClientKind.desktopIpc;
    case 'archive':
      return ThreadClientKind.archive;
    case 'bridge':
      return ThreadClientKind.bridge;
    default:
      return ThreadClientKind.unknown;
  }
}

ProviderKind providerKindFromThreadId(String threadId) {
  if (threadId.startsWith('claude:')) {
    return ProviderKind.claudeCode;
  }
  return ProviderKind.codex;
}

String nativeThreadIdFromThreadId(String threadId) {
  final separator = threadId.indexOf(':');
  if (separator <= 0 || separator == threadId.length - 1) {
    return threadId;
  }
  return threadId.substring(separator + 1);
}

extension ThreadClientKindWire on ThreadClientKind {
  String get wireValue {
    switch (this) {
      case ThreadClientKind.cli:
        return 'cli';
      case ThreadClientKind.vscode:
        return 'vscode';
      case ThreadClientKind.remoteControl:
        return 'remote_control';
      case ThreadClientKind.desktopIpc:
        return 'desktop_ipc';
      case ThreadClientKind.archive:
        return 'archive';
      case ThreadClientKind.bridge:
        return 'bridge';
      case ThreadClientKind.unknown:
        return 'unknown';
    }
  }
}

BridgeApiRouteKind bridgeApiRouteKindFromWire(String wireValue) {
  switch (wireValue) {
    case 'tailscale':
      return BridgeApiRouteKind.tailscale;
    case 'local_network':
      return BridgeApiRouteKind.localNetwork;
    default:
      throw FormatException(
        'Unknown BridgeApiRouteKind wire value "$wireValue".',
      );
  }
}

extension BridgeApiRouteKindWire on BridgeApiRouteKind {
  String get wireValue {
    switch (this) {
      case BridgeApiRouteKind.tailscale:
        return 'tailscale';
      case BridgeApiRouteKind.localNetwork:
        return 'local_network';
    }
  }
}

class BridgeApiRouteDto {
  const BridgeApiRouteDto({
    required this.id,
    required this.kind,
    required this.baseUrl,
    required this.reachable,
    required this.isPreferred,
  });

  final String id;
  final BridgeApiRouteKind kind;
  final String baseUrl;
  final bool reachable;
  final bool isPreferred;

  factory BridgeApiRouteDto.fromJson(Map<String, dynamic> json) {
    return BridgeApiRouteDto(
      id: json['id'] as String,
      kind: bridgeApiRouteKindFromWire(json['kind'] as String),
      baseUrl: json['base_url'] as String,
      reachable: json['reachable'] as bool? ?? false,
      isPreferred: json['is_preferred'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'kind': kind.wireValue,
      'base_url': baseUrl,
      'reachable': reachable,
      'is_preferred': isPreferred,
    };
  }
}

class PairingRouteInventoryDto {
  const PairingRouteInventoryDto({
    required this.reachable,
    required this.routes,
    this.advertisedBaseUrl,
    this.message,
  });

  final bool reachable;
  final String? advertisedBaseUrl;
  final List<BridgeApiRouteDto> routes;
  final String? message;

  factory PairingRouteInventoryDto.fromJson(Map<String, dynamic> json) {
    final routes = json['routes'];
    if (routes is! List<dynamic>) {
      throw const FormatException(
        'Missing or invalid "routes" in pairing route response.',
      );
    }
    return PairingRouteInventoryDto(
      reachable: json['reachable'] as bool? ?? false,
      advertisedBaseUrl: json['advertised_base_url'] as String?,
      routes: routes
          .map((entry) {
            if (entry is! Map<String, dynamic>) {
              throw const FormatException('Invalid bridge route entry.');
            }
            return BridgeApiRouteDto.fromJson(entry);
          })
          .toList(growable: false),
      message: json['message'] as String?,
    );
  }
}

class NetworkSettingsDto {
  const NetworkSettingsDto({
    required this.contractVersion,
    required this.localNetworkPairingEnabled,
    required this.routes,
    this.message,
  });

  final String contractVersion;
  final bool localNetworkPairingEnabled;
  final List<BridgeApiRouteDto> routes;
  final String? message;

  factory NetworkSettingsDto.fromJson(Map<String, dynamic> json) {
    final routes = json['routes'];
    if (routes is! List<dynamic>) {
      throw const FormatException(
        'Missing or invalid "routes" in network settings response.',
      );
    }
    return NetworkSettingsDto(
      contractVersion: json['contract_version'] as String,
      localNetworkPairingEnabled:
          json['local_network_pairing_enabled'] as bool? ?? false,
      routes: routes
          .map((entry) {
            if (entry is! Map<String, dynamic>) {
              throw const FormatException('Invalid bridge route entry.');
            }
            return BridgeApiRouteDto.fromJson(entry);
          })
          .toList(growable: false),
      message: json['message'] as String?,
    );
  }
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
      case BridgeEventKind.userInputRequested:
        return 'user_input_requested';
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

extension TurnModeWire on TurnMode {
  String get wireValue {
    switch (this) {
      case TurnMode.act:
        return 'act';
      case TurnMode.plan:
        return 'plan';
    }
  }
}

extension ThreadTimelineGroupKindWire on ThreadTimelineGroupKind {
  String get wireValue {
    switch (this) {
      case ThreadTimelineGroupKind.exploration:
        return 'exploration';
    }
  }
}

extension ThreadTimelineExplorationKindWire on ThreadTimelineExplorationKind {
  String get wireValue {
    switch (this) {
      case ThreadTimelineExplorationKind.read:
        return 'read';
      case ThreadTimelineExplorationKind.search:
        return 'search';
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

extension SpeechModelStateWire on SpeechModelState {
  String get wireValue {
    switch (this) {
      case SpeechModelState.unsupported:
        return 'unsupported';
      case SpeechModelState.notInstalled:
        return 'not_installed';
      case SpeechModelState.installing:
        return 'installing';
      case SpeechModelState.ready:
        return 'ready';
      case SpeechModelState.busy:
        return 'busy';
      case SpeechModelState.failed:
        return 'failed';
    }
  }
}

SpeechModelState speechModelStateFromWire(String wireValue) {
  return SpeechModelState.values.firstWhere(
    (state) => state.wireValue == wireValue,
    orElse: () => throw FormatException(
      'Unknown SpeechModelState wire value "$wireValue".',
    ),
  );
}

ThreadGitDiffMode threadGitDiffModeFromWire(String wireValue) {
  return ThreadGitDiffMode.values.firstWhere(
    (mode) => mode.wireValue == wireValue,
    orElse: () => throw FormatException(
      'Unknown ThreadGitDiffMode wire value "$wireValue".',
    ),
  );
}

GitDiffChangeType gitDiffChangeTypeFromWire(String wireValue) {
  return GitDiffChangeType.values.firstWhere(
    (changeType) => changeType.wireValue == wireValue,
    orElse: () => GitDiffChangeType.unknown,
  );
}

extension ThreadGitDiffModeWire on ThreadGitDiffMode {
  String get wireValue {
    switch (this) {
      case ThreadGitDiffMode.workspace:
        return 'workspace';
      case ThreadGitDiffMode.latestThreadChange:
        return 'latest_thread_change';
    }
  }
}

extension GitDiffChangeTypeWire on GitDiffChangeType {
  String get wireValue {
    switch (this) {
      case GitDiffChangeType.added:
        return 'added';
      case GitDiffChangeType.modified:
        return 'modified';
      case GitDiffChangeType.deleted:
        return 'deleted';
      case GitDiffChangeType.renamed:
        return 'renamed';
      case GitDiffChangeType.copied:
        return 'copied';
      case GitDiffChangeType.typeChanged:
        return 'type_changed';
      case GitDiffChangeType.unmerged:
        return 'unmerged';
      case GitDiffChangeType.unknown:
        return 'unknown';
    }
  }
}

class ReasoningEffortOptionDto {
  const ReasoningEffortOptionDto({
    required this.reasoningEffort,
    this.description,
  });

  final String reasoningEffort;
  final String? description;

  factory ReasoningEffortOptionDto.fromJson(Map<String, dynamic> json) {
    return ReasoningEffortOptionDto(
      reasoningEffort: json['reasoning_effort'] as String,
      description: json['description'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'reasoning_effort': reasoningEffort,
      if (description != null) 'description': description,
    };
  }
}

class ModelOptionDto {
  const ModelOptionDto({
    required this.id,
    required this.model,
    required this.displayName,
    required this.description,
    required this.isDefault,
    required this.defaultReasoningEffort,
    required this.supportedReasoningEfforts,
  });

  final String id;
  final String model;
  final String displayName;
  final String description;
  final bool isDefault;
  final String? defaultReasoningEffort;
  final List<ReasoningEffortOptionDto> supportedReasoningEfforts;

  factory ModelOptionDto.fromJson(Map<String, dynamic> json) {
    final supported = json['supported_reasoning_efforts'];
    if (supported is! List<dynamic>) {
      throw const FormatException(
        'Missing or invalid "supported_reasoning_efforts" array in model option.',
      );
    }

    return ModelOptionDto(
      id: json['id'] as String,
      model: json['model'] as String,
      displayName: json['display_name'] as String,
      description: (json['description'] as String?) ?? '',
      isDefault: (json['is_default'] as bool?) ?? false,
      defaultReasoningEffort: json['default_reasoning_effort'] as String?,
      supportedReasoningEfforts: supported
          .map((entry) {
            if (entry is! Map<String, dynamic>) {
              throw const FormatException(
                'Invalid reasoning effort option in model option.',
              );
            }
            return ReasoningEffortOptionDto.fromJson(entry);
          })
          .toList(growable: false),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'model': model,
      'display_name': displayName,
      'description': description,
      'is_default': isDefault,
      'default_reasoning_effort': defaultReasoningEffort,
      'supported_reasoning_efforts': supportedReasoningEfforts
          .map((option) => option.toJson())
          .toList(growable: false),
    };
  }
}

class ModelCatalogDto {
  const ModelCatalogDto({required this.contractVersion, required this.models});

  final String contractVersion;
  final List<ModelOptionDto> models;

  factory ModelCatalogDto.fromJson(Map<String, dynamic> json) {
    final models = json['models'];
    if (models is! List<dynamic>) {
      throw const FormatException(
        'Missing or invalid "models" array in model catalog response.',
      );
    }

    return ModelCatalogDto(
      contractVersion: json['contract_version'] as String,
      models: models
          .map((entry) {
            if (entry is! Map<String, dynamic>) {
              throw const FormatException(
                'Invalid model option in model catalog response.',
              );
            }
            return ModelOptionDto.fromJson(entry);
          })
          .toList(growable: false),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'contract_version': contractVersion,
      'models': models.map((model) => model.toJson()).toList(growable: false),
    };
  }
}

class SpeechModelStatusDto {
  const SpeechModelStatusDto({
    required this.contractVersion,
    required this.provider,
    required this.modelId,
    required this.state,
    this.downloadProgress,
    this.lastError,
    this.installedBytes,
  });

  final String contractVersion;
  final String provider;
  final String modelId;
  final SpeechModelState state;
  final int? downloadProgress;
  final String? lastError;
  final int? installedBytes;

  factory SpeechModelStatusDto.fromJson(Map<String, dynamic> json) {
    final stateWire = json['state'];
    if (stateWire is! String) {
      throw const FormatException('Missing or invalid "state" value.');
    }

    return SpeechModelStatusDto(
      contractVersion: json['contract_version'] as String,
      provider: json['provider'] as String,
      modelId: json['model_id'] as String,
      state: speechModelStateFromWire(stateWire),
      downloadProgress: (json['download_progress'] as num?)?.toInt(),
      lastError: json['last_error'] as String?,
      installedBytes: (json['installed_bytes'] as num?)?.toInt(),
    );
  }
}

class SpeechModelMutationAcceptedDto {
  const SpeechModelMutationAcceptedDto({
    required this.contractVersion,
    required this.provider,
    required this.modelId,
    required this.state,
    required this.message,
  });

  final String contractVersion;
  final String provider;
  final String modelId;
  final SpeechModelState state;
  final String message;

  factory SpeechModelMutationAcceptedDto.fromJson(Map<String, dynamic> json) {
    final stateWire = json['state'];
    if (stateWire is! String) {
      throw const FormatException('Missing or invalid "state" value.');
    }

    return SpeechModelMutationAcceptedDto(
      contractVersion: json['contract_version'] as String,
      provider: json['provider'] as String,
      modelId: json['model_id'] as String,
      state: speechModelStateFromWire(stateWire),
      message: json['message'] as String,
    );
  }
}

class SpeechTranscriptionResultDto {
  const SpeechTranscriptionResultDto({
    required this.contractVersion,
    required this.provider,
    required this.modelId,
    required this.text,
    required this.durationMs,
  });

  final String contractVersion;
  final String provider;
  final String modelId;
  final String text;
  final int durationMs;

  factory SpeechTranscriptionResultDto.fromJson(Map<String, dynamic> json) {
    return SpeechTranscriptionResultDto(
      contractVersion: json['contract_version'] as String,
      provider: json['provider'] as String,
      modelId: json['model_id'] as String,
      text: json['text'] as String,
      durationMs: (json['duration_ms'] as num).toInt(),
    );
  }
}

enum ServiceHealthStatus { healthy, degraded, unavailable }

ServiceHealthStatus serviceHealthStatusFromWire(String wireValue) {
  return ServiceHealthStatus.values.firstWhere(
    (status) => status.name == wireValue,
    orElse: () => throw FormatException(
      'Unknown ServiceHealthStatus wire value "$wireValue".',
    ),
  );
}

class ServiceHealthDto {
  const ServiceHealthDto({required this.status, this.message});

  final ServiceHealthStatus status;
  final String? message;

  factory ServiceHealthDto.fromJson(Map<String, dynamic> json) {
    return ServiceHealthDto(
      status: serviceHealthStatusFromWire(json['status'] as String),
      message: json['message'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'status': status.name,
      if (message != null) 'message': message,
    };
  }
}

class TrustStateDto {
  const TrustStateDto({required this.trusted, required this.accessMode});

  final bool trusted;
  final AccessMode accessMode;

  factory TrustStateDto.fromJson(Map<String, dynamic> json) {
    return TrustStateDto(
      trusted: json['trusted'] as bool,
      accessMode: accessModeFromWire(json['access_mode'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'trusted': trusted,
      'access_mode': accessMode.wireValue,
    };
  }
}

class ApprovalSummaryDto {
  const ApprovalSummaryDto({
    required this.approvalId,
    required this.threadId,
    required this.action,
    required this.status,
    required this.reason,
    this.target,
  });

  final String approvalId;
  final String threadId;
  final String action;
  final ApprovalStatus status;
  final String reason;
  final String? target;

  factory ApprovalSummaryDto.fromJson(Map<String, dynamic> json) {
    return ApprovalSummaryDto(
      approvalId: json['approval_id'] as String,
      threadId: json['thread_id'] as String,
      action: json['action'] as String,
      status: approvalStatusFromWire(json['status'] as String),
      reason: json['reason'] as String,
      target: json['target'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'approval_id': approvalId,
      'thread_id': threadId,
      'action': action,
      'status': status.name,
      'reason': reason,
      if (target != null) 'target': target,
    };
  }
}

class ThreadGitStatusDto {
  const ThreadGitStatusDto({
    required this.workspace,
    required this.repository,
    required this.branch,
    this.remote,
    required this.dirty,
    required this.aheadBy,
    required this.behindBy,
  });

  final String workspace;
  final String repository;
  final String branch;
  final String? remote;
  final bool dirty;
  final int aheadBy;
  final int behindBy;

  factory ThreadGitStatusDto.fromJson(Map<String, dynamic> json) {
    return ThreadGitStatusDto(
      workspace: json['workspace'] as String,
      repository: json['repository'] as String,
      branch: json['branch'] as String,
      remote: json['remote'] as String?,
      dirty: json['dirty'] as bool,
      aheadBy: json['ahead_by'] as int,
      behindBy: json['behind_by'] as int,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'workspace': workspace,
      'repository': repository,
      'branch': branch,
      if (remote != null) 'remote': remote,
      'dirty': dirty,
      'ahead_by': aheadBy,
      'behind_by': behindBy,
    };
  }
}

class UserInputOptionDto {
  const UserInputOptionDto({
    required this.optionId,
    required this.label,
    required this.description,
    required this.isRecommended,
  });

  final String optionId;
  final String label;
  final String description;
  final bool isRecommended;

  factory UserInputOptionDto.fromJson(Map<String, dynamic> json) {
    return UserInputOptionDto(
      optionId: json['option_id'] as String,
      label: json['label'] as String,
      description: (json['description'] as String?) ?? '',
      isRecommended: json['is_recommended'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'option_id': optionId,
      'label': label,
      'description': description,
      'is_recommended': isRecommended,
    };
  }
}

class UserInputQuestionDto {
  const UserInputQuestionDto({
    required this.questionId,
    required this.prompt,
    required this.options,
  });

  final String questionId;
  final String prompt;
  final List<UserInputOptionDto> options;

  factory UserInputQuestionDto.fromJson(Map<String, dynamic> json) {
    final optionsJson = json['options'];
    if (optionsJson is! List<dynamic>) {
      throw const FormatException(
        'Missing or invalid "options" in user input question.',
      );
    }

    return UserInputQuestionDto(
      questionId: json['question_id'] as String,
      prompt: json['prompt'] as String,
      options: optionsJson
          .map((item) {
            if (item is! Map<String, dynamic>) {
              throw const FormatException(
                'User input option must be a JSON object.',
              );
            }
            return UserInputOptionDto.fromJson(item);
          })
          .toList(growable: false),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'question_id': questionId,
      'prompt': prompt,
      'options': options
          .map((option) => option.toJson())
          .toList(growable: false),
    };
  }
}

class PendingUserInputDto {
  const PendingUserInputDto({
    required this.requestId,
    required this.title,
    required this.questions,
    this.detail,
  });

  final String requestId;
  final String title;
  final String? detail;
  final List<UserInputQuestionDto> questions;

  factory PendingUserInputDto.fromJson(Map<String, dynamic> json) {
    final questionsJson = json['questions'];
    if (questionsJson is! List<dynamic>) {
      throw const FormatException(
        'Missing or invalid "questions" in pending user input.',
      );
    }

    return PendingUserInputDto(
      requestId: json['request_id'] as String,
      title: json['title'] as String,
      detail: json['detail'] as String?,
      questions: questionsJson
          .map((item) {
            if (item is! Map<String, dynamic>) {
              throw const FormatException(
                'Pending user input question must be a JSON object.',
              );
            }
            return UserInputQuestionDto.fromJson(item);
          })
          .toList(growable: false),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'request_id': requestId,
      'title': title,
      if (detail != null) 'detail': detail,
      'questions': questions
          .map((question) => question.toJson())
          .toList(growable: false),
    };
  }
}

class UserInputAnswerDto {
  const UserInputAnswerDto({required this.questionId, required this.optionId});

  final String questionId;
  final String optionId;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{'question_id': questionId, 'option_id': optionId};
  }
}

class ThreadSnapshotDto {
  const ThreadSnapshotDto({
    required this.contractVersion,
    required this.thread,
    required this.entries,
    required this.approvals,
    this.gitStatus,
    this.pendingUserInput,
  });

  final String contractVersion;
  final ThreadDetailDto thread;
  final List<ThreadTimelineEntryDto> entries;
  final List<ApprovalSummaryDto> approvals;
  final ThreadGitStatusDto? gitStatus;
  final PendingUserInputDto? pendingUserInput;

  factory ThreadSnapshotDto.fromJson(Map<String, dynamic> json) {
    final threadJson = json['thread'];
    if (threadJson is! Map<String, dynamic>) {
      throw const FormatException(
        'Missing or invalid "thread" in thread snapshot response.',
      );
    }

    final entriesJson = json['entries'];
    if (entriesJson is! List<dynamic>) {
      throw const FormatException(
        'Missing or invalid "entries" in thread snapshot response.',
      );
    }

    final approvalsJson = json['approvals'];
    if (approvalsJson is! List<dynamic>) {
      throw const FormatException(
        'Missing or invalid "approvals" in thread snapshot response.',
      );
    }

    return ThreadSnapshotDto(
      contractVersion: json['contract_version'] as String,
      thread: ThreadDetailDto.fromJson(threadJson),
      entries: entriesJson
          .map((item) {
            if (item is! Map<String, dynamic>) {
              throw const FormatException(
                'Thread snapshot entry must be a JSON object.',
              );
            }
            return ThreadTimelineEntryDto.fromJson(item);
          })
          .toList(growable: false),
      approvals: approvalsJson
          .map((item) {
            if (item is! Map<String, dynamic>) {
              throw const FormatException(
                'Thread snapshot approval must be a JSON object.',
              );
            }
            return ApprovalSummaryDto.fromJson(item);
          })
          .toList(growable: false),
      gitStatus: json['git_status'] is Map<String, dynamic>
          ? ThreadGitStatusDto.fromJson(
              json['git_status'] as Map<String, dynamic>,
            )
          : null,
      pendingUserInput: json['pending_user_input'] is Map<String, dynamic>
          ? PendingUserInputDto.fromJson(
              json['pending_user_input'] as Map<String, dynamic>,
            )
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'contract_version': contractVersion,
      'thread': thread.toJson(),
      'entries': entries.map((entry) => entry.toJson()).toList(growable: false),
      'approvals': approvals
          .map((approval) => approval.toJson())
          .toList(growable: false),
      if (gitStatus != null) 'git_status': gitStatus!.toJson(),
      if (pendingUserInput != null)
        'pending_user_input': pendingUserInput!.toJson(),
    };
  }
}

class TurnMutationAcceptedDto {
  const TurnMutationAcceptedDto({
    required this.contractVersion,
    required this.threadId,
    required this.threadStatus,
    required this.message,
    this.turnId,
  });

  final String contractVersion;
  final String threadId;
  final ThreadStatus threadStatus;
  final String message;
  final String? turnId;

  factory TurnMutationAcceptedDto.fromJson(Map<String, dynamic> json) {
    return TurnMutationAcceptedDto(
      contractVersion: json['contract_version'] as String,
      threadId: json['thread_id'] as String,
      threadStatus: threadStatusFromWire(json['thread_status'] as String),
      message: json['message'] as String,
      turnId: json['turn_id'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'contract_version': contractVersion,
      'thread_id': threadId,
      'thread_status': threadStatus.wireValue,
      'message': message,
      'turn_id': turnId,
    };
  }
}

class BootstrapDto {
  const BootstrapDto({
    required this.contractVersion,
    required this.bridge,
    required this.codex,
    required this.trust,
    required this.threads,
    required this.models,
  });

  final String contractVersion;
  final ServiceHealthDto bridge;
  final ServiceHealthDto codex;
  final TrustStateDto trust;
  final List<ThreadSummaryDto> threads;
  final List<ModelOptionDto> models;

  factory BootstrapDto.fromJson(Map<String, dynamic> json) {
    final threadsJson = json['threads'];
    if (threadsJson is! List<dynamic>) {
      throw const FormatException(
        'Missing or invalid "threads" in bootstrap response.',
      );
    }

    final modelsJson = json['models'];
    if (modelsJson is! List<dynamic>) {
      throw const FormatException(
        'Missing or invalid "models" in bootstrap response.',
      );
    }

    final bridgeJson = json['bridge'];
    if (bridgeJson is! Map<String, dynamic>) {
      throw const FormatException(
        'Missing or invalid "bridge" in bootstrap response.',
      );
    }

    final codexJson = json['codex'];
    if (codexJson is! Map<String, dynamic>) {
      throw const FormatException(
        'Missing or invalid "codex" in bootstrap response.',
      );
    }

    final trustJson = json['trust'];
    if (trustJson is! Map<String, dynamic>) {
      throw const FormatException(
        'Missing or invalid "trust" in bootstrap response.',
      );
    }

    return BootstrapDto(
      contractVersion: json['contract_version'] as String,
      bridge: ServiceHealthDto.fromJson(bridgeJson),
      codex: ServiceHealthDto.fromJson(codexJson),
      trust: TrustStateDto.fromJson(trustJson),
      threads: threadsJson
          .map((item) {
            if (item is! Map<String, dynamic>) {
              throw const FormatException(
                'Bootstrap thread must be a JSON object.',
              );
            }
            return ThreadSummaryDto.fromJson(item);
          })
          .toList(growable: false),
      models: modelsJson
          .map((item) {
            if (item is! Map<String, dynamic>) {
              throw const FormatException(
                'Bootstrap model must be a JSON object.',
              );
            }
            return ModelOptionDto.fromJson(item);
          })
          .toList(growable: false),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'contract_version': contractVersion,
      'bridge': bridge.toJson(),
      'codex': codex.toJson(),
      'trust': trust.toJson(),
      'threads': threads
          .map((thread) => thread.toJson())
          .toList(growable: false),
      'models': models.map((model) => model.toJson()).toList(growable: false),
    };
  }
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

class GitDiffFileSummaryDto {
  const GitDiffFileSummaryDto({
    required this.path,
    this.oldPath,
    this.newPath,
    required this.changeType,
    required this.additions,
    required this.deletions,
    required this.isBinary,
  });

  final String path;
  final String? oldPath;
  final String? newPath;
  final GitDiffChangeType changeType;
  final int additions;
  final int deletions;
  final bool isBinary;

  factory GitDiffFileSummaryDto.fromJson(Map<String, dynamic> json) {
    return GitDiffFileSummaryDto(
      path: json['path'] as String,
      oldPath: json['old_path'] as String?,
      newPath: json['new_path'] as String?,
      changeType: gitDiffChangeTypeFromWire(json['change_type'] as String),
      additions: (json['additions'] as num).toInt(),
      deletions: (json['deletions'] as num).toInt(),
      isBinary: json['is_binary'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'path': path,
      'old_path': oldPath,
      'new_path': newPath,
      'change_type': changeType.wireValue,
      'additions': additions,
      'deletions': deletions,
      'is_binary': isBinary,
    };
  }
}

class ThreadGitDiffDto {
  const ThreadGitDiffDto({
    required this.contractVersion,
    required this.thread,
    required this.repository,
    required this.mode,
    required this.files,
    required this.unifiedDiff,
    required this.fetchedAt,
    this.revision,
  });

  final String contractVersion;
  final ThreadDetailDto thread;
  final ThreadGitStatusDto repository;
  final ThreadGitDiffMode mode;
  final String? revision;
  final List<GitDiffFileSummaryDto> files;
  final String unifiedDiff;
  final String fetchedAt;

  factory ThreadGitDiffDto.fromJson(Map<String, dynamic> json) {
    final threadJson = json['thread'];
    if (threadJson is! Map<String, dynamic>) {
      throw const FormatException(
        'Missing or invalid "thread" object in git diff response.',
      );
    }
    final repositoryJson = json['repository'];
    if (repositoryJson is! Map<String, dynamic>) {
      throw const FormatException(
        'Missing or invalid "repository" object in git diff response.',
      );
    }
    final filesJson = json['files'];
    if (filesJson is! List<dynamic>) {
      throw const FormatException(
        'Missing or invalid "files" array in git diff response.',
      );
    }

    return ThreadGitDiffDto(
      contractVersion: json['contract_version'] as String,
      thread: ThreadDetailDto.fromJson(threadJson),
      repository: ThreadGitStatusDto.fromJson(repositoryJson),
      mode: threadGitDiffModeFromWire(json['mode'] as String),
      revision: json['revision'] as String?,
      files: filesJson
          .map((entry) {
            if (entry is! Map<String, dynamic>) {
              throw const FormatException(
                'Git diff file summary must be a JSON object.',
              );
            }
            return GitDiffFileSummaryDto.fromJson(entry);
          })
          .toList(growable: false),
      unifiedDiff: (json['unified_diff'] as String?) ?? '',
      fetchedAt: json['fetched_at'] as String,
    );
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

class OpenOnMacResponseDto {
  const OpenOnMacResponseDto({
    required this.contractVersion,
    required this.threadId,
    required this.attemptedUrl,
    required this.message,
    required this.bestEffort,
  });

  final String contractVersion;
  final String threadId;
  final String attemptedUrl;
  final String message;
  final bool bestEffort;

  factory OpenOnMacResponseDto.fromJson(Map<String, dynamic> json) {
    return OpenOnMacResponseDto(
      contractVersion: json['contract_version'] as String,
      threadId: json['thread_id'] as String,
      attemptedUrl: json['attempted_url'] as String,
      message: json['message'] as String,
      bestEffort: json['best_effort'] as bool,
    );
  }
}

class ApprovalGateResponseDto {
  const ApprovalGateResponseDto({
    required this.contractVersion,
    required this.operation,
    required this.outcome,
    required this.message,
    required this.approval,
  });

  final String contractVersion;
  final String operation;
  final String outcome;
  final String message;
  final ApprovalRecordDto approval;

  factory ApprovalGateResponseDto.fromJson(Map<String, dynamic> json) {
    final approval = json['approval'];
    if (approval is! Map<String, dynamic>) {
      throw const FormatException(
        'Missing or invalid "approval" object in approval gate response.',
      );
    }

    return ApprovalGateResponseDto(
      contractVersion: json['contract_version'] as String,
      operation: json['operation'] as String,
      outcome: json['outcome'] as String,
      message: json['message'] as String,
      approval: ApprovalRecordDto.fromJson(approval),
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

TurnMode turnModeFromWire(String wireValue) {
  return TurnMode.values.firstWhere(
    (mode) => mode.wireValue == wireValue,
    orElse: () =>
        throw FormatException('Unknown TurnMode wire value "$wireValue".'),
  );
}

ThreadTimelineGroupKind threadTimelineGroupKindFromWire(String wireValue) {
  return ThreadTimelineGroupKind.values.firstWhere(
    (kind) => kind.wireValue == wireValue,
    orElse: () => throw FormatException(
      'Unknown ThreadTimelineGroupKind wire value "$wireValue".',
    ),
  );
}

ThreadTimelineExplorationKind threadTimelineExplorationKindFromWire(
  String wireValue,
) {
  return ThreadTimelineExplorationKind.values.firstWhere(
    (kind) => kind.wireValue == wireValue,
    orElse: () => throw FormatException(
      'Unknown ThreadTimelineExplorationKind wire value "$wireValue".',
    ),
  );
}

class ThreadTimelineAnnotationsDto {
  const ThreadTimelineAnnotationsDto({
    this.groupKind,
    this.groupId,
    this.explorationKind,
    this.entryLabel,
  });

  final ThreadTimelineGroupKind? groupKind;
  final String? groupId;
  final ThreadTimelineExplorationKind? explorationKind;
  final String? entryLabel;

  factory ThreadTimelineAnnotationsDto.fromJson(Map<String, dynamic> json) {
    return ThreadTimelineAnnotationsDto(
      groupKind: json['group_kind'] == null
          ? null
          : threadTimelineGroupKindFromWire(json['group_kind'] as String),
      groupId: json['group_id'] as String?,
      explorationKind: json['exploration_kind'] == null
          ? null
          : threadTimelineExplorationKindFromWire(
              json['exploration_kind'] as String,
            ),
      entryLabel: json['entry_label'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'group_kind': groupKind?.wireValue,
      'group_id': groupId,
      'exploration_kind': explorationKind?.wireValue,
      'entry_label': entryLabel,
    };
  }
}

class ThreadSummaryDto {
  const ThreadSummaryDto({
    required this.contractVersion,
    required this.threadId,
    String? nativeThreadId,
    this.provider = ProviderKind.codex,
    this.client = ThreadClientKind.cli,
    required this.title,
    required this.status,
    required this.workspace,
    required this.repository,
    required this.branch,
    required this.updatedAt,
  }) : nativeThreadId = nativeThreadId ?? threadId;

  final String contractVersion;
  final String threadId;
  final String nativeThreadId;
  final ProviderKind provider;
  final ThreadClientKind client;
  final String title;
  final ThreadStatus status;
  final String workspace;
  final String repository;
  final String branch;
  final String updatedAt;

  factory ThreadSummaryDto.fromJson(Map<String, dynamic> json) {
    final threadId = json['thread_id'] as String;
    return ThreadSummaryDto(
      contractVersion: json['contract_version'] as String,
      threadId: threadId,
      nativeThreadId:
          json['native_thread_id'] as String? ??
          nativeThreadIdFromThreadId(threadId),
      provider: json['provider'] is String
          ? providerKindFromWire(json['provider'] as String)
          : providerKindFromThreadId(threadId),
      client: json['client'] is String
          ? threadClientKindFromWire(json['client'] as String)
          : threadClientKindFromSource(json['source'] as String? ?? 'cli'),
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
      'native_thread_id': nativeThreadId,
      'provider': provider.wireValue,
      'client': client.wireValue,
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
    String? nativeThreadId,
    this.provider = ProviderKind.codex,
    this.client = ThreadClientKind.cli,
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
    this.activeTurnId,
  }) : nativeThreadId = nativeThreadId ?? threadId;

  final String contractVersion;
  final String threadId;
  final String nativeThreadId;
  final ProviderKind provider;
  final ThreadClientKind client;
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
  final String? activeTurnId;

  ThreadDetailDto copyWith({
    String? contractVersion,
    String? threadId,
    String? nativeThreadId,
    ProviderKind? provider,
    ThreadClientKind? client,
    String? title,
    ThreadStatus? status,
    String? workspace,
    String? repository,
    String? branch,
    String? createdAt,
    String? updatedAt,
    String? source,
    AccessMode? accessMode,
    String? lastTurnSummary,
    String? activeTurnId,
  }) {
    return ThreadDetailDto(
      contractVersion: contractVersion ?? this.contractVersion,
      threadId: threadId ?? this.threadId,
      nativeThreadId: nativeThreadId ?? this.nativeThreadId,
      provider: provider ?? this.provider,
      client: client ?? this.client,
      title: title ?? this.title,
      status: status ?? this.status,
      workspace: workspace ?? this.workspace,
      repository: repository ?? this.repository,
      branch: branch ?? this.branch,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      source: source ?? this.source,
      accessMode: accessMode ?? this.accessMode,
      lastTurnSummary: lastTurnSummary ?? this.lastTurnSummary,
      activeTurnId: activeTurnId ?? this.activeTurnId,
    );
  }

  factory ThreadDetailDto.fromJson(Map<String, dynamic> json) {
    final threadId = json['thread_id'] as String;
    final source = json['source'] as String? ?? 'cli';
    return ThreadDetailDto(
      contractVersion: json['contract_version'] as String,
      threadId: threadId,
      nativeThreadId:
          json['native_thread_id'] as String? ??
          nativeThreadIdFromThreadId(threadId),
      provider: json['provider'] is String
          ? providerKindFromWire(json['provider'] as String)
          : providerKindFromThreadId(threadId),
      client: json['client'] is String
          ? threadClientKindFromWire(json['client'] as String)
          : threadClientKindFromSource(source),
      title: json['title'] as String,
      status: threadStatusFromWire(json['status'] as String),
      workspace: json['workspace'] as String,
      repository: json['repository'] as String,
      branch: json['branch'] as String,
      createdAt: json['created_at'] as String,
      updatedAt: json['updated_at'] as String,
      source: source,
      accessMode: accessModeFromWire(json['access_mode'] as String),
      lastTurnSummary: json['last_turn_summary'] as String,
      activeTurnId: json['active_turn_id'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'contract_version': contractVersion,
      'thread_id': threadId,
      'native_thread_id': nativeThreadId,
      'provider': provider.wireValue,
      'client': client.wireValue,
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
      'active_turn_id': activeTurnId,
    };
  }
}

class ThreadUsageWindowDto {
  const ThreadUsageWindowDto({
    required this.usedPercent,
    required this.limitWindowSeconds,
    required this.resetAfterSeconds,
    required this.resetAt,
  });

  final int usedPercent;
  final int limitWindowSeconds;
  final int resetAfterSeconds;
  final int resetAt;

  factory ThreadUsageWindowDto.fromJson(Map<String, dynamic> json) {
    return ThreadUsageWindowDto(
      usedPercent: (json['used_percent'] as num).toInt(),
      limitWindowSeconds: (json['limit_window_seconds'] as num).toInt(),
      resetAfterSeconds: (json['reset_after_seconds'] as num).toInt(),
      resetAt: (json['reset_at'] as num).toInt(),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'used_percent': usedPercent,
      'limit_window_seconds': limitWindowSeconds,
      'reset_after_seconds': resetAfterSeconds,
      'reset_at': resetAt,
    };
  }
}

class ThreadUsageDto {
  const ThreadUsageDto({
    required this.contractVersion,
    required this.threadId,
    required this.provider,
    required this.primaryWindow,
    this.planType,
    this.secondaryWindow,
  });

  final String contractVersion;
  final String threadId;
  final ProviderKind provider;
  final String? planType;
  final ThreadUsageWindowDto primaryWindow;
  final ThreadUsageWindowDto? secondaryWindow;

  factory ThreadUsageDto.fromJson(Map<String, dynamic> json) {
    final primaryWindowJson = json['primary_window'];
    if (primaryWindowJson is! Map<String, dynamic>) {
      throw const FormatException(
        'Missing or invalid "primary_window" in thread usage response.',
      );
    }

    return ThreadUsageDto(
      contractVersion: json['contract_version'] as String,
      threadId: json['thread_id'] as String,
      provider: providerKindFromWire(json['provider'] as String),
      planType: json['plan_type'] as String?,
      primaryWindow: ThreadUsageWindowDto.fromJson(primaryWindowJson),
      secondaryWindow: json['secondary_window'] is Map<String, dynamic>
          ? ThreadUsageWindowDto.fromJson(
              json['secondary_window'] as Map<String, dynamic>,
            )
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'contract_version': contractVersion,
      'thread_id': threadId,
      'provider': provider.wireValue,
      if (planType != null) 'plan_type': planType,
      'primary_window': primaryWindow.toJson(),
      if (secondaryWindow != null)
        'secondary_window': secondaryWindow!.toJson(),
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
    this.annotations,
  });

  final String eventId;
  final BridgeEventKind kind;
  final String occurredAt;
  final String summary;
  final Map<String, dynamic> payload;
  final ThreadTimelineAnnotationsDto? annotations;

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
      annotations: json['annotations'] is Map<String, dynamic>
          ? ThreadTimelineAnnotationsDto.fromJson(
              json['annotations'] as Map<String, dynamic>,
            )
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'event_id': eventId,
      'kind': kind.wireValue,
      'occurred_at': occurredAt,
      'summary': summary,
      'payload': payload,
      'annotations': annotations?.toJson(),
    };
  }
}

class ThreadTimelinePageDto {
  const ThreadTimelinePageDto({
    required this.contractVersion,
    required this.thread,
    required this.entries,
    this.pendingUserInput,
    required this.nextBefore,
    required this.hasMoreBefore,
  });

  final String contractVersion;
  final ThreadDetailDto thread;
  final List<ThreadTimelineEntryDto> entries;
  final PendingUserInputDto? pendingUserInput;
  final String? nextBefore;
  final bool hasMoreBefore;

  factory ThreadTimelinePageDto.fromJson(Map<String, dynamic> json) {
    final threadJson = json['thread'];
    if (threadJson is! Map<String, dynamic>) {
      throw const FormatException(
        'Missing or invalid "thread" in timeline page response.',
      );
    }

    final entriesJson = json['entries'];
    if (entriesJson is! List) {
      throw const FormatException(
        'Missing or invalid "entries" in timeline page response.',
      );
    }

    return ThreadTimelinePageDto(
      contractVersion: json['contract_version'] as String,
      thread: ThreadDetailDto.fromJson(threadJson),
      entries: entriesJson
          .map((item) {
            if (item is! Map<String, dynamic>) {
              throw const FormatException(
                'Timeline page entry must be a JSON object.',
              );
            }

            return ThreadTimelineEntryDto.fromJson(item);
          })
          .toList(growable: false),
      pendingUserInput: json['pending_user_input'] is Map<String, dynamic>
          ? PendingUserInputDto.fromJson(
              json['pending_user_input'] as Map<String, dynamic>,
            )
          : null,
      nextBefore: json['next_before'] as String?,
      hasMoreBefore: json['has_more_before'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'contract_version': contractVersion,
      'thread': thread.toJson(),
      'entries': entries.map((entry) => entry.toJson()).toList(growable: false),
      if (pendingUserInput != null)
        'pending_user_input': pendingUserInput!.toJson(),
      'next_before': nextBefore,
      'has_more_before': hasMoreBefore,
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

class SecurityEventRecordDto {
  const SecurityEventRecordDto({
    required this.severity,
    required this.category,
    required this.event,
  });

  final String severity;
  final String category;
  final BridgeEventEnvelope<Map<String, dynamic>> event;

  SecurityAuditEventDto? get auditEvent {
    try {
      return SecurityAuditEventDto.fromJson(event.payload);
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  factory SecurityEventRecordDto.fromJson(Map<String, dynamic> json) {
    final eventJson = json['event'];
    if (eventJson is! Map<String, dynamic>) {
      throw const FormatException(
        'Missing or invalid "event" in security event record.',
      );
    }

    return SecurityEventRecordDto(
      severity: json['severity'] as String,
      category: json['category'] as String,
      event: BridgeEventEnvelope<Map<String, dynamic>>.fromJson(
        eventJson,
        (payload) => payload,
      ),
    );
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
    this.annotations,
  });

  final String contractVersion;
  final String eventId;
  final String threadId;
  final BridgeEventKind kind;
  final String occurredAt;
  final TPayload payload;
  final ThreadTimelineAnnotationsDto? annotations;

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
      annotations: json['annotations'] is Map<String, dynamic>
          ? ThreadTimelineAnnotationsDto.fromJson(
              json['annotations'] as Map<String, dynamic>,
            )
          : null,
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
      'annotations': annotations?.toJson(),
    };
  }
}
