import 'dart:async';
import 'dart:convert';

import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:codex_mobile_companion/foundation/network/bridge_transport.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final threadListBridgeApiProvider = Provider<ThreadListBridgeApi>((ref) {
  return HttpThreadListBridgeApi(transport: ref.watch(bridgeTransportProvider));
});

abstract class ThreadListBridgeApi {
  Future<List<ThreadSummaryDto>> fetchThreads({
    required String bridgeApiBaseUrl,
  });
}

class HttpThreadListBridgeApi implements ThreadListBridgeApi {
  HttpThreadListBridgeApi({BridgeTransport? transport})
    : _transport = transport ?? createDefaultBridgeTransport();

  final BridgeTransport _transport;

  @override
  Future<List<ThreadSummaryDto>> fetchThreads({
    required String bridgeApiBaseUrl,
  }) async {
    try {
      final response = await _transport.get(
        _buildThreadListUri(bridgeApiBaseUrl),
        headers: const <String, String>{'accept': 'application/json'},
      );
      final decoded = _decodeJsonValue(response.bodyText);

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
    } on BridgeTransportConnectionException {
      throw const ThreadListBridgeException(
        'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on FormatException {
      throw const ThreadListBridgeException(
        'Bridge returned an invalid thread list response.',
      );
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
