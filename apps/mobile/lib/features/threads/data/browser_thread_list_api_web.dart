import 'dart:convert';

import 'package:codex_mobile_companion/features/threads/data/browser_thread_list_api.dart';
import 'package:codex_mobile_companion/features/threads/data/browser_thread_list_api_stub.dart';
import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:http/browser_client.dart';
import 'package:http/http.dart' as http;

BrowserThreadListApi createBrowserThreadListApi() {
  return BrowserHttpThreadListApi();
}

class BrowserHttpThreadListApi implements BrowserThreadListApi {
  BrowserHttpThreadListApi({BrowserClient? client})
    : _client = client ?? BrowserClient();

  final http.Client _client;

  @override
  Future<List<ThreadSummaryDto>> fetchThreads({
    required String bridgeApiBaseUrl,
  }) async {
    late final http.Response response;
    try {
      response = await _client.get(
        _buildThreadListUri(bridgeApiBaseUrl),
        headers: const <String, String>{'accept': 'application/json'},
      );
    } catch (_) {
      throw const BrowserThreadListException(
        'Couldn’t reach the local bridge from this browser. Check the localhost bridge and CORS settings.',
      );
    }

    final decoded = response.body.trim().isEmpty
        ? const <String, dynamic>{}
        : jsonDecode(response.body);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw BrowserThreadListException(
        decoded is Map<String, dynamic> &&
                decoded['message'] is String &&
                (decoded['message'] as String).trim().isNotEmpty
            ? (decoded['message'] as String).trim()
            : 'Couldn’t load threads from the local bridge.',
      );
    }

    final threadItems = decoded is List
        ? decoded
        : decoded is Map<String, dynamic>
        ? decoded['threads']
        : null;
    if (threadItems is! List) {
      throw const BrowserThreadListException(
        'Local bridge returned an invalid thread list response.',
      );
    }

    return threadItems
        .map((item) {
          if (item is! Map<String, dynamic>) {
            throw const BrowserThreadListException(
              'Local bridge returned an invalid thread list entry.',
            );
          }
          return ThreadSummaryDto.fromJson(item);
        })
        .toList(growable: false);
  }
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
