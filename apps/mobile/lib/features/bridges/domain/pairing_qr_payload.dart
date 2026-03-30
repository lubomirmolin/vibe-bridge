import 'dart:convert';

import 'package:vibe_bridge/foundation/contracts/bridge_contracts.dart'
    as bridge_contracts;

const String _defaultBridgeDisplayName = 'Vibe bridge';

class PairingQrPayload {
  const PairingQrPayload({
    required this.contractVersion,
    required this.bridgeId,
    this.bridgeName = _defaultBridgeDisplayName,
    required this.bridgeApiBaseUrl,
    required this.bridgeApiRoutes,
    required this.sessionId,
    required this.pairingToken,
    this.issuedAtEpochSeconds,
    this.expiresAtEpochSeconds,
  });

  final String contractVersion;
  final String bridgeId;
  final String bridgeName;
  final String bridgeApiBaseUrl;
  final List<BridgeApiRoute> bridgeApiRoutes;
  final String sessionId;
  final String pairingToken;
  final int? issuedAtEpochSeconds;
  final int? expiresAtEpochSeconds;

  List<BridgeApiRoute> get orderedReachableRoutes => _orderedReachableRoutes(
    bridgeApiRoutes,
    fallbackBaseUrl: bridgeApiBaseUrl,
  );

  DateTime? get issuedAtUtc => _epochSecondsToUtc(issuedAtEpochSeconds);

  DateTime? get expiresAtUtc => _epochSecondsToUtc(expiresAtEpochSeconds);

  factory PairingQrPayload.fromJson(Map<String, dynamic> json) {
    final bridgeApiBaseUrl = _readRequiredStringAny(json, [
      'bridge_api_base_url',
      'u',
    ]);
    final bridgeApiRoutes = _readBridgeApiRoutes(
      json,
      fallbackBaseUrl: bridgeApiBaseUrl,
    );
    final parsed = PairingQrPayload(
      contractVersion: _readRequiredStringAny(json, ['contract_version', 'v']),
      bridgeId: _readRequiredStringAny(json, ['bridge_id', 'b']),
      bridgeName:
          _readOptionalStringAny(json, ['bridge_name']) ??
          _defaultBridgeDisplayName,
      bridgeApiBaseUrl: bridgeApiBaseUrl,
      bridgeApiRoutes: bridgeApiRoutes,
      sessionId: _readRequiredStringAny(json, ['session_id', 's']),
      pairingToken: _readRequiredStringAny(json, ['pairing_token', 't']),
      issuedAtEpochSeconds: _readOptionalIntAny(json, [
        'issued_at_epoch_seconds',
        'i',
      ]),
      expiresAtEpochSeconds: _readOptionalIntAny(json, [
        'expires_at_epoch_seconds',
        'e',
      ]),
    );

    if (!_isSupportedPairingContractVersion(parsed.contractVersion)) {
      throw const FormatException('Unsupported pairing contract version.');
    }

    if (parsed.orderedReachableRoutes.isEmpty) {
      throw const FormatException('Invalid bridge_api_routes.');
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

bool _isSupportedPairingContractVersion(String contractVersion) {
  final normalized = contractVersion.trim();
  if (normalized == bridge_contracts.contractVersion) {
    return true;
  }

  return RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(normalized);
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
    required this.bridgeApiRoutes,
    required this.sessionId,
    required this.pairedAtEpochSeconds,
  });

  final String bridgeId;
  final String bridgeName;
  final String bridgeApiBaseUrl;
  final List<BridgeApiRoute> bridgeApiRoutes;
  final String sessionId;
  final int pairedAtEpochSeconds;

  List<BridgeApiRoute> get orderedReachableRoutes => _orderedReachableRoutes(
    bridgeApiRoutes,
    fallbackBaseUrl: bridgeApiBaseUrl,
  );

  factory TrustedBridgeIdentity.fromPayload(
    PairingQrPayload payload, {
    required DateTime pairedAtUtc,
  }) {
    return TrustedBridgeIdentity(
      bridgeId: payload.bridgeId,
      bridgeName: payload.bridgeName,
      bridgeApiBaseUrl: payload.bridgeApiBaseUrl,
      bridgeApiRoutes: payload.bridgeApiRoutes,
      sessionId: payload.sessionId,
      pairedAtEpochSeconds: pairedAtUtc.millisecondsSinceEpoch ~/ 1000,
    );
  }

  factory TrustedBridgeIdentity.fromJson(Map<String, dynamic> json) {
    return TrustedBridgeIdentity(
      bridgeId: _readRequiredString(json, 'bridge_id'),
      bridgeName: _readRequiredString(json, 'bridge_name'),
      bridgeApiBaseUrl: _readRequiredString(json, 'bridge_api_base_url'),
      bridgeApiRoutes: _readBridgeApiRoutes(
        json,
        fallbackBaseUrl: _readRequiredString(json, 'bridge_api_base_url'),
      ),
      sessionId: _readRequiredString(json, 'session_id'),
      pairedAtEpochSeconds: _readRequiredInt(json, 'paired_at_epoch_seconds'),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'bridge_id': bridgeId,
      'bridge_name': bridgeName,
      'bridge_api_base_url': bridgeApiBaseUrl,
      'bridge_api_routes': bridgeApiRoutes
          .map((route) => route.toJson())
          .toList(growable: false),
      'session_id': sessionId,
      'paired_at_epoch_seconds': pairedAtEpochSeconds,
    };
  }
}

enum BridgeApiRouteKind { tailscale, localNetwork }

class BridgeApiRoute {
  const BridgeApiRoute({
    required this.id,
    required this.kind,
    required this.baseUrl,
    required this.reachable,
    required this.isPreferred,
  });

