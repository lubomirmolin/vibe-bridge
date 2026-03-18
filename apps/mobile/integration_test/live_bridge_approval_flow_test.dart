import 'dart:convert';
import 'dart:io';

import 'package:codex_mobile_companion/features/approvals/data/approval_bridge_api.dart';
import 'package:codex_mobile_companion/features/pairing/domain/pairing_qr_payload.dart';
import 'package:codex_mobile_companion/features/settings/data/settings_bridge_api.dart';
import 'package:codex_mobile_companion/features/threads/data/thread_detail_bridge_api.dart';
import 'package:codex_mobile_companion/features/threads/data/thread_list_bridge_api.dart';
import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:codex_mobile_companion/foundation/storage/secure_store.dart';
import 'package:codex_mobile_companion/foundation/storage/secure_store_provider.dart';
import 'package:codex_mobile_companion/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'live bridge approval queue/detail/approve/reject flow uses real mobile UI surfaces',
    (tester) async {
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

      final queuedPullApproval = await _expectApprovalRequired(
        () => threadApi.pullRepository(
          bridgeApiBaseUrl: bridgeApiBaseUrl,
          threadId: gitThreadContext.threadId,
          remote: gitThreadContext.remote,
        ),
      );

      await settingsApi.setAccessMode(
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        accessMode: AccessMode.fullControl,
        phoneId: trustedSession.phoneId,
        bridgeId: trustedSession.bridgeId,
        sessionToken: trustedSession.sessionToken,
        actor: _integrationActor,
      );

      final secureStore = InMemorySecureStore();
      await _seedTrustedBridge(
        secureStore: secureStore,
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        trustedSession: trustedSession,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [appSecureStoreProvider.overrideWithValue(secureStore)],
          child: const CodexMobileApp(),
        ),
      );
      await tester.pumpAndSettle();

      await _pumpUntilFound(tester, find.text('Threads'));
      await _pumpUntilFound(
        tester,
        find.byKey(const Key('open-approvals-queue')),
      );

      await tester.tap(find.byKey(const Key('open-approvals-queue')));
      await tester.pumpAndSettle();

      final branchSwitchCard = find.byKey(
        Key('approval-card-${queuedBranchSwitchApproval.approvalId}'),
      );
      await _pumpUntilFound(tester, branchSwitchCard);
      await tester.tap(branchSwitchCard);
      await tester.pumpAndSettle();

      await _pumpUntilFound(
        tester,
        find.byKey(const Key('approval-detail-id')),
      );
      expect(
        find.textContaining(queuedBranchSwitchApproval.approvalId),
        findsOneWidget,
      );
      expect(find.text('Branch switch'), findsOneWidget);

      final approveButtonFinder = find.byKey(
        const Key('approve-approval-button'),
      );
      await _scrollUntilVisible(tester, approveButtonFinder);
      await tester.tap(approveButtonFinder);
      await tester.pumpAndSettle();

      await _waitForApprovalStatus(
        approvalApi: approvalApi,
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        approvalId: queuedBranchSwitchApproval.approvalId,
        expectedStatus: ApprovalStatus.approved,
      );

      await tester.pageBack();
      await tester.pumpAndSettle();

      await _refreshApprovalsQueue(tester);
      await _expectQueueCardStatus(
        tester,
        approvalId: queuedBranchSwitchApproval.approvalId,
        expectedStatusLabel: 'Approved',
      );

      final pullCard = find.byKey(
        Key('approval-card-${queuedPullApproval.approvalId}'),
      );
      await _scrollUntilVisible(tester, pullCard);
      await tester.tap(pullCard);
      await tester.pumpAndSettle();

      await _pumpUntilFound(
        tester,
        find.byKey(const Key('approval-detail-id')),
      );
      expect(
        find.textContaining(queuedPullApproval.approvalId),
        findsOneWidget,
      );
      expect(find.text('Git pull'), findsOneWidget);

      final rejectButtonFinder = find.byKey(
        const Key('reject-approval-button'),
      );
      await _scrollUntilVisible(tester, rejectButtonFinder);
      await tester.tap(rejectButtonFinder);
      await tester.pumpAndSettle();

      await _waitForApprovalStatus(
        approvalApi: approvalApi,
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        approvalId: queuedPullApproval.approvalId,
        expectedStatus: ApprovalStatus.rejected,
      );

      await tester.pageBack();
      await tester.pumpAndSettle();
      await _refreshApprovalsQueue(tester);
      await _expectQueueCardStatus(
        tester,
        approvalId: queuedPullApproval.approvalId,
        expectedStatusLabel: 'Rejected',
      );

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
              (approval) =>
                  approval.approvalId == queuedPullApproval.approvalId,
            )
            .status,
        ApprovalStatus.rejected,
      );
    },
  );
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
  final bridgeName = _readRequiredString(bridgeIdentity, 'display_name');
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
    bridgeName: bridgeName,
    sessionId: sessionId,
    sessionToken: _readRequiredString(finalize, 'session_token'),
  );
}

