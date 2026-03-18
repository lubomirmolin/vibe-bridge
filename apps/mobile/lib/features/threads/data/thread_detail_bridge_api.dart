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
}

class HttpThreadDetailBridgeApi implements ThreadDetailBridgeApi {
  const HttpThreadDetailBridgeApi();

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
      );
    } on HandshakeException {
      throw const ThreadDetailBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
      );
    } on HttpException {
      throw const ThreadDetailBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
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
      );
    } on HandshakeException {
      throw const ThreadDetailBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
      );
    } on HttpException {
      throw const ThreadDetailBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
      );
    } on FormatException {
      throw const ThreadDetailBridgeException(
        message: 'Bridge returned an invalid thread timeline response.',
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
  });

  final String message;
  final bool isUnavailable;

  @override
  String toString() => message;
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
