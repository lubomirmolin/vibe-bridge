import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'bridge_transport.dart';

BridgeTransport createBridgeTransport() {
  return const IoBridgeTransport();
}

class IoBridgeTransport implements BridgeTransport {
  const IoBridgeTransport();

  @override
  Future<BridgeTransportResponse> get(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final client = HttpClient()..connectionTimeout = timeout;

    try {
      final request = await client.getUrl(uri);
      _setHeaders(request, headers);
      final response = await request.close();
      return BridgeTransportResponse(
        statusCode: response.statusCode,
        bodyBytes: await _readResponseBytes(response),
      );
    } on SocketException {
      throw const BridgeTransportConnectionException();
    } on HandshakeException {
      throw const BridgeTransportConnectionException();
    } on HttpException {
      throw const BridgeTransportConnectionException();
    } on TimeoutException {
      throw const BridgeTransportConnectionException();
    } finally {
      client.close();
    }
  }

  @override
  Future<BridgeTransportResponse> post(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
    Object? body,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final client = HttpClient()..connectionTimeout = timeout;

    try {
      final request = await client.postUrl(uri);
      _setHeaders(request, headers);
      _writeBody(request, body);
      final response = await request.close();
      return BridgeTransportResponse(
        statusCode: response.statusCode,
        bodyBytes: await _readResponseBytes(response),
      );
    } on SocketException {
      throw const BridgeTransportConnectionException();
    } on HandshakeException {
      throw const BridgeTransportConnectionException();
    } on HttpException {
      throw const BridgeTransportConnectionException();
    } on TimeoutException {
      throw const BridgeTransportConnectionException();
    } finally {
      client.close();
    }
  }

  @override
  Future<BridgeTransportResponse> multipartPost(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
    List<BridgeMultipartField> fields = const <BridgeMultipartField>[],
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final client = HttpClient()..connectionTimeout = timeout;
    final boundary =
        'vibe-bridge-companion-${DateTime.now().microsecondsSinceEpoch}';

    try {
      final request = await client.postUrl(uri);
      _setHeaders(request, headers);
      request.headers.set(
        'content-type',
        'multipart/form-data; boundary=$boundary',
      );
      for (final field in fields) {
        request.write('--$boundary\r\n');
        request.write(
          'Content-Disposition: form-data; name="${field.name}"; filename="${field.fileName}"\r\n',
        );
        request.write('Content-Type: ${field.contentType}\r\n\r\n');
        request.add(field.bytes);
        request.write('\r\n');
      }
      request.write('--$boundary--\r\n');
      final response = await request.close();
      return BridgeTransportResponse(
        statusCode: response.statusCode,
        bodyBytes: await _readResponseBytes(response),
      );
    } on SocketException {
      throw const BridgeTransportConnectionException();
    } on HandshakeException {
      throw const BridgeTransportConnectionException();
    } on HttpException {
      throw const BridgeTransportConnectionException();
    } on TimeoutException {
      throw const BridgeTransportConnectionException();
    } finally {
      client.close();
    }
  }

  @override
  Future<BridgeEventStreamConnection> openEventStream(
    Uri uri, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    try {
      final socket = await WebSocket.connect(uri.toString()).timeout(timeout);
      final controller = StreamController<String>();
      Future<void>? closeFuture;

      void closeController() {
        if (!controller.isClosed) {
          unawaited(controller.close());
        }
      }

      // WebSocket.done may complete with an error after an abrupt remote close.
      // The stream listener handles reconnect signaling, so suppress the extra
      // uncaught future error from the socket internals.
      unawaited(socket.done.catchError((Object _) {}));

      late final StreamSubscription<dynamic> socketSubscription;
      Future<void> closeConnection() {
        return closeFuture ??= () async {
          try {
            await socketSubscription.cancel();
          } catch (_) {
            // Ignore duplicate or late subscription cancellation failures.
          }
          try {
            await socket.close();
          } on SocketException {
            // Ignore already-closed socket teardown failures.
          } on WebSocketException {
            // Ignore already-closed websocket teardown failures.
          }
          await socket.done.catchError((Object _) {});
          if (!controller.isClosed) {
            await controller.close();
          }
        }();
      }

      socketSubscription = socket.listen(
        (message) {
          if (controller.isClosed) {
            return;
          }
          if (message is String) {
            controller.add(message);
            return;
          }
          if (message is List<int>) {
            controller.add(utf8.decode(message));
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!controller.isClosed) {
            controller.addError(error, stackTrace);
          }
          closeController();
        },
        onDone: closeController,
        cancelOnError: false,
      );

      return BridgeEventStreamConnection(
        messages: controller.stream,
        close: closeConnection,
      );
    } on SocketException {
      throw const BridgeTransportConnectionException();
    } on HandshakeException {
      throw const BridgeTransportConnectionException();
    } on HttpException {
      throw const BridgeTransportConnectionException();
    } on TimeoutException {
      throw const BridgeTransportConnectionException();
    } on WebSocketException {
      throw const BridgeTransportConnectionException();
    }
  }

  void _setHeaders(HttpClientRequest request, Map<String, String> headers) {
    for (final entry in headers.entries) {
      request.headers.set(entry.key, entry.value);
    }
  }

  void _writeBody(HttpClientRequest request, Object? body) {
    if (body == null) {
      return;
    }
    if (body is String) {
      request.add(utf8.encode(body));
      return;
    }
    if (body is List<int>) {
      request.add(body);
      return;
    }
    request.add(utf8.encode(jsonEncode(body)));
  }
}

Future<Uint8List> _readResponseBytes(HttpClientResponse response) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in response) {
    builder.add(chunk);
  }
  return builder.takeBytes();
}
