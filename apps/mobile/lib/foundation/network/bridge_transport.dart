import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'bridge_transport_stub.dart'
    if (dart.library.html) 'bridge_transport_web.dart'
    if (dart.library.io) 'bridge_transport_io.dart'
    as impl;

final bridgeTransportProvider = Provider<BridgeTransport>((ref) {
  return impl.createBridgeTransport();
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
  const BridgeTransportConnectionException([this.message = 'Couldn’t reach the bridge.']);

  final String message;

  @override
  String toString() => message;
}
