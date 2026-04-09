import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:vibe_bridge/foundation/logging/thread_diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('export waits for queued writes before reading diagnostics', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'thread-diagnostics-test-',
    );
    addTearDown(() async {
      await tempDir.delete(recursive: true);
    });

    final file = File('${tempDir.path}/thread_diagnostics.ndjson');
    final logFileResolver = Completer<File>();
    final diagnostics = ThreadDiagnosticsService(
      logFileResolver: () => logFileResolver.future,
    );

    unawaited(
      diagnostics.record(
        kind: 'thread_load_failed',
        threadId: 'codex:thread-123',
        data: const <String, Object?>{'phase': 'fetch_thread_detail'},
      ),
    );

    final exportFuture = diagnostics.export(threadId: 'codex:thread-123');
    logFileResolver.complete(file);

    final exported = await exportFuture;
    expect(exported, contains('thread_load_failed'));
    expect(exported, contains('fetch_thread_detail'));
  });

  test(
    'export falls back to recent diagnostics when thread filter is empty',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'thread-diagnostics-test-',
      );
      addTearDown(() async {
        await tempDir.delete(recursive: true);
      });

      final file = File('${tempDir.path}/thread_diagnostics.ndjson');
      await file.writeAsString(
        [
          jsonEncode({
            'ts': '2026-04-08T10:00:00Z',
            'sessionId': 'session-1',
            'kind': 'http_get_failed',
            'threadId': null,
            'data': {'path': '/threads'},
          }),
          jsonEncode({
            'ts': '2026-04-08T10:00:01Z',
            'sessionId': 'session-1',
            'kind': 'thread_load_failed',
            'threadId': 'codex:other-thread',
            'data': {'phase': 'fetch_thread_timeline'},
          }),
        ].join('\n'),
      );

      final diagnostics = ThreadDiagnosticsService(
        logFileResolver: () async => file,
      );

      final exported = await diagnostics.export(
        threadId: 'codex:missing-thread',
        includeFallbackRecent: true,
        fallbackLimit: 10,
      );

      expect(
        exported,
        contains('No exact diagnostics matched threadId=codex:missing-thread'),
      );
      expect(exported, contains('http_get_failed'));
      expect(exported, contains('thread_load_failed'));
    },
  );
}
