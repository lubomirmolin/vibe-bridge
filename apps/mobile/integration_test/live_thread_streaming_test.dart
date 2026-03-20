import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:codex_mobile_companion/features/approvals/data/approval_bridge_api.dart';
import 'package:codex_mobile_companion/features/settings/data/settings_bridge_api.dart';
import 'package:codex_mobile_companion/features/threads/presentation/thread_detail_page.dart';
import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:codex_mobile_companion/foundation/storage/secure_store.dart';
import 'package:codex_mobile_companion/foundation/storage/secure_store_provider.dart';
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
      expect(find.text('Investigate live streaming'), findsOneWidget);
      await bridgeServer.waitForSocketCount(1);

      await bridgeServer.emitLiveEvent(
        const BridgeEventEnvelope<Map<String, dynamic>>(
          contractVersion: contractVersion,
          eventId: 'evt-stream-1',
          threadId: 'thread-123',
          kind: BridgeEventKind.messageDelta,
          occurredAt: '2026-03-20T09:00:00Z',
          payload: {'type': 'agentMessage', 'text': 'Hel'},
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Hel'), findsOneWidget);
      expect(
        find.byKey(const Key('thread-message-card-evt-stream-1')),
        findsOneWidget,
      );

      await bridgeServer.emitLiveEvent(
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
      await tester.pumpAndSettle();

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
  );
}

class _TestBridgeServer {
  _TestBridgeServer._(this._server)
    : _threadSummary = const ThreadSummaryDto(
        contractVersion: contractVersion,
        threadId: 'thread-123',
        title: 'Investigate live streaming',
        status: ThreadStatus.running,
        workspace: '/workspace/codex-mobile-companion',
        repository: 'codex-mobile-companion',
        branch: 'main',
        updatedAt: '2026-03-20T08:59:00Z',
      ),
      _threadDetail = const ThreadDetailDto(
        contractVersion: contractVersion,
        threadId: 'thread-123',
        title: 'Investigate live streaming',
        status: ThreadStatus.running,
        workspace: '/workspace/codex-mobile-companion',
        repository: 'codex-mobile-companion',
        branch: 'main',
        createdAt: '2026-03-20T08:55:00Z',
        updatedAt: '2026-03-20T08:59:00Z',
        source: 'cli',
        accessMode: AccessMode.controlWithApprovals,
        lastTurnSummary: 'Streaming is active',
      );

  final HttpServer _server;
  final List<WebSocket> _sockets = <WebSocket>[];
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
    for (final socket in List<WebSocket>.from(_sockets)) {
      await socket.close();
    }
    await _server.close(force: true);
  }

  Future<void> waitForSocketCount(
    int expectedCount, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (_sockets.length >= expectedCount) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    throw TimeoutException(
      'Timed out waiting for $expectedCount websocket subscriptions.',
    );
  }

  Future<void> emitLiveEvent(
    BridgeEventEnvelope<Map<String, dynamic>> event,
  ) async {
    _threadSummary = ThreadSummaryDto(
      contractVersion: _threadSummary.contractVersion,
      threadId: _threadSummary.threadId,
      title: _threadSummary.title,
      status: _resolveThreadStatus(event) ?? _threadSummary.status,
      workspace: _threadSummary.workspace,
      repository: _threadSummary.repository,
      branch: _threadSummary.branch,
      updatedAt: event.occurredAt,
    );
    _threadDetail = ThreadDetailDto(
      contractVersion: _threadDetail.contractVersion,
      threadId: _threadDetail.threadId,
      title: _threadDetail.title,
      status: _resolveThreadStatus(event) ?? _threadDetail.status,
      workspace: _threadDetail.workspace,
      repository: _threadDetail.repository,
      branch: _threadDetail.branch,
      createdAt: _threadDetail.createdAt,
      updatedAt: event.occurredAt,
      source: _threadDetail.source,
      accessMode: _threadDetail.accessMode,
      lastTurnSummary: _summarizeEvent(event),
    );
    _timelineByEventId[event.eventId] = ThreadTimelineEntryDto(
      eventId: event.eventId,
      kind: event.kind,
      occurredAt: event.occurredAt,
      summary: _summarizeEvent(event),
      payload: event.payload,
    );

    final encoded = jsonEncode(<String, dynamic>{
      'contract_version': event.contractVersion,
      'event_id': event.eventId,
      'thread_id': event.threadId,
      'kind': event.kind.wireValue,
      'occurred_at': event.occurredAt,
      'payload': event.payload,
    });

    for (final socket in List<WebSocket>.from(_sockets)) {
      socket.add(encoded);
    }
  }

  Future<void> _handleRequest(HttpRequest request) async {
    if (request.uri.path == '/stream' &&
        WebSocketTransformer.isUpgradeRequest(request)) {
      final socket = await WebSocketTransformer.upgrade(request);
      _sockets.add(socket);
      socket.done.whenComplete(() => _sockets.remove(socket));
      socket.add(
        jsonEncode(<String, dynamic>{
          'contract_version': contractVersion,
          'event': 'subscribed',
          'thread_ids':
              request.uri.queryParametersAll['thread_id'] ?? <String>[],
        }),
      );
      return;
    }

    switch (request.uri.path) {
      case '/threads':
        await _writeJson(request, <String, dynamic>{
          'contract_version': contractVersion,
          'threads': <Map<String, dynamic>>[_threadSummary.toJson()],
        });
        return;
      case '/threads/thread-123':
        await _writeJson(request, <String, dynamic>{
          'contract_version': contractVersion,
          'thread': _threadDetail.toJson(),
        });
        return;
      case '/threads/thread-123/timeline':
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

  throw TestFailure('Timed out waiting for ${finder.description}.');
}
