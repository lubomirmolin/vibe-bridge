import 'dart:convert';
import 'dart:io';

import 'package:flutter_driver/flutter_driver.dart';
import 'package:integration_test/integration_test_driver.dart';

const String _probeFilePath = 'apps/mobile/lib/live_approval_probe.dart';

Future<void> main() async {
  if (!_shouldRunClaudeTeardownVerification()) {
    await integrationDriver();
    return;
  }

  final bridgeApiBaseUrl = _resolveBridgeApiBaseUrl();
  final workspacePath = _resolveWorkspacePath();
  final probeFile = File(_resolveProbeFilePath());
  final baselineProbeContents = await probeFile.readAsString();
  final baselineThread = await _fetchLatestClaudeThread(
    bridgeApiBaseUrl: bridgeApiBaseUrl,
    workspacePath: workspacePath,
  );

  try {
    await integrationDriver();
  } on DriverError catch (error) {
    if (!_isVmServiceTeardown(error)) {
      rethrow;
    }

    final verified = await _verifyCompletedProbeEditAfterTeardown(
      bridgeApiBaseUrl: bridgeApiBaseUrl,
      workspacePath: workspacePath,
      baselineThreadId: baselineThread?.threadId,
      baselineProbeContents: baselineProbeContents,
      probeFile: probeFile,
    );
    if (!verified) {
      rethrow;
    }

    stdout.writeln(
      'Recovered integration success after VM service teardown by verifying '
      'a newer Claude Code thread completed the probe edit through the bridge.',
    );
  }
}

bool _shouldRunClaudeTeardownVerification() {
  final hasClaudeBridge =
      (Platform.environment['LIVE_CLAUDE_APPROVAL_BRIDGE_BASE_URL'] ?? '')
          .trim()
          .isNotEmpty;
  final hasClaudeWorkspace =
      (Platform.environment['LIVE_CLAUDE_APPROVAL_WORKSPACE'] ?? '')
          .trim()
          .isNotEmpty;
  return hasClaudeBridge || hasClaudeWorkspace;
}

String _resolveBridgeApiBaseUrl() {
  return Platform.environment['LIVE_CLAUDE_APPROVAL_BRIDGE_BASE_URL'] ??
      'http://127.0.0.1:3110';
}

String _resolveWorkspacePath() {
  return Platform.environment['LIVE_CLAUDE_APPROVAL_WORKSPACE'] ??
      Directory.current.parent.parent.path;
}

String _resolveProbeFilePath() {
  return Directory.current.parent.parent.uri
      .resolve(_probeFilePath)
      .toFilePath();
}

bool _isVmServiceTeardown(DriverError error) {
  final message = error.toString();
  return message.contains('Service has disappeared');
}

Future<bool> _verifyCompletedProbeEditAfterTeardown({
  required String bridgeApiBaseUrl,
  required String workspacePath,
  required String? baselineThreadId,
  required String baselineProbeContents,
  required File probeFile,
}) async {
  final deadline = DateTime.now().add(const Duration(minutes: 2));

  while (DateTime.now().isBefore(deadline)) {
    final latestThread = await _fetchLatestClaudeThread(
      bridgeApiBaseUrl: bridgeApiBaseUrl,
      workspacePath: workspacePath,
    );
    final probeContents = await probeFile.readAsString();
    if (latestThread == null ||
        latestThread.threadId == baselineThreadId ||
        probeContents == baselineProbeContents) {
      await Future<void>.delayed(const Duration(seconds: 1));
      continue;
    }

    final snapshot = await _fetchThreadSnapshot(
      bridgeApiBaseUrl: bridgeApiBaseUrl,
      threadId: latestThread.threadId,
    );
    final thread = snapshot['thread'];
    final pendingUserInput = snapshot['pending_user_input'];
    final entries = snapshot['entries'];
    final status = thread is Map<String, dynamic> ? thread['status'] : null;
    final hasProbeFileChange =
        entries is List<dynamic> &&
        entries.any((entry) {
          if (entry is! Map<String, dynamic> ||
              entry['kind'] != 'file_change') {
            return false;
          }
          final payload = entry['payload'];
          if (payload is! Map<String, dynamic>) {
            return false;
          }
          final input = payload['input'];
          if (input is Map<String, dynamic>) {
            final filePath = input['file_path'];
            if (filePath is String && filePath.endsWith(_probeFilePath)) {
              return true;
            }
          }
          final toolUseResult = payload['tool_use_result'];
          if (toolUseResult is Map<String, dynamic>) {
            final filePath = toolUseResult['filePath'];
            if (filePath is String && filePath.endsWith(_probeFilePath)) {
              return true;
            }
          }
          return false;
        });

    if (status == 'completed' &&
        pendingUserInput == null &&
        hasProbeFileChange) {
      return true;
    }

    await Future<void>.delayed(const Duration(seconds: 1));
  }

  return false;
}

Future<_ClaudeThreadSummary?> _fetchLatestClaudeThread({
  required String bridgeApiBaseUrl,
  required String workspacePath,
}) async {
  final decoded = await _getJson(_buildBridgeUri(bridgeApiBaseUrl, '/threads'));
  if (decoded is! List<dynamic>) {
    return null;
  }

  _ClaudeThreadSummary? latest;
  for (final rawThread in decoded) {
    if (rawThread is! Map<String, dynamic>) {
      continue;
    }
    if (rawThread['provider'] != 'claude_code') {
      continue;
    }
    if ((rawThread['workspace'] as String?)?.trim() != workspacePath) {
      continue;
    }
    final threadId = rawThread['thread_id'];
    final updatedAt = rawThread['updated_at'];
    if (threadId is! String || updatedAt is! String) {
      continue;
    }
    final parsedUpdatedAt = DateTime.tryParse(updatedAt);
    if (parsedUpdatedAt == null) {
      continue;
    }
    final candidate = _ClaudeThreadSummary(
      threadId: threadId,
      updatedAt: parsedUpdatedAt,
    );
    if (latest == null || candidate.updatedAt.isAfter(latest.updatedAt)) {
      latest = candidate;
    }
  }
  return latest;
}

Future<Map<String, dynamic>> _fetchThreadSnapshot({
  required String bridgeApiBaseUrl,
  required String threadId,
}) async {
  final decoded = await _getJson(
    _buildBridgeUri(bridgeApiBaseUrl, '/threads/$threadId/snapshot'),
  );
  if (decoded is! Map<String, dynamic>) {
    throw StateError('Expected snapshot object for $threadId, got $decoded');
  }
  return decoded;
}

Future<Object?> _getJson(Uri uri) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final request = await client.getUrl(uri);
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'GET $uri failed with ${response.statusCode}: $body',
        uri: uri,
      );
    }
    return jsonDecode(body);
  } finally {
    client.close();
  }
}

Uri _buildBridgeUri(String baseUrl, String routePath) {
  final baseUri = Uri.parse(baseUrl);
  final normalizedBasePath = baseUri.path.endsWith('/')
      ? baseUri.path.substring(0, baseUri.path.length - 1)
      : baseUri.path;
  final normalizedRoute = routePath.startsWith('/') ? routePath : '/$routePath';
  final fullPath =
      '${normalizedBasePath.isEmpty ? '' : normalizedBasePath}$normalizedRoute';
  return baseUri.replace(path: fullPath, queryParameters: null);
}

class _ClaudeThreadSummary {
  const _ClaudeThreadSummary({required this.threadId, required this.updatedAt});

  final String threadId;
  final DateTime updatedAt;
}
