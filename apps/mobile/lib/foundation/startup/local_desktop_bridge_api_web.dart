import 'dart:convert';

import 'package:http/browser_client.dart';
import 'package:http/http.dart' as http;

import 'local_desktop_bridge_api.dart';

LocalDesktopBridgeApi createLocalDesktopBridgeApi() {
  return BrowserLocalDesktopBridgeApi();
}

class BrowserLocalDesktopBridgeApi implements LocalDesktopBridgeApi {
  BrowserLocalDesktopBridgeApi({BrowserClient? client})
    : _client = client ?? BrowserClient();

  final http.Client _client;

  @override
  Future<LocalDesktopBridgeProbeResult> probe({
    required String bridgeApiBaseUrl,
  }) async {
    late final http.Response response;
    try {
      response = await _client.get(
        _buildHealthUri(bridgeApiBaseUrl),
        headers: const <String, String>{'accept': 'application/json'},
      );
    } catch (_) {
      return const LocalDesktopBridgeProbeResult.unreachable(
        errorMessage:
            'Couldn’t reach the local bridge from this browser. Check the localhost bridge and browser access settings.',
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      return LocalDesktopBridgeProbeResult.unreachable(
        errorMessage:
            'Local bridge responded with ${response.statusCode}. Start the bridge on this machine and retry.',
      );
    }

    final body = response.body.trim().isEmpty
        ? const <String, dynamic>{}
        : jsonDecode(response.body);
    if (body is! Map<String, dynamic> || body['status'] != 'ok') {
      return const LocalDesktopBridgeProbeResult.unreachable(
        errorMessage:
            'Local bridge health check returned an unexpected response.',
      );
    }

    return const LocalDesktopBridgeProbeResult.reachable();
  }
}

Uri _buildHealthUri(String baseUrl) {
  final baseUri = Uri.parse(baseUrl);
  final normalizedBasePath = baseUri.path.endsWith('/')
      ? baseUri.path.substring(0, baseUri.path.length - 1)
      : baseUri.path;

  return baseUri.replace(
    path: '${normalizedBasePath.isEmpty ? '' : normalizedBasePath}/healthz',
    queryParameters: null,
  );
}
