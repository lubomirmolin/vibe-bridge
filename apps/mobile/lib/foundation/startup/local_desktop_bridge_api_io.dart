import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'local_desktop_bridge_api.dart';

LocalDesktopBridgeApi createLocalDesktopBridgeApi() {
  return const HttpLocalDesktopBridgeApi();
}

class HttpLocalDesktopBridgeApi implements LocalDesktopBridgeApi {
  const HttpLocalDesktopBridgeApi();

  @override
  Future<LocalDesktopBridgeProbeResult> probe({
    required String bridgeApiBaseUrl,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);

    try {
      final request = await client.getUrl(_buildHealthUri(bridgeApiBaseUrl));
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close();
      final bodyText = await utf8.decodeStream(response);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        return LocalDesktopBridgeProbeResult.unreachable(
          errorMessage:
              'Local bridge responded with ${response.statusCode}. Start the bridge on this machine and retry.',
        );
      }

      final body = bodyText.trim().isEmpty
          ? const <String, dynamic>{}
          : jsonDecode(bodyText);
      if (body is! Map<String, dynamic> || body['status'] != 'ok') {
        return const LocalDesktopBridgeProbeResult.unreachable(
          errorMessage:
              'Local bridge health check returned an unexpected response.',
        );
      }

      return const LocalDesktopBridgeProbeResult.reachable();
    } on SocketException {
      return const LocalDesktopBridgeProbeResult.unreachable(
        errorMessage:
            'Couldn’t reach the local bridge at 127.0.0.1. Start the bridge on this machine and retry.',
      );
    } on HandshakeException {
      return const LocalDesktopBridgeProbeResult.unreachable(
        errorMessage:
            'The local bridge TLS handshake failed. Check the bridge endpoint and retry.',
      );
    } on HttpException {
      return const LocalDesktopBridgeProbeResult.unreachable(
        errorMessage:
            'The local bridge connection failed before the health check completed.',
      );
    } on TimeoutException {
      return const LocalDesktopBridgeProbeResult.unreachable(
        errorMessage:
            'The local bridge did not respond in time. Make sure it is running and retry.',
      );
    } on FormatException {
      return const LocalDesktopBridgeProbeResult.unreachable(
        errorMessage: 'The local bridge health response was not valid JSON.',
      );
    } finally {
      client.close();
    }
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
