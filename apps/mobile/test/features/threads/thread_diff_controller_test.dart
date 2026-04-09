import 'dart:async';

import 'package:vibe_bridge/features/threads/application/thread_diff_controller.dart';
import 'package:vibe_bridge/features/threads/data/thread_diff_bridge_api.dart';
import 'package:vibe_bridge/features/threads/data/thread_live_stream.dart';
import 'package:vibe_bridge/foundation/contracts/bridge_contracts.dart';
import 'package:vibe_bridge/foundation/logging/thread_diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('thread diff load records diagnostics for generic failures', () async {
    final diagnostics = _RecordingThreadDiagnosticsService();
    final controller = ThreadDiffController(
      bridgeApiBaseUrl: 'https://bridge.ts.net',
      threadId: 'codex:thread-123',
      bridgeApi: _ThrowingThreadDiffBridgeApi(),
      liveStream: _IdleThreadLiveStream(),
      diagnostics: diagnostics,
    );
    addTearDown(controller.dispose);

    await _waitUntil(
      () => diagnostics.records.any(
        (record) => record.kind == 'thread_diff_load_failed',
      ),
    );

    final failure = diagnostics.records.lastWhere(
      (record) => record.kind == 'thread_diff_load_failed',
    );
    expect(failure.threadId, 'codex:thread-123');
    expect(failure.data['errorType'], 'StateError');
    expect(
      controller.state.errorMessage,
      'Couldn’t load the git diff right now.',
    );
  });
}

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 3),
  Duration step = const Duration(milliseconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) {
      return;
    }
    await Future<void>.delayed(step);
  }

  if (!condition()) {
    fail('Timed out while waiting for expected asynchronous condition.');
  }
}

class _ThrowingThreadDiffBridgeApi implements ThreadDiffBridgeApi {
  @override
  Future<ThreadGitDiffDto> fetchThreadGitDiff({
    required String bridgeApiBaseUrl,
    required String threadId,
    required ThreadGitDiffMode mode,
    String? path,
  }) async {
    throw StateError('diff parsing exploded');
  }
}

class _IdleThreadLiveStream implements ThreadLiveStream {
  @override
  Future<ThreadLiveSubscription> subscribe({
    required String bridgeApiBaseUrl,
    String? threadId,
    int? afterSeq,
  }) async {
    final controller =
        StreamController<BridgeEventEnvelope<Map<String, dynamic>>>(sync: true);
    return ThreadLiveSubscription(
      events: controller.stream,
      close: () async {
        await controller.close();
      },
    );
  }
}

class _RecordingThreadDiagnosticsService extends ThreadDiagnosticsService {
  final List<_RecordedDiagnostic> records = <_RecordedDiagnostic>[];

  @override
  Future<void> record({
    required String kind,
    String? threadId,
    Map<String, Object?> data = const <String, Object?>{},
  }) {
    records.add(
      _RecordedDiagnostic(
        kind: kind,
        threadId: threadId,
        data: Map<String, Object?>.from(data),
      ),
    );
    return Future<void>.value();
  }
}

class _RecordedDiagnostic {
  const _RecordedDiagnostic({
    required this.kind,
    required this.threadId,
    required this.data,
  });

  final String kind;
  final String? threadId;
  final Map<String, Object?> data;
}
