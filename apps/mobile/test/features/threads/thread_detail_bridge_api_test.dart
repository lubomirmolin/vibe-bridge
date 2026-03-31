import 'dart:convert';
import 'dart:io';

import 'package:vibe_bridge/features/threads/data/thread_detail_bridge_api.dart';
import 'package:vibe_bridge/foundation/contracts/bridge_contracts.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'startTurn sends images, model, and effort overrides to the bridge',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });

      final requestBody = <String, dynamic>{};
      final requestPath = <String>[];
      server.listen((request) async {
        requestPath.add(request.uri.path);
        requestBody.addAll(
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>,
        );
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode(<String, dynamic>{
              'contract_version': contractVersion,
              'thread_id': 'thread-123',
              'thread_status': 'running',
              'message': 'turn accepted',
            }),
          );
        await request.response.close();
      });

      final bridgeApi = HttpThreadDetailBridgeApi();
      final result = await bridgeApi.startTurn(
        bridgeApiBaseUrl:
            'http://${InternetAddress.loopbackIPv4.address}:${server.port}',
        threadId: 'thread-123',
        prompt: 'Investigate model propagation',
        images: const <String>['data:image/png;base64,AAA'],
        model: 'gpt-5-mini',
        effort: 'high',
      );

      expect(requestPath, <String>['/threads/thread-123/turns']);
      expect(requestBody['prompt'], 'Investigate model propagation');
      expect(requestBody['images'], const <String>[
        'data:image/png;base64,AAA',
      ]);
      expect(requestBody['model'], 'gpt-5-mini');
      expect(requestBody['effort'], 'high');
      expect(result.threadStatus, ThreadStatus.running);
    },
  );

  test('interruptTurn sends turn_id when provided', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await server.close(force: true);
    });

    final requestBody = <String, dynamic>{};
    final requestPath = <String>[];
    server.listen((request) async {
      requestPath.add(request.uri.path);
      requestBody.addAll(
        jsonDecode(await utf8.decoder.bind(request).join())
            as Map<String, dynamic>,
      );
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode(<String, dynamic>{
            'contract_version': contractVersion,
            'thread_id': 'thread-123',
            'thread_status': 'interrupted',
            'message': 'interrupt requested',
          }),
        );
      await request.response.close();
    });

    final bridgeApi = HttpThreadDetailBridgeApi();
    final result = await bridgeApi.interruptTurn(
      bridgeApiBaseUrl:
          'http://${InternetAddress.loopbackIPv4.address}:${server.port}',
      threadId: 'thread-123',
      turnId: 'turn-456',
    );

    expect(requestPath, <String>['/threads/thread-123/interrupt']);
    expect(requestBody['turn_id'], 'turn-456');
    expect(result.threadStatus, ThreadStatus.interrupted);
  });
}
