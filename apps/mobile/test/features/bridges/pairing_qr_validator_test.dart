import 'package:vibe_bridge/features/bridges/domain/pairing_qr_validator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('accepts a valid compact pairing payload', () {
    final result = validatePairingQrPayload(
      _validPayload(),
      nowUtc: DateTime.fromMillisecondsSinceEpoch(150 * 1000, isUtc: true),
      consumedSessionIds: <String>{},
    );

    expect(result.isValid, isTrue);
    expect(result.payload?.bridgeId, 'bridge-a1');
    expect(result.payload?.sessionId, 'session-1');
  });

  test('accepts a valid legacy pairing payload', () {
    final result = validatePairingQrPayload(
      _legacyPayload(),
      nowUtc: DateTime.fromMillisecondsSinceEpoch(150 * 1000, isUtc: true),
      consumedSessionIds: <String>{},
    );

    expect(result.isValid, isTrue);
    expect(result.payload?.bridgeName, 'Vibe bridge companion');
    expect(result.payload?.expiresAtEpochSeconds, 200);
  });

  test('rejects malformed payload with rescan guidance', () {
    final result = validatePairingQrPayload(
      '{"broken":',
      nowUtc: DateTime.utc(2026, 3, 17, 21, 0),
      consumedSessionIds: <String>{},
    );

    expect(result.isValid, isFalse);
    expect(result.error, PairingValidationError.malformed);
    expect(result.message, contains('Please rescan from the host bridge'));
  });

  test('rejects expired payload', () {
    final result = validatePairingQrPayload(
      _legacyPayload(issuedAtEpochSeconds: 1, expiresAtEpochSeconds: 10),
      nowUtc: DateTime.fromMillisecondsSinceEpoch(11 * 1000, isUtc: true),
      consumedSessionIds: <String>{},
    );

    expect(result.isValid, isFalse);
    expect(result.error, PairingValidationError.expired);
  });

  test('rejects reused payload by session id', () {
    final result = validatePairingQrPayload(
      _validPayload(sessionId: 'session-reused'),
      nowUtc: DateTime.fromMillisecondsSinceEpoch(150 * 1000, isUtc: true),
      consumedSessionIds: <String>{'session-reused'},
    );

    expect(result.isValid, isFalse);
    expect(result.error, PairingValidationError.reused);
  });

  test('rejects payloads with unsupported bridge routes as malformed', () {
    final result = validatePairingQrPayload(
      _validPayload(bridgeApiBaseUrl: 'http://127.0.0.1:3110'),
      nowUtc: DateTime.fromMillisecondsSinceEpoch(150 * 1000, isUtc: true),
      consumedSessionIds: <String>{},
    );

    expect(result.isValid, isFalse);
    expect(result.error, PairingValidationError.malformed);
  });
}

String _validPayload({
  String bridgeId = 'bridge-a1',
  String bridgeApiBaseUrl = 'https://bridge.ts.net',
  String sessionId = 'session-1',
}) {
  return '''
{
  "v": "2026-03-17",
  "b": "$bridgeId",
  "u": "$bridgeApiBaseUrl",
  "s": "$sessionId",
  "t": "ptk-abc"
}
''';
}

String _legacyPayload({
  String bridgeId = 'bridge-a1',
  String bridgeApiBaseUrl = 'https://bridge.ts.net',
  String sessionId = 'session-1',
  int issuedAtEpochSeconds = 100,
  int expiresAtEpochSeconds = 200,
}) {
  return '''
{
  "contract_version": "2026-03-17",
  "bridge_id": "$bridgeId",
  "bridge_name": "Vibe bridge companion",
  "bridge_api_base_url": "$bridgeApiBaseUrl",
  "session_id": "$sessionId",
  "pairing_token": "ptk-abc",
  "issued_at_epoch_seconds": $issuedAtEpochSeconds,
  "expires_at_epoch_seconds": $expiresAtEpochSeconds
}
''';
}
