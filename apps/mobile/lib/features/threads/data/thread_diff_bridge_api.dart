import 'dart:async';
import 'dart:convert';

import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:codex_mobile_companion/foundation/network/bridge_transport.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final threadDiffBridgeApiProvider = Provider<ThreadDiffBridgeApi>((ref) {
  return HttpThreadDiffBridgeApi(transport: ref.watch(bridgeTransportProvider));
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
  HttpThreadDiffBridgeApi({BridgeTransport? transport})
    : _transport = transport ?? createDefaultBridgeTransport();

  final BridgeTransport _transport;

  @override
  Future<ThreadGitDiffDto> fetchThreadGitDiff({
    required String bridgeApiBaseUrl,
    required String threadId,
    required ThreadGitDiffMode mode,
    String? path,
  }) async {
    try {
      final response = await _transport.get(
        _buildThreadGitDiffUri(
          bridgeApiBaseUrl,
          threadId,
          mode: mode,
          path: path,
        ),
        headers: const <String, String>{'accept': 'application/json'},
      );
      final decoded = _decodeJsonObject(response.bodyText);

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
    } on BridgeTransportConnectionException {
      throw const ThreadGitDiffBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on FormatException {
      throw const ThreadGitDiffBridgeException(
        message: 'Bridge returned an invalid git diff response.',
      );
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
