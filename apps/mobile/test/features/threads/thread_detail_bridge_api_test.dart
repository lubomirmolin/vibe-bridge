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
        clientMessageId: 'client-msg-123',
        clientTurnIntentId: 'turn-intent-123',
        images: const <String>['data:image/png;base64,AAA'],
        model: 'gpt-5-mini',
        effort: 'high',
      );

      expect(requestPath, <String>['/threads/thread-123/turns']);
      expect(requestBody['prompt'], 'Investigate model propagation');
      expect(requestBody['client_message_id'], 'client-msg-123');
      expect(requestBody['client_turn_intent_id'], 'turn-intent-123');
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

  test('fetchThreadUsage decodes the compact usage payload', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await server.close(force: true);
    });

    final requestPath = <String>[];
    server.listen((request) async {
      requestPath.add(request.uri.path);
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode(<String, dynamic>{
            'contract_version': contractVersion,
            'thread_id': 'codex:thread-123',
            'provider': 'codex',
            'plan_type': 'pro',
            'primary_window': <String, dynamic>{
              'used_percent': 6,
              'limit_window_seconds': 18000,
              'reset_after_seconds': 12223,
              'reset_at': 1774996694,
            },
            'secondary_window': <String, dynamic>{
              'used_percent': 42,
              'limit_window_seconds': 604800,
              'reset_after_seconds': 213053,
              'reset_at': 1775197525,
            },
          }),
        );
      await request.response.close();
    });

    final bridgeApi = HttpThreadDetailBridgeApi();
    final usage = await bridgeApi.fetchThreadUsage(
      bridgeApiBaseUrl:
          'http://${InternetAddress.loopbackIPv4.address}:${server.port}',
      threadId: 'codex:thread-123',
    );

    expect(requestPath, <String>['/threads/codex%3Athread-123/usage']);
    expect(usage.provider, ProviderKind.codex);
    expect(usage.planType, 'pro');
    expect(usage.primaryWindow.usedPercent, 6);
    expect(usage.secondaryWindow?.usedPercent, 42);
  });

  test(
    'startTurn surfaces bridge error messages for structured failures',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });

      server.listen((request) async {
        request.response
          ..statusCode = HttpStatus.badRequest
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode(<String, dynamic>{
              'error': 'turn_start_failed',
              'code': 'unsupported_turn_mode',
              'message':
                  'plan mode is not implemented for Claude Code threads yet',
            }),
          );
        await request.response.close();
      });

      final bridgeApi = HttpThreadDetailBridgeApi();
      expect(
        () => bridgeApi.startTurn(
          bridgeApiBaseUrl:
              'http://${InternetAddress.loopbackIPv4.address}:${server.port}',
          threadId: 'claude:test-thread',
          prompt: 'Plan the change',
          mode: TurnMode.plan,
        ),
        throwsA(
          isA<ThreadTurnBridgeException>().having(
            (error) => error.message,
            'message',
            'plan mode is not implemented for Claude Code threads yet',
          ),
        ),
      );
    },
  );

  test(
    'startTurn includes HTTP status when the bridge error is not JSON',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });

      server.listen((request) async {
        request.response
          ..statusCode = HttpStatus.badGateway
          ..headers.contentType = ContentType.text
          ..write('upstream exploded');
        await request.response.close();
      });

      final bridgeApi = HttpThreadDetailBridgeApi();
      expect(
        () => bridgeApi.startTurn(
          bridgeApiBaseUrl:
              'http://${InternetAddress.loopbackIPv4.address}:${server.port}',
          threadId: 'thread-123',
          prompt: 'Investigate failure handling',
        ),
        throwsA(
          isA<ThreadTurnBridgeException>().having(
            (error) => error.message,
            'message',
            'Couldn’t update turn state right now (HTTP 502).',
          ),
        ),
      );
    },
  );

  test(
    'startTurn sanitizes minified Claude crash output from the bridge',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });

      server.listen((request) async {
        request.response
          ..statusCode = HttpStatus.badGateway
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode(<String, dynamic>{
              'error': 'turn_start_failed',
              'code': 'upstream_mutation_failed',
              'message':
                  'Claude process exited with status 1: `),Q.code=Z.error.code,Q.errors=Z.error.errors;else Q.message=Z.error.message;Us2.DefaultTransport=yZ1;',
            }),
          );
        await request.response.close();
      });

      final bridgeApi = HttpThreadDetailBridgeApi();
      expect(
        () => bridgeApi.startTurn(
          bridgeApiBaseUrl:
              'http://${InternetAddress.loopbackIPv4.address}:${server.port}',
          threadId: 'claude:test-thread',
          prompt: 'Investigate Claude failure handling',
        ),
        throwsA(
          isA<ThreadTurnBridgeException>().having(
            (error) => error.message,
            'message',
            'Claude process exited with status 1: Claude CLI crashed before returning a usable error. Check the bridge logs for details.',
          ),
        ),
      );
    },
  );
}
