import 'dart:async';
import 'dart:convert';

import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:codex_mobile_companion/foundation/network/bridge_transport.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final settingsBridgeApiProvider = Provider<SettingsBridgeApi>((ref) {
  return HttpSettingsBridgeApi(transport: ref.watch(bridgeTransportProvider));
});

abstract class SettingsBridgeApi {
  Future<AccessMode> fetchAccessMode({required String bridgeApiBaseUrl});

  Future<AccessMode> setAccessMode({
    required String bridgeApiBaseUrl,
    required AccessMode accessMode,
    String? phoneId,
    String? bridgeId,
    String? sessionToken,
    String? localSessionKind,
    String actor,
  });

  Future<List<SecurityEventRecordDto>> fetchSecurityEvents({
    required String bridgeApiBaseUrl,
  });
}

class HttpSettingsBridgeApi implements SettingsBridgeApi {
  HttpSettingsBridgeApi({BridgeTransport? transport})
    : _transport = transport ?? createDefaultBridgeTransport();

  final BridgeTransport _transport;

  @override
  Future<AccessMode> fetchAccessMode({required String bridgeApiBaseUrl}) async {
    try {
      final policyResult = await _fetchJson(
        transport: _transport,
        uri: _buildUri(bridgeApiBaseUrl, '/policy/access-mode'),
      );

      if (policyResult.statusCode >= 200 && policyResult.statusCode < 300) {
        final accessMode = policyResult.json['access_mode'];
        if (accessMode is String) {
          return accessModeFromWire(accessMode);
        }
      } else if (policyResult.statusCode != 404) {
        throw SettingsBridgeException(
          message:
              _readOptionalString(policyResult.json, 'message') ??
              'Couldn’t load the access mode right now.',
        );
      }

      final bootstrapResult = await _fetchJson(
        transport: _transport,
        uri: _buildUri(bridgeApiBaseUrl, '/bootstrap'),
      );
      if (bootstrapResult.statusCode >= 200 &&
          bootstrapResult.statusCode < 300) {
        final trust = bootstrapResult.json['trust'];
        if (trust is Map<String, dynamic>) {
          final accessMode = trust['access_mode'];
          if (accessMode is String) {
            return accessModeFromWire(accessMode);
          }
        }
      }

      throw SettingsBridgeException(
        message:
            _readOptionalString(bootstrapResult.json, 'message') ??
            'Couldn’t load the access mode right now.',
      );
    } on BridgeTransportConnectionException {
      throw const SettingsBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on FormatException {
      throw const SettingsBridgeException(
        message: 'Bridge returned an invalid access-mode response.',
      );
    }
  }

  @override
  Future<AccessMode> setAccessMode({
    required String bridgeApiBaseUrl,
    required AccessMode accessMode,
    String? phoneId,
    String? bridgeId,
    String? sessionToken,
    String? localSessionKind,
    String actor = 'mobile-device',
  }) async {
    try {
      final queryParameters = <String, String>{
        'mode': accessMode.wireValue,
        'actor': actor,
      };
      if (phoneId != null && phoneId.trim().isNotEmpty) {
        queryParameters['phone_id'] = phoneId.trim();
      }
      if (bridgeId != null && bridgeId.trim().isNotEmpty) {
        queryParameters['bridge_id'] = bridgeId.trim();
      }
      if (sessionToken != null && sessionToken.trim().isNotEmpty) {
        queryParameters['session_token'] = sessionToken.trim();
      }
      if (localSessionKind != null && localSessionKind.trim().isNotEmpty) {
        queryParameters['local_session'] = localSessionKind.trim();
      }

      final response = await _transport.post(
        _buildUri(bridgeApiBaseUrl, '/policy/access-mode', queryParameters),
        headers: const <String, String>{'accept': 'application/json'},
      );
      final decoded = _decodeJsonObject(response.bodyText);

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final rawMode = decoded['access_mode'];
        if (rawMode is! String) {
          throw const FormatException(
            'Missing or invalid "access_mode" in policy response.',
          );
        }
        return accessModeFromWire(rawMode);
      }

      throw SettingsBridgeException(
        message:
            _readOptionalString(decoded, 'message') ??
            'Couldn’t update access mode right now.',
        statusCode: response.statusCode,
      );
    } on BridgeTransportConnectionException {
      throw const SettingsBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on FormatException {
      throw const SettingsBridgeException(
        message: 'Bridge returned an invalid access-mode response.',
      );
    }
  }

  @override
  Future<List<SecurityEventRecordDto>> fetchSecurityEvents({
    required String bridgeApiBaseUrl,
  }) async {
    try {
      final response = await _transport.get(
        _buildUri(bridgeApiBaseUrl, '/security/events'),
        headers: const <String, String>{'accept': 'application/json'},
      );
      final decoded = _decodeJsonObject(response.bodyText);

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final eventsJson = decoded['events'];
        if (eventsJson is! List) {
          throw const FormatException(
            'Missing or invalid "events" list in security response.',
          );
        }

        return eventsJson
            .map((entry) {
              if (entry is! Map<String, dynamic>) {
                throw const FormatException(
                  'Security event entry must be a JSON object.',
                );
              }
              return SecurityEventRecordDto.fromJson(entry);
            })
            .toList(growable: false);
      }

      throw SettingsBridgeException(
        message:
            _readOptionalString(decoded, 'message') ??
            'Couldn’t load recent security events right now.',
      );
    } on BridgeTransportConnectionException {
      throw const SettingsBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on FormatException {
      throw const SettingsBridgeException(
        message: 'Bridge returned an invalid security-events response.',
      );
    }
  }
}

class _JsonResponse {
  const _JsonResponse({required this.statusCode, required this.json});

  final int statusCode;
  final Map<String, dynamic> json;
}

class SettingsBridgeException implements Exception {
  const SettingsBridgeException({
    required this.message,
    this.statusCode,
    this.isConnectivityError = false,
  });

  final String message;
  final int? statusCode;
  final bool isConnectivityError;

  @override
  String toString() => message;
}

Uri _buildUri(String baseUrl, String routePath, [Map<String, String>? query]) {
  final baseUri = Uri.parse(baseUrl);
  final normalizedBasePath = baseUri.path.endsWith('/')
      ? baseUri.path.substring(0, baseUri.path.length - 1)
      : baseUri.path;
  final normalizedRoute = routePath.startsWith('/') ? routePath : '/$routePath';
  final fullPath =
      '${normalizedBasePath.isEmpty ? '' : normalizedBasePath}$normalizedRoute';

  return baseUri.replace(
    path: fullPath,
    queryParameters: query == null || query.isEmpty ? null : query,
  );
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

Future<_JsonResponse> _fetchJson({
  required BridgeTransport transport,
  required Uri uri,
}) async {
  final response = await transport.get(
    uri,
    headers: const <String, String>{'accept': 'application/json'},
  );
  return _JsonResponse(
    statusCode: response.statusCode,
    json: _decodeJsonObject(response.bodyText),
  );
}

String? _readOptionalString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    return null;
  }
  return value.trim();
}
