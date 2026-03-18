import 'dart:convert';
import 'dart:io';

import 'package:codex_mobile_companion/features/approvals/data/approval_bridge_api.dart';
import 'package:codex_mobile_companion/features/settings/data/settings_bridge_api.dart';
import 'package:codex_mobile_companion/features/threads/data/thread_detail_bridge_api.dart';
import 'package:codex_mobile_companion/features/threads/data/thread_list_bridge_api.dart';
import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('live bridge approval queue/detail/approve/reject flow', (
    tester,
  ) async {
    final bridgeApiBaseUrl = _resolveBridgeApiBaseUrl();
    final threadApi = const HttpThreadDetailBridgeApi();
    final threadListApi = const HttpThreadListBridgeApi();
    final approvalApi = const HttpApprovalBridgeApi();
    final settingsApi = const HttpSettingsBridgeApi();

    final trustedSession = await _createTrustedSession(bridgeApiBaseUrl);
    final gitThreadContext = await _selectThreadWithGitContext(
      bridgeApiBaseUrl: bridgeApiBaseUrl,
      threadApi: threadApi,
      threadListApi: threadListApi,
    );

    await settingsApi.setAccessMode(
      bridgeApiBaseUrl: bridgeApiBaseUrl,
      accessMode: AccessMode.controlWithApprovals,
      phoneId: trustedSession.phoneId,
      bridgeId: trustedSession.bridgeId,
      sessionToken: trustedSession.sessionToken,
      actor: _integrationActor,
    );

    final queuedBranchSwitchApproval = await _expectApprovalRequired(
      () => threadApi.switchBranch(
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        threadId: gitThreadContext.threadId,
        branch: gitThreadContext.branch,
      ),
    );

    final approvalsAfterBranchSwitch = await approvalApi.fetchApprovals(
      bridgeApiBaseUrl: bridgeApiBaseUrl,
    );
    final branchSwitchRecord = approvalsAfterBranchSwitch.firstWhere(
      (approval) =>
          approval.approvalId == queuedBranchSwitchApproval.approvalId,
    );
    expect(branchSwitchRecord.status, ApprovalStatus.pending);
    expect(branchSwitchRecord.threadId, gitThreadContext.threadId);

    await settingsApi.setAccessMode(
      bridgeApiBaseUrl: bridgeApiBaseUrl,
      accessMode: AccessMode.fullControl,
      phoneId: trustedSession.phoneId,
      bridgeId: trustedSession.bridgeId,
      sessionToken: trustedSession.sessionToken,
      actor: _integrationActor,
    );

    final approveResponse = await approvalApi.approve(
      bridgeApiBaseUrl: bridgeApiBaseUrl,
      approvalId: queuedBranchSwitchApproval.approvalId,
    );
    expect(approveResponse.approval.status, ApprovalStatus.approved);
    expect(approveResponse.approval.threadId, gitThreadContext.threadId);
    expect(approveResponse.mutationResult, isNotNull);

    await settingsApi.setAccessMode(
      bridgeApiBaseUrl: bridgeApiBaseUrl,
      accessMode: AccessMode.controlWithApprovals,
      phoneId: trustedSession.phoneId,
      bridgeId: trustedSession.bridgeId,
      sessionToken: trustedSession.sessionToken,
      actor: _integrationActor,
    );

    final queuedPullApproval = await _expectApprovalRequired(
      () => threadApi.pullRepository(
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        threadId: gitThreadContext.threadId,
        remote: gitThreadContext.remote,
      ),
    );

    final approvalsAfterPull = await approvalApi.fetchApprovals(
      bridgeApiBaseUrl: bridgeApiBaseUrl,
    );
    final pullRecord = approvalsAfterPull.firstWhere(
      (approval) => approval.approvalId == queuedPullApproval.approvalId,
    );
    expect(pullRecord.status, ApprovalStatus.pending);
    expect(pullRecord.threadId, gitThreadContext.threadId);

    await settingsApi.setAccessMode(
      bridgeApiBaseUrl: bridgeApiBaseUrl,
      accessMode: AccessMode.fullControl,
      phoneId: trustedSession.phoneId,
      bridgeId: trustedSession.bridgeId,
      sessionToken: trustedSession.sessionToken,
      actor: _integrationActor,
    );

    final rejectResponse = await approvalApi.reject(
      bridgeApiBaseUrl: bridgeApiBaseUrl,
      approvalId: queuedPullApproval.approvalId,
    );
    expect(rejectResponse.approval.status, ApprovalStatus.rejected);
    expect(rejectResponse.approval.threadId, gitThreadContext.threadId);
    expect(rejectResponse.mutationResult, isNull);

    final finalApprovals = await approvalApi.fetchApprovals(
      bridgeApiBaseUrl: bridgeApiBaseUrl,
    );
    expect(
      finalApprovals
          .firstWhere(
            (approval) =>
                approval.approvalId == queuedBranchSwitchApproval.approvalId,
          )
          .status,
      ApprovalStatus.approved,
    );
    expect(
      finalApprovals
          .firstWhere(
            (approval) => approval.approvalId == queuedPullApproval.approvalId,
          )
          .status,
      ApprovalStatus.rejected,
    );
  });
}

