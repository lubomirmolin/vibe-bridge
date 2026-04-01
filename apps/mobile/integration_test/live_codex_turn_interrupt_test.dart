import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vibe_bridge/features/threads/application/thread_detail_controller.dart';
import 'package:vibe_bridge/features/threads/data/thread_detail_bridge_api.dart';
import 'package:vibe_bridge/features/threads/presentation/thread_detail_page.dart';
import 'package:vibe_bridge/foundation/contracts/bridge_contracts.dart';
import 'package:vibe_bridge/foundation/storage/secure_store.dart';
import 'package:vibe_bridge/foundation/storage/secure_store_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'real bridge Codex thread interrupt cancels an active turn from the mobile UI',
    (tester) async {
      final bridgeApiBaseUrl = _resolveBridgeApiBaseUrl();
      await _requireAndroidLoopbackDevice(bridgeApiBaseUrl);

      final workspacePath = _resolveWorkspacePath();
      final threadApi = HttpThreadDetailBridgeApi();
      final createdThread = await threadApi.createThread(
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        workspace: workspacePath,
        provider: ProviderKind.codex,
      );
      final createdThreadId = createdThread.thread.threadId;
      await threadApi.startTurn(
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        threadId: createdThreadId,
        prompt: _buildInterruptProbePrompt(),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appSecureStoreProvider.overrideWithValue(InMemorySecureStore()),
          ],
          child: MaterialApp(
            home: ThreadDetailPage(
              bridgeApiBaseUrl: bridgeApiBaseUrl,
              threadId: createdThreadId,
            ),
          ),
        ),
      );

      await _pumpUntilFound(
        tester,
        find.byKey(const Key('thread-detail-title')),
        timeout: const Duration(seconds: 20),
      );

      await _waitForThreadControllerToSettle(
        tester,
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        threadId: createdThreadId,
      );
      await _waitForRunningInterruptState(
        tester,
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        threadId: createdThreadId,
      );

      await tester.tap(find.byKey(const Key('turn-interrupt-button')));
      await tester.pump();
      await _assertInterruptSettlesThread(
        tester,
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        threadId: createdThreadId,
      );

      debugPrint(
        'LIVE_CODEX_INTERRUPT_RESULT '
        'thread_id=$createdThreadId '
        'workspace=$workspacePath',
      );
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );
}

String _buildInterruptProbePrompt() {
  return 'Review this repository for open source README quality. '
      'Inspect the README and several related project files before answering, '
      'and explain concrete improvements with evidence from the codebase.';
}

String _resolveBridgeApiBaseUrl() {
  const configured = String.fromEnvironment(
    'LIVE_CODEX_THREAD_CREATION_BRIDGE_BASE_URL',
  );
  if (configured.isNotEmpty) {
    return configured;
  }

  return 'http://10.0.2.2:3110';
}

String _resolveWorkspacePath() {
  const configured = String.fromEnvironment(
    'LIVE_CODEX_THREAD_CREATION_WORKSPACE',
  );
  if (configured.isNotEmpty) {
    return configured;
  }

  return '/Users/lubomirmolin/PhpstormProjects/codex-mobile-companion';
}

Future<void> _requireAndroidLoopbackDevice(String bridgeApiBaseUrl) async {
  if (!Platform.isAndroid) {
    fail(
      'This live bridge integration test only supports Android devices. '
      'Run it with `flutter drive --driver=test_driver/integration_test.dart --target=integration_test/live_codex_turn_interrupt_test.dart -d <android-device-id>`.',
    );
  }

  final androidInfo = await DeviceInfoPlugin().androidInfo;
  if (androidInfo.isPhysicalDevice &&
      !_usesLoopbackBridgeUrl(bridgeApiBaseUrl)) {
    fail(
      'This live bridge integration test only supports physical Android devices '
      'when the bridge URL is loopback-backed via `adb reverse`, for example '
      '`http://127.0.0.1:3310`.',
    );
  }
}

bool _usesLoopbackBridgeUrl(String bridgeApiBaseUrl) {
  final uri = Uri.tryParse(bridgeApiBaseUrl);
  final host = uri?.host.trim().toLowerCase() ?? '';
  return host == '127.0.0.1' || host == 'localhost';
}

