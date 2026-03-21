import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final threadDetailBridgeApiProvider = Provider<ThreadDetailBridgeApi>((ref) {
  return const HttpThreadDetailBridgeApi();
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
}

class HttpThreadDetailBridgeApi implements ThreadDetailBridgeApi {
  const HttpThreadDetailBridgeApi();

  @override
  Future<ThreadSnapshotDto> createThread({
    required String bridgeApiBaseUrl,
    required String workspace,
    String? model,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);

    try {
      final request = await client.postUrl(
        _buildCreateThreadUri(bridgeApiBaseUrl),
      );
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      request.write(
        jsonEncode(<String, dynamic>{
          'workspace': workspace,
          if (model != null && model.trim().isNotEmpty) 'model': model.trim(),
        }),
      );

      final response = await request.close();
      final bodyText = await utf8.decodeStream(response);
      final decoded = _decodeJsonObject(bodyText);

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
    } on SocketException {
      throw const ThreadCreateBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on HandshakeException {
      throw const ThreadCreateBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on HttpException {
      throw const ThreadCreateBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on TimeoutException {
      throw const ThreadCreateBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on FormatException {
      throw const ThreadCreateBridgeException(
        message: 'Bridge returned an invalid thread creation response.',
      );
    } finally {
      client.close();
    }
  }

  @override
  Future<ModelCatalogDto> fetchModelCatalog({
    required String bridgeApiBaseUrl,
  }) async {
    final bootstrap = await _getBootstrap(bridgeApiBaseUrl);
    if (bootstrap?.models.isNotEmpty == true) {
      return ModelCatalogDto(
        contractVersion: bootstrap!.contractVersion,
        models: bootstrap.models,
      );
    }

    final catalog = await _getModelCatalog(bridgeApiBaseUrl);
    return catalog?.models.isNotEmpty == true ? catalog! : fallbackModelCatalog;
  }

  @override
  Future<GitStatusResponseDto> fetchGitStatus({
    required String bridgeApiBaseUrl,
    required String threadId,
  }) async {
    final snapshot = await _fetchThreadSnapshot(
      bridgeApiBaseUrl: bridgeApiBaseUrl,
      threadId: threadId,
    );
    final gitStatus = snapshot.gitStatus;
    if (gitStatus == null) {
      throw const ThreadGitBridgeException(
        message: 'Git status is unavailable for this thread snapshot.',
      );
    }

    return GitStatusResponseDto(
      contractVersion: snapshot.contractVersion,
      threadId: snapshot.thread.threadId,
      repository: RepositoryContextDto(
        workspace: gitStatus.workspace,
        repository: gitStatus.repository,
        branch: gitStatus.branch,
        remote: gitStatus.remote ?? 'origin',
      ),
      status: GitStatusDto(
        dirty: gitStatus.dirty,
        aheadBy: gitStatus.aheadBy,
        behindBy: gitStatus.behindBy,
      ),
    );
  }

  @override
  Future<MutationResultResponseDto> switchBranch({
    required String bridgeApiBaseUrl,
    required String threadId,
    required String branch,
  }) {
    throw const ThreadGitMutationBridgeException(
      message: 'Git mutations are not exposed by the rewrite backend yet.',
    );
  }

  @override
  Future<MutationResultResponseDto> pullRepository({
    required String bridgeApiBaseUrl,
    required String threadId,
    String? remote,
  }) {
    throw const ThreadGitMutationBridgeException(
      message: 'Git mutations are not exposed by the rewrite backend yet.',
    );
  }

  @override
  Future<MutationResultResponseDto> pushRepository({
    required String bridgeApiBaseUrl,
    required String threadId,
    String? remote,
  }) {
    throw const ThreadGitMutationBridgeException(
      message: 'Git mutations are not exposed by the rewrite backend yet.',
    );
  }

  @override
  Future<TurnMutationResult> startTurn({
    required String bridgeApiBaseUrl,
    required String threadId,
    required String prompt,
  }) {
    return _postTurnMutation(
      bridgeApiBaseUrl: bridgeApiBaseUrl,
      threadId: threadId,
      operation: 'start',
      routeSegment: 'turns',
      body: <String, dynamic>{'prompt': prompt},
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
  Future<OpenOnMacResponseDto> openOnMac({
    required String bridgeApiBaseUrl,
    required String threadId,
  }) async {
    throw const ThreadOpenOnMacBridgeException(
      message: 'Open-on-Mac is not available in the rewrite backend yet.',
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
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);

    try {
      final request = await client.getUrl(
        _buildThreadSnapshotUri(bridgeApiBaseUrl, threadId),
      );
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close();
      final bodyText = await utf8.decodeStream(response);
      final decoded = _decodeJsonObject(bodyText);

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
    } on SocketException {
      throw const ThreadDetailBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on HandshakeException {
      throw const ThreadDetailBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on HttpException {
      throw const ThreadDetailBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on TimeoutException {
      throw const ThreadDetailBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on FormatException {
      throw const ThreadDetailBridgeException(
        message: 'Bridge returned an invalid thread snapshot response.',
      );
    } finally {
      client.close();
    }
  }

  @override
  Future<ThreadTimelinePageDto> fetchThreadTimelinePage({
    required String bridgeApiBaseUrl,
    required String threadId,
    String? before,
    int limit = 50,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);

    try {
      final request = await client.getUrl(
        _buildThreadHistoryUri(
          bridgeApiBaseUrl,
          threadId,
          before: before,
          limit: limit,
        ),
      );
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close();
      final bodyText = await utf8.decodeStream(response);
      final decoded = _decodeJsonObject(bodyText);

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
    } on SocketException {
      throw const ThreadDetailBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on HandshakeException {
      throw const ThreadDetailBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on HttpException {
      throw const ThreadDetailBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on TimeoutException {
      throw const ThreadDetailBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on FormatException {
      throw const ThreadDetailBridgeException(
        message: 'Bridge returned an invalid thread timeline response.',
      );
    } finally {
      client.close();
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
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);

    try {
      final request = await client.postUrl(
        _buildThreadTurnMutationUri(bridgeApiBaseUrl, threadId, routeSegment),
      );
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      request.write(jsonEncode(body));
      final response = await request.close();
      final bodyText = await utf8.decodeStream(response);
      final decoded = _decodeJsonObject(bodyText);

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
    } on SocketException {
      throw const ThreadTurnBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on HandshakeException {
      throw const ThreadTurnBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on HttpException {
      throw const ThreadTurnBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on TimeoutException {
      throw const ThreadTurnBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on FormatException {
      throw const ThreadTurnBridgeException(
        message: 'Bridge returned an invalid turn control response.',
      );
    } finally {
      client.close();
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

Future<BootstrapDto?> _getBootstrap(String bridgeApiBaseUrl) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);

  try {
    final request = await client.getUrl(_buildBootstrapUri(bridgeApiBaseUrl));
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final response = await request.close();
    final bodyText = await utf8.decodeStream(response);
    final decoded = _decodeJsonObject(bodyText);

    if (response.statusCode >= 200 && response.statusCode < 300) {
      try {
        return BootstrapDto.fromJson(decoded);
      } on FormatException {
        return null;
      }
    }

    return null;
  } on SocketException {
    return null;
  } on HandshakeException {
    return null;
  } on HttpException {
    return null;
  } on TimeoutException {
    return null;
  } on FormatException {
    return null;
  } finally {
    client.close();
  }
}

Future<ModelCatalogDto?> _getModelCatalog(String bridgeApiBaseUrl) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);

  try {
    final request = await client.getUrl(_buildModelsUri(bridgeApiBaseUrl));
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final response = await request.close();
    final bodyText = await utf8.decodeStream(response);
    final decoded = _decodeJsonObject(bodyText);

    if (response.statusCode >= 200 && response.statusCode < 300) {
      try {
        return ModelCatalogDto.fromJson(decoded);
      } on FormatException {
        return null;
      }
    }

    return null;
  } on SocketException {
    return null;
  } on HandshakeException {
    return null;
  } on HttpException {
    return null;
  } on TimeoutException {
    return null;
  } on FormatException {
    return null;
  } finally {
    client.close();
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
