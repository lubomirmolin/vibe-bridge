import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final threadLiveStreamProvider = Provider<ThreadLiveStream>((ref) {
  return const HttpThreadLiveStream();
});

abstract class ThreadLiveStream {
  Future<ThreadLiveSubscription> subscribe({
    required String bridgeApiBaseUrl,
    String? threadId,
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

class HttpThreadLiveStream implements ThreadLiveStream {
  const HttpThreadLiveStream();

  @override
  Future<ThreadLiveSubscription> subscribe({
    required String bridgeApiBaseUrl,
    String? threadId,
  }) async {
    final uri = _buildStreamUri(bridgeApiBaseUrl, threadId);
    final socket = await WebSocket.connect(
      uri.toString(),
    ).timeout(const Duration(seconds: 5));

    final controller =
        StreamController<BridgeEventEnvelope<Map<String, dynamic>>>();

    late final StreamSubscription<dynamic> socketSubscription;
    socketSubscription = socket.listen(
      (frame) {
        if (frame is! String) {
          return;
        }

        try {
          final decoded = jsonDecode(frame);
          if (decoded is! Map<String, dynamic>) {
            return;
          }

          if (decoded['event'] == 'subscribed') {
            return;
          }

          final event = BridgeEventEnvelope<Map<String, dynamic>>.fromJson(
            decoded,
            (payload) => payload,
          );
          controller.add(event);
        } on FormatException {
          // Ignore malformed frames to keep the stream alive.
        }
      },
      onError: controller.addError,
      onDone: () {
        if (!controller.isClosed) {
          controller.close();
        }
      },
      cancelOnError: false,
    );

    return ThreadLiveSubscription(
      events: controller.stream,
      close: () async {
        await socketSubscription.cancel();
        await socket.close();
        if (!controller.isClosed) {
          await controller.close();
        }
      },
    );
  }
}

Uri _buildStreamUri(String baseUrl, String? threadId) {
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
        : <String, String>{'scope': 'thread', 'thread_id': normalizedThreadId},
  );
}