Future<void> _seedTrustedBridge({
  required InMemorySecureStore secureStore,
  required String bridgeApiBaseUrl,
  required _TrustedSession trustedSession,
}) async {
  await secureStore.writeSecret(
    SecureValueKey.pairingPrivateKey,
    trustedSession.phoneId,
  );
  await secureStore.writeSecret(
    SecureValueKey.sessionToken,
    trustedSession.sessionToken,
  );

  final trustedBridge = TrustedBridgeIdentity(
    bridgeId: trustedSession.bridgeId,
    bridgeName: trustedSession.bridgeName,
    bridgeApiBaseUrl: bridgeApiBaseUrl,
    sessionId: trustedSession.sessionId,
    pairedAtEpochSeconds: DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000,
  );

  await secureStore.writeSecret(
    SecureValueKey.trustedBridgeIdentity,
    jsonEncode(trustedBridge.toJson()),
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

      final branch = gitStatus.repository.branch.trim();
      final remote = gitStatus.repository.remote.trim();
      if (branch.isEmpty || remote.isEmpty) {
        continue;
      }

      return _GitThreadContext(
        threadId: thread.threadId,
        branch: branch,
        remote: remote,
      );
    } on ThreadGitBridgeException {
      continue;
    }
  }

  fail(
    'No thread with bridge-backed git context was available to validate approval flows.',
  );
}

Future<void> _refreshApprovalsQueue(WidgetTester tester) async {
  final refreshFinder = find.byTooltip('Refresh approvals');
  await _pumpUntilFound(tester, refreshFinder);
  await tester.tap(refreshFinder.first);
  await tester.pumpAndSettle();
}

Future<void> _expectQueueCardStatus(
  WidgetTester tester, {
  required String approvalId,
  required String expectedStatusLabel,
}) async {
  final cardFinder = find.byKey(Key('approval-card-$approvalId'));

  final foundCard = await _tryScrollUntilVisible(tester, cardFinder);
  if (!foundCard) {
    // Some live bridge setups return only pending approvals in queue payloads.
    // In that case, a resolved approval legitimately disappears from the queue.
    expect(cardFinder, findsNothing);
    return;
  }

  expect(cardFinder, findsOneWidget);
  expect(
    find.descendant(of: cardFinder, matching: find.text(expectedStatusLabel)),
    findsOneWidget,
  );
}

Future<void> _waitForApprovalStatus({
  required HttpApprovalBridgeApi approvalApi,
  required String bridgeApiBaseUrl,
  required String approvalId,
  required ApprovalStatus expectedStatus,
  Duration timeout = const Duration(seconds: 12),
}) async {
  final deadline = DateTime.now().add(timeout);
  ApprovalStatus? latestStatus;

  while (DateTime.now().isBefore(deadline)) {
    final approvals = await approvalApi.fetchApprovals(
      bridgeApiBaseUrl: bridgeApiBaseUrl,
    );

    for (final approval in approvals) {
      if (approval.approvalId == approvalId) {
        latestStatus = approval.status;
        if (latestStatus == expectedStatus) {
          return;
        }
      }
    }

    await Future<void>.delayed(const Duration(milliseconds: 250));
  }

  fail(
    'Timed out waiting for approval $approvalId to reach '
    '$expectedStatus (latest: $latestStatus).',
  );
}

Future<void> _pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 12),
}) async {
  final deadline = DateTime.now().add(timeout);

  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isNotEmpty) {
      return;
    }
  }

  fail('Timed out waiting for finder: $finder');
}

Future<void> _scrollUntilVisible(WidgetTester tester, Finder finder) async {
  final wasFound = await _tryScrollUntilVisible(tester, finder);
  if (wasFound) {
    return;
  }

  fail('Timed out scrolling to finder: $finder');
}

Future<bool> _tryScrollUntilVisible(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isNotEmpty) {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    return true;
  }

  final scrollableCandidates = find.byType(Scrollable);
  if (scrollableCandidates.evaluate().isEmpty) {
    return false;
  }

  final scrollable = find.byType(Scrollable).first;

  for (var attempt = 0; attempt < 25; attempt += 1) {
    if (finder.evaluate().isNotEmpty) {
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
      return true;
    }

    await tester.drag(scrollable, const Offset(0, -300));
    await tester.pumpAndSettle();
  }

  for (var attempt = 0; attempt < 25; attempt += 1) {
    if (finder.evaluate().isNotEmpty) {
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
      return true;
    }

    await tester.drag(scrollable, const Offset(0, 300));
    await tester.pumpAndSettle();
  }

  return finder.evaluate().isNotEmpty;
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
    required this.bridgeName,
    required this.sessionId,
    required this.sessionToken,
  });

  final String phoneId;
  final String bridgeId;
  final String bridgeName;
  final String sessionId;
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
