import 'dart:async';
import 'dart:io';

import 'package:vibe_bridge/foundation/network/bridge_transport_io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'openEventStream handles server-initiated closure without uncaught async errors',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final serverClosedSocket = Completer<void>();

      server.listen((request) async {
        final webSocket = await WebSocketTransformer.upgrade(request);
        unawaited(
          webSocket.close().whenComplete(() {
            if (!serverClosedSocket.isCompleted) {
              serverClosedSocket.complete();
            }
          }),
        );
      });

      addTearDown(() async {
        await server.close(force: true);
      });

      final uncaughtErrors = <Object>[];

      await runZonedGuarded(
        () async {
          final transport = const IoBridgeTransport();
          final connection = await transport.openEventStream(
            Uri.parse('ws://${server.address.address}:${server.port}/events'),
          );
          final completion = Completer<void>();
          final subscription = connection.messages.listen(
            (_) {},
            onError: (_) {
              if (!completion.isCompleted) {
                completion.complete();
              }
            },
            onDone: () {
              if (!completion.isCompleted) {
                completion.complete();
              }
            },
          );

          await serverClosedSocket.future.timeout(const Duration(seconds: 2));
          await completion.future.timeout(const Duration(seconds: 2));
          await subscription.cancel();
          await connection.close();
          await Future<void>.delayed(const Duration(milliseconds: 50));
        },
        (error, _) {
          uncaughtErrors.add(error);
        },
      );

      expect(uncaughtErrors, isEmpty);
    },
  );

  test(
    'openEventStream close is idempotent after the socket is closed',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final socketConnected = Completer<void>();

      server.listen((request) async {
        final webSocket = await WebSocketTransformer.upgrade(request);
        if (!socketConnected.isCompleted) {
          socketConnected.complete();
        }
        await webSocket.done;
      });

      addTearDown(() async {
        await server.close(force: true);
      });

      final transport = const IoBridgeTransport();
      final connection = await transport.openEventStream(
        Uri.parse('ws://${server.address.address}:${server.port}/events'),
      );

      final subscription = connection.messages.listen((_) {});
      await socketConnected.future.timeout(const Duration(seconds: 2));
      await connection.close();
      await connection.close();
      await subscription.cancel();
    },
  );
}
