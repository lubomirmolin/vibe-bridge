import 'bridge_transport.dart';

BridgeTransport createBridgeTransport() {
  return const UnsupportedBridgeTransport();
}

class UnsupportedBridgeTransport implements BridgeTransport {
  const UnsupportedBridgeTransport();

  @override
  Future<BridgeTransportResponse> get(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
    Duration timeout = const Duration(seconds: 5),
  }) async {
    throw const BridgeTransportConnectionException(
      'Bridge transport is unavailable on this platform.',
    );
  }

  @override
  Future<BridgeTransportResponse> post(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
    Object? body,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    throw const BridgeTransportConnectionException(
      'Bridge transport is unavailable on this platform.',
    );
  }

  @override
  Future<BridgeTransportResponse> multipartPost(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
    List<BridgeMultipartField> fields = const <BridgeMultipartField>[],
    Duration timeout = const Duration(seconds: 20),
  }) async {
    throw const BridgeTransportConnectionException(
      'Bridge transport is unavailable on this platform.',
    );
  }

  @override
  Future<BridgeEventStreamConnection> openEventStream(
    Uri uri, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    throw const BridgeTransportConnectionException(
      'Bridge transport is unavailable on this platform.',
    );
  }
}
