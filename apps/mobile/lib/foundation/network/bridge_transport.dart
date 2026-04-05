import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:vibe_bridge/foundation/logging/thread_diagnostics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'bridge_transport_stub.dart'
    if (dart.library.html) 'bridge_transport_web.dart'
    if (dart.library.io) 'bridge_transport_io.dart'
    as impl;

final bridgeTransportProvider = Provider<BridgeTransport>((ref) {
  return LoggingBridgeTransport(
    inner: impl.createBridgeTransport(),
    diagnostics: ref.watch(threadDiagnosticsServiceProvider),
  );
});

BridgeTransport createDefaultBridgeTransport() {
  return impl.createBridgeTransport();
}

abstract class BridgeTransport {
  Future<BridgeTransportResponse> get(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
    Duration timeout = const Duration(seconds: 5),
  });

  Future<BridgeTransportResponse> post(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
    Object? body,
    Duration timeout = const Duration(seconds: 5),
  });

  Future<BridgeTransportResponse> multipartPost(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
    List<BridgeMultipartField> fields = const <BridgeMultipartField>[],
    Duration timeout = const Duration(seconds: 20),
  });

  Future<BridgeEventStreamConnection> openEventStream(
    Uri uri, {
    Duration timeout = const Duration(seconds: 5),
  });
}

class BridgeTransportResponse {
  const BridgeTransportResponse({
    required this.statusCode,
    required Uint8List bodyBytes,
  }) : _bodyBytes = bodyBytes;

  final int statusCode;
  final Uint8List _bodyBytes;

  Uint8List get bodyBytes => Uint8List.fromList(_bodyBytes);

  String get bodyText => utf8.decode(_bodyBytes);

  dynamic decodeJson() {
    final normalizedBody = bodyText.trim();
    if (normalizedBody.isEmpty) {
      return <String, dynamic>{};
    }
    return jsonDecode(normalizedBody);
  }
}

class BridgeMultipartField {
  const BridgeMultipartField({
    required this.name,
    required this.bytes,
    required this.fileName,
    required this.contentType,
  });

  final String name;
  final List<int> bytes;
  final String fileName;
  final String contentType;
}

class BridgeEventStreamConnection {
  BridgeEventStreamConnection({
    required this.messages,
    required Future<void> Function() close,
  }) : _close = close;

  final Stream<String> messages;
  final Future<void> Function() _close;

  Future<void> close() => _close();
}

class BridgeTransportConnectionException implements Exception {
  const BridgeTransportConnectionException([
    this.message = 'Couldn’t reach the bridge.',
  ]);

  final String message;

  @override
  String toString() => message;
}

class LoggingBridgeTransport implements BridgeTransport {
  const LoggingBridgeTransport({
    required this.inner,
    required this.diagnostics,
  });

  final BridgeTransport inner;
  final ThreadDiagnosticsService diagnostics;

