import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'local_desktop_bridge_api_stub.dart'
    if (dart.library.html) 'local_desktop_bridge_api_web.dart'
    if (dart.library.io) 'local_desktop_bridge_api_io.dart'
    as impl;

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
  return const LocalDesktopConfig(
    enabled: bool.fromEnvironment(
      'CODEX_LOCAL_DESKTOP_ENABLED',
      defaultValue: true,
    ),
    bridgeApiBaseUrl: String.fromEnvironment(
      'CODEX_LOCAL_BRIDGE_BASE_URL',
      defaultValue: defaultLocalDesktopBridgeBaseUrl,
    ),
  );
});

final localDesktopBridgeApiProvider = Provider<LocalDesktopBridgeApi>((ref) {
  return impl.createLocalDesktopBridgeApi();
});
