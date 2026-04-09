import 'dart:convert';
import 'dart:typed_data';

import 'package:vibe_bridge/foundation/logging/thread_diagnostics.dart';
import 'package:vibe_bridge/foundation/network/bridge_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('get requests emit diagnostics on success', () async {
    final diagnostics = _RecordingThreadDiagnosticsService();
    final transport = LoggingBridgeTransport(
      inner: _FakeBridgeTransport(
        getHandler:
            ({
              required Uri uri,
              required Map<String, String> headers,
              required Duration timeout,
            }) async {
              return BridgeTransportResponse(
                statusCode: 200,
                bodyBytes: Uint8List.fromList(
                  utf8.encode('{"thread_id":"codex:thread-123"}'),
                ),
              );
            },
      ),
      diagnostics: diagnostics,
    );

    final response = await transport.get(
      Uri.parse('https://bridge.ts.net/threads/codex%3Athread-123/history'),
    );

    expect(response.statusCode, 200);
    expect(diagnostics.records.map((record) => record.kind), <String>[
      'http_get_started',
      'http_get_completed',
    ]);
    expect(diagnostics.records.first.threadId, 'codex:thread-123');
    expect(diagnostics.records.last.data['statusCode'], 200);
    expect(
      diagnostics.records.last.data['bodyPreview'],
      contains('codex:thread-123'),
    );
  });

  test('get request failures emit diagnostics', () async {
    final diagnostics = _RecordingThreadDiagnosticsService();
    final transport = LoggingBridgeTransport(
      inner: _FakeBridgeTransport(
        getHandler:
            ({
              required Uri uri,
              required Map<String, String> headers,
              required Duration timeout,
            }) async {
              throw const BridgeTransportConnectionException('network down');
            },
      ),
      diagnostics: diagnostics,
    );

    await expectLater(
      () => transport.get(
        Uri.parse('https://bridge.ts.net/threads/codex%3Athread-123/history'),
      ),
      throwsA(isA<BridgeTransportConnectionException>()),
    );

    expect(diagnostics.records.map((record) => record.kind), <String>[
      'http_get_started',
      'http_get_failed',
    ]);
    expect(diagnostics.records.last.threadId, 'codex:thread-123');
    expect(diagnostics.records.last.data['error'], 'network down');
  });
}

typedef _GetHandler =
    Future<BridgeTransportResponse> Function({
      required Uri uri,
      required Map<String, String> headers,
      required Duration timeout,
    });

class _FakeBridgeTransport implements BridgeTransport {
  _FakeBridgeTransport({required _GetHandler getHandler})
    : _getHandler = getHandler;

  final _GetHandler _getHandler;

  @override
  Future<BridgeTransportResponse> get(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
    Duration timeout = const Duration(seconds: 5),
  }) {
    return _getHandler(uri: uri, headers: headers, timeout: timeout);
  }

  @override
  Future<BridgeEventStreamConnection> openEventStream(
    Uri uri, {
    Duration timeout = const Duration(seconds: 5),
  }) {
    throw UnimplementedError();
  }

  @override
  Future<BridgeTransportResponse> multipartPost(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
    List<BridgeMultipartField> fields = const <BridgeMultipartField>[],
    Duration timeout = const Duration(seconds: 20),
  }) {
    throw UnimplementedError();
  }

  @override
  Future<BridgeTransportResponse> post(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
    Object? body,
    Duration timeout = const Duration(seconds: 5),
  }) {
    throw UnimplementedError();
  }
}

class _RecordingThreadDiagnosticsService extends ThreadDiagnosticsService {
  final List<_RecordedDiagnostic> records = <_RecordedDiagnostic>[];

  @override
  Future<void> record({
    required String kind,
    String? threadId,
    Map<String, Object?> data = const <String, Object?>{},
  }) {
    records.add(
      _RecordedDiagnostic(
        kind: kind,
        threadId: threadId,
        data: Map<String, Object?>.from(data),
      ),
    );
    return Future<void>.value();
  }
}

class _RecordedDiagnostic {
  const _RecordedDiagnostic({
    required this.kind,
    required this.threadId,
    required this.data,
  });

  final String kind;
  final String? threadId;
  final Map<String, Object?> data;
}