Future<void> _waitForThreadControllerToSettle(
  WidgetTester tester, {
  required String bridgeApiBaseUrl,
  required String threadId,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final args = ThreadDetailControllerArgs(
    bridgeApiBaseUrl: bridgeApiBaseUrl,
    threadId: threadId,
  );
  final container = ProviderScope.containerOf(
    tester.element(find.byType(MaterialApp)),
  );
  final deadline = DateTime.now().add(timeout);

  while (DateTime.now().isBefore(deadline)) {
    final state = container.read(threadDetailControllerProvider(args));
    if (!state.isLoading &&
        state.hasThread &&
        !state.isComposerMutationInFlight) {
      return;
    }
    await tester.pump(const Duration(milliseconds: 200));
  }

  final state = container.read(threadDetailControllerProvider(args));
  fail(
    'Timed out waiting for thread detail controller to settle for $threadId. '
    'isLoading=${state.isLoading} '
    'hasThread=${state.hasThread} '
    'isComposerMutationInFlight=${state.isComposerMutationInFlight} '
    'status=${state.thread?.status.wireValue}',
  );
}

Future<void> _waitForRunningInterruptState(
  WidgetTester tester, {
  required String bridgeApiBaseUrl,
  required String threadId,
  Duration timeout = const Duration(seconds: 40),
}) async {
  final args = ThreadDetailControllerArgs(
    bridgeApiBaseUrl: bridgeApiBaseUrl,
    threadId: threadId,
  );
  final container = ProviderScope.containerOf(
    tester.element(find.byType(MaterialApp)),
  );
  final deadline = DateTime.now().add(timeout);
  var sawRunningSnapshot = false;

  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 150));
    final state = container.read(threadDetailControllerProvider(args));
    final snapshot = await _fetchThreadSnapshotJson(
      bridgeApiBaseUrl: bridgeApiBaseUrl,
      threadId: threadId,
    );
    final rawStatus =
        ((snapshot['thread'] as Map<String, dynamic>?)?['status'] as String?)
            ?.trim() ??
        '';
    if (rawStatus == ThreadStatus.running.wireValue) {
      sawRunningSnapshot = true;
    }

    final hasInterruptButton = find
        .byKey(const Key('turn-interrupt-button'))
        .evaluate()
        .isNotEmpty;

    if (state.thread?.status == ThreadStatus.running &&
        sawRunningSnapshot &&
        hasInterruptButton) {
      return;
    }
  }

  final snapshot = await _fetchThreadSnapshotJson(
    bridgeApiBaseUrl: bridgeApiBaseUrl,
    threadId: threadId,
  );
  fail(
    'Timed out waiting for running interrupt state on $threadId. '
    'snapshot_status=${(snapshot['thread'] as Map<String, dynamic>?)?['status']} '
    'snapshot_entries=${(snapshot['entries'] as List<dynamic>? ?? const []).length}',
  );
}

Future<void> _assertInterruptSettlesThread(
  WidgetTester tester, {
  required String bridgeApiBaseUrl,
  required String threadId,
  Duration timeout = const Duration(seconds: 25),
}) async {
  final args = ThreadDetailControllerArgs(
    bridgeApiBaseUrl: bridgeApiBaseUrl,
    threadId: threadId,
  );
  final container = ProviderScope.containerOf(
    tester.element(find.byType(MaterialApp)),
  );
  final deadline = DateTime.now().add(timeout);
  final statusLog = <String>[];

  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 150));
    final state = container.read(threadDetailControllerProvider(args));
    final snapshot = await _fetchThreadSnapshotJson(
      bridgeApiBaseUrl: bridgeApiBaseUrl,
      threadId: threadId,
    );
    final thread = snapshot['thread'];
    if (thread is! Map<String, dynamic>) {
      fail('Expected thread payload for $threadId, got $thread');
    }

    final rawStatus = (thread['status'] as String?)?.trim() ?? '';
    statusLog.add(rawStatus);

    if (state.turnControlErrorMessage != null) {
      fail(
        'Interrupt surfaced a mobile error for $threadId: '
        '${state.turnControlErrorMessage}',
      );
    }

    if (rawStatus == ThreadStatus.interrupted.wireValue &&
        state.thread?.status == ThreadStatus.interrupted &&
        !state.isInterruptMutationInFlight &&
        find.byKey(const Key('turn-interrupt-button')).evaluate().isEmpty) {
      return;
    }

    if (rawStatus == ThreadStatus.completed.wireValue ||
        rawStatus == ThreadStatus.failed.wireValue) {
      fail(
        'Thread $threadId reached terminal status $rawStatus instead of '
        'interrupting. Observed statuses: ${statusLog.join(' -> ')}',
      );
    }
  }

  final state = container.read(threadDetailControllerProvider(args));
  fail(
    'Timed out waiting for interrupt to settle thread $threadId. '
    'controller_status=${state.thread?.status.wireValue} '
    'interrupt_in_flight=${state.isInterruptMutationInFlight} '
    'error=${state.turnControlErrorMessage} '
    'observed_statuses=${statusLog.join(' -> ')}',
  );
}

Future<Map<String, dynamic>> _fetchThreadSnapshotJson({
  required String bridgeApiBaseUrl,
  required String threadId,
}) async {
  final decoded = await _getJson(
    _buildBridgeUri(bridgeApiBaseUrl, '/threads/$threadId/snapshot'),
  );
  if (decoded is! Map<String, dynamic>) {
    fail('Snapshot response for $threadId was not a JSON object: $decoded');
  }
  return decoded;
}

Future<Object?> _getJson(Uri uri) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final request = await client.getUrl(uri);
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final response = await request.close();
    final body = await utf8.decoder.bind(response).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      fail('GET $uri failed with ${response.statusCode}: $body');
    }
    return jsonDecode(body);
  } finally {
    client.close(force: true);
  }
}

Uri _buildBridgeUri(String baseUrl, String path) {
  final baseUri = Uri.parse(baseUrl);
  final normalizedBasePath = baseUri.path.endsWith('/')
      ? baseUri.path.substring(0, baseUri.path.length - 1)
      : baseUri.path;
  final normalizedPath = path.startsWith('/') ? path : '/$path';
  return baseUri.replace(
    path:
        '${normalizedBasePath.isEmpty ? '' : normalizedBasePath}$normalizedPath',
  );
}

Future<void> _pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 10),
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