const String _integrationActor = 'integration-test';
const String _integrationPhoneId = 'integration-live-phone';
const String _integrationPhoneName = 'Integration Test Phone';

String _resolveBridgeApiBaseUrl() {
  const configured = String.fromEnvironment('LIVE_BRIDGE_BASE_URL');
  if (configured.isNotEmpty) {
    return configured;
  }

  if (Platform.isAndroid) {
    return 'http://10.0.2.2:3110';
  }

  return 'http://127.0.0.1:3110';
}

Future<_TrustedSession> _createTrustedSession(String bridgeApiBaseUrl) async {
  final pairingSession = await _requestJson(
    _buildUri(bridgeApiBaseUrl, '/pairing/session'),
  );

  final bridgeIdentity = _readRequiredObject(pairingSession, 'bridge_identity');
  final pairing = _readRequiredObject(pairingSession, 'pairing_session');

  final bridgeId = _readRequiredString(bridgeIdentity, 'bridge_id');
  final sessionId = _readRequiredString(pairing, 'session_id');
  final pairingToken = _readRequiredString(pairing, 'pairing_token');

  final finalize = await _requestJson(
    _buildUri(bridgeApiBaseUrl, '/pairing/finalize', {
      'session_id': sessionId,
      'pairing_token': pairingToken,
      'phone_id': _integrationPhoneId,
      'phone_name': _integrationPhoneName,
      'bridge_id': bridgeId,
    }),
  );

  return _TrustedSession(
    phoneId: _integrationPhoneId,
    bridgeId: bridgeId,
    sessionToken: _readRequiredString(finalize, 'session_token'),
  );
}

Future<_GitThreadContext> _selectThreadWithGitContext({
  required String bridgeApiBaseUrl,
  required HttpThreadDetailBridgeApi threadApi,
  required HttpThreadListBridgeApi threadListApi,
}) async {
  final threads = await threadListApi.fetchThreads(
    bridgeApiBaseUrl: bridgeApiBaseUrl,
  );

  expect(
    threads,
    isNotEmpty,
    reason: 'Live bridge did not return any threads from /threads.',
  );

  for (final thread in threads) {
    try {
      final gitStatus = await threadApi.fetchGitStatus(
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        threadId: thread.threadId,
      );

      return _GitThreadContext(
        threadId: thread.threadId,
        branch: gitStatus.repository.branch,
        remote: gitStatus.repository.remote,
      );
    } on ThreadGitBridgeException {
      continue;
    }
  }

  fail(
    'No thread with bridge-backed git context was available to validate approval flows.',
  );
}

Future<ApprovalRecordDto> _expectApprovalRequired(
  Future<MutationResultResponseDto> Function() mutation,
) async {
  try {
    await mutation();
  } on ThreadGitApprovalRequiredException catch (error) {
    return error.approval;
  }

  fail(
    'Expected a 202 approval_required response but mutation executed directly.',
  );
}

Future<Map<String, dynamic>> _requestJson(Uri uri) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final request = await client.postUrl(uri);
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final response = await request.close();
    final body = await utf8.decodeStream(response);
    final decoded = _decodeJsonObject(body);

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return decoded;
    }

    final code = decoded['code'];
    final message = decoded['message'];
    fail(
      'Request to $uri failed with status ${response.statusCode}: '
      'code=${code ?? 'unknown'} message=${message ?? body}',
    );
  } finally {
    client.close();
  }
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
    fail('Expected JSON object response, got: $decoded');
  }

  return decoded;
}

Map<String, dynamic> _readRequiredObject(
  Map<String, dynamic> json,
  String key,
) {
  final value = json[key];
  if (value is! Map<String, dynamic>) {
    fail('Missing required object "$key" in payload: $json');
  }
  return value;
}

String _readRequiredString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    fail('Missing required string "$key" in payload: $json');
  }
  return value.trim();
}

class _TrustedSession {
  const _TrustedSession({
    required this.phoneId,
    required this.bridgeId,
    required this.sessionToken,
  });

  final String phoneId;
  final String bridgeId;
  final String sessionToken;
}

class _GitThreadContext {
  const _GitThreadContext({
    required this.threadId,
    required this.branch,
    required this.remote,
  });

  final String threadId;
  final String branch;
  final String remote;
}
