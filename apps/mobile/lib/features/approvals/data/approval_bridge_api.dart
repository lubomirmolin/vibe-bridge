import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final approvalBridgeApiProvider = Provider<ApprovalBridgeApi>((ref) {
  return const HttpApprovalBridgeApi();
});

abstract class ApprovalBridgeApi {
  Future<AccessMode> fetchAccessMode({required String bridgeApiBaseUrl});

  Future<List<ApprovalRecordDto>> fetchApprovals({
    required String bridgeApiBaseUrl,
  });

  Future<ApprovalResolutionResponseDto> approve({
    required String bridgeApiBaseUrl,
    required String approvalId,
  });

  Future<ApprovalResolutionResponseDto> reject({
    required String bridgeApiBaseUrl,
    required String approvalId,
  });
}

class HttpApprovalBridgeApi implements ApprovalBridgeApi {
  const HttpApprovalBridgeApi();

  @override
  Future<AccessMode> fetchAccessMode({required String bridgeApiBaseUrl}) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);

    try {
      final policyResult = await _fetchJsonResponse(
        client: client,
        uri: _buildAccessModeUri(bridgeApiBaseUrl),
      );

      if (policyResult.statusCode >= 200 && policyResult.statusCode < 300) {
        final accessMode = policyResult.object['access_mode'];
        if (accessMode is String) {
          return accessModeFromWire(accessMode);
        }
      } else if (policyResult.statusCode != HttpStatus.notFound) {
        throw ApprovalBridgeException(
          message:
              _readOptionalString(policyResult.object, 'message') ??
              'Couldn’t read access mode right now.',
        );
      }

      final bootstrapResult = await _fetchJsonResponse(
        client: client,
        uri: _buildBootstrapUri(bridgeApiBaseUrl),
      );
      if (bootstrapResult.statusCode >= 200 &&
          bootstrapResult.statusCode < 300) {
        final trust = bootstrapResult.object['trust'];
        if (trust is Map<String, dynamic>) {
          final accessMode = trust['access_mode'];
          if (accessMode is String) {
            return accessModeFromWire(accessMode);
          }
        }
      }

      throw ApprovalBridgeException(
        message:
            _readOptionalString(bootstrapResult.object, 'message') ??
            'Couldn’t read access mode right now.',
      );
    } on SocketException {
      throw const ApprovalBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on HandshakeException {
      throw const ApprovalBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on HttpException {
      throw const ApprovalBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on TimeoutException {
      throw const ApprovalBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on FormatException {
      throw const ApprovalBridgeException(
        message: 'Bridge returned an invalid policy response.',
      );
    } finally {
      client.close();
    }
  }

  @override
  Future<List<ApprovalRecordDto>> fetchApprovals({
    required String bridgeApiBaseUrl,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);

    try {
      final request = await client.getUrl(_buildApprovalsUri(bridgeApiBaseUrl));
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close();
      final decoded = _decodeJson(await utf8.decodeStream(response));

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final approvalsJson = switch (decoded) {
          Map<String, dynamic>() => decoded['approvals'],
          List<dynamic>() => decoded,
          _ => null,
        };
        if (approvalsJson is! List) {
          throw const FormatException(
            'Missing or invalid "approvals" list in approvals response.',
          );
        }

        return approvalsJson
            .map((entry) {
              if (entry is! Map<String, dynamic>) {
                throw const FormatException(
                  'Approval entry must be a JSON object.',
                );
              }
              return _parseApprovalRecord(entry);
            })
            .toList(growable: false);
      }

      throw ApprovalBridgeException(
        message:
            _readOptionalString(
              decoded is Map<String, dynamic>
                  ? decoded
                  : const <String, dynamic>{},
              'message',
            ) ??
            'Couldn’t load approvals right now.',
      );
    } on SocketException {
      throw const ApprovalBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on HandshakeException {
      throw const ApprovalBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on HttpException {
      throw const ApprovalBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on TimeoutException {
      throw const ApprovalBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on FormatException {
      throw const ApprovalBridgeException(
        message: 'Bridge returned an invalid approvals response.',
      );
    } finally {
      client.close();
    }
  }

  @override
  Future<ApprovalResolutionResponseDto> approve({
    required String bridgeApiBaseUrl,
    required String approvalId,
  }) {
    return _postResolution(
      bridgeApiBaseUrl: bridgeApiBaseUrl,
      approvalId: approvalId,
      action: 'approve',
    );
  }

  @override
  Future<ApprovalResolutionResponseDto> reject({
    required String bridgeApiBaseUrl,
    required String approvalId,
  }) {
    return _postResolution(
      bridgeApiBaseUrl: bridgeApiBaseUrl,
      approvalId: approvalId,
      action: 'reject',
    );
  }

  Future<ApprovalResolutionResponseDto> _postResolution({
    required String bridgeApiBaseUrl,
    required String approvalId,
    required String action,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);

    try {
      final request = await client.postUrl(
        _buildApprovalResolutionUri(bridgeApiBaseUrl, approvalId, action),
      );
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close();
      final decoded = _decodeJsonObject(await utf8.decodeStream(response));

      if (response.statusCode >= 200 && response.statusCode < 300) {
        return ApprovalResolutionResponseDto.fromJson(decoded);
      }

      throw ApprovalResolutionBridgeException(
        message:
            _readOptionalString(decoded, 'message') ??
            'Couldn’t resolve approval right now.',
        statusCode: response.statusCode,
        code: _readOptionalString(decoded, 'code'),
      );
    } on SocketException {
      throw const ApprovalResolutionBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on HandshakeException {
      throw const ApprovalResolutionBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on HttpException {
      throw const ApprovalResolutionBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on TimeoutException {
      throw const ApprovalResolutionBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on FormatException {
      throw const ApprovalResolutionBridgeException(
        message: 'Bridge returned an invalid approval resolution response.',
      );
    } finally {
      client.close();
    }
  }
}

class _JsonObjectResponse {
  const _JsonObjectResponse({required this.statusCode, required this.object});

  final int statusCode;
  final Map<String, dynamic> object;
}

class ApprovalBridgeException implements Exception {
  const ApprovalBridgeException({
    required this.message,
    this.isConnectivityError = false,
  });

  final String message;
  final bool isConnectivityError;

  @override
  String toString() => message;
}

class ApprovalResolutionBridgeException implements Exception {
  const ApprovalResolutionBridgeException({
    required this.message,
    this.statusCode,
    this.code,
    this.isConnectivityError = false,
  });

  final String message;
  final int? statusCode;
  final String? code;
  final bool isConnectivityError;

  bool get isNonActionable =>
      statusCode == 404 ||
      statusCode == 409 ||
      code == 'approval_not_pending' ||
      code == 'approval_not_found' ||
      code == 'approval_target_not_found';

  @override
  String toString() => message;
}

Uri _buildApprovalsUri(String baseUrl) {
  final baseUri = Uri.parse(baseUrl);
  final normalizedBasePath = baseUri.path.endsWith('/')
      ? baseUri.path.substring(0, baseUri.path.length - 1)
      : baseUri.path;
  final fullPath =
      '${normalizedBasePath.isEmpty ? '' : normalizedBasePath}/approvals';
  return baseUri.replace(path: fullPath, queryParameters: null);
}

Uri _buildApprovalResolutionUri(
  String baseUrl,
  String approvalId,
  String action,
) {
  final baseUri = Uri.parse(baseUrl);
  final normalizedBasePath = baseUri.path.endsWith('/')
      ? baseUri.path.substring(0, baseUri.path.length - 1)
      : baseUri.path;
  final fullPath =
      '${normalizedBasePath.isEmpty ? '' : normalizedBasePath}/approvals/${Uri.encodeComponent(approvalId)}/${Uri.encodeComponent(action)}';
  return baseUri.replace(path: fullPath, queryParameters: null);
}

Uri _buildAccessModeUri(String baseUrl) {
  final baseUri = Uri.parse(baseUrl);
  final normalizedBasePath = baseUri.path.endsWith('/')
      ? baseUri.path.substring(0, baseUri.path.length - 1)
      : baseUri.path;
  final fullPath =
      '${normalizedBasePath.isEmpty ? '' : normalizedBasePath}/policy/access-mode';
  return baseUri.replace(path: fullPath, queryParameters: null);
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

dynamic _decodeJson(String bodyText) {
  if (bodyText.trim().isEmpty) {
    return <String, dynamic>{};
  }

  return jsonDecode(bodyText);
}

Map<String, dynamic> _decodeJsonObject(String bodyText) {
  if (bodyText.trim().isEmpty) {
    return <String, dynamic>{};
  }

  final decoded = _decodeJson(bodyText);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Expected JSON object response.');
  }

  return decoded;
}

Future<_JsonObjectResponse> _fetchJsonResponse({
  required HttpClient client,
  required Uri uri,
}) async {
  final request = await client.getUrl(uri);
  request.headers.set(HttpHeaders.acceptHeader, 'application/json');
  final response = await request.close();
  return _JsonObjectResponse(
    statusCode: response.statusCode,
    object: _decodeJsonObject(await utf8.decodeStream(response)),
  );
}

ApprovalRecordDto _parseApprovalRecord(Map<String, dynamic> json) {
  final hasLegacyShape =
      json['repository'] is Map<String, dynamic> &&
      json['git_status'] is Map<String, dynamic> &&
      json['requested_at'] is String;
  if (hasLegacyShape) {
    return ApprovalRecordDto.fromJson(json);
  }

  return ApprovalRecordDto(
    contractVersion: (json['contract_version'] as String?) ?? contractVersion,
    approvalId: json['approval_id'] as String,
    threadId: json['thread_id'] as String,
    action: json['action'] as String,
    target: (json['target'] as String?) ?? '',
    reason: (json['reason'] as String?) ?? 'approval_requested',
    status: approvalStatusFromWire((json['status'] as String?) ?? 'pending'),
    requestedAt: (json['requested_at'] as String?) ?? '',
    resolvedAt: json['resolved_at'] as String?,
    repository: const RepositoryContextDto(
      workspace: 'Unknown workspace',
      repository: 'Unknown repository',
      branch: 'unknown',
      remote: 'unknown',
    ),
    gitStatus: const GitStatusDto(dirty: false, aheadBy: 0, behindBy: 0),
  );
}

String? _readOptionalString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    return null;
  }

  return value.trim();
}
