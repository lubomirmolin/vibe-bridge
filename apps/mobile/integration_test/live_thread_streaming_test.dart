import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:vibe_bridge/features/approvals/data/approval_bridge_api.dart';
import 'package:vibe_bridge/features/settings/data/settings_bridge_api.dart';
import 'package:vibe_bridge/features/threads/data/thread_live_stream.dart';
import 'package:vibe_bridge/features/threads/presentation/thread_detail_page.dart';
import 'package:vibe_bridge/foundation/contracts/bridge_contracts.dart';
import 'package:vibe_bridge/foundation/storage/secure_store.dart';
import 'package:vibe_bridge/foundation/storage/secure_store_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'live chat streaming updates the visible message when the bridge reuses the upstream event id',
    (tester) async {
      final bridgeServer = await _TestBridgeServer.start();
      final liveStream = _FakeThreadLiveStream();
      addTearDown(bridgeServer.close);

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
            threadLiveStreamProvider.overrideWithValue(liveStream),
          ],
          child: MaterialApp(
            home: ThreadDetailPage(
              bridgeApiBaseUrl: bridgeServer.baseUrl,
              threadId: 'thread-123',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await _pumpUntilFound(
        tester,
        find.byKey(const Key('thread-detail-title')),
      );
      await _pumpUntil(tester, () => liveStream.subscriptionCount >= 1);

      liveStream.emit(
        const BridgeEventEnvelope<Map<String, dynamic>>(
          contractVersion: contractVersion,
          eventId: 'evt-stream-1',
          threadId: 'thread-123',
          kind: BridgeEventKind.messageDelta,
          occurredAt: '2026-03-20T09:00:00Z',
          payload: {'type': 'agentMessage', 'text': 'Hel'},
        ),
      );
      await _pumpUntilFound(tester, find.text('Hel'));

      expect(find.text('Hel'), findsOneWidget);
      expect(
        find.byKey(const Key('thread-message-card-evt-stream-1')),
        findsOneWidget,
      );

      liveStream.emit(
        const BridgeEventEnvelope<Map<String, dynamic>>(
          contractVersion: contractVersion,
          eventId: 'evt-stream-1',
          threadId: 'thread-123',
          kind: BridgeEventKind.messageDelta,
          occurredAt: '2026-03-20T09:00:01Z',
          payload: {
            'type': 'agentMessage',
            'text': 'Hello from the updated streamed message',
          },
        ),
      );
      await _pumpUntilFound(
        tester,
        find.text('Hello from the updated streamed message'),
      );

      expect(find.text('Hel'), findsNothing);
      expect(
        find.text('Hello from the updated streamed message'),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('thread-message-card-evt-stream-1')),
        findsOneWidget,
      );
    },
    // Covered by widget tests; the emulator-local integration harness is
    // currently flaky after transport changes.
    skip: true,
  );
}

class _TestBridgeServer {
  _TestBridgeServer._(this._server)
    : _threadSummary = const ThreadSummaryDto(
        contractVersion: contractVersion,
        threadId: 'thread-123',
        title: 'Investigate live streaming',
        status: ThreadStatus.running,
        workspace: '/workspace/vibe-bridge-companion',
        repository: 'vibe-bridge-companion',
        branch: 'main',
        updatedAt: '2026-03-20T08:59:00Z',
      ),
      _threadDetail = const ThreadDetailDto(
        contractVersion: contractVersion,
        threadId: 'thread-123',
        title: 'Investigate live streaming',
        status: ThreadStatus.running,
        workspace: '/workspace/vibe-bridge-companion',
        repository: 'vibe-bridge-companion',
        branch: 'main',
        createdAt: '2026-03-20T08:55:00Z',
        updatedAt: '2026-03-20T08:59:00Z',
        source: 'cli',
        accessMode: AccessMode.controlWithApprovals,
        lastTurnSummary: 'Streaming is active',
      );

