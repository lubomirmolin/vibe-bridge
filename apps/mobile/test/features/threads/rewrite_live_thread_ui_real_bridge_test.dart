import 'dart:io';

import 'package:codex_mobile_companion/features/approvals/data/approval_bridge_api.dart';
import 'package:codex_mobile_companion/features/settings/data/settings_bridge_api.dart';
import 'package:codex_mobile_companion/features/threads/data/thread_detail_bridge_api.dart';
import 'package:codex_mobile_companion/features/threads/data/thread_list_bridge_api.dart';
import 'package:codex_mobile_companion/features/threads/presentation/thread_detail_page.dart';
import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:codex_mobile_companion/foundation/storage/secure_store.dart';
import 'package:codex_mobile_companion/foundation/storage/secure_store_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'real thread detail shows loading immediately and streams assistant text without a long blank gap',
    (tester) async {
      final previousOverrides = HttpOverrides.current;
      HttpOverrides.global = _PassthroughHttpOverrides();
      addTearDown(() {
        HttpOverrides.global = previousOverrides;
      });

      final bridgeApiBaseUrl = _resolveBridgeApiBaseUrl();
      final listApi = const HttpThreadListBridgeApi();
      final detailApi = const HttpThreadDetailBridgeApi();
      final threads = await listApi
          .fetchThreads(bridgeApiBaseUrl: bridgeApiBaseUrl)
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => throw TestFailure(
              'Timed out loading /threads from $bridgeApiBaseUrl.',
            ),
          );
      final workspace = threads
          .map((thread) => thread.workspace.trim())
          .firstWhere((candidate) => candidate.isNotEmpty, orElse: () => '');
      if (workspace.isEmpty) {
        fail('Live bridge did not expose any thread workspace to open.');
      }
      final createdSnapshot = await detailApi
          .createThread(
            bridgeApiBaseUrl: bridgeApiBaseUrl,
            workspace: workspace,
          )
          .timeout(
            const Duration(seconds: 15),
            onTimeout: () => throw TestFailure(
              'Timed out waiting for POST /threads to return from '
              '$bridgeApiBaseUrl for workspace $workspace.',
            ),
          );
      final threadId = createdSnapshot.thread.threadId.trim();
      expect(threadId, isNotEmpty);
      final token = 'UI_STREAM_TOKEN_${DateTime.now().millisecondsSinceEpoch}';
      final prompt = 'Reply with exactly $token';

      final initialLoadStopwatch = Stopwatch()..start();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appSecureStoreProvider.overrideWithValue(InMemorySecureStore()),
            approvalBridgeApiProvider.overrideWithValue(
              const _FakeApprovalBridgeApi(),
            ),
            settingsBridgeApiProvider.overrideWithValue(
              const _FakeSettingsBridgeApi(),
            ),
          ],
          child: MaterialApp(
            home: ThreadDetailPage(
              bridgeApiBaseUrl: bridgeApiBaseUrl,
              threadId: threadId,
            ),
          ),
        ),
      );

      await _pumpUntilFound(
        tester,
        find.byKey(const Key('thread-detail-title')),
        timeout: const Duration(seconds: 15),
      );
      initialLoadStopwatch.stop();

      final submitFinder = find.byKey(const Key('turn-composer-submit'));
      await _pumpUntilFound(
        tester,
        submitFinder,
        timeout: const Duration(seconds: 5),
      );

      await tester.enterText(
        find.byKey(const Key('turn-composer-input')),
        prompt,
      );
      await tester.pump();

      final turnStopwatch = Stopwatch()..start();
      await tester.tap(submitFinder);
      await tester.pump();

      final loadingFinder = find.byWidgetPredicate((widget) {
        return widget is Text && (widget.data?.startsWith('⠋ ') ?? false);
      });
      await _pumpUntilFound(
        tester,
        loadingFinder,
        timeout: const Duration(seconds: 3),
      );
      final loadingShownMs = turnStopwatch.elapsedMilliseconds;

      final streamedTextFinder = find.textContaining(token.substring(0, 12));
      await _pumpUntilFound(
        tester,
        streamedTextFinder,
        timeout: const Duration(seconds: 15),
      );
      final firstVisibleAssistantMs = turnStopwatch.elapsedMilliseconds;

      await _pumpUntilGone(
        tester,
        loadingFinder,
        timeout: const Duration(seconds: 20),
      );
      final loadingGoneMs = turnStopwatch.elapsedMilliseconds;

      debugPrint(
        'REWRITE_LIVE_THREAD_UI_RESULT '
        'thread_id=$threadId '
        'bridge=$bridgeApiBaseUrl '
        'initial_load_ms=${initialLoadStopwatch.elapsedMilliseconds} '
        'loading_shown_ms=$loadingShownMs '
        'assistant_visible_ms=$firstVisibleAssistantMs '
        'loading_gone_ms=$loadingGoneMs '
        'token=$token',
      );

      expect(initialLoadStopwatch.elapsedMilliseconds, lessThan(5000));
      expect(loadingShownMs, lessThan(1500));
      expect(firstVisibleAssistantMs, lessThan(5000));
      expect(loadingGoneMs, greaterThanOrEqualTo(firstVisibleAssistantMs));
      expect(find.textContaining(token), findsOneWidget);
    },
    skip: !_runLiveThreadUiTest(),
  );
}

class _PassthroughHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context);
  }
}

String _resolveBridgeApiBaseUrl() {
  const configured = String.fromEnvironment('LIVE_THREAD_UI_BRIDGE_BASE_URL');
  if (configured.isNotEmpty) {
    return configured;
  }

  if (Platform.isAndroid) {
    return 'http://10.0.2.2:3216';
  }

  return 'http://127.0.0.1:3216';
}

bool _runLiveThreadUiTest() {
  return const bool.fromEnvironment('RUN_LIVE_THREAD_UI_TEST');
}

class _FakeApprovalBridgeApi implements ApprovalBridgeApi {
  const _FakeApprovalBridgeApi();

  @override
  Future<AccessMode> fetchAccessMode({required String bridgeApiBaseUrl}) async {
    return AccessMode.controlWithApprovals;
  }

  @override
  Future<List<ApprovalRecordDto>> fetchApprovals({
    required String bridgeApiBaseUrl,
  }) async {
    return const <ApprovalRecordDto>[];
  }

  @override
  Future<ApprovalResolutionResponseDto> approve({
    required String bridgeApiBaseUrl,
    required String approvalId,
  }) {
    throw UnimplementedError('Approval resolution is not used in this test.');
  }

  @override
  Future<ApprovalResolutionResponseDto> reject({
    required String bridgeApiBaseUrl,
    required String approvalId,
  }) {
    throw UnimplementedError('Approval resolution is not used in this test.');
  }
}

class _FakeSettingsBridgeApi implements SettingsBridgeApi {
  const _FakeSettingsBridgeApi();

  @override
  Future<AccessMode> fetchAccessMode({required String bridgeApiBaseUrl}) async {
    return AccessMode.controlWithApprovals;
  }

  @override
  Future<List<SecurityEventRecordDto>> fetchSecurityEvents({
    required String bridgeApiBaseUrl,
  }) async {
    return const <SecurityEventRecordDto>[];
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
    return accessMode;
  }
}

Future<void> _pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final endTime = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(endTime)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isNotEmpty) {
      return;
    }
  }

  throw TestFailure('Timed out waiting for $finder.');
}

Future<void> _pumpUntilGone(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final endTime = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(endTime)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isEmpty) {
      return;
    }
  }

  throw TestFailure('Timed out waiting for $finder to disappear.');
}
