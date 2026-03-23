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
import 'package:device_info_plus/device_info_plus.dart';
import 'package:codex_mobile_companion/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'live branch-switch approval can be approved from the real approvals UI',
    (tester) async {
      await _requireAndroidEmulator();
      final harness = await _bootstrapLiveTestHarness();

      await harness.settingsApi.setAccessMode(
        bridgeApiBaseUrl: harness.bridgeApiBaseUrl,
        accessMode: AccessMode.controlWithApprovals,
        phoneId: harness.trustedSession.phoneId,
        bridgeId: harness.trustedSession.bridgeId,
        sessionToken: harness.trustedSession.sessionToken,
        actor: _integrationActor,
      );

      final queuedApproval = await _expectApprovalRequired(
        () => harness.threadApi.switchBranch(
          bridgeApiBaseUrl: harness.bridgeApiBaseUrl,
          threadId: harness.gitThreadContext.threadId,
          branch: harness.gitThreadContext.branch,
        ),
      );

      await harness.settingsApi.setAccessMode(
        bridgeApiBaseUrl: harness.bridgeApiBaseUrl,
        accessMode: AccessMode.fullControl,
        phoneId: harness.trustedSession.phoneId,
        bridgeId: harness.trustedSession.bridgeId,
        sessionToken: harness.trustedSession.sessionToken,
        actor: _integrationActor,
      );

      await _launchTrustedBridgeApp(
        tester,
        bridgeApiBaseUrl: harness.bridgeApiBaseUrl,
        trustedSession: harness.trustedSession,
      );
      await _openApprovalDetail(tester, approvalId: queuedApproval.approvalId);

      await _pumpUntilFound(
        tester,
        find.byKey(const Key('approval-detail-id')),
      );
      expect(find.textContaining(queuedApproval.approvalId), findsOneWidget);
      expect(find.text('Branch switch'), findsOneWidget);

      final approveButtonFinder = find.byKey(
        const Key('approve-approval-button'),
      );
      await _scrollUntilVisible(tester, approveButtonFinder);
      await tester.tap(approveButtonFinder);
      await _pumpForTransition(tester);

      await _waitForApprovalStatus(
        approvalApi: harness.approvalApi,
        bridgeApiBaseUrl: harness.bridgeApiBaseUrl,
        approvalId: queuedApproval.approvalId,
        expectedStatus: ApprovalStatus.approved,
      );

      final finalApprovals = await harness.approvalApi.fetchApprovals(
        bridgeApiBaseUrl: harness.bridgeApiBaseUrl,
      );
      expect(
        finalApprovals
            .firstWhere(
              (approval) => approval.approvalId == queuedApproval.approvalId,
            )
            .status,
        ApprovalStatus.approved,
      );
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  testWidgets(
    'live pull approval can be rejected from the real approvals UI',
    (tester) async {
      await _requireAndroidEmulator();
      final harness = await _bootstrapLiveTestHarness();

      await harness.settingsApi.setAccessMode(
        bridgeApiBaseUrl: harness.bridgeApiBaseUrl,
        accessMode: AccessMode.controlWithApprovals,
        phoneId: harness.trustedSession.phoneId,
        bridgeId: harness.trustedSession.bridgeId,
        sessionToken: harness.trustedSession.sessionToken,
        actor: _integrationActor,
      );

      final queuedApproval = await _expectApprovalRequired(
        () => harness.threadApi.pullRepository(
          bridgeApiBaseUrl: harness.bridgeApiBaseUrl,
          threadId: harness.gitThreadContext.threadId,
          remote: harness.gitThreadContext.remote,
        ),
      );

      await harness.settingsApi.setAccessMode(
        bridgeApiBaseUrl: harness.bridgeApiBaseUrl,
        accessMode: AccessMode.fullControl,
        phoneId: harness.trustedSession.phoneId,
        bridgeId: harness.trustedSession.bridgeId,
        sessionToken: harness.trustedSession.sessionToken,
        actor: _integrationActor,
      );

      await _launchTrustedBridgeApp(
        tester,
        bridgeApiBaseUrl: harness.bridgeApiBaseUrl,
        trustedSession: harness.trustedSession,
      );
      await _openApprovalDetail(tester, approvalId: queuedApproval.approvalId);

      await _pumpUntilFound(
        tester,
        find.byKey(const Key('approval-detail-id')),
      );
      expect(find.textContaining(queuedApproval.approvalId), findsOneWidget);
      expect(find.text('Git pull'), findsOneWidget);

      final rejectButtonFinder = find.byKey(
        const Key('reject-approval-button'),
      );
      await _scrollUntilVisible(tester, rejectButtonFinder);
      await tester.tap(rejectButtonFinder);
      await _pumpForTransition(tester);

      await _waitForApprovalStatus(
        approvalApi: harness.approvalApi,
        bridgeApiBaseUrl: harness.bridgeApiBaseUrl,
        approvalId: queuedApproval.approvalId,
        expectedStatus: ApprovalStatus.rejected,
      );

      final finalApprovals = await harness.approvalApi.fetchApprovals(
        bridgeApiBaseUrl: harness.bridgeApiBaseUrl,
      );
      expect(
        finalApprovals
            .firstWhere(
              (approval) => approval.approvalId == queuedApproval.approvalId,
            )
            .status,
        ApprovalStatus.rejected,
      );
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

const String _integrationActor = 'integration-test';
const String _integrationPhoneId = 'integration-live-phone';
const String _integrationPhoneName = 'Integration Test Phone';

Future<_LiveTestHarness> _bootstrapLiveTestHarness() async {
  final bridgeApiBaseUrl = _resolveBridgeApiBaseUrl();
  final threadApi = const HttpThreadDetailBridgeApi();
  final threadListApi = const HttpThreadListBridgeApi();
  final approvalApi = const HttpApprovalBridgeApi();
  final settingsApi = const HttpSettingsBridgeApi();

  await _resetTrustedSession(bridgeApiBaseUrl);
  final trustedSession = await _createTrustedSession(bridgeApiBaseUrl);
  final gitThreadContext = await _selectThreadWithGitContext(
    bridgeApiBaseUrl: bridgeApiBaseUrl,
    threadApi: threadApi,
    threadListApi: threadListApi,
  );

  return _LiveTestHarness(
    bridgeApiBaseUrl: bridgeApiBaseUrl,
    threadApi: threadApi,
    approvalApi: approvalApi,
    settingsApi: settingsApi,
    trustedSession: trustedSession,
    gitThreadContext: gitThreadContext,
  );
}

Future<void> _launchTrustedBridgeApp(
  WidgetTester tester, {
  required String bridgeApiBaseUrl,
  required _TrustedSession trustedSession,
}) async {
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
  await _pumpForTransition(tester);
}

Future<void> _openApprovalDetail(
  WidgetTester tester, {
  required String approvalId,
}) async {
  final approvalsQueueButton = find.byKey(const Key('open-approvals-queue'));
  await _pumpUntilFound(tester, approvalsQueueButton);
  await tester.tap(approvalsQueueButton);
  await _pumpForTransition(tester);

  final approvalCard = find.byKey(Key('approval-card-$approvalId'));
  await _scrollUntilVisible(tester, approvalCard);
  await tester.tap(approvalCard);
  await _pumpForTransition(tester);
}

String _resolveBridgeApiBaseUrl() {
  const configured = String.fromEnvironment('LIVE_BRIDGE_BASE_URL');
  if (configured.isNotEmpty) {
    return configured;
  }

  return 'http://10.0.2.2:3110';
}

Future<void> _requireAndroidEmulator() async {
  if (!Platform.isAndroid) {
    fail(
      'This live bridge integration test only supports Android emulators. '
      'Run it with `flutter test integration_test/live_bridge_approval_flow_test.dart -d <android-emulator-id>`.',
    );
  }

  final androidInfo = await DeviceInfoPlugin().androidInfo;
  if (androidInfo.isPhysicalDevice) {
    fail(
      'This live bridge integration test only supports Android emulators. '
      'Physical Android devices cannot reach the default emulator bridge host '
      '`http://10.0.2.2:3110`.',
    );
  }
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

Future<void> _resetTrustedSession(String bridgeApiBaseUrl) async {
  await _requestJson(_buildUri(bridgeApiBaseUrl, '/pairing/trust/revoke'));
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

Future<void> _pumpForTransition(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
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
    await _pumpForTransition(tester);
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
      await _pumpForTransition(tester);
      return true;
    }

    await tester.drag(scrollable, const Offset(0, -300));
    await _pumpForTransition(tester);
  }

  for (var attempt = 0; attempt < 25; attempt += 1) {
    if (finder.evaluate().isNotEmpty) {
      await tester.ensureVisible(finder);
      await _pumpForTransition(tester);
      return true;
    }

    await tester.drag(scrollable, const Offset(0, 300));
    await _pumpForTransition(tester);
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

class _LiveTestHarness {
  const _LiveTestHarness({
    required this.bridgeApiBaseUrl,
    required this.threadApi,
    required this.approvalApi,
    required this.settingsApi,
    required this.trustedSession,
    required this.gitThreadContext,
  });

  final String bridgeApiBaseUrl;
  final HttpThreadDetailBridgeApi threadApi;
  final HttpApprovalBridgeApi approvalApi;
  final HttpSettingsBridgeApi settingsApi;
  final _TrustedSession trustedSession;
  final _GitThreadContext gitThreadContext;
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
