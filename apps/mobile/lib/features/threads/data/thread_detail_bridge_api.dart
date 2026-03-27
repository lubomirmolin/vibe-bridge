import 'dart:async';
import 'dart:convert';

import 'package:vibe_bridge/foundation/contracts/bridge_contracts.dart';
import 'package:vibe_bridge/foundation/network/bridge_transport.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final threadDetailBridgeApiProvider = Provider<ThreadDetailBridgeApi>((ref) {
  return HttpThreadDetailBridgeApi(
    transport: ref.watch(bridgeTransportProvider),
  );
});

const ModelCatalogDto fallbackModelCatalog = ModelCatalogDto(
  contractVersion: contractVersion,
  models: <ModelOptionDto>[
    ModelOptionDto(
      id: 'gpt-5',
      model: 'gpt-5',
      displayName: 'GPT-5',
      description: '',
      isDefault: true,
      defaultReasoningEffort: 'medium',
      supportedReasoningEfforts: <ReasoningEffortOptionDto>[
        ReasoningEffortOptionDto(reasoningEffort: 'low'),
        ReasoningEffortOptionDto(reasoningEffort: 'medium'),
        ReasoningEffortOptionDto(reasoningEffort: 'high'),
      ],
    ),
    ModelOptionDto(
      id: 'gpt-5-mini',
      model: 'gpt-5-mini',
      displayName: 'GPT-5 Mini',
      description: '',
      isDefault: false,
      defaultReasoningEffort: 'medium',
      supportedReasoningEfforts: <ReasoningEffortOptionDto>[
        ReasoningEffortOptionDto(reasoningEffort: 'low'),
        ReasoningEffortOptionDto(reasoningEffort: 'medium'),
        ReasoningEffortOptionDto(reasoningEffort: 'high'),
      ],
    ),
    ModelOptionDto(
      id: 'o4-mini',
      model: 'o4-mini',
      displayName: 'o4-mini',
      description: '',
      isDefault: false,
      defaultReasoningEffort: 'high',
      supportedReasoningEfforts: <ReasoningEffortOptionDto>[
        ReasoningEffortOptionDto(reasoningEffort: 'low'),
        ReasoningEffortOptionDto(reasoningEffort: 'medium'),
        ReasoningEffortOptionDto(reasoningEffort: 'high'),
      ],
    ),
  ],
);

abstract class ThreadDetailBridgeApi {
  Future<ModelCatalogDto> fetchModelCatalog({
    required String bridgeApiBaseUrl,
  }) async {
    return fallbackModelCatalog;
  }

  Future<ThreadSnapshotDto> createThread({
    required String bridgeApiBaseUrl,
    required String workspace,
    String? model,
  });

  Future<ThreadDetailDto> fetchThreadDetail({
    required String bridgeApiBaseUrl,
    required String threadId,
  });

  Future<ThreadTimelinePageDto> fetchThreadTimelinePage({
    required String bridgeApiBaseUrl,
    required String threadId,
    String? before,
    int limit = 50,
  });

  Future<List<ThreadTimelineEntryDto>> fetchThreadTimeline({
    required String bridgeApiBaseUrl,
    required String threadId,
  });

  Future<TurnMutationResult> startTurn({
    required String bridgeApiBaseUrl,
    required String threadId,
    required String prompt,
    List<String> images = const <String>[],
    String? model,
    String? effort,
  });

  Future<TurnMutationResult> steerTurn({
    required String bridgeApiBaseUrl,
    required String threadId,
    required String instruction,
  });

  Future<TurnMutationResult> interruptTurn({
    required String bridgeApiBaseUrl,
    required String threadId,
  });

  Future<TurnMutationResult> startCommitAction({
    required String bridgeApiBaseUrl,
    required String threadId,
    String? model,
    String? effort,
  }) async {
    throw const ThreadTurnBridgeException(
      message: 'Commit is unavailable in this build.',
    );
  }

  Future<OpenOnMacResponseDto> openOnMac({
    required String bridgeApiBaseUrl,
    required String threadId,
  });

  Future<GitStatusResponseDto> fetchGitStatus({
    required String bridgeApiBaseUrl,
    required String threadId,
  });

