import 'dart:convert';

import 'package:codex_mobile_companion/foundation/network/bridge_transport.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const String defaultLocalDesktopBridgeBaseUrl = 'http://127.0.0.1:3110';

class LocalDesktopConfig {
  const LocalDesktopConfig({
    required this.enabled,
    required this.bridgeApiBaseUrl,
  });

  final bool enabled;
  final String bridgeApiBaseUrl;
}

class LocalDesktopBridgeProbeResult {
  const LocalDesktopBridgeProbeResult._({
    required this.isReachable,
    this.errorMessage,
  });

  const LocalDesktopBridgeProbeResult.reachable() : this._(isReachable: true);

  const LocalDesktopBridgeProbeResult.unreachable({String? errorMessage})
    : this._(isReachable: false, errorMessage: errorMessage);

  final bool isReachable;
  final String? errorMessage;
}

abstract class LocalDesktopBridgeApi {
  Future<LocalDesktopBridgeProbeResult> probe({
    required String bridgeApiBaseUrl,
  });
}

final localDesktopConfigProvider = Provider<LocalDesktopConfig>((ref) {
  final isMacOS = !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  return LocalDesktopConfig(
    enabled: kIsWeb || isMacOS,
    bridgeApiBaseUrl: defaultLocalDesktopBridgeBaseUrl,
  );
});

final localDesktopBridgeApiProvider = Provider<LocalDesktopBridgeApi>((ref) {
  return HttpLocalDesktopBridgeApi(
    transport: ref.watch(bridgeTransportProvider),
  );
});

class HttpLocalDesktopBridgeApi implements LocalDesktopBridgeApi {
  HttpLocalDesktopBridgeApi({BridgeTransport? transport})
    : _transport = transport ?? createDefaultBridgeTransport();

  final BridgeTransport _transport;

  @override
  Future<LocalDesktopBridgeProbeResult> probe({
    required String bridgeApiBaseUrl,
  }) async {
    try {
      final response = await _transport.get(
        _buildHealthUri(bridgeApiBaseUrl),
        headers: const <String, String>{'accept': 'application/json'},
        timeout: const Duration(seconds: 2),
      );

      if (response.statusCode < 200 || response.statusCode >= 300) {
        return LocalDesktopBridgeProbeResult.unreachable(
          errorMessage:
              'Local bridge responded with ${response.statusCode}. Start the bridge on this machine and retry.',
        );
      }

      final body = response.bodyText.trim().isEmpty
          ? const <String, dynamic>{}
          : jsonDecode(response.bodyText);
      if (body is! Map<String, dynamic> || body['status'] != 'ok') {
        return const LocalDesktopBridgeProbeResult.unreachable(
          errorMessage:
              'Local bridge health check returned an unexpected response.',
        );
      }

      return const LocalDesktopBridgeProbeResult.reachable();
    } on BridgeTransportConnectionException {
      return const LocalDesktopBridgeProbeResult.unreachable(
        errorMessage:
            'Couldn’t reach the local bridge at 127.0.0.1. Start the bridge on this machine and retry.',
      );
    } on FormatException {
      return const LocalDesktopBridgeProbeResult.unreachable(
        errorMessage: 'The local bridge health response was not valid JSON.',
      );
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
