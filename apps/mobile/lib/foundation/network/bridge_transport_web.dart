import 'dart:async';
import 'dart:convert';

import 'package:http/browser_client.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'bridge_transport.dart';

BridgeTransport createBridgeTransport() {
  return BrowserBridgeTransport();
}

class BrowserBridgeTransport implements BridgeTransport {
  BrowserBridgeTransport({BrowserClient? client})
    : _client = client ?? BrowserClient();

  final http.Client _client;

  @override
  Future<BridgeTransportResponse> get(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
    Duration timeout = const Duration(seconds: 5),
  }) async {
    try {
      final response = await _client
          .get(uri, headers: headers)
          .timeout(timeout);
      return BridgeTransportResponse(
        statusCode: response.statusCode,
        bodyBytes: response.bodyBytes,
      );
    } on TimeoutException {
      throw const BridgeTransportConnectionException();
    } catch (_) {
      throw const BridgeTransportConnectionException();
    }
  }

  @override
  Future<BridgeTransportResponse> post(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
    Object? body,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    try {
      final response = await _client
          .post(
            uri,
            headers: headers,
            body: switch (body) {
              null => null,
              String() => body,
              List<int>() => body,
              _ => jsonEncode(body),
            },
          )
          .timeout(timeout);
      return BridgeTransportResponse(
        statusCode: response.statusCode,
        bodyBytes: response.bodyBytes,
      );
    } on TimeoutException {
      throw const BridgeTransportConnectionException();
    } catch (_) {
      throw const BridgeTransportConnectionException();
    }
  }

  @override
  Future<BridgeTransportResponse> multipartPost(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
    List<BridgeMultipartField> fields = const <BridgeMultipartField>[],
    Duration timeout = const Duration(seconds: 20),
  }) async {
    try {
      final request = http.MultipartRequest('POST', uri);
      request.headers.addAll(headers);
      for (final field in fields) {
        request.files.add(
          http.MultipartFile.fromBytes(
            field.name,
            field.bytes,
            filename: field.fileName,
          ),
        );
      }

      final response = await http.Response.fromStream(
        await _client.send(request).timeout(timeout),
      );
      return BridgeTransportResponse(
        statusCode: response.statusCode,
        bodyBytes: response.bodyBytes,
      );
    } on TimeoutException {
      throw const BridgeTransportConnectionException();
    } catch (_) {
      throw const BridgeTransportConnectionException();
    }
  }

  @override
  Future<BridgeEventStreamConnection> openEventStream(
    Uri uri, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    try {
      final channel = WebSocketChannel.connect(uri);
      await channel.ready.timeout(timeout);
      final messages = channel.stream
          .where((message) => message is String)
          .cast<String>();
      return BridgeEventStreamConnection(
        messages: messages,
        close: () async {
          await channel.sink.close();
        },
      );
    } on TimeoutException {
      throw const BridgeTransportConnectionException();
    } catch (_) {
      throw const BridgeTransportConnectionException();
    }
  }
}
