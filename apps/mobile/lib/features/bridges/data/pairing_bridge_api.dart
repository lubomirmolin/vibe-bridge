import 'dart:async';
import 'dart:convert';

import 'package:vibe_bridge/features/bridges/domain/pairing_qr_payload.dart';
import 'package:vibe_bridge/foundation/network/bridge_transport.dart';

abstract class PairingBridgeApi {
  Future<PairingFinalizeResult> finalizeTrust({
    required PairingQrPayload payload,
    required String phoneId,
    required String phoneName,
  });

  Future<PairingHandshakeResult> handshake({
    required TrustedBridgeIdentity trustedBridge,
    required String phoneId,
    required String sessionToken,
  });

  Future<PairingRevokeResult> revokeTrust({
    required TrustedBridgeIdentity trustedBridge,
    required String? phoneId,
  });
}

class HttpPairingBridgeApi implements PairingBridgeApi {
  HttpPairingBridgeApi({BridgeTransport? transport})
    : _transport = transport ?? createDefaultBridgeTransport();

  final BridgeTransport _transport;

  @override
  Future<PairingFinalizeResult> finalizeTrust({
    required PairingQrPayload payload,
    required String phoneId,
    required String phoneName,
  }) async {
    for (final route in payload.orderedReachableRoutes) {
      try {
        final uri = _buildPairingUri(
          route.baseUrl,
          '/pairing/finalize',
          <String, String>{
            'session_id': payload.sessionId,
            'pairing_token': payload.pairingToken,
            'phone_id': phoneId,
            'phone_name': phoneName,
            'bridge_id': payload.bridgeId,
          },
        );

        final response = await _post(uri);
        if (response.statusCode >= 200 && response.statusCode < 300) {
          final bridgeIdentity = _readRequiredObject(
            response.jsonBody,
            'bridge_identity',
          );
          final sessionToken = _readRequiredString(
            response.jsonBody,
            'session_token',
          );
          final bridgeId = _readRequiredString(bridgeIdentity, 'bridge_id');
          final bridgeName = _readRequiredString(
            bridgeIdentity,
            'display_name',
          );

          if (bridgeId != payload.bridgeId) {
            throw const FormatException(
              'Bridge identity mismatch in finalize response.',
            );
          }

          return PairingFinalizeResult.success(
            sessionToken: sessionToken,
            bridgeId: bridgeId,
            bridgeName: bridgeName,
            bridgeApiBaseUrl: route.baseUrl,
            bridgeApiRoutes: _readBridgeApiRoutes(
              response.jsonBody,
              fallbackBaseUrl: route.baseUrl,
            ),
          );
        }

        final code = _readOptionalString(response.jsonBody, 'code');
        final message =
            _readOptionalString(response.jsonBody, 'message') ??
            'Could not complete trust confirmation. Please try again.';
        return PairingFinalizeResult.failure(code: code, message: message);
      } on BridgeTransportConnectionException {
        continue;
      } on FormatException {
        return const PairingFinalizeResult.failure(
          code: 'bridge_response_invalid',
          message:
              'Bridge returned an invalid trust response. Please regenerate pairing from the host bridge.',
        );
      }
    }

    return const PairingFinalizeResult.failure(
      code: 'connectivity_unavailable',
      message:
          'Cannot reach the bridge over Tailscale or local network right now. Check connectivity and try again.',
    );
  }

  @override
  Future<PairingHandshakeResult> handshake({
    required TrustedBridgeIdentity trustedBridge,
    required String phoneId,
    required String sessionToken,
  }) async {
    for (final route in trustedBridge.orderedReachableRoutes) {
      try {
        final uri = _buildPairingUri(
          route.baseUrl,
          '/pairing/handshake',
          <String, String>{
            'phone_id': phoneId,
            'bridge_id': trustedBridge.bridgeId,
            'session_token': sessionToken,
          },
        );

        final response = await _post(uri);
        if (response.statusCode >= 200 && response.statusCode < 300) {
          final bridgeIdentity = _readRequiredObject(
            response.jsonBody,
            'bridge_identity',
          );
          return PairingHandshakeResult.trusted(
            bridgeId: _readRequiredString(bridgeIdentity, 'bridge_id'),
            bridgeName: _readRequiredString(bridgeIdentity, 'display_name'),
            bridgeApiBaseUrl: route.baseUrl,
            bridgeApiRoutes: _readBridgeApiRoutes(
              response.jsonBody,
              fallbackBaseUrl: route.baseUrl,
            ),
            sessionId: _readRequiredString(response.jsonBody, 'session_id'),
          );
        }

        final code = _readOptionalString(response.jsonBody, 'code');
        final message =
            _readOptionalString(response.jsonBody, 'message') ??
            'Stored trust is no longer accepted by the bridge.';
        return PairingHandshakeResult.untrusted(code: code, message: message);
      } on BridgeTransportConnectionException {
        continue;
      } on FormatException {
        return const PairingHandshakeResult.untrusted(
          code: 'bridge_response_invalid',
          message:
              'Bridge returned an invalid trust response. Re-pair from the host bridge.',
        );
      }
    }

    return const PairingHandshakeResult.connectivityUnavailable(
      message:
          'Bridge routes are currently unreachable over Tailscale and local network. Reconnect and retry.',
    );
  }

