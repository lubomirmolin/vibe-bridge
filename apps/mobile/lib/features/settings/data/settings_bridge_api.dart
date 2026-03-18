import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final settingsBridgeApiProvider = Provider<SettingsBridgeApi>((ref) {
  return const HttpSettingsBridgeApi();
});

abstract class SettingsBridgeApi {
  Future<AccessMode> fetchAccessMode({required String bridgeApiBaseUrl});

  Future<AccessMode> setAccessMode({
    required String bridgeApiBaseUrl,
    required AccessMode accessMode,
    required String phoneId,
    required String bridgeId,
    required String sessionToken,
    String actor,
  });

  Future<List<SecurityEventRecordDto>> fetchSecurityEvents({
    required String bridgeApiBaseUrl,
  });
}

class HttpSettingsBridgeApi implements SettingsBridgeApi {
  const HttpSettingsBridgeApi();

  @override
  Future<AccessMode> fetchAccessMode({required String bridgeApiBaseUrl}) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);

    try {
      final request = await client.getUrl(
        _buildUri(bridgeApiBaseUrl, '/policy/access-mode'),
      );
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close();
      final decoded = _decodeJsonObject(await utf8.decodeStream(response));

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final accessMode = decoded['access_mode'];
        if (accessMode is! String) {
          throw const FormatException(
            'Missing or invalid "access_mode" in policy response.',
          );
        }
        return accessModeFromWire(accessMode);
      }

      throw SettingsBridgeException(
        message:
            _readOptionalString(decoded, 'message') ??
            'Couldn’t load the access mode right now.',
      );
    } on SocketException {
      throw const SettingsBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on HandshakeException {
      throw const SettingsBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on HttpException {
      throw const SettingsBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on TimeoutException {
      throw const SettingsBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on FormatException {
      throw const SettingsBridgeException(
        message: 'Bridge returned an invalid access-mode response.',
      );
    } finally {
      client.close();
    }
  }

  @override
  Future<AccessMode> setAccessMode({
    required String bridgeApiBaseUrl,
    required AccessMode accessMode,
    required String phoneId,
    required String bridgeId,
    required String sessionToken,
    String actor = 'mobile-device',
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);

    try {
      final request = await client.postUrl(
        _buildUri(bridgeApiBaseUrl, '/policy/access-mode', <String, String>{
          'mode': accessMode.wireValue,
          'phone_id': phoneId,
          'bridge_id': bridgeId,
          'session_token': sessionToken,
          'actor': actor,
        }),
      );
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close();
      final decoded = _decodeJsonObject(await utf8.decodeStream(response));

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
    } on SocketException {
      throw const SettingsBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on HandshakeException {
      throw const SettingsBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on HttpException {
      throw const SettingsBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on TimeoutException {
      throw const SettingsBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on FormatException {
      throw const SettingsBridgeException(
        message: 'Bridge returned an invalid access-mode response.',
      );
    } finally {
      client.close();
    }
  }

  @override
  Future<List<SecurityEventRecordDto>> fetchSecurityEvents({
    required String bridgeApiBaseUrl,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);

    try {
      final request = await client.getUrl(
        _buildUri(bridgeApiBaseUrl, '/security/events'),
      );
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close();
      final decoded = _decodeJsonObject(await utf8.decodeStream(response));

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
    } on SocketException {
      throw const SettingsBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on HandshakeException {
      throw const SettingsBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on HttpException {
      throw const SettingsBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on TimeoutException {
      throw const SettingsBridgeException(
        message: 'Cannot reach the bridge. Check your private route.',
        isConnectivityError: true,
      );
    } on FormatException {
      throw const SettingsBridgeException(
        message: 'Bridge returned an invalid security-events response.',
      );
    } finally {
      client.close();
    }
  }
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

String? _readOptionalString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    return null;
  }
  return value.trim();
}
