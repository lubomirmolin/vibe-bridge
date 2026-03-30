import 'package:vibe_bridge/features/bridges/domain/pairing_qr_payload.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('decodes compact pairing routes and short timestamps', () {
    final payload = decodePairingQrPayload('''
{
  "v": "2026-03-29",
  "b": "bridge-a1",
  "u": "https://bridge.ts.net",
  "r": [
    "https://bridge.ts.net",
    "http://192.168.1.10:3110"
  ],
  "s": "session-1",
  "t": "ptk-abc",
  "i": 100,
  "e": 200
}
''');

    expect(payload.bridgeId, 'bridge-a1');
    expect(payload.sessionId, 'session-1');
    expect(payload.issuedAtEpochSeconds, 100);
    expect(payload.expiresAtEpochSeconds, 200);
    expect(payload.bridgeApiRoutes, hasLength(2));
    expect(payload.bridgeApiRoutes.first.baseUrl, 'https://bridge.ts.net');
    expect(payload.bridgeApiRoutes.first.isPreferred, isTrue);
    expect(payload.bridgeApiRoutes.last.baseUrl, 'http://192.168.1.10:3110');
    expect(payload.bridgeApiRoutes.last.kind, BridgeApiRouteKind.localNetwork);
  });

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
