import 'dart:convert';
import 'dart:io';

import 'package:codex_mobile_companion/features/approvals/data/approval_bridge_api.dart';
import 'package:codex_mobile_companion/features/settings/data/settings_bridge_api.dart';
import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('HTTP bridge compatibility', () {
    test('settings access mode falls back to bootstrap trust state', () async {
      final server = await _startServer((request) async {
        if (request.uri.path == '/policy/access-mode') {
          request.response.statusCode = HttpStatus.notFound;
          request.response.write(
            jsonEncode(<String, dynamic>{
              'error': 'not_found',
              'code': 'not_found',
              'message': 'missing route',
            }),
          );
          await request.response.close();
          return;
        }

        if (request.uri.path == '/bootstrap') {
          request.response.statusCode = HttpStatus.ok;
          request.response.write(
            jsonEncode(<String, dynamic>{
              'contract_version': contractVersion,
              'bridge': {'status': 'healthy'},
              'codex': {'status': 'healthy'},
              'trust': {'trusted': true, 'access_mode': 'full_control'},
              'threads': <Object?>[],
              'models': <Object?>[],
            }),
          );
          await request.response.close();
          return;
        }

        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      });
      addTearDown(server.close);

      final api = const HttpSettingsBridgeApi();
      final mode = await api.fetchAccessMode(
        bridgeApiBaseUrl: 'http://127.0.0.1:${server.port}',
      );

      expect(mode, AccessMode.fullControl);
    });

    test('approvals api accepts summary-style rewrite responses', () async {
      final server = await _startServer((request) async {
        if (request.uri.path == '/approvals') {
          request.response.statusCode = HttpStatus.ok;
          request.response.write(
            jsonEncode(<String, dynamic>{
              'contract_version': contractVersion,
              'approvals': <Object?>[
                <String, dynamic>{
                  'approval_id': 'approval-1',
                  'thread_id': 'thread-1',
                  'action': 'git_pull',
                  'status': 'pending',
                  'reason': 'approval_requested',
                  'target': 'origin',
                },
              ],
            }),
          );
          await request.response.close();
          return;
        }

        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      });
      addTearDown(server.close);

      final api = const HttpApprovalBridgeApi();
      final approvals = await api.fetchApprovals(
        bridgeApiBaseUrl: 'http://127.0.0.1:${server.port}',
      );

      expect(approvals, hasLength(1));
      expect(approvals.single.approvalId, 'approval-1');
      expect(approvals.single.repository.workspace, 'Unknown workspace');
      expect(approvals.single.gitStatus.dirty, isFalse);
    });
  });
}

Future<HttpServer> _startServer(
  Future<void> Function(HttpRequest request) handler,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    request.response.headers.contentType = ContentType.json;
    await handler(request);
  });
  return server;
}
