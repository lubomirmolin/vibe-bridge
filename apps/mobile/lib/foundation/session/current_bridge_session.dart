import 'package:codex_mobile_companion/features/pairing/application/pairing_controller.dart';
import 'package:codex_mobile_companion/features/pairing/domain/pairing_qr_payload.dart';
import 'package:codex_mobile_companion/foundation/platform/app_platform.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum AppBridgeSessionKind { paired, localLoopback }

class AppBridgeSession {
  const AppBridgeSession.paired({
    required this.bridgeApiBaseUrl,
    required this.bridgeId,
    required this.displayName,
    required this.trustedBridge,
  }) : kind = AppBridgeSessionKind.paired,
       localSessionKind = null,
       canMutateAccessMode = true,
       canUnpair = true;

  const AppBridgeSession.localLoopback({
    required this.bridgeApiBaseUrl,
    required this.displayName,
    required this.localSessionKind,
  }) : kind = AppBridgeSessionKind.localLoopback,
       bridgeId = null,
       trustedBridge = null,
       canMutateAccessMode = true,
       canUnpair = false;

  final AppBridgeSessionKind kind;
  final String bridgeApiBaseUrl;
  final String? bridgeId;
  final String displayName;
  final TrustedBridgeIdentity? trustedBridge;
  final String? localSessionKind;
  final bool canMutateAccessMode;
  final bool canUnpair;

  bool get isPaired => kind == AppBridgeSessionKind.paired;
  bool get isLocalLoopback => kind == AppBridgeSessionKind.localLoopback;
}

final currentBridgeSessionProvider = Provider.family<AppBridgeSession?, String>(
  (ref, bridgeApiBaseUrl) {
    final pairingState = ref.watch(pairingControllerProvider);
    final platform = ref.watch(appPlatformProvider);
    final normalizedBaseUrl = bridgeApiBaseUrl.trim();
    final trustedBridge = pairingState.trustedBridge;

    if (trustedBridge != null &&
        trustedBridge.bridgeApiBaseUrl.trim() == normalizedBaseUrl) {
      return AppBridgeSession.paired(
        bridgeApiBaseUrl: trustedBridge.bridgeApiBaseUrl,
        bridgeId: trustedBridge.bridgeId,
        displayName: trustedBridge.bridgeName,
        trustedBridge: trustedBridge,
      );
    }

    if (platform.supportsLocalLoopbackBridge &&
        _isLoopbackBridgeApiBaseUrl(normalizedBaseUrl)) {
      return AppBridgeSession.localLoopback(
        bridgeApiBaseUrl: normalizedBaseUrl,
        displayName: 'Current machine',
        localSessionKind: platform.isWeb ? 'browser_local' : 'desktop_local',
      );
    }

    return null;
  },
);

bool _isLoopbackBridgeApiBaseUrl(String bridgeApiBaseUrl) {
  if (bridgeApiBaseUrl.isEmpty) {
    return false;
  }

  final uri = Uri.tryParse(bridgeApiBaseUrl);
  final host = uri?.host.trim().toLowerCase();
  return host == 'localhost' || host == '127.0.0.1' || host == '::1';
}
