import 'dart:convert';

import 'package:codex_linux_shell/src/contracts.dart';
import 'package:http/http.dart' as http;

abstract interface class ShellBridgeClient {
  Future<BridgeHealthResponseDto> fetchHealth();
  Future<ThreadListResponseDto> fetchThreads();
  Future<SpeechModelStatusDto> fetchSpeechModelStatus();
  Future<PairingSessionResponseDto> fetchPairingSession();
  Future<PairingRevokeResponseDto> revokeTrust({String? phoneId});
}

class BridgeShellApiClient implements ShellBridgeClient {
  BridgeShellApiClient({http.Client? httpClient, Uri? apiBaseUrl})
    : _httpClient = httpClient ?? http.Client(),
      apiBaseUrl = apiBaseUrl ?? Uri.parse('http://127.0.0.1:3110');

  final http.Client _httpClient;
  final Uri apiBaseUrl;

  @override
  Future<BridgeHealthResponseDto> fetchHealth() async {
    final bootstrap = await _fetchJson('/bootstrap');
    final pairingRoute = await _fetchJson('/pairing/route');
    final trust = await _fetchJson('/pairing/trust');
    final threads = (bootstrap['threads'] as List<dynamic>? ?? const []).length;

    return BridgeHealthResponseDto(
      status:
          (bootstrap['bridge'] as Map<String, dynamic>? ??
                  const {})['status'] ==
              'healthy'
          ? 'ok'
          : 'degraded',
      runtime: BridgeRuntimeSnapshotDto(
        mode: 'auto',
        state:
            (bootstrap['codex'] as Map<String, dynamic>? ??
                    const {})['status'] ==
                'healthy'
            ? 'managed'
            : 'degraded',
        endpoint: null,
        pid: null,
        detail:
            ((bootstrap['codex'] as Map<String, dynamic>? ??
                    const {})['message']
                as String?) ??
            'Bridge is running.',
      ),
      pairingRoute: BridgePairingRouteHealthDto.fromJson(pairingRoute),
      trust: trust.isEmpty ? null : BridgeTrustStatusDto.fromJson(trust),
      api: BridgeApiSurfaceDto(
        endpoints: const [
          'GET /healthz',
          'GET /bootstrap',
          'GET /speech/models/parakeet',
          'GET /pairing/session',
          'POST /pairing/trust/revoke',
          'GET /threads',
        ],
        seededThreadCount: threads,
      ),
    );
  }

  @override
  Future<ThreadListResponseDto> fetchThreads() async {
    final data = await _sendJsonRequest(_resolve('/threads'));
    final threads = (data as List<dynamic>)
        .map(
          (entry) => ThreadSummaryDto.fromJson(
            Map<String, dynamic>.from(entry as Map<dynamic, dynamic>),
          ),
        )
        .toList(growable: false);
    return ThreadListResponseDto(
      contractVersion: threads.isEmpty
          ? SharedContract.version
          : threads.first.contractVersion,
      threads: threads,
    );
  }

  @override
  Future<SpeechModelStatusDto> fetchSpeechModelStatus() async {
    final data = await _fetchJson('/speech/models/parakeet');
    return SpeechModelStatusDto.fromJson(data);
  }

  @override
  Future<PairingSessionResponseDto> fetchPairingSession() async {
    final data = await _fetchJson('/pairing/session');
    return PairingSessionResponseDto.fromJson(data);
  }

  @override
  Future<PairingRevokeResponseDto> revokeTrust({String? phoneId}) async {
    final query = <String, String>{'actor': 'linux-shell'};
    if (phoneId != null && phoneId.trim().isNotEmpty) {
      query['phone_id'] = phoneId.trim();
    }
    final url = _resolve(
      '/pairing/trust/revoke',
    ).replace(queryParameters: query);
    final data = await _sendJsonRequest(url, method: 'POST');
    return PairingRevokeResponseDto.fromJson(data as Map<String, dynamic>);
  }

  Uri _resolve(String path) => apiBaseUrl.resolve(path);

  Future<Map<String, dynamic>> _fetchJson(String path) async {
    final data = await _sendJsonRequest(_resolve(path));
    return Map<String, dynamic>.from(data as Map);
  }

  Future<dynamic> _sendJsonRequest(Uri url, {String method = 'GET'}) async {
    final request = http.Request(method, url)
      ..headers['accept'] = 'application/json';
    final streamed = await _httpClient.send(request);
    final response = await http.Response.fromStream(streamed);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw BridgeShellApiClientException(
        'bridge returned HTTP ${response.statusCode}: ${response.body}',
      );
    }

    try {
      return jsonDecode(response.body);
    } catch (error) {
      throw BridgeShellApiClientException(
        'failed to decode bridge payload: $error',
      );
    }
  }
}

class BridgeShellApiClientException implements Exception {
  const BridgeShellApiClientException(this.message);

  final String message;

  @override
  String toString() => message;
}