  @override
  Future<PairingRevokeResult> revokeTrust({
    required TrustedBridgeIdentity trustedBridge,
    required String? phoneId,
  }) async {
    final query = <String, String>{'actor': 'mobile-device'};
    final normalizedPhoneId = phoneId?.trim();
    if (normalizedPhoneId != null && normalizedPhoneId.isNotEmpty) {
      query['phone_id'] = normalizedPhoneId;
    }

    for (final route in trustedBridge.orderedReachableRoutes) {
      try {
        final uri = _buildPairingUri(
          route.baseUrl,
          '/pairing/trust/revoke',
          query,
        );

        final response = await _post(uri);
        if (response.statusCode >= 200 && response.statusCode < 300) {
          return const PairingRevokeResult.success();
        }

        return PairingRevokeResult.failure(
          message:
              _readOptionalString(response.jsonBody, 'message') ??
              'Couldn’t revoke bridge trust from mobile right now.',
        );
      } on BridgeTransportConnectionException {
        continue;
      } on FormatException {
        return const PairingRevokeResult.failure(
          message:
              'Bridge returned an invalid unpair response. Local trust will still be cleared.',
        );
      }
    }

    return const PairingRevokeResult.failure(
      message:
          'Could not reach the bridge to revoke trust over Tailscale or local network. Local trust will still be cleared.',
    );
  }

  Future<_HttpJsonResponse> _post(Uri uri) async {
    final response = await _transport.post(
      uri,
      headers: const <String, String>{'accept': 'application/json'},
    );
    return _HttpJsonResponse(
      response.statusCode,
      _decodeJsonObject(response.bodyText),
    );
  }
}

class PairingFinalizeResult {
  const PairingFinalizeResult._({
    this.sessionToken,
    this.bridgeId,
    this.bridgeName,
    this.bridgeApiBaseUrl,
    this.bridgeApiRoutes,
    this.code,
    this.message,
  });

  final String? sessionToken;
  final String? bridgeId;
  final String? bridgeName;
  final String? bridgeApiBaseUrl;
  final List<BridgeApiRoute>? bridgeApiRoutes;
  final String? code;
  final String? message;

  bool get isSuccess =>
      sessionToken != null &&
      bridgeId != null &&
      bridgeName != null &&
      bridgeApiBaseUrl != null &&
      bridgeApiRoutes != null;

  bool get requiresRescan {
    return code == 'session_already_consumed' ||
        code == 'pairing_session_expired' ||
        code == 'unknown_pairing_session' ||
        code == 'invalid_pairing_token';
  }

  const factory PairingFinalizeResult.success({
    required String sessionToken,
    required String bridgeId,
    required String bridgeName,
    required String bridgeApiBaseUrl,
    required List<BridgeApiRoute> bridgeApiRoutes,
  }) = _PairingFinalizeSuccess;

  const factory PairingFinalizeResult.failure({
    required String? code,
    required String message,
  }) = _PairingFinalizeFailure;
}

class _PairingFinalizeSuccess extends PairingFinalizeResult {
  const _PairingFinalizeSuccess({
    required super.sessionToken,
    required super.bridgeId,
    required super.bridgeName,
    required super.bridgeApiBaseUrl,
    required super.bridgeApiRoutes,
  }) : super._();
}

class _PairingFinalizeFailure extends PairingFinalizeResult {
  const _PairingFinalizeFailure({required super.code, required super.message})
    : super._();
}

class PairingHandshakeResult {
  const PairingHandshakeResult._({
    required this.isTrusted,
    this.code,
    this.message,
    this.bridgeId,
    this.bridgeName,
    this.bridgeApiBaseUrl,
    this.bridgeApiRoutes,
    this.sessionId,
    required this.connectivityUnavailable,
  });

