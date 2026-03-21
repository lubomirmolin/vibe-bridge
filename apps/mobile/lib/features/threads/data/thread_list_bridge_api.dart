import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final threadListBridgeApiProvider = Provider<ThreadListBridgeApi>((ref) {
  return const HttpThreadListBridgeApi();
});

abstract class ThreadListBridgeApi {
  Future<List<ThreadSummaryDto>> fetchThreads({
    required String bridgeApiBaseUrl,
  });
}

class HttpThreadListBridgeApi implements ThreadListBridgeApi {
  const HttpThreadListBridgeApi();

  @override
  Future<List<ThreadSummaryDto>> fetchThreads({
    required String bridgeApiBaseUrl,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);

    try {
      final request = await client.getUrl(
        _buildThreadListUri(bridgeApiBaseUrl),
      );
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');

      final response = await request.close();
      final bodyText = await utf8.decodeStream(response);
      final decoded = _decodeJsonValue(bodyText);

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final threadItems = decoded is List
            ? decoded
            : decoded is Map<String, dynamic>
            ? decoded['threads']
            : null;
        if (threadItems is! List) {
          throw const FormatException(
            'Missing or invalid threads list in bridge response.',
          );
        }

        return threadItems
            .map((item) {
              if (item is! Map<String, dynamic>) {
                throw const FormatException(
                  'Thread list item must be a JSON object.',
                );
              }

              return ThreadSummaryDto.fromJson(item);
            })
            .toList(growable: false);
      }

      throw ThreadListBridgeException(
        _readOptionalString(decoded, 'message') ??
            'Couldn’t load threads from the bridge.',
      );
    } on SocketException {
      throw const ThreadListBridgeException(
        'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on HandshakeException {
      throw const ThreadListBridgeException(
        'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on HttpException {
      throw const ThreadListBridgeException(
        'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on TimeoutException {
      throw const ThreadListBridgeException(
        'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on FormatException {
      throw const ThreadListBridgeException(
        'Bridge returned an invalid thread list response.',
      );
    } finally {
      client.close();
    }
  }
}

class ThreadListBridgeException implements Exception {
  const ThreadListBridgeException(
    this.message, {
    this.isConnectivityError = false,
  });

  final String message;
  final bool isConnectivityError;

  @override
  String toString() => message;
}

Uri _buildThreadListUri(String baseUrl) {
  final baseUri = Uri.parse(baseUrl);
  final normalizedBasePath = baseUri.path.endsWith('/')
      ? baseUri.path.substring(0, baseUri.path.length - 1)
      : baseUri.path;
  final fullPath =
      '${normalizedBasePath.isEmpty ? '' : normalizedBasePath}/threads';

  return baseUri.replace(path: fullPath, queryParameters: null);
}

dynamic _decodeJsonValue(String bodyText) {
  if (bodyText.trim().isEmpty) {
    return <String, dynamic>{};
  }

  return jsonDecode(bodyText);
}

String? _readOptionalString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    return null;
  }
  return value.trim();
}