  @override
  Future<BridgeTransportResponse> get(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
    Duration timeout = const Duration(seconds: 5),
  }) {
    return inner.get(uri, headers: headers, timeout: timeout);
  }

  @override
  Future<BridgeTransportResponse> post(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
    Object? body,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final threadId = _threadIdFromUri(uri);
    unawaited(
      diagnostics.record(
        kind: 'http_post_started',
        threadId: threadId,
        data: <String, Object?>{
          'uri': uri.toString(),
          'path': uri.path,
          'bodyPreview': _previewBridgeBody(body),
          'timeoutMs': timeout.inMilliseconds,
        },
      ),
    );
    try {
      final response = await inner.post(
        uri,
        headers: headers,
        body: body,
        timeout: timeout,
      );
      unawaited(
        diagnostics.record(
          kind: 'http_post_completed',
          threadId: threadId,
          data: <String, Object?>{
            'uri': uri.toString(),
            'path': uri.path,
            'statusCode': response.statusCode,
            'bodyPreview': _previewBridgeBody(response.bodyText),
          },
        ),
      );
      return response;
    } on BridgeTransportConnectionException catch (error) {
      unawaited(
        diagnostics.record(
          kind: 'http_post_failed',
          threadId: threadId,
          data: <String, Object?>{
            'uri': uri.toString(),
            'path': uri.path,
            'error': error.message,
            'errorType': error.runtimeType.toString(),
          },
        ),
      );
      rethrow;
    } catch (error) {
      unawaited(
        diagnostics.record(
          kind: 'http_post_failed',
          threadId: threadId,
          data: <String, Object?>{
            'uri': uri.toString(),
            'path': uri.path,
            'error': error.toString(),
            'errorType': error.runtimeType.toString(),
          },
        ),
      );
      rethrow;
    }
  }

  @override
  Future<BridgeTransportResponse> multipartPost(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
    List<BridgeMultipartField> fields = const <BridgeMultipartField>[],
    Duration timeout = const Duration(seconds: 20),
  }) {
    return inner.multipartPost(
      uri,
      headers: headers,
      fields: fields,
      timeout: timeout,
    );
  }

  @override
  Future<BridgeEventStreamConnection> openEventStream(
    Uri uri, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final threadId = uri.queryParameters['thread_id']?.trim();
    unawaited(
      diagnostics.record(
        kind: 'live_stream_connect_started',
        threadId: threadId,
        data: <String, Object?>{
          'uri': uri.toString(),
          'scope': uri.queryParameters['scope'],
          'afterSeq': uri.queryParameters['after_seq'],
        },
      ),
    );
    try {
      final connection = await inner.openEventStream(uri, timeout: timeout);
      unawaited(
        diagnostics.record(
          kind: 'live_stream_connected',
          threadId: threadId,
          data: <String, Object?>{
            'uri': uri.toString(),
            'scope': uri.queryParameters['scope'],
          },
        ),
      );
      final controller = StreamController<String>();
      Future<void>? closeFuture;

      late final StreamSubscription<String> subscription;
      Future<void> closeConnection() {
        return closeFuture ??= () async {
          await subscription.cancel();
          await connection.close();
          await controller.close();
          await diagnostics.record(
            kind: 'live_stream_closed',
            threadId: threadId,
            data: <String, Object?>{
              'uri': uri.toString(),
              'reason': 'client_close',
            },
          );
        }();
      }

      subscription = connection.messages.listen(
        (frame) {
          unawaited(
            diagnostics.record(
              kind: 'live_stream_frame',
              threadId: threadId,
              data: <String, Object?>{
                'uri': uri.toString(),
                'framePreview': _previewBridgeBody(frame),
              },
            ),
          );
          if (!controller.isClosed) {
            controller.add(frame);
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          unawaited(
            diagnostics.record(
              kind: 'live_stream_error',
              threadId: threadId,
              data: <String, Object?>{
                'uri': uri.toString(),
                'error': error.toString(),
                'errorType': error.runtimeType.toString(),
              },
            ),
          );
          if (!controller.isClosed) {
            controller.addError(error, stackTrace);
          }
          unawaited(controller.close());
        },
        onDone: () {
          unawaited(
            diagnostics.record(
              kind: 'live_stream_closed',
              threadId: threadId,
              data: <String, Object?>{
                'uri': uri.toString(),
                'reason': 'server_done',
              },
            ),
          );
          unawaited(controller.close());
        },
        cancelOnError: false,
      );

      return BridgeEventStreamConnection(
        messages: controller.stream,
        close: closeConnection,
      );
    } on BridgeTransportConnectionException catch (error) {
      unawaited(
        diagnostics.record(
          kind: 'live_stream_connect_failed',
          threadId: threadId,
          data: <String, Object?>{
            'uri': uri.toString(),
            'error': error.message,
            'errorType': error.runtimeType.toString(),
          },
        ),
      );
      rethrow;
    }
  }
}

String? _threadIdFromUri(Uri uri) {
  final segments = uri.pathSegments;
  final threadsIndex = segments.indexOf('threads');
  if (threadsIndex < 0 || threadsIndex + 1 >= segments.length) {
    return null;
  }
  final threadId = segments[threadsIndex + 1].trim();
  return threadId.isEmpty ? null : threadId;
}

String _previewBridgeBody(Object? body, {int maxChars = 240}) {
  if (body == null) {
    return '<empty>';
  }
  final text = body is String ? body : jsonEncode(body);
  final normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (normalized.length <= maxChars) {
    return normalized;
  }
  return '${normalized.substring(0, maxChars)}...';
}