  final String id;
  final BridgeApiRouteKind kind;
  final String baseUrl;
  final bool reachable;
  final bool isPreferred;

  factory BridgeApiRoute.fromJson(Map<String, dynamic> json) {
    final baseUrl = _readRequiredString(json, 'base_url');
    final kind = _readBridgeApiRouteKind(
      json['kind'] as String? ?? _inferBridgeApiRouteKindWire(baseUrl),
      baseUrl,
    );
    if (!isSupportedBridgeApiRouteBaseUrl(baseUrl, kind: kind)) {
      throw const FormatException('Invalid bridge API route.');
    }

    return BridgeApiRoute(
      id: _readRequiredString(json, 'id'),
      kind: kind,
      baseUrl: baseUrl,
      reachable: json['reachable'] as bool? ?? false,
      isPreferred: json['is_preferred'] as bool? ?? false,
    );
  }

  factory BridgeApiRoute.legacy({required String baseUrl}) {
    final kind = _readBridgeApiRouteKind(
      _inferBridgeApiRouteKindWire(baseUrl),
      baseUrl,
    );
    return BridgeApiRoute(
      id: kind == BridgeApiRouteKind.tailscale ? 'tailscale' : 'local_network',
      kind: kind,
      baseUrl: baseUrl,
      reachable: true,
      isPreferred: true,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'kind': switch (kind) {
        BridgeApiRouteKind.tailscale => 'tailscale',
        BridgeApiRouteKind.localNetwork => 'local_network',
      },
      'base_url': baseUrl,
      'reachable': reachable,
      'is_preferred': isPreferred,
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

List<BridgeApiRoute> _readBridgeApiRoutes(
  Map<String, dynamic> json, {
  required String fallbackBaseUrl,
}) {
  final compactRoutes = json['r'];
  if (compactRoutes is List<dynamic>) {
    final parsed = compactRoutes
        .asMap()
        .entries
        .map(
          (entry) => _readCompactBridgeApiRoute(
            entry.value,
            index: entry.key,
            fallbackBaseUrl: fallbackBaseUrl,
          ),
        )
        .toList(growable: false);
    if (parsed.isEmpty) {
      throw const FormatException('r must not be empty.');
    }
    return parsed;
  }

  final rawRoutes = json['bridge_api_routes'];
  if (rawRoutes is List<dynamic>) {
    final parsed = rawRoutes
        .map((entry) {
          if (entry is! Map<String, dynamic>) {
            throw const FormatException('Invalid bridge_api_routes entry.');
          }
          return BridgeApiRoute.fromJson(entry);
        })
        .toList(growable: false);
    if (parsed.isEmpty) {
      throw const FormatException('bridge_api_routes must not be empty.');
    }
    return parsed;
  }

  if (!isSupportedBridgeApiRouteBaseUrl(fallbackBaseUrl)) {
    throw const FormatException('Invalid bridge_api_base_url.');
  }

  return <BridgeApiRoute>[BridgeApiRoute.legacy(baseUrl: fallbackBaseUrl)];
}

BridgeApiRoute _readCompactBridgeApiRoute(
  dynamic rawRoute, {
  required int index,
  required String fallbackBaseUrl,
}) {
  if (rawRoute is String) {
    return _buildCompactBridgeApiRoute(
      baseUrl: rawRoute,
      index: index,
      fallbackBaseUrl: fallbackBaseUrl,
    );
  }

  throw const FormatException('Invalid r entry.');
}

BridgeApiRoute _buildCompactBridgeApiRoute({
  required String baseUrl,
  required int index,
  required String fallbackBaseUrl,
}) {
  final normalizedBaseUrl = baseUrl.trim();
  final kind = _readBridgeApiRouteKind(
    _inferBridgeApiRouteKindWire(normalizedBaseUrl),
    normalizedBaseUrl,
  );
  if (!isSupportedBridgeApiRouteBaseUrl(normalizedBaseUrl, kind: kind)) {
    throw const FormatException('Invalid bridge API route.');
  }

  return BridgeApiRoute(
    id: kind == BridgeApiRouteKind.tailscale ? 'tailscale' : 'local_network',
    kind: kind,
    baseUrl: normalizedBaseUrl,
    reachable: true,
    isPreferred: index == 0 || normalizedBaseUrl == fallbackBaseUrl.trim(),
  );
}

BridgeApiRouteKind _readBridgeApiRouteKind(String raw, String baseUrl) {
  switch (raw.trim().toLowerCase()) {
    case 'tailscale':
      return BridgeApiRouteKind.tailscale;
    case 'local_network':
      return BridgeApiRouteKind.localNetwork;
    default:
      return _readBridgeApiRouteKind(
        _inferBridgeApiRouteKindWire(baseUrl),
        baseUrl,
      );
  }
}

String _inferBridgeApiRouteKindWire(String baseUrl) {
  return isPrivateBridgeApiBaseUrl(baseUrl) ? 'tailscale' : 'local_network';
}

int compareBridgeApiRoutes(BridgeApiRoute left, BridgeApiRoute right) {
  final leftScore = _bridgeApiRouteSortScore(left);
  final rightScore = _bridgeApiRouteSortScore(right);
  if (leftScore != rightScore) {
    return rightScore.compareTo(leftScore);
  }
  return left.baseUrl.compareTo(right.baseUrl);
}

int _bridgeApiRouteSortScore(BridgeApiRoute route) {
  if (route.isPreferred && route.reachable) {
    return 4;
  }
  if (route.kind == BridgeApiRouteKind.tailscale && route.reachable) {
    return 3;
  }
  if (route.kind == BridgeApiRouteKind.localNetwork && route.reachable) {
    return 2;
  }
  if (route.isPreferred) {
    return 1;
  }
  return 0;
}

List<BridgeApiRoute> _orderedReachableRoutes(
  List<BridgeApiRoute> routes, {
  required String fallbackBaseUrl,
}) {
  final reachableRoutes = routes.where((route) => route.reachable).toList();
  if (reachableRoutes.isEmpty) {
    final fallbackRoute = routes.firstWhere(
      (route) => route.baseUrl == fallbackBaseUrl,
      orElse: () => BridgeApiRoute.legacy(baseUrl: fallbackBaseUrl),
    );
    return List<BridgeApiRoute>.unmodifiable(<BridgeApiRoute>[fallbackRoute]);
  }

  reachableRoutes.sort(compareBridgeApiRoutes);
  return List<BridgeApiRoute>.unmodifiable(reachableRoutes);
}

DateTime? _epochSecondsToUtc(int? epochSeconds) {
  if (epochSeconds == null) {
    return null;
  }

  return DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000, isUtc: true);
}

bool isSupportedBridgeApiRouteBaseUrl(
  String rawBaseUrl, {
  BridgeApiRouteKind? kind,
}) {
  if (kind == BridgeApiRouteKind.localNetwork) {
    return isLocalNetworkBridgeApiBaseUrl(rawBaseUrl);
  }

  if (kind == BridgeApiRouteKind.tailscale) {
    return isPrivateBridgeApiBaseUrl(rawBaseUrl);
  }

  return isPrivateBridgeApiBaseUrl(rawBaseUrl) ||
      isLocalNetworkBridgeApiBaseUrl(rawBaseUrl);
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

  final parsedIpv4Address = _tryParseIpv4Address(host);
  if (parsedIpv4Address != null) {
    if (_isLoopbackIpv4(parsedIpv4Address)) {
      return false;
    }

    if (_isPrivateIpv4(parsedIpv4Address) ||
        _isLinkLocalIpv4(parsedIpv4Address)) {
      return false;
    }
  } else if (host.contains(':')) {
    return false;
  }

  return host.endsWith('.ts.net') || host.endsWith('.tailscale.net');
}

bool isLocalNetworkBridgeApiBaseUrl(String rawBaseUrl) {
  final uri = Uri.tryParse(rawBaseUrl);
  if (uri == null || uri.scheme.toLowerCase() != 'http' || uri.host.isEmpty) {
    return false;
  }

  final parsedAddress = _tryParseIpv4Address(uri.host);
  if (parsedAddress == null) {
    return false;
  }

  if (_isLoopbackIpv4(parsedAddress)) {
    return false;
  }

  return _isPrivateIpv4(parsedAddress);
}

List<int>? _tryParseIpv4Address(String rawHost) {
  final segments = rawHost.split('.');
  if (segments.length != 4) {
    return null;
  }

  final octets = <int>[];
  for (final segment in segments) {
    if (segment.isEmpty || !RegExp(r'^\d+$').hasMatch(segment)) {
      return null;
    }
    final parsed = int.tryParse(segment);
    if (parsed == null || parsed < 0 || parsed > 255) {
      return null;
    }
    octets.add(parsed);
  }
  return octets;
}

bool _isLoopbackIpv4(List<int> octets) => octets.first == 127;

bool _isPrivateIpv4(List<int> octets) {
  final first = octets[0];
  final second = octets[1];
  return first == 10 ||
      (first == 172 && second >= 16 && second <= 31) ||
      (first == 192 && second == 168);
}

bool _isLinkLocalIpv4(List<int> octets) {
  return octets[0] == 169 && octets[1] == 254;
}