  Future<MutationResultResponseDto> switchBranch({
    required String bridgeApiBaseUrl,
    required String threadId,
    required String branch,
  });

  Future<MutationResultResponseDto> pullRepository({
    required String bridgeApiBaseUrl,
    required String threadId,
    String? remote,
  });

  Future<MutationResultResponseDto> pushRepository({
    required String bridgeApiBaseUrl,
    required String threadId,
    String? remote,
  });

  Future<SpeechModelStatusDto> fetchSpeechStatus({
    required String bridgeApiBaseUrl,
  }) async {
    return const SpeechModelStatusDto(
      contractVersion: contractVersion,
      provider: 'fluid_audio',
      modelId: 'parakeet-tdt-0.6b-v3-coreml',
      state: SpeechModelState.unsupported,
      lastError: 'Speech transcription is unavailable in this build.',
    );
  }

  Future<SpeechTranscriptionResultDto> transcribeAudio({
    required String bridgeApiBaseUrl,
    required List<int> audioBytes,
    String fileName = 'voice-message.wav',
  }) async {
    throw const ThreadSpeechBridgeException(
      message: 'Speech transcription is unavailable in this build.',
      code: 'speech_unsupported',
    );
  }
}

class HttpThreadDetailBridgeApi implements ThreadDetailBridgeApi {
  HttpThreadDetailBridgeApi({BridgeTransport? transport})
    : _transport = transport ?? createDefaultBridgeTransport();

  final BridgeTransport _transport;

