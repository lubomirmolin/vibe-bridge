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
      final request = await client.getUrl(
        _buildAccessModeUri(bridgeApiBaseUrl),
      );
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close();
      final decoded = _decodeJsonObject(await utf8.decodeStream(response));

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final accessMode = decoded['access_mode'];
        if (accessMode is! String) {
          throw const FormatException(
            'Missing or invalid "access_mode" in policy response.',
          );
        }
        return accessModeFromWire(accessMode);
      }

      throw ApprovalBridgeException(
        message:
            _readOptionalString(decoded, 'message') ??
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
      final decoded = _decodeJsonObject(await utf8.decodeStream(response));

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final approvalsJson = decoded['approvals'];
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
              return ApprovalRecordDto.fromJson(entry);
            })
            .toList(growable: false);
      }

      throw ApprovalBridgeException(
        message:
            _readOptionalString(decoded, 'message') ??
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
