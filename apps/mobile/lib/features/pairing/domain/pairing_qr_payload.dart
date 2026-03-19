import 'dart:convert';
import 'dart:io';

import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart'
    as bridge_contracts;

const String _defaultBridgeDisplayName = 'Codex Mobile Companion';

class PairingQrPayload {
  const PairingQrPayload({
    required this.contractVersion,
    required this.bridgeId,
    this.bridgeName = _defaultBridgeDisplayName,
    required this.bridgeApiBaseUrl,
    required this.sessionId,
    required this.pairingToken,
    this.issuedAtEpochSeconds,
    this.expiresAtEpochSeconds,
  });

  final String contractVersion;
  final String bridgeId;
  final String bridgeName;
  final String bridgeApiBaseUrl;
  final String sessionId;
  final String pairingToken;
  final int? issuedAtEpochSeconds;
  final int? expiresAtEpochSeconds;

  DateTime? get issuedAtUtc {
    final issuedAtEpochSeconds = this.issuedAtEpochSeconds;
    if (issuedAtEpochSeconds == null) {
      return null;
    }

    return DateTime.fromMillisecondsSinceEpoch(
      issuedAtEpochSeconds * 1000,
      isUtc: true,
    );
  }

  DateTime? get expiresAtUtc {
    final expiresAtEpochSeconds = this.expiresAtEpochSeconds;
    if (expiresAtEpochSeconds == null) {
      return null;
    }

    return DateTime.fromMillisecondsSinceEpoch(
      expiresAtEpochSeconds * 1000,
      isUtc: true,
    );
  }

  factory PairingQrPayload.fromJson(Map<String, dynamic> json) {
    final parsed = PairingQrPayload(
      contractVersion: _readRequiredStringAny(json, ['contract_version', 'v']),
      bridgeId: _readRequiredStringAny(json, ['bridge_id', 'b']),
      bridgeName:
          _readOptionalStringAny(json, ['bridge_name']) ??
          _defaultBridgeDisplayName,
      bridgeApiBaseUrl: _readRequiredStringAny(json, [
        'bridge_api_base_url',
        'u',
      ]),
      sessionId: _readRequiredStringAny(json, ['session_id', 's']),
      pairingToken: _readRequiredStringAny(json, ['pairing_token', 't']),
      issuedAtEpochSeconds: _readOptionalIntAny(json, [
        'issued_at_epoch_seconds',
      ]),
      expiresAtEpochSeconds: _readOptionalIntAny(json, [
        'expires_at_epoch_seconds',
      ]),
    );

    if (parsed.contractVersion != bridge_contracts.contractVersion) {
      throw const FormatException('Unsupported pairing contract version.');
    }

    final bridgeUri = Uri.tryParse(parsed.bridgeApiBaseUrl);
    if (bridgeUri == null || !bridgeUri.hasScheme || bridgeUri.host.isEmpty) {
      throw const FormatException('Invalid bridge_api_base_url.');
    }

    final issuedAtEpochSeconds = parsed.issuedAtEpochSeconds;
    final expiresAtEpochSeconds = parsed.expiresAtEpochSeconds;
    if ((issuedAtEpochSeconds == null) != (expiresAtEpochSeconds == null)) {
      throw const FormatException(
        'Pairing timestamps must be supplied together.',
      );
    }

    if (issuedAtEpochSeconds != null &&
        expiresAtEpochSeconds != null &&
        expiresAtEpochSeconds <= issuedAtEpochSeconds) {
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

String _readRequiredStringAny(Map<String, dynamic> json, List<String> keys) {
  final value = _readOptionalStringAny(json, keys);
  if (value != null) {
    return value;
  }

  throw FormatException('Missing or invalid field "${keys.first}".');
}

String? _readOptionalStringAny(Map<String, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value is String && value.trim().isNotEmpty) {
      return value.trim();
    }
  }

  return null;
}

int? _readOptionalIntAny(Map<String, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value is int) {
      return value;
    }
  }

  return null;
}

bool isPrivateBridgeApiBaseUrl(String rawBaseUrl) {
  final uri = Uri.tryParse(rawBaseUrl);
  if (uri == null || uri.scheme.toLowerCase() != 'https' || uri.host.isEmpty) {
    return false;
  }

  final host = uri.host.toLowerCase();
  if (host == 'localhost') {
    return false;
  }

  final parsedAddress = InternetAddress.tryParse(host);
  if (parsedAddress != null) {
    if (parsedAddress.isLoopback ||
        parsedAddress.type == InternetAddressType.IPv6) {
      return false;
    }

    final octets = parsedAddress.rawAddress;
    if (octets.length == 4) {
      final first = octets[0];
      final second = octets[1];
      final isPrivateRange =
          first == 10 ||
          (first == 172 && second >= 16 && second <= 31) ||
          (first == 192 && second == 168) ||
          (first == 169 && second == 254);
      if (isPrivateRange) {
        return false;
      }
    }
  }

  return host.endsWith('.ts.net') || host.endsWith('.tailscale.net');
}
