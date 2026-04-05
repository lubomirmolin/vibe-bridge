import 'dart:async';
import 'dart:convert';

import 'package:vibe_bridge/foundation/contracts/bridge_contracts.dart';
import 'package:vibe_bridge/foundation/network/bridge_transport.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final threadLiveStreamProvider = Provider<ThreadLiveStream>((ref) {
  return HttpThreadLiveStream(transport: ref.watch(bridgeTransportProvider));
});

abstract class ThreadLiveStream {
  Future<ThreadLiveSubscription> subscribe({
    required String bridgeApiBaseUrl,
    String? threadId,
    int? afterSeq,
  });
}

class ThreadLiveSubscription {
  ThreadLiveSubscription({
    required this.events,
    required Future<void> Function() close,
  }) : _close = close;

  final Stream<BridgeEventEnvelope<Map<String, dynamic>>> events;
  final Future<void> Function() _close;

  Future<void> close() => _close();
}

class ThreadLiveReplayGapException implements Exception {
  const ThreadLiveReplayGapException({
    required this.latestSeq,
    required this.oldestSeq,
  });

  final int? latestSeq;
  final int? oldestSeq;

  @override
  String toString() {
    return 'ThreadLiveReplayGapException(latestSeq: $latestSeq, oldestSeq: $oldestSeq)';
  }
}

class HttpThreadLiveStream implements ThreadLiveStream {
  const HttpThreadLiveStream({required BridgeTransport transport})
    : _transport = transport;

  final BridgeTransport _transport;

  @override
  Future<ThreadLiveSubscription> subscribe({
    required String bridgeApiBaseUrl,
    String? threadId,
    int? afterSeq,
  }) async {
    final uri = _buildStreamUri(bridgeApiBaseUrl, threadId, afterSeq: afterSeq);
    final connection = await _transport.openEventStream(uri);
    final controller =
        StreamController<BridgeEventEnvelope<Map<String, dynamic>>>();
    Future<void>? closeFuture;
    final subscribedCompleter = Completer<void>();

    void closeController() {
      if (!controller.isClosed) {
        unawaited(controller.close());
      }
    }

    late final StreamSubscription<String> socketSubscription;
    Future<void> closeSubscription() {
      return closeFuture ??= () async {
        try {
          await socketSubscription.cancel();
        } catch (_) {
          // Ignore duplicate or late subscription cancellation failures.
        }
        try {
          await connection.close();
        } catch (_) {
          // Ignore already-closed connection teardown failures.
        }
        if (!controller.isClosed) {
          await controller.close();
        }
      }();
    }

    socketSubscription = connection.messages.listen(
      (frame) {
        try {
          final decoded = jsonDecode(frame);
          if (decoded is! Map<String, dynamic>) {
            return;
          }

          if (decoded['event'] == 'subscribed') {
            final replayGap = decoded['replay_gap'] == true;
            if (replayGap) {
              if (!subscribedCompleter.isCompleted) {
                subscribedCompleter.completeError(
                  ThreadLiveReplayGapException(
                    latestSeq: decoded['latest_seq'] as int?,
                    oldestSeq: decoded['oldest_seq'] as int?,
                  ),
                );
              }
              unawaited(closeSubscription());
              return;
            }
            if (!subscribedCompleter.isCompleted) {
              subscribedCompleter.complete();
            }
            return;
          }

          final event = BridgeEventEnvelope<Map<String, dynamic>>.fromJson(
            decoded,
            (payload) => payload,
          );
          if (!controller.isClosed) {
            controller.add(event);
          }
        } on FormatException {
          // Ignore malformed frames to keep the stream alive.
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!subscribedCompleter.isCompleted) {
          subscribedCompleter.completeError(error, stackTrace);
        }
        if (!controller.isClosed) {
          controller.addError(error, stackTrace);
        }
        closeController();
      },
      onDone: () {
        if (!subscribedCompleter.isCompleted) {
          subscribedCompleter.completeError(
            StateError('Live stream closed before subscription completed.'),
          );
        }
        closeController();
      },
      cancelOnError: false,
    );

    await subscribedCompleter.future;

    return ThreadLiveSubscription(
      events: controller.stream,
      close: closeSubscription,
    );
  }
}

Uri _buildStreamUri(String baseUrl, String? threadId, {int? afterSeq}) {
  final baseUri = Uri.parse(baseUrl);
  final normalizedBasePath = baseUri.path.endsWith('/')
      ? baseUri.path.substring(0, baseUri.path.length - 1)
      : baseUri.path;
  final wsScheme = baseUri.scheme == 'https' ? 'wss' : 'ws';
  final fullPath =
      '${normalizedBasePath.isEmpty ? '' : normalizedBasePath}/events';

  final normalizedThreadId = threadId?.trim();
  return baseUri.replace(
    scheme: wsScheme,
    path: fullPath,
    queryParameters: normalizedThreadId == null || normalizedThreadId.isEmpty
        ? <String, String>{'scope': 'list'}
        : <String, String>{
            'scope': 'thread',
            'thread_id': normalizedThreadId,
            if (afterSeq != null && afterSeq > 0) 'after_seq': '$afterSeq',
          },
  );
}