  @override
  Future<ThreadSnapshotDto> createThread({
    required String bridgeApiBaseUrl,
    required String workspace,
    String? model,
  }) async {
    try {
      final response = await _transport.post(
        _buildCreateThreadUri(bridgeApiBaseUrl),
        headers: const <String, String>{
          'accept': 'application/json',
          'content-type': 'application/json',
        },
        body: jsonEncode(<String, dynamic>{
          'workspace': workspace,
          if (model != null && model.trim().isNotEmpty) 'model': model.trim(),
        }),
      );
      final decoded = _decodeJsonObject(response.bodyText);

      if (response.statusCode >= 200 && response.statusCode < 300) {
        try {
          return ThreadSnapshotDto.fromJson(decoded);
        } on FormatException {
          throw const ThreadCreateBridgeException(
            message: 'Bridge returned an invalid thread creation response.',
          );
        }
      }

      throw ThreadCreateBridgeException(
        message:
            _readOptionalString(decoded, 'message') ??
            'Couldn’t create a new thread right now.',
      );
    } on BridgeTransportConnectionException {
      throw const ThreadCreateBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on FormatException {
      throw const ThreadCreateBridgeException(
        message: 'Bridge returned an invalid thread creation response.',
      );
    }
  }

  @override
  Future<ModelCatalogDto> fetchModelCatalog({
    required String bridgeApiBaseUrl,
  }) async {
    final bootstrap = await _getBootstrap(_transport, bridgeApiBaseUrl);
    if (bootstrap?.models.isNotEmpty == true) {
      return ModelCatalogDto(
        contractVersion: bootstrap!.contractVersion,
        models: bootstrap.models,
      );
    }

    final catalog = await _getModelCatalog(_transport, bridgeApiBaseUrl);
    return catalog?.models.isNotEmpty == true ? catalog! : fallbackModelCatalog;
  }

  @override
  Future<GitStatusResponseDto> fetchGitStatus({
    required String bridgeApiBaseUrl,
    required String threadId,
  }) async {
    try {
      final response = await _transport.get(
        _buildThreadGitStatusUri(bridgeApiBaseUrl, threadId),
        headers: const <String, String>{'accept': 'application/json'},
      );
      final decoded = _decodeJsonObject(response.bodyText);

      if (response.statusCode >= 200 && response.statusCode < 300) {
        try {
          return GitStatusResponseDto.fromJson(decoded);
        } on FormatException {
          throw const ThreadGitBridgeException(
            message: 'Bridge returned an invalid git status response.',
          );
        }
      }

      throw ThreadGitBridgeException(
        message:
            _readOptionalString(decoded, 'message') ??
            'Couldn’t load git status right now.',
        statusCode: response.statusCode,
        code: _readOptionalString(decoded, 'code'),
      );
    } on BridgeTransportConnectionException {
      throw const ThreadGitBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on FormatException {
      throw const ThreadGitBridgeException(
        message: 'Bridge returned an invalid git status response.',
      );
    }
  }

  @override
  Future<MutationResultResponseDto> switchBranch({
    required String bridgeApiBaseUrl,
    required String threadId,
    required String branch,
  }) {
    return _postGitMutation(
      bridgeApiBaseUrl: bridgeApiBaseUrl,
      threadId: threadId,
      routeSegment: 'branch-switch',
      body: <String, dynamic>{'branch': branch},
    );
  }

  @override
  Future<MutationResultResponseDto> pullRepository({
    required String bridgeApiBaseUrl,
    required String threadId,
    String? remote,
  }) {
    return _postGitMutation(
      bridgeApiBaseUrl: bridgeApiBaseUrl,
      threadId: threadId,
      routeSegment: 'pull',
      body: <String, dynamic>{
        if (remote != null && remote.trim().isNotEmpty) 'remote': remote.trim(),
      },
    );
  }

  @override
  Future<MutationResultResponseDto> pushRepository({
    required String bridgeApiBaseUrl,
    required String threadId,
    String? remote,
  }) {
    return _postGitMutation(
      bridgeApiBaseUrl: bridgeApiBaseUrl,
      threadId: threadId,
      routeSegment: 'push',
      body: <String, dynamic>{
        if (remote != null && remote.trim().isNotEmpty) 'remote': remote.trim(),
      },
    );
  }

  @override
  Future<TurnMutationResult> startTurn({
    required String bridgeApiBaseUrl,
    required String threadId,
    required String prompt,
    List<String> images = const <String>[],
    String? model,
    String? effort,
  }) {
    final normalizedImages = images
        .map((image) => image.trim())
        .where((image) => image.isNotEmpty)
        .toList(growable: false);
    return _postTurnMutation(
      bridgeApiBaseUrl: bridgeApiBaseUrl,
      threadId: threadId,
      operation: 'start',
      routeSegment: 'turns',
      body: <String, dynamic>{
        'prompt': prompt,
        if (normalizedImages.isNotEmpty) 'images': normalizedImages,
        if (model != null && model.trim().isNotEmpty) 'model': model.trim(),
        if (effort != null && effort.trim().isNotEmpty) 'effort': effort.trim(),
      },
    );
  }

  @override
  Future<TurnMutationResult> steerTurn({
    required String bridgeApiBaseUrl,
    required String threadId,
    required String instruction,
  }) {
    return _postTurnMutation(
      bridgeApiBaseUrl: bridgeApiBaseUrl,
      threadId: threadId,
      operation: 'steer',
      routeSegment: 'turns',
      body: <String, dynamic>{'prompt': instruction, 'mode': 'steer'},
    );
  }

  @override
  Future<TurnMutationResult> interruptTurn({
    required String bridgeApiBaseUrl,
    required String threadId,
  }) {
    return _postTurnMutation(
      bridgeApiBaseUrl: bridgeApiBaseUrl,
      threadId: threadId,
      operation: 'interrupt',
      routeSegment: 'interrupt',
      body: const <String, dynamic>{},
    );
  }

  @override
  Future<TurnMutationResult> startCommitAction({
    required String bridgeApiBaseUrl,
    required String threadId,
    String? model,
    String? effort,
  }) {
    return _postActionMutation(
      bridgeApiBaseUrl: bridgeApiBaseUrl,
      threadId: threadId,
      operation: 'commit',
      actionPath: 'actions/commit',
      body: <String, dynamic>{
        if (model != null && model.trim().isNotEmpty) 'model': model.trim(),
        if (effort != null && effort.trim().isNotEmpty) 'effort': effort.trim(),
      },
    );
  }

  @override
  Future<OpenOnMacResponseDto> openOnMac({
    required String bridgeApiBaseUrl,
    required String threadId,
  }) async {
    throw const ThreadOpenOnMacBridgeException(
      message: 'Open-on-host is unavailable in this build.',
    );
  }

  @override
  Future<ThreadDetailDto> fetchThreadDetail({
    required String bridgeApiBaseUrl,
    required String threadId,
  }) async {
    final snapshot = await _fetchThreadSnapshot(
      bridgeApiBaseUrl: bridgeApiBaseUrl,
      threadId: threadId,
    );
    return snapshot.thread;
  }

  Future<ThreadSnapshotDto> _fetchThreadSnapshot({
    required String bridgeApiBaseUrl,
    required String threadId,
  }) async {
    try {
      final response = await _transport.get(
        _buildThreadSnapshotUri(bridgeApiBaseUrl, threadId),
        headers: const <String, String>{'accept': 'application/json'},
      );
      final decoded = _decodeJsonObject(response.bodyText);

      if (response.statusCode >= 200 && response.statusCode < 300) {
        try {
          return ThreadSnapshotDto.fromJson(decoded);
        } on FormatException {
          throw const ThreadDetailBridgeException(
            message: 'Bridge returned an invalid thread snapshot response.',
          );
        }
      }

      throw ThreadDetailBridgeException(
        message:
            _readOptionalString(decoded, 'message') ??
            'Couldn’t load this thread right now.',
        isUnavailable: response.statusCode == 404,
      );
    } on BridgeTransportConnectionException {
      throw const ThreadDetailBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on FormatException {
      throw const ThreadDetailBridgeException(
        message: 'Bridge returned an invalid thread snapshot response.',
      );
    }
  }

  @override
  Future<ThreadTimelinePageDto> fetchThreadTimelinePage({
    required String bridgeApiBaseUrl,
    required String threadId,
    String? before,
    int limit = 50,
  }) async {
    try {
      final response = await _transport.get(
        _buildThreadHistoryUri(
          bridgeApiBaseUrl,
          threadId,
          before: before,
          limit: limit,
        ),
        headers: const <String, String>{'accept': 'application/json'},
      );
      final decoded = _decodeJsonObject(response.bodyText);

      if (response.statusCode >= 200 && response.statusCode < 300) {
        try {
          return ThreadTimelinePageDto.fromJson(decoded);
        } on FormatException {
          throw const ThreadDetailBridgeException(
            message: 'Bridge returned an invalid thread timeline response.',
          );
        }
      }

      throw ThreadDetailBridgeException(
        message:
            _readOptionalString(decoded, 'message') ??
            'Couldn’t load thread history right now.',
        isUnavailable: response.statusCode == 404,
      );
    } on BridgeTransportConnectionException {
      throw const ThreadDetailBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on FormatException {
      throw const ThreadDetailBridgeException(
        message: 'Bridge returned an invalid thread timeline response.',
      );
    }
  }

  @override
  Future<List<ThreadTimelineEntryDto>> fetchThreadTimeline({
    required String bridgeApiBaseUrl,
    required String threadId,
  }) async {
    final entries = <ThreadTimelineEntryDto>[];
    String? before;

    while (true) {
      final page = await fetchThreadTimelinePage(
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        threadId: threadId,
        before: before,
        limit: 100,
      );
      entries.insertAll(0, page.entries);
      if (!page.hasMoreBefore || page.nextBefore == null) {
        return List<ThreadTimelineEntryDto>.unmodifiable(entries);
      }
      before = page.nextBefore;
    }
  }

  Future<TurnMutationResult> _postTurnMutation({
    required String bridgeApiBaseUrl,
    required String threadId,
    required String operation,
    required String routeSegment,
    required Map<String, dynamic> body,
  }) async {
    return _postTurnLikeMutation(
      bridgeApiBaseUrl: bridgeApiBaseUrl,
      threadId: threadId,
      operation: operation,
      uri: _buildThreadTurnMutationUri(
        bridgeApiBaseUrl,
        threadId,
        routeSegment,
      ),
      body: body,
    );
  }

  Future<TurnMutationResult> _postActionMutation({
    required String bridgeApiBaseUrl,
    required String threadId,
    required String operation,
    required String actionPath,
    required Map<String, dynamic> body,
  }) async {
    return _postTurnLikeMutation(
      bridgeApiBaseUrl: bridgeApiBaseUrl,
      threadId: threadId,
      operation: operation,
      uri: _buildThreadActionMutationUri(
        bridgeApiBaseUrl,
        threadId,
        actionPath,
      ),
      body: body,
    );
  }

  Future<TurnMutationResult> _postTurnLikeMutation({
    required String bridgeApiBaseUrl,
    required String threadId,
    required String operation,
    required Uri uri,
    required Map<String, dynamic> body,
  }) async {
    try {
      final response = await _transport.post(
        uri,
        headers: const <String, String>{
          'accept': 'application/json',
          'content-type': 'application/json',
        },
        body: jsonEncode(body),
      );
      final decoded = _decodeJsonObject(response.bodyText);

      if (response.statusCode >= 200 && response.statusCode < 300) {
        try {
          final accepted = TurnMutationAcceptedDto.fromJson(decoded);
          return TurnMutationResult(
            contractVersion: accepted.contractVersion,
            threadId: accepted.threadId,
            operation: operation,
            outcome: 'accepted',
            message: accepted.message,
            threadStatus: accepted.threadStatus,
          );
        } on FormatException {
          throw ThreadTurnBridgeException(
            message:
                _readOptionalString(decoded, 'message') ??
                'Turn control request did not return a valid thread state.',
          );
        }
      }

      throw ThreadTurnBridgeException(
        message:
            _readOptionalString(decoded, 'message') ??
            'Couldn’t update turn state right now.',
      );
    } on BridgeTransportConnectionException {
      throw const ThreadTurnBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on FormatException {
      throw const ThreadTurnBridgeException(
        message: 'Bridge returned an invalid turn control response.',
      );
    }
  }

  Future<MutationResultResponseDto> _postGitMutation({
    required String bridgeApiBaseUrl,
    required String threadId,
    required String routeSegment,
    required Map<String, dynamic> body,
  }) async {
    try {
      final response = await _transport.post(
        _buildThreadGitMutationUri(bridgeApiBaseUrl, threadId, routeSegment),
        headers: const <String, String>{
          'accept': 'application/json',
          'content-type': 'application/json',
        },
        body: jsonEncode(body),
      );
      final decoded = _decodeJsonObject(response.bodyText);

      if (response.statusCode == 202) {
        try {
          final gate = ApprovalGateResponseDto.fromJson(decoded);
          throw ThreadGitApprovalRequiredException(
            message: gate.message,
            operation: gate.operation,
            outcome: gate.outcome,
            approval: gate.approval,
          );
        } on FormatException {
          throw const ThreadGitMutationBridgeException(
            message: 'Bridge returned an invalid approval response.',
            statusCode: 202,
            code: 'approval_required',
          );
        }
      }

      if (response.statusCode >= 200 && response.statusCode < 300) {
        try {
          return MutationResultResponseDto.fromJson(decoded);
        } on FormatException {
          throw const ThreadGitMutationBridgeException(
            message: 'Bridge returned an invalid git mutation response.',
          );
        }
      }

      throw ThreadGitMutationBridgeException(
        message:
            _readOptionalString(decoded, 'message') ??
            'Couldn’t complete the git action right now.',
        statusCode: response.statusCode,
        code: _readOptionalString(decoded, 'code'),
      );
    } on ThreadGitApprovalRequiredException {
      rethrow;
    } on BridgeTransportConnectionException {
      throw const ThreadGitMutationBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on FormatException {
      throw const ThreadGitMutationBridgeException(
        message: 'Bridge returned an invalid git mutation response.',
      );
    }
  }

  @override
  Future<SpeechModelStatusDto> fetchSpeechStatus({
    required String bridgeApiBaseUrl,
  }) async {
    try {
      final response = await _transport.get(
        _buildSpeechModelUri(bridgeApiBaseUrl),
        headers: const <String, String>{'accept': 'application/json'},
      );
      final decoded = _decodeJsonObject(response.bodyText);

      if (response.statusCode >= 200 && response.statusCode < 300) {
        try {
          return SpeechModelStatusDto.fromJson(decoded);
        } on FormatException {
          throw const ThreadSpeechBridgeException(
            message: 'Bridge returned an invalid speech status response.',
          );
        }
      }

      throw ThreadSpeechBridgeException(
        message:
            _readOptionalString(decoded, 'message') ??
            'Couldn’t load speech status right now.',
        statusCode: response.statusCode,
        code: _readOptionalString(decoded, 'code'),
      );
    } on BridgeTransportConnectionException {
      throw const ThreadSpeechBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on FormatException {
      throw const ThreadSpeechBridgeException(
        message: 'Bridge returned an invalid speech status response.',
      );
    }
  }

  @override
  Future<SpeechTranscriptionResultDto> transcribeAudio({
    required String bridgeApiBaseUrl,
    required List<int> audioBytes,
    String fileName = 'voice-message.wav',
  }) async {
    try {
      final response = await _transport.multipartPost(
        _buildSpeechTranscriptionUri(bridgeApiBaseUrl),
        headers: const <String, String>{'accept': 'application/json'},
        fields: <BridgeMultipartField>[
          BridgeMultipartField(
            name: 'audio',
            bytes: audioBytes,
            fileName: fileName,
            contentType: 'audio/wav',
          ),
        ],
      );
      final decoded = _decodeJsonObject(response.bodyText);

      if (response.statusCode >= 200 && response.statusCode < 300) {
        try {
          return SpeechTranscriptionResultDto.fromJson(decoded);
        } on FormatException {
          throw const ThreadSpeechBridgeException(
            message: 'Bridge returned an invalid transcription response.',
          );
        }
      }

      throw ThreadSpeechBridgeException(
        message:
            _readOptionalString(decoded, 'message') ??
            'Couldn’t transcribe that recording right now.',
        statusCode: response.statusCode,
        code: _readOptionalString(decoded, 'code'),
      );
    } on BridgeTransportConnectionException {
      throw const ThreadSpeechBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on FormatException {
      throw const ThreadSpeechBridgeException(
        message: 'Bridge returned an invalid transcription response.',
      );
    }
  }
}

class ThreadDetailBridgeException implements Exception {
  const ThreadDetailBridgeException({
    required this.message,
    this.isUnavailable = false,
    this.isConnectivityError = false,
  });

  final String message;
  final bool isUnavailable;
  final bool isConnectivityError;

  @override
  String toString() => message;
}

class ThreadCreateBridgeException implements Exception {
  const ThreadCreateBridgeException({
    required this.message,
    this.isConnectivityError = false,
  });

  final String message;
  final bool isConnectivityError;

  @override
  String toString() => message;
}

class ThreadTurnBridgeException implements Exception {
  const ThreadTurnBridgeException({
    required this.message,
    this.isConnectivityError = false,
  });

  final String message;
  final bool isConnectivityError;

  @override
  String toString() => message;
}

class ThreadGitBridgeException implements Exception {
  const ThreadGitBridgeException({
    required this.message,
    this.statusCode,
    this.code,
    this.isConnectivityError = false,
  });

  final String message;
  final int? statusCode;
  final String? code;
  final bool isConnectivityError;

  @override
  String toString() => message;
}

class ThreadGitMutationBridgeException implements Exception {
  const ThreadGitMutationBridgeException({
    required this.message,
    this.statusCode,
    this.code,
    this.isConnectivityError = false,
  });

  final String message;
  final int? statusCode;
  final String? code;
  final bool isConnectivityError;

  @override
  String toString() => message;
}

class ThreadGitApprovalRequiredException
    extends ThreadGitMutationBridgeException {
  const ThreadGitApprovalRequiredException({
    required super.message,
    required this.operation,
    required this.outcome,
    required this.approval,
  }) : super(statusCode: 202, code: 'approval_required');

  final String operation;
  final String outcome;
  final ApprovalRecordDto approval;
}

class ThreadOpenOnMacBridgeException implements Exception {
  const ThreadOpenOnMacBridgeException({
    required this.message,
    this.statusCode,
    this.code,
    this.isConnectivityError = false,
  });

  final String message;
  final int? statusCode;
  final String? code;
  final bool isConnectivityError;

  @override
  String toString() => message;
}

class ThreadSpeechBridgeException implements Exception {
  const ThreadSpeechBridgeException({
    required this.message,
    this.statusCode,
    this.code,
    this.isConnectivityError = false,
  });

  final String message;
  final int? statusCode;
  final String? code;
  final bool isConnectivityError;

  @override
  String toString() => message;
}

class TurnMutationResult {
  const TurnMutationResult({
    required this.contractVersion,
    required this.threadId,
    required this.operation,
    required this.outcome,
    required this.message,
    required this.threadStatus,
  });

  final String contractVersion;
  final String threadId;
  final String operation;
  final String outcome;
  final String message;
  final ThreadStatus threadStatus;

  factory TurnMutationResult.fromJson(Map<String, dynamic> json) {
    final threadStatusWire = json['thread_status'];
    if (threadStatusWire is! String) {
      throw const FormatException('Missing or invalid "thread_status" value.');
    }

    return TurnMutationResult(
      contractVersion: json['contract_version'] as String,
      threadId: json['thread_id'] as String,
      operation: json['operation'] as String,
      outcome: json['outcome'] as String,
      message: json['message'] as String,
      threadStatus: threadStatusFromWire(threadStatusWire),
    );
  }
}

Future<BootstrapDto?> _getBootstrap(
  BridgeTransport transport,
  String bridgeApiBaseUrl,
) async {
  try {
    final response = await transport.get(
      _buildBootstrapUri(bridgeApiBaseUrl),
      headers: const <String, String>{'accept': 'application/json'},
    );
    final decoded = _decodeJsonObject(response.bodyText);

    if (response.statusCode >= 200 && response.statusCode < 300) {
      try {
        return BootstrapDto.fromJson(decoded);
      } on FormatException {
        return null;
      }
    }

    return null;
  } on BridgeTransportConnectionException {
    return null;
  } on FormatException {
    return null;
  }
}

Future<ModelCatalogDto?> _getModelCatalog(
  BridgeTransport transport,
  String bridgeApiBaseUrl,
) async {
  try {
    final response = await transport.get(
      _buildModelsUri(bridgeApiBaseUrl),
      headers: const <String, String>{'accept': 'application/json'},
    );
    final decoded = _decodeJsonObject(response.bodyText);

    if (response.statusCode >= 200 && response.statusCode < 300) {
      try {
        return ModelCatalogDto.fromJson(decoded);
      } on FormatException {
        return null;
      }
    }

    return null;
  } on BridgeTransportConnectionException {
    return null;
  } on FormatException {
    return null;
  }
}

Uri _buildBootstrapUri(String baseUrl) {
  final baseUri = Uri.parse(baseUrl);
  final normalizedBasePath = baseUri.path.endsWith('/')
      ? baseUri.path.substring(0, baseUri.path.length - 1)
      : baseUri.path;
  final fullPath =
      '${normalizedBasePath.isEmpty ? '' : normalizedBasePath}/bootstrap';
  return baseUri.replace(path: fullPath, queryParameters: null);
}

Uri _buildModelsUri(String baseUrl) {
  final baseUri = Uri.parse(baseUrl);
  final normalizedBasePath = baseUri.path.endsWith('/')
      ? baseUri.path.substring(0, baseUri.path.length - 1)
      : baseUri.path;
  final fullPath =
      '${normalizedBasePath.isEmpty ? '' : normalizedBasePath}/models';
  return baseUri.replace(path: fullPath, queryParameters: null);
}

Uri _buildSpeechModelUri(String baseUrl) {
  final baseUri = Uri.parse(baseUrl);
  final normalizedBasePath = baseUri.path.endsWith('/')
      ? baseUri.path.substring(0, baseUri.path.length - 1)
      : baseUri.path;
  final fullPath =
      '${normalizedBasePath.isEmpty ? '' : normalizedBasePath}/speech/models/parakeet';
  return baseUri.replace(path: fullPath, queryParameters: null);
}

Uri _buildSpeechTranscriptionUri(String baseUrl) {
  final baseUri = Uri.parse(baseUrl);
  final normalizedBasePath = baseUri.path.endsWith('/')
      ? baseUri.path.substring(0, baseUri.path.length - 1)
      : baseUri.path;
  final fullPath =
      '${normalizedBasePath.isEmpty ? '' : normalizedBasePath}/speech/transcriptions';
  return baseUri.replace(path: fullPath, queryParameters: null);
}

Uri _buildCreateThreadUri(String baseUrl) {
  final baseUri = Uri.parse(baseUrl);
  final normalizedBasePath = baseUri.path.endsWith('/')
      ? baseUri.path.substring(0, baseUri.path.length - 1)
      : baseUri.path;
  final fullPath =
      '${normalizedBasePath.isEmpty ? '' : normalizedBasePath}/threads';
  return baseUri.replace(path: fullPath, queryParameters: null);
}

Uri _buildThreadSnapshotUri(String baseUrl, String threadId) {
  final baseUri = Uri.parse(baseUrl);
  final normalizedBasePath = baseUri.path.endsWith('/')
      ? baseUri.path.substring(0, baseUri.path.length - 1)
      : baseUri.path;
  final fullPath =
      '${normalizedBasePath.isEmpty ? '' : normalizedBasePath}/threads/${Uri.encodeComponent(threadId)}/snapshot';
  return baseUri.replace(path: fullPath, queryParameters: null);
}

Uri _buildThreadHistoryUri(
  String baseUrl,
  String threadId, {
  String? before,
  int? limit,
}) {
  final baseUri = Uri.parse(baseUrl);
  final normalizedBasePath = baseUri.path.endsWith('/')
      ? baseUri.path.substring(0, baseUri.path.length - 1)
      : baseUri.path;
  final fullPath =
      '${normalizedBasePath.isEmpty ? '' : normalizedBasePath}/threads/${Uri.encodeComponent(threadId)}/history';
  final queryParameters = <String, String>{};
  final normalizedBefore = before?.trim();
  if (normalizedBefore != null && normalizedBefore.isNotEmpty) {
    queryParameters['before'] = normalizedBefore;
  }
  if (limit != null && limit > 0) {
    queryParameters['limit'] = '$limit';
  }
  return baseUri.replace(
    path: fullPath,
    queryParameters: queryParameters.isEmpty ? null : queryParameters,
  );
}

Uri _buildThreadGitStatusUri(String baseUrl, String threadId) {
  final baseUri = Uri.parse(baseUrl);
  final normalizedBasePath = baseUri.path.endsWith('/')
      ? baseUri.path.substring(0, baseUri.path.length - 1)
      : baseUri.path;
  final fullPath =
      '${normalizedBasePath.isEmpty ? '' : normalizedBasePath}/threads/${Uri.encodeComponent(threadId)}/git/status';
  return baseUri.replace(path: fullPath, queryParameters: null);
}

Uri _buildThreadGitMutationUri(String baseUrl, String threadId, String action) {
  final baseUri = Uri.parse(baseUrl);
  final normalizedBasePath = baseUri.path.endsWith('/')
      ? baseUri.path.substring(0, baseUri.path.length - 1)
      : baseUri.path;
  final fullPath =
      '${normalizedBasePath.isEmpty ? '' : normalizedBasePath}/threads/${Uri.encodeComponent(threadId)}/git/${Uri.encodeComponent(action)}';
  return baseUri.replace(path: fullPath, queryParameters: null);
}

Uri _buildThreadTurnMutationUri(
  String baseUrl,
  String threadId,
  String action,
) {
  final baseUri = Uri.parse(baseUrl);
  final normalizedBasePath = baseUri.path.endsWith('/')
      ? baseUri.path.substring(0, baseUri.path.length - 1)
      : baseUri.path;
  final fullPath =
      '${normalizedBasePath.isEmpty ? '' : normalizedBasePath}/threads/${Uri.encodeComponent(threadId)}/${Uri.encodeComponent(action)}';
  return baseUri.replace(path: fullPath, queryParameters: null);
}

Uri _buildThreadActionMutationUri(
  String baseUrl,
  String threadId,
  String actionPath,
) {
  final baseUri = Uri.parse(baseUrl);
  final normalizedBasePath = baseUri.path.endsWith('/')
      ? baseUri.path.substring(0, baseUri.path.length - 1)
      : baseUri.path;
  final normalizedActionPath = actionPath
      .split('/')
      .map(Uri.encodeComponent)
      .join('/');
  final fullPath =
      '${normalizedBasePath.isEmpty ? '' : normalizedBasePath}/threads/${Uri.encodeComponent(threadId)}/$normalizedActionPath';
  return baseUri.replace(path: fullPath, queryParameters: null);
}

Map<String, dynamic> _decodeJsonObject(String bodyText) {
  if (bodyText.trim().isEmpty) {
    return <String, dynamic>{};
  }

  final decoded = jsonDecode(bodyText);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Expected JSON object response.');
  }

  return decoded;
}

String? _readOptionalString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    return null;
  }

  return value.trim();
}
