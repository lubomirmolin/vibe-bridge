import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final threadDetailBridgeApiProvider = Provider<ThreadDetailBridgeApi>((ref) {
  return const HttpThreadDetailBridgeApi();
});

abstract class ThreadDetailBridgeApi {
  Future<ThreadDetailDto> fetchThreadDetail({
    required String bridgeApiBaseUrl,
    required String threadId,
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
  Future<GitStatusResponseDto> fetchGitStatus({
    required String bridgeApiBaseUrl,
    required String threadId,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);

    try {
      final request = await client.getUrl(
        _buildThreadGitStatusUri(bridgeApiBaseUrl, threadId),
      );
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close();
      final bodyText = await utf8.decodeStream(response);
      final decoded = _decodeJsonObject(bodyText);

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
    } on SocketException {
      throw const ThreadGitBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on HandshakeException {
      throw const ThreadGitBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on HttpException {
      throw const ThreadGitBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on TimeoutException {
      throw const ThreadGitBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on FormatException {
      throw const ThreadGitBridgeException(
        message: 'Bridge returned an invalid git status response.',
      );
    } finally {
      client.close();
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
      action: 'branch-switch',
      queryParamName: 'branch',
      queryParamValue: branch,
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
      action: 'pull',
      queryParamName: remote == null ? null : 'remote',
      queryParamValue: remote,
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
      action: 'push',
      queryParamName: remote == null ? null : 'remote',
      queryParamValue: remote,
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
      action: 'start',
      queryParamName: 'prompt',
      queryParamValue: prompt,
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
      action: 'steer',
      queryParamName: 'instruction',
      queryParamValue: instruction,
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
      action: 'interrupt',
    );
  }

  @override
  Future<OpenOnMacResponseDto> openOnMac({
    required String bridgeApiBaseUrl,
    required String threadId,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);

    try {
      final request = await client.postUrl(
        _buildThreadOpenOnMacUri(bridgeApiBaseUrl, threadId),
      );
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close();
      final bodyText = await utf8.decodeStream(response);
      final decoded = _decodeJsonObject(bodyText);

      if (response.statusCode >= 200 && response.statusCode < 300) {
        try {
          return OpenOnMacResponseDto.fromJson(decoded);
        } on FormatException {
          throw const ThreadOpenOnMacBridgeException(
            message: 'Bridge returned an invalid open-on-Mac response.',
          );
        }
      }

      throw ThreadOpenOnMacBridgeException(
        message:
            _readOptionalString(decoded, 'message') ??
            'Couldn’t open this thread in Codex.app right now.',
        statusCode: response.statusCode,
        code: _readOptionalString(decoded, 'code'),
      );
    } on SocketException {
      throw const ThreadOpenOnMacBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on HandshakeException {
      throw const ThreadOpenOnMacBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on HttpException {
      throw const ThreadOpenOnMacBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on TimeoutException {
      throw const ThreadOpenOnMacBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on FormatException {
      throw const ThreadOpenOnMacBridgeException(
        message: 'Bridge returned an invalid open-on-Mac response.',
      );
    } finally {
      client.close();
    }
  }

  @override
  Future<ThreadDetailDto> fetchThreadDetail({
    required String bridgeApiBaseUrl,
    required String threadId,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);

    try {
      final request = await client.getUrl(
        _buildThreadUri(bridgeApiBaseUrl, threadId),
      );
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close();
      final bodyText = await utf8.decodeStream(response);
      final decoded = _decodeJsonObject(bodyText);

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final threadJson = decoded['thread'];
        if (threadJson is! Map<String, dynamic>) {
          throw const FormatException(
            'Missing or invalid "thread" object in bridge response.',
          );
        }

        return ThreadDetailDto.fromJson(threadJson);
      }

      throw ThreadDetailBridgeException(
        message:
            _readOptionalString(decoded, 'message') ??
            'Couldn’t open this thread right now.',
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
        message: 'Bridge returned an invalid thread detail response.',
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
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);

    try {
      final request = await client.getUrl(
        _buildThreadTimelineUri(bridgeApiBaseUrl, threadId),
      );
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close();
      final bodyText = await utf8.decodeStream(response);
      final decoded = _decodeJsonObject(bodyText);

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final eventsJson = decoded['events'];
        if (eventsJson is! List) {
          throw const FormatException(
            'Missing or invalid "events" list in bridge response.',
          );
        }

        return eventsJson
            .map((item) {
              if (item is! Map<String, dynamic>) {
                throw const FormatException(
                  'Timeline entry must be a JSON object.',
                );
              }

              return ThreadTimelineEntryDto.fromJson(item);
            })
            .toList(growable: false);
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

  Future<TurnMutationResult> _postTurnMutation({
    required String bridgeApiBaseUrl,
    required String threadId,
    required String action,
    String? queryParamName,
    String? queryParamValue,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);

    try {
      final request = await client.postUrl(
        _buildThreadTurnMutationUri(
          bridgeApiBaseUrl,
          threadId,
          action,
          queryParamName: queryParamName,
          queryParamValue: queryParamValue,
        ),
      );
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close();
      final bodyText = await utf8.decodeStream(response);
      final decoded = _decodeJsonObject(bodyText);

      if (response.statusCode >= 200 && response.statusCode < 300) {
        try {
          return TurnMutationResult.fromJson(decoded);
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

  Future<MutationResultResponseDto> _postGitMutation({
    required String bridgeApiBaseUrl,
    required String threadId,
    required String action,
    String? queryParamName,
    String? queryParamValue,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);

    try {
      final request = await client.postUrl(
        _buildThreadGitMutationUri(
          bridgeApiBaseUrl,
          threadId,
          action,
          queryParamName: queryParamName,
          queryParamValue: queryParamValue,
        ),
      );
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close();
      final bodyText = await utf8.decodeStream(response);
      final decoded = _decodeJsonObject(bodyText);

      if (response.statusCode == 202 ||
          _readOptionalString(decoded, 'outcome') == 'approval_required') {
        try {
          final gateResponse = ApprovalGateResponseDto.fromJson(decoded);
          throw ThreadGitApprovalRequiredException(
            message: gateResponse.message,
            operation: gateResponse.operation,
            outcome: gateResponse.outcome,
            approval: gateResponse.approval,
          );
        } on FormatException {
          throw ThreadGitMutationBridgeException(
            message:
                _readOptionalString(decoded, 'message') ??
                'Bridge returned an invalid approval-gate response.',
            statusCode: response.statusCode,
            code: _readOptionalString(decoded, 'code'),
          );
        }
      }

      if (response.statusCode >= 200 && response.statusCode < 300) {
        try {
          return MutationResultResponseDto.fromJson(decoded);
        } on FormatException {
          throw ThreadGitMutationBridgeException(
            message:
                _readOptionalString(decoded, 'message') ??
                'Git action did not return a valid repository state.',
          );
        }
      }

      throw ThreadGitMutationBridgeException(
        message:
            _readOptionalString(decoded, 'message') ??
            'Couldn’t run the git action right now.',
        statusCode: response.statusCode,
        code: _readOptionalString(decoded, 'code'),
      );
    } on SocketException {
      throw const ThreadGitMutationBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on HandshakeException {
      throw const ThreadGitMutationBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on HttpException {
      throw const ThreadGitMutationBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on TimeoutException {
      throw const ThreadGitMutationBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on FormatException {
      throw const ThreadGitMutationBridgeException(
        message: 'Bridge returned an invalid git mutation response.',
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

Uri _buildThreadUri(String baseUrl, String threadId) {
  final baseUri = Uri.parse(baseUrl);
  final normalizedBasePath = baseUri.path.endsWith('/')
      ? baseUri.path.substring(0, baseUri.path.length - 1)
      : baseUri.path;
  final fullPath =
      '${normalizedBasePath.isEmpty ? '' : normalizedBasePath}/threads/${Uri.encodeComponent(threadId)}';
  return baseUri.replace(path: fullPath, queryParameters: null);
}

Uri _buildThreadTimelineUri(String baseUrl, String threadId) {
  final baseUri = Uri.parse(baseUrl);
  final normalizedBasePath = baseUri.path.endsWith('/')
      ? baseUri.path.substring(0, baseUri.path.length - 1)
      : baseUri.path;
  final fullPath =
      '${normalizedBasePath.isEmpty ? '' : normalizedBasePath}/threads/${Uri.encodeComponent(threadId)}/timeline';
  return baseUri.replace(path: fullPath, queryParameters: null);
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

Uri _buildThreadOpenOnMacUri(String baseUrl, String threadId) {
  final baseUri = Uri.parse(baseUrl);
  final normalizedBasePath = baseUri.path.endsWith('/')
      ? baseUri.path.substring(0, baseUri.path.length - 1)
      : baseUri.path;
  final fullPath =
      '${normalizedBasePath.isEmpty ? '' : normalizedBasePath}/threads/${Uri.encodeComponent(threadId)}/open-on-mac';
  return baseUri.replace(path: fullPath, queryParameters: null);
}

Uri _buildThreadGitMutationUri(
  String baseUrl,
  String threadId,
  String action, {
  String? queryParamName,
  String? queryParamValue,
}) {
  final baseUri = Uri.parse(baseUrl);
  final normalizedBasePath = baseUri.path.endsWith('/')
      ? baseUri.path.substring(0, baseUri.path.length - 1)
      : baseUri.path;
  final fullPath =
      '${normalizedBasePath.isEmpty ? '' : normalizedBasePath}/threads/${Uri.encodeComponent(threadId)}/git/${Uri.encodeComponent(action)}';

  final queryParameters = <String, String>{};
  if (queryParamName != null && queryParamValue != null) {
    queryParameters[queryParamName] = queryParamValue;
  }

  return baseUri.replace(
    path: fullPath,
    queryParameters: queryParameters.isEmpty ? null : queryParameters,
  );
}

Uri _buildThreadTurnMutationUri(
  String baseUrl,
  String threadId,
  String action, {
  String? queryParamName,
  String? queryParamValue,
}) {
  final baseUri = Uri.parse(baseUrl);
  final normalizedBasePath = baseUri.path.endsWith('/')
      ? baseUri.path.substring(0, baseUri.path.length - 1)
      : baseUri.path;
  final fullPath =
      '${normalizedBasePath.isEmpty ? '' : normalizedBasePath}/threads/${Uri.encodeComponent(threadId)}/turns/${Uri.encodeComponent(action)}';

  final queryParameters = <String, String>{};
  if (queryParamName != null && queryParamValue != null) {
    queryParameters[queryParamName] = queryParamValue;
  }

  return baseUri.replace(
    path: fullPath,
    queryParameters: queryParameters.isEmpty ? null : queryParameters,
  );
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
