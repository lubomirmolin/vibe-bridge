import 'local_desktop_bridge_api.dart';

LocalDesktopBridgeApi createLocalDesktopBridgeApi() {
  return const UnsupportedLocalDesktopBridgeApi();
}

class UnsupportedLocalDesktopBridgeApi implements LocalDesktopBridgeApi {
  const UnsupportedLocalDesktopBridgeApi();

  @override
  Future<LocalDesktopBridgeProbeResult> probe({
    required String bridgeApiBaseUrl,
  }) async {
    return const LocalDesktopBridgeProbeResult.unreachable(
      errorMessage:
          'Local desktop bridge mode is unavailable on this platform.',
    );
  }
}
