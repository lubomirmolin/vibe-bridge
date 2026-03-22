import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final threadDiffBridgeApiProvider = Provider<ThreadDiffBridgeApi>((ref) {
  return const HttpThreadDiffBridgeApi();
});

abstract class ThreadDiffBridgeApi {
  Future<ThreadGitDiffDto> fetchThreadGitDiff({
    required String bridgeApiBaseUrl,
    required String threadId,
    required ThreadGitDiffMode mode,
    String? path,
  });
}

class HttpThreadDiffBridgeApi implements ThreadDiffBridgeApi {
  const HttpThreadDiffBridgeApi();

  @override
  Future<ThreadGitDiffDto> fetchThreadGitDiff({
    required String bridgeApiBaseUrl,
    required String threadId,
    required ThreadGitDiffMode mode,
    String? path,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);

    try {
      final request = await client.getUrl(
        _buildThreadGitDiffUri(
          bridgeApiBaseUrl,
          threadId,
          mode: mode,
          path: path,
        ),
      );
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close();
      final decoded = _decodeJsonObject(await utf8.decodeStream(response));

      if (response.statusCode >= 200 && response.statusCode < 300) {
        try {
          return ThreadGitDiffDto.fromJson(decoded);
        } on FormatException {
          throw const ThreadGitDiffBridgeException(
            message: 'Bridge returned an invalid git diff response.',
          );
        }
      }

      throw ThreadGitDiffBridgeException(
        message:
            _readOptionalString(decoded, 'message') ??
            'Couldn’t load the git diff right now.',
        statusCode: response.statusCode,
        code: _readOptionalString(decoded, 'code'),
      );
    } on SocketException {
      throw const ThreadGitDiffBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on HandshakeException {
      throw const ThreadGitDiffBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on HttpException {
      throw const ThreadGitDiffBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on TimeoutException {
      throw const ThreadGitDiffBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on FormatException {
      throw const ThreadGitDiffBridgeException(
        message: 'Bridge returned an invalid git diff response.',
      );
    } finally {
      client.close();
    }
  }
}

Uri _buildThreadGitDiffUri(
  String baseUrl,
  String threadId, {
  required ThreadGitDiffMode mode,
  String? path,
}) {
  final baseUri = Uri.parse(baseUrl);
  final normalizedBasePath = baseUri.path.endsWith('/')
      ? baseUri.path.substring(0, baseUri.path.length - 1)
      : baseUri.path;
  final fullPath =
      '${normalizedBasePath.isEmpty ? '' : normalizedBasePath}/threads/${Uri.encodeComponent(threadId)}/git/diff';
  final queryParameters = <String, String>{'mode': mode.wireValue};
  final normalizedPath = path?.trim();
  if (normalizedPath != null && normalizedPath.isNotEmpty) {
    queryParameters['path'] = normalizedPath;
  }
  return baseUri.replace(path: fullPath, queryParameters: queryParameters);
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

class ThreadGitDiffBridgeException implements Exception {
  const ThreadGitDiffBridgeException({
    required this.message,
    this.isConnectivityError = false,
    this.statusCode,
    this.code,
  });

  final String message;
  final bool isConnectivityError;
  final int? statusCode;
  final String? code;

  @override
  String toString() => 'ThreadGitDiffBridgeException(message: $message)';
}
