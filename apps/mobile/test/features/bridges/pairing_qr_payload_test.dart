import 'package:vibe_bridge/features/bridges/domain/pairing_qr_payload.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('tailscale routes stay private without dart:io parsing', () {
    expect(isPrivateBridgeApiBaseUrl('https://my-host.ts.net/bridge'), isTrue);
    expect(isPrivateBridgeApiBaseUrl('https://192.168.1.10/bridge'), isFalse);
    expect(isPrivateBridgeApiBaseUrl('https://[::1]/bridge'), isFalse);
  });

  test('local network routes use pure IPv4 parsing', () {
    expect(isLocalNetworkBridgeApiBaseUrl('http://192.168.1.10:3110'), isTrue);
    expect(isLocalNetworkBridgeApiBaseUrl('http://127.0.0.1:3110'), isFalse);
    expect(
      isLocalNetworkBridgeApiBaseUrl('http://bridge.ts.net:3110'),
      isFalse,
    );
  });
}
