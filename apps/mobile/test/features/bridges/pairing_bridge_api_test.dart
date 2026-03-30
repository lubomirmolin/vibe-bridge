import 'dart:convert';
import 'dart:io';

import 'package:vibe_bridge/features/bridges/data/pairing_bridge_api.dart';
import 'package:vibe_bridge/features/bridges/domain/pairing_qr_payload.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'handshake keeps saved trust when the reachable route returns a service outage',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });

      server.listen((request) async {
        request.response
          ..statusCode = HttpStatus.serviceUnavailable
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode(<String, dynamic>{
              'message':
                  'Bridge service on this route is unavailable right now.',
            }),
          );
        await request.response.close();
      });

      final bridgeApi = HttpPairingBridgeApi();
      final result = await bridgeApi.handshake(
        trustedBridge: _trustedBridge(server.port),
        phoneId: 'phone-1',
        sessionToken: 'session-token',
      );

      expect(result.isTrusted, isFalse);
      expect(result.connectivityUnavailable, isTrue);
      expect(result.requiresRePair, isFalse);
      expect(
        result.message,
        'Bridge service on this route is unavailable right now.',
      );
    },
  );

  test(
    'handshake treats an invalid reachable response as connectivity loss',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });

      server.listen((request) async {
        request.response
          ..statusCode = HttpStatus.badGateway
          ..headers.contentType = ContentType.text
          ..write('<html>upstream unavailable</html>');
        await request.response.close();
      });

      final bridgeApi = HttpPairingBridgeApi();
      final result = await bridgeApi.handshake(
        trustedBridge: _trustedBridge(server.port),
        phoneId: 'phone-1',
        sessionToken: 'session-token',
      );

      expect(result.isTrusted, isFalse);
      expect(result.connectivityUnavailable, isTrue);
      expect(result.requiresRePair, isFalse);
      expect(
        result.message,
        'Host bridge is reachable, but did not return a valid pairing response. Check that the host bridge is running and retry.',
      );
    },
  );

  test('handshake still requires re-pair on explicit trust revocation', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await server.close(force: true);
    });

    server.listen((request) async {
      request.response
        ..statusCode = HttpStatus.forbidden
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode(<String, dynamic>{
            'code': 'trust_revoked',
            'message':
                'Trust was revoked for this session. Re-pair from the host bridge pairing QR.',
          }),
        );
      await request.response.close();
    });

    final bridgeApi = HttpPairingBridgeApi();
    final result = await bridgeApi.handshake(
      trustedBridge: _trustedBridge(server.port),
      phoneId: 'phone-1',
      sessionToken: 'session-token',
    );

    expect(result.isTrusted, isFalse);
    expect(result.connectivityUnavailable, isFalse);
    expect(result.requiresRePair, isTrue);
    expect(result.code, 'trust_revoked');
  });
}

TrustedBridgeIdentity _trustedBridge(int port) {
  final baseUrl = 'http://${InternetAddress.loopbackIPv4.address}:$port';
  return TrustedBridgeIdentity(
    bridgeId: 'bridge-a1',
    bridgeName: 'Operator Workstation',
    bridgeApiBaseUrl: baseUrl,
    bridgeApiRoutes: <BridgeApiRoute>[BridgeApiRoute.legacy(baseUrl: baseUrl)],
    sessionId: 'session-1',
    pairedAtEpochSeconds: 100,
  );
}
