import 'dart:convert';

import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart'
    as bridge_contracts;

class PairingQrPayload {
  const PairingQrPayload({
    required this.contractVersion,
    required this.bridgeId,
    required this.bridgeName,
    required this.bridgeApiBaseUrl,
    required this.sessionId,
    required this.pairingToken,
    required this.issuedAtEpochSeconds,
    required this.expiresAtEpochSeconds,
  });

  final String contractVersion;
  final String bridgeId;
  final String bridgeName;
  final String bridgeApiBaseUrl;
  final String sessionId;
  final String pairingToken;
  final int issuedAtEpochSeconds;
  final int expiresAtEpochSeconds;

  DateTime get issuedAtUtc => DateTime.fromMillisecondsSinceEpoch(
    issuedAtEpochSeconds * 1000,
    isUtc: true,
  );

  DateTime get expiresAtUtc => DateTime.fromMillisecondsSinceEpoch(
    expiresAtEpochSeconds * 1000,
    isUtc: true,
  );

  factory PairingQrPayload.fromJson(Map<String, dynamic> json) {
    final parsed = PairingQrPayload(
      contractVersion: _readRequiredString(json, 'contract_version'),
      bridgeId: _readRequiredString(json, 'bridge_id'),
      bridgeName: _readRequiredString(json, 'bridge_name'),
      bridgeApiBaseUrl: _readRequiredString(json, 'bridge_api_base_url'),
      sessionId: _readRequiredString(json, 'session_id'),
      pairingToken: _readRequiredString(json, 'pairing_token'),
      issuedAtEpochSeconds: _readRequiredInt(json, 'issued_at_epoch_seconds'),
      expiresAtEpochSeconds: _readRequiredInt(json, 'expires_at_epoch_seconds'),
    );

    if (parsed.contractVersion != bridge_contracts.contractVersion) {
      throw const FormatException('Unsupported pairing contract version.');
    }

    final bridgeUri = Uri.tryParse(parsed.bridgeApiBaseUrl);
    if (bridgeUri == null || !bridgeUri.hasScheme || bridgeUri.host.isEmpty) {
      throw const FormatException('Invalid bridge_api_base_url.');
    }

    if (parsed.expiresAtEpochSeconds <= parsed.issuedAtEpochSeconds) {
      throw const FormatException('Pairing expiry must be after issue time.');
    }

    return parsed;
  }
}

PairingQrPayload decodePairingQrPayload(String rawPayload) {
  final decoded = jsonDecode(rawPayload);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Pairing payload must decode to an object.');
  }

  return PairingQrPayload.fromJson(decoded);
}

class TrustedBridgeIdentity {
  const TrustedBridgeIdentity({
    required this.bridgeId,
    required this.bridgeName,
    required this.bridgeApiBaseUrl,
    required this.sessionId,
    required this.pairedAtEpochSeconds,
  });

  final String bridgeId;
  final String bridgeName;
  final String bridgeApiBaseUrl;
  final String sessionId;
  final int pairedAtEpochSeconds;

  factory TrustedBridgeIdentity.fromPayload(
    PairingQrPayload payload, {
    required DateTime pairedAtUtc,
  }) {
    return TrustedBridgeIdentity(
      bridgeId: payload.bridgeId,
      bridgeName: payload.bridgeName,
      bridgeApiBaseUrl: payload.bridgeApiBaseUrl,
      sessionId: payload.sessionId,
      pairedAtEpochSeconds: pairedAtUtc.millisecondsSinceEpoch ~/ 1000,
    );
  }

  factory TrustedBridgeIdentity.fromJson(Map<String, dynamic> json) {
    return TrustedBridgeIdentity(
      bridgeId: _readRequiredString(json, 'bridge_id'),
      bridgeName: _readRequiredString(json, 'bridge_name'),
      bridgeApiBaseUrl: _readRequiredString(json, 'bridge_api_base_url'),
      sessionId: _readRequiredString(json, 'session_id'),
      pairedAtEpochSeconds: _readRequiredInt(json, 'paired_at_epoch_seconds'),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'bridge_id': bridgeId,
      'bridge_name': bridgeName,
      'bridge_api_base_url': bridgeApiBaseUrl,
      'session_id': sessionId,
      'paired_at_epoch_seconds': pairedAtEpochSeconds,
    };
  }
}

String _readRequiredString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('Missing or invalid field "$key".');
  }

  return value.trim();
}

int _readRequiredInt(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is int) {
    return value;
  }

  throw FormatException('Missing or invalid field "$key".');
}