  final bool isTrusted;
  final String? code;
  final String? message;
  final String? bridgeId;
  final String? bridgeName;
  final String? bridgeApiBaseUrl;
  final List<BridgeApiRoute>? bridgeApiRoutes;
  final String? sessionId;
  final bool connectivityUnavailable;

  bool get requiresRePair {
    if (isTrusted || connectivityUnavailable) {
      return false;
    }

    return code == 'trust_revoked' ||
        code == 'bridge_identity_mismatch' ||
        code == 'session_token_mismatch' ||
        code == 'trusted_phone_mismatch';
  }

  const factory PairingHandshakeResult.trusted({
    String? bridgeId,
    String? bridgeName,
    String? bridgeApiBaseUrl,
    List<BridgeApiRoute>? bridgeApiRoutes,
    String? sessionId,
  }) = _PairingHandshakeTrusted;

  const factory PairingHandshakeResult.untrusted({
    required String? code,
    required String message,
  }) = _PairingHandshakeUntrusted;

  const factory PairingHandshakeResult.connectivityUnavailable({
    required String message,
  }) = _PairingHandshakeConnectivityUnavailable;
}

class PairingRevokeResult {
  const PairingRevokeResult._({required this.isSuccess, this.message});

  final bool isSuccess;
  final String? message;

  const factory PairingRevokeResult.success() = _PairingRevokeSuccess;

  const factory PairingRevokeResult.failure({required String message}) =
      _PairingRevokeFailure;
}

class _PairingRevokeSuccess extends PairingRevokeResult {
  const _PairingRevokeSuccess() : super._(isSuccess: true);
}

class _PairingRevokeFailure extends PairingRevokeResult {
  const _PairingRevokeFailure({required super.message})
    : super._(isSuccess: false);
}

class _PairingHandshakeTrusted extends PairingHandshakeResult {
  const _PairingHandshakeTrusted({
    super.bridgeId,
    super.bridgeName,
    super.bridgeApiBaseUrl,
    super.bridgeApiRoutes,
    super.sessionId,
  }) : super._(isTrusted: true, connectivityUnavailable: false);
}

class _PairingHandshakeUntrusted extends PairingHandshakeResult {
  const _PairingHandshakeUntrusted({
    required super.code,
    required super.message,
  }) : super._(isTrusted: false, connectivityUnavailable: false);
}

class _PairingHandshakeConnectivityUnavailable extends PairingHandshakeResult {
  const _PairingHandshakeConnectivityUnavailable({required super.message})
    : super._(isTrusted: false, connectivityUnavailable: true);
}

Uri _buildPairingUri(
  String baseUrl,
  String routePath,
  Map<String, String> query,
) {
  final baseUri = Uri.parse(baseUrl);
  final normalizedBasePath = baseUri.path.endsWith('/')
      ? baseUri.path.substring(0, baseUri.path.length - 1)
      : baseUri.path;
  final normalizedRoute = routePath.startsWith('/') ? routePath : '/$routePath';

  final fullPath =
      '${normalizedBasePath.isEmpty ? '' : normalizedBasePath}$normalizedRoute';
  return baseUri.replace(path: fullPath, queryParameters: query);
}

Map<String, dynamic> _decodeJsonObject(String bodyText) {
  if (bodyText.trim().isEmpty) {
    return <String, dynamic>{};
  }

  final decoded = jsonDecode(bodyText);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Expected JSON object response.');
  }
  return decoded;
}

String _readRequiredString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('Missing or invalid "$key" in bridge response.');
  }
  return value.trim();
}

String? _readOptionalString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    return null;
  }
  return value.trim();
}

Map<String, dynamic> _readRequiredObject(
  Map<String, dynamic> json,
  String key,
) {
  final value = json[key];
  if (value is! Map<String, dynamic>) {
    throw FormatException('Missing or invalid "$key" in bridge response.');
  }
  return value;
}

class _HttpJsonResponse {
  const _HttpJsonResponse(this.statusCode, this.jsonBody);

  final int statusCode;
  final Map<String, dynamic> jsonBody;
}

List<BridgeApiRoute> _readBridgeApiRoutes(
  Map<String, dynamic> json, {
  required String fallbackBaseUrl,
}) {
  final rawRoutes = json['bridge_api_routes'];
  if (rawRoutes is List<dynamic>) {
    return rawRoutes
        .map((entry) {
          if (entry is! Map<String, dynamic>) {
            throw const FormatException(
              'Invalid bridge_api_routes response entry.',
            );
          }
          return BridgeApiRoute.fromJson(entry);
        })
        .toList(growable: false);
  }

  return <BridgeApiRoute>[BridgeApiRoute.legacy(baseUrl: fallbackBaseUrl)];
}