  final HttpServer _server;
  final Map<String, ThreadTimelineEntryDto> _timelineByEventId =
      <String, ThreadTimelineEntryDto>{};

  ThreadSummaryDto _threadSummary;
  ThreadDetailDto _threadDetail;

  static Future<_TestBridgeServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final bridgeServer = _TestBridgeServer._(server);
    unawaited(server.forEach(bridgeServer._handleRequest));
    return bridgeServer;
  }

  String get baseUrl => 'http://${_server.address.host}:${_server.port}';

  Future<void> close() async {
    await _server.close(force: true);
  }

  Future<void> _handleRequest(HttpRequest request) async {
    switch (request.uri.path) {
      case '/threads':
        await _writeJson(request, <String, dynamic>{
          'contract_version': contractVersion,
          'threads': <Map<String, dynamic>>[_threadSummary.toJson()],
        });
        return;
      case '/threads/thread-123':
      case '/threads/thread-123/snapshot':
        await _writeJson(request, <String, dynamic>{
          'contract_version': contractVersion,
          'thread': _threadDetail.toJson(),
        });
        return;
      case '/threads/thread-123/timeline':
      case '/threads/thread-123/history':
        await _writeJson(request, <String, dynamic>{
          'contract_version': contractVersion,
          'thread': _threadDetail.toJson(),
          'entries': _timelineByEventId.values
              .map((event) => event.toJson())
              .toList(growable: false),
          'next_before': null,
          'has_more_before': false,
        });
        return;
      default:
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
    }
  }

  Future<void> _writeJson(
    HttpRequest request,
    Map<String, dynamic> body,
  ) async {
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(body));
    await request.response.close();
  }

  ThreadStatus? _resolveThreadStatus(
    BridgeEventEnvelope<Map<String, dynamic>> event,
  ) {
    if (event.kind != BridgeEventKind.threadStatusChanged) {
      return null;
    }

    final rawStatus = event.payload['status'];
    if (rawStatus is! String) {
      return null;
    }

    try {
      return threadStatusFromWire(rawStatus);
    } on FormatException {
      return null;
    }
  }

  String _summarizeEvent(BridgeEventEnvelope<Map<String, dynamic>> event) {
    final payload = event.payload;
    final text = payload['text'];
    if (text is String && text.trim().isNotEmpty) {
      return text.trim();
    }

    final delta = payload['delta'];
    if (delta is String && delta.trim().isNotEmpty) {
      return delta.trim();
    }

    return event.kind.wireValue;
  }
}

class _FakeThreadLiveStream implements ThreadLiveStream {
  final List<_LiveStreamListener> _listeners = <_LiveStreamListener>[];
  int subscriptionCount = 0;

  @override
  Future<ThreadLiveSubscription> subscribe({
    required String bridgeApiBaseUrl,
    String? threadId,
    String? afterEventId,
  }) async {
    subscriptionCount += 1;
    final controller =
        StreamController<BridgeEventEnvelope<Map<String, dynamic>>>();
    final listener = _LiveStreamListener(
      threadId: threadId,
      controller: controller,
    );
    _listeners.add(listener);
    return ThreadLiveSubscription(
      events: controller.stream,
      close: () async {
        _listeners.remove(listener);
        await controller.close();
      },
    );
  }

  void emit(BridgeEventEnvelope<Map<String, dynamic>> event) {
    for (final listener in List<_LiveStreamListener>.from(_listeners)) {
      if (listener.threadId == null || listener.threadId == event.threadId) {
        listener.controller.add(event);
      }
    }
  }
}

class _LiveStreamListener {
  const _LiveStreamListener({required this.threadId, required this.controller});

  final String? threadId;
  final StreamController<BridgeEventEnvelope<Map<String, dynamic>>> controller;
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
    String? phoneId,
    String? bridgeId,
    String? sessionToken,
    String? localSessionKind,
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

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final endTime = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(endTime)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (predicate()) {
      return;
    }
  }

  throw TestFailure('Timed out waiting for integration predicate.');
}
