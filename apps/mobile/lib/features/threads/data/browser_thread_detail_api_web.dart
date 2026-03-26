import 'dart:convert';

import 'package:codex_mobile_companion/features/threads/data/browser_thread_detail_api.dart';
import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:http/browser_client.dart';
import 'package:http/http.dart' as http;

BrowserThreadDetailApi createBrowserThreadDetailApi() {
  return BrowserHttpThreadDetailApi();
}

class BrowserHttpThreadDetailApi implements BrowserThreadDetailApi {
  BrowserHttpThreadDetailApi({BrowserClient? client})
    : _client = client ?? BrowserClient();

  final http.Client _client;

  @override
  Future<ThreadSnapshotDto> fetchThreadSnapshot({
    required String bridgeApiBaseUrl,
    required String threadId,
  }) async {
    final decoded = await _getJson(
      _buildThreadSnapshotUri(bridgeApiBaseUrl, threadId),
      fallbackMessage: 'Couldn’t load that thread from the local bridge.',
    );
    if (decoded is! Map<String, dynamic>) {
      throw const BrowserThreadDetailException(
        'Local bridge returned an invalid thread snapshot response.',
      );
    }
    return ThreadSnapshotDto.fromJson(decoded);
  }

  @override
  Future<AccessMode> fetchAccessMode({required String bridgeApiBaseUrl}) async {
    final decoded = await _getJson(
      _buildAccessModeUri(bridgeApiBaseUrl),
      fallbackMessage: 'Couldn’t load access mode from the local bridge.',
    );
    if (decoded is! Map<String, dynamic>) {
      throw const BrowserThreadDetailException(
        'Local bridge returned an invalid access-mode response.',
      );
    }

    final accessMode = decoded['access_mode'];
    if (accessMode is! String) {
      throw const BrowserThreadDetailException(
        'Local bridge returned an invalid access-mode response.',
      );
    }
    return accessModeFromWire(accessMode);
  }

  @override
  Future<AccessMode> setAccessMode({
    required String bridgeApiBaseUrl,
    required AccessMode accessMode,
  }) async {
    final uri = _buildAccessModeMutationUri(bridgeApiBaseUrl, accessMode);
    final decoded = await _postJson(
      uri,
      headers: const <String, String>{'accept': 'application/json'},
      fallbackMessage: 'Couldn’t update access mode from the browser.',
    );
    if (decoded is! Map<String, dynamic>) {
      throw const BrowserThreadDetailException(
        'Local bridge returned an invalid access-mode response.',
      );
    }

    final rawAccessMode = decoded['access_mode'];
    if (rawAccessMode is! String) {
      throw const BrowserThreadDetailException(
        'Local bridge returned an invalid access-mode response.',
      );
    }
    return accessModeFromWire(rawAccessMode);
  }

  @override
  Future<TurnMutationAcceptedDto> startTurn({
    required String bridgeApiBaseUrl,
    required String threadId,
    required String prompt,
  }) async {
    final decoded = await _postJson(
      _buildThreadTurnUri(bridgeApiBaseUrl, threadId),
      headers: const <String, String>{
        'accept': 'application/json',
        'content-type': 'application/json',
      },
      body: jsonEncode(<String, dynamic>{'prompt': prompt}),
      fallbackMessage: 'Couldn’t submit that prompt right now.',
    );
    if (decoded is! Map<String, dynamic>) {
      throw const BrowserThreadDetailException(
        'Local bridge returned an invalid turn response.',
      );
    }
    return TurnMutationAcceptedDto.fromJson(decoded);
  }

  @override
  Future<TurnMutationAcceptedDto> interruptTurn({
    required String bridgeApiBaseUrl,
    required String threadId,
  }) async {
    final decoded = await _postJson(
      _buildThreadInterruptUri(bridgeApiBaseUrl, threadId),
      headers: const <String, String>{
        'accept': 'application/json',
        'content-type': 'application/json',
      },
      body: '{}',
      fallbackMessage: 'Couldn’t interrupt the active turn right now.',
    );
    if (decoded is! Map<String, dynamic>) {
      throw const BrowserThreadDetailException(
        'Local bridge returned an invalid interrupt response.',
      );
    }
    return TurnMutationAcceptedDto.fromJson(decoded);
  }

  Future<dynamic> _getJson(Uri uri, {required String fallbackMessage}) async {
    late final http.Response response;
    try {
      response = await _client.get(
        uri,
        headers: const <String, String>{'accept': 'application/json'},
      );
    } catch (_) {
      throw const BrowserThreadDetailException(
        'Couldn’t reach the local bridge from this browser. Check the localhost bridge and CORS settings.',
      );
    }
    return _decodeResponse(response, fallbackMessage: fallbackMessage);
  }

  Future<dynamic> _postJson(
    Uri uri, {
    required Map<String, String> headers,
    String? body,
    required String fallbackMessage,
  }) async {
    late final http.Response response;
    try {
      response = await _client.post(uri, headers: headers, body: body);
    } catch (_) {
      throw const BrowserThreadDetailException(
        'Couldn’t reach the local bridge from this browser. Check the localhost bridge and CORS settings.',
      );
    }
    return _decodeResponse(response, fallbackMessage: fallbackMessage);
  }

  dynamic _decodeResponse(
    http.Response response, {
    required String fallbackMessage,
  }) {
    final decoded = response.body.trim().isEmpty
        ? const <String, dynamic>{}
        : jsonDecode(response.body);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw BrowserThreadDetailException(
        decoded is Map<String, dynamic> &&
                decoded['message'] is String &&
                (decoded['message'] as String).trim().isNotEmpty
            ? (decoded['message'] as String).trim()
            : fallbackMessage,
      );
    }

    return decoded;
  }
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

Uri _buildAccessModeUri(String baseUrl) {
  final baseUri = Uri.parse(baseUrl);
  final normalizedBasePath = baseUri.path.endsWith('/')
      ? baseUri.path.substring(0, baseUri.path.length - 1)
      : baseUri.path;
  final fullPath =
      '${normalizedBasePath.isEmpty ? '' : normalizedBasePath}/policy/access-mode';
  return baseUri.replace(path: fullPath, queryParameters: null);
}

Uri _buildAccessModeMutationUri(String baseUrl, AccessMode accessMode) {
  return _buildAccessModeUri(baseUrl).replace(
    queryParameters: <String, String>{
      'mode': accessMode.wireValue,
      'local_session': 'browser_local',
      'actor': 'browser-local',
    },
  );
}

Uri _buildThreadTurnUri(String baseUrl, String threadId) {
  final baseUri = Uri.parse(baseUrl);
  final normalizedBasePath = baseUri.path.endsWith('/')
      ? baseUri.path.substring(0, baseUri.path.length - 1)
      : baseUri.path;
  final fullPath =
      '${normalizedBasePath.isEmpty ? '' : normalizedBasePath}/threads/${Uri.encodeComponent(threadId)}/turns';
  return baseUri.replace(path: fullPath, queryParameters: null);
}

Uri _buildThreadInterruptUri(String baseUrl, String threadId) {
  final baseUri = Uri.parse(baseUrl);
  final normalizedBasePath = baseUri.path.endsWith('/')
      ? baseUri.path.substring(0, baseUri.path.length - 1)
      : baseUri.path;
  final fullPath =
      '${normalizedBasePath.isEmpty ? '' : normalizedBasePath}/threads/${Uri.encodeComponent(threadId)}/interrupt';
  return baseUri.replace(path: fullPath, queryParameters: null);
}
