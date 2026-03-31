import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibe_bridge/features/threads/application/thread_detail_controller.dart';
import 'package:vibe_bridge/features/threads/application/thread_list_controller.dart';
import 'package:vibe_bridge/features/threads/data/thread_cache_repository.dart';
import 'package:vibe_bridge/features/threads/data/thread_detail_bridge_api.dart';
import 'package:vibe_bridge/features/threads/data/thread_list_bridge_api.dart';
import 'package:vibe_bridge/features/threads/data/thread_live_stream.dart';
import 'package:vibe_bridge/features/threads/domain/thread_activity_item.dart';
import 'package:vibe_bridge/foundation/contracts/bridge_contracts.dart';
import 'package:vibe_bridge/foundation/network/bridge_transport_io.dart';
import 'package:vibe_bridge/foundation/storage/secure_store.dart';

void main() {
  test(
    'live status probe detects premature non-running status before later streamed activity',
    () async {
      final previousOverrides = HttpOverrides.current;
      HttpOverrides.global = _PassthroughHttpOverrides();
      addTearDown(() {
        HttpOverrides.global = previousOverrides;
      });

      final bridgeApiBaseUrl = _resolveBridgeApiBaseUrl();
      final attempts = _resolveProbeAttempts();
      final prompt = _resolveProbePrompt();
      final workspace = await _resolveWorkspace(bridgeApiBaseUrl);
      final reports = <_StatusOrderProbeAttemptReport>[];

      for (var attempt = 1; attempt <= attempts; attempt += 1) {
        final report = await _runStatusOrderProbeAttempt(
          attempt: attempt,
          bridgeApiBaseUrl: bridgeApiBaseUrl,
          workspace: workspace,
          prompt: prompt,
        );
        reports.add(report);
        debugPrint(report.toLogLine());
      }

      final suspicious = reports.where(
        (report) => report.hasSuspiciousSymptoms,
      );
      if (suspicious.isNotEmpty) {
        fail(
          'LIVE_STATUS_PROBE detected suspicious status ordering:\n'
          '${suspicious.map((report) => report.toFailureLine()).join('\n')}',
        );
      }

      debugPrint(
        'LIVE_STATUS_PROBE_SUMMARY '
        'attempts=$attempts '
        'bridge=$bridgeApiBaseUrl '
        'prompt="${prompt.replaceAll('"', "'")}" '
        'result=clean',
      );
    },
    skip: !_runLiveStatusProbe(),
    timeout: const Timeout(Duration(minutes: 15)),
  );
}

Future<_StatusOrderProbeAttemptReport> _runStatusOrderProbeAttempt({
  required int attempt,
  required String bridgeApiBaseUrl,
  required String workspace,
  required String prompt,
}) async {
  final detailApi = HttpThreadDetailBridgeApi();
  final listApi = HttpThreadListBridgeApi();
  final liveStream = HttpThreadLiveStream(transport: const IoBridgeTransport());
  final debugLogs = <String>[];
  final startedAt = DateTime.now();
  final stopwatch = Stopwatch()..start();
  final rawEvents = <BridgeEventEnvelope<Map<String, dynamic>>>[];
  final rawErrors = <Object>[];
  final rawTimeline = <_RawEventObservation>[];
  final snapshotTimeline = <_StatusObservation>[];
  final controllerTimeline = <_StatusObservation>[];

  final snapshot = await detailApi
      .createThread(
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        workspace: workspace,
        provider: ProviderKind.codex,
      )
      .timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw TestFailure(
          'Attempt $attempt timed out creating a thread via $bridgeApiBaseUrl.',
        ),
      );

  final threadId = snapshot.thread.threadId.trim();
  expect(threadId, isNotEmpty);

  final rawSubscription = await liveStream.subscribe(
    bridgeApiBaseUrl: bridgeApiBaseUrl,
    threadId: threadId,
  );
  final rawEventSubscription = rawSubscription.events.listen((event) {
    rawEvents.add(event);
    rawTimeline.add(
      _RawEventObservation(
        at: stopwatch.elapsed,
        eventId: event.eventId,
        kind: event.kind,
        status: _eventStatus(event),
        textPreview: _previewMessageText(event.payload),
      ),
    );
  }, onError: rawErrors.add);

  final listController = ThreadListController(
    bridgeApi: listApi,
    cacheRepository: SecureStoreThreadCacheRepository(
      secureStore: InMemorySecureStore(),
      nowUtc: () => DateTime.now().toUtc(),
    ),
    liveStream: liveStream,
    bridgeApiBaseUrl: bridgeApiBaseUrl,
  );
  final detailController = ThreadDetailController(
    bridgeApiBaseUrl: bridgeApiBaseUrl,
    threadId: threadId,
    initialVisibleTimelineEntries: 200,
    bridgeApi: detailApi,
    liveStream: liveStream,
    threadListController: listController,
    debugLog: debugLogs.add,
  );

  try {
    await _waitUntil(
      () =>
          !detailController.state.isLoading &&
          detailController.state.thread != null,
      timeout: const Duration(seconds: 20),
    );
    _recordControllerStatusIfChanged(
      timeline: controllerTimeline,
      stopwatch: stopwatch,
      status: detailController.state.thread?.status,
    );

    final submitted = await detailController.submitComposerInput(prompt);
    if (!submitted) {
      throw TestFailure(
        'Attempt $attempt could not submit the live status probe prompt.',
      );
    }

    final settleResult = await _observeTurnStatusOrdering(
      detailApi: detailApi,
      bridgeApiBaseUrl: bridgeApiBaseUrl,
      threadId: threadId,
      detailController: detailController,
      stopwatch: stopwatch,
      snapshotTimeline: snapshotTimeline,
      controllerTimeline: controllerTimeline,
      rawTimeline: rawTimeline,
    );

    final snapshotAfterProbe = await detailApi.fetchThreadDetail(
      bridgeApiBaseUrl: bridgeApiBaseUrl,
      threadId: threadId,
    );

    return _StatusOrderProbeAttemptReport(
      attempt: attempt,
      threadId: threadId,
      prompt: prompt,
      startedAt: startedAt,
      didSettle: settleResult.didSettle,
      controllerStatus: detailController.state.thread?.status,
      snapshotStatus: snapshotAfterProbe.status,
      rawEventCount: rawEvents.length,
      rawErrors: List<Object>.unmodifiable(rawErrors),
      rawTimeline: List<_RawEventObservation>.unmodifiable(rawTimeline),
      snapshotTimeline: List<_StatusObservation>.unmodifiable(snapshotTimeline),
      controllerTimeline: List<_StatusObservation>.unmodifiable(
        controllerTimeline,
      ),
      debugLogs: List<String>.unmodifiable(debugLogs),
    );
  } finally {
    await rawEventSubscription.cancel();
    await rawSubscription.close();
    detailController.dispose();
    listController.dispose();
  }
}

Future<_StatusSettleResult> _observeTurnStatusOrdering({
  required HttpThreadDetailBridgeApi detailApi,
  required String bridgeApiBaseUrl,
  required String threadId,
  required ThreadDetailController detailController,
  required Stopwatch stopwatch,
  required List<_StatusObservation> snapshotTimeline,
  required List<_StatusObservation> controllerTimeline,
  required List<_RawEventObservation> rawTimeline,
}) async {
  final deadline = DateTime.now().add(_resolveProbeTimeout());
  var lastObservedRawCount = rawTimeline.length;
  var lastObservedRawEventAt = stopwatch.elapsed;
  var lastSnapshotPollAt = Duration.zero;

  while (DateTime.now().isBefore(deadline)) {
    final now = stopwatch.elapsed;
    if (rawTimeline.length != lastObservedRawCount) {
      lastObservedRawCount = rawTimeline.length;
      lastObservedRawEventAt = now;
    }

    _recordControllerStatusIfChanged(
      timeline: controllerTimeline,
      stopwatch: stopwatch,
      status: detailController.state.thread?.status,
    );

    if (now - lastSnapshotPollAt >= const Duration(milliseconds: 350)) {
      lastSnapshotPollAt = now;
      try {
        final snapshot = await detailApi.fetchThreadDetail(
          bridgeApiBaseUrl: bridgeApiBaseUrl,
          threadId: threadId,
        );
        _recordStatusIfChanged(
          timeline: snapshotTimeline,
          at: stopwatch.elapsed,
          source: 'snapshot',
          status: snapshot.status,
        );
      } catch (_) {
        // Ignore best-effort probe polling failures.
      }
    }

    final hasAssistantOutput = detailController.state.items.any(
      (item) =>
          item.type == ThreadActivityItemType.assistantOutput &&
          item.body.trim().isNotEmpty,
    );
    final controllerStatus = detailController.state.thread?.status;
    final quietFor = stopwatch.elapsed - lastObservedRawEventAt;
    final looksSettled =
        hasAssistantOutput &&
        controllerStatus != ThreadStatus.running &&
        quietFor >= const Duration(seconds: 2);
    if (looksSettled) {
      return _StatusSettleResult(didSettle: true);
    }

    await Future<void>.delayed(const Duration(milliseconds: 100));
  }

  return _StatusSettleResult(didSettle: false);
}

void _recordControllerStatusIfChanged({
  required List<_StatusObservation> timeline,
  required Stopwatch stopwatch,
  required ThreadStatus? status,
}) {
  if (status == null) {
    return;
  }
  _recordStatusIfChanged(
    timeline: timeline,
    at: stopwatch.elapsed,
    source: 'controller',
    status: status,
  );
}

void _recordStatusIfChanged({
  required List<_StatusObservation> timeline,
  required Duration at,
  required String source,
  required ThreadStatus status,
}) {
  if (timeline.isNotEmpty && timeline.last.status == status) {
    return;
  }
  timeline.add(_StatusObservation(at: at, source: source, status: status));
}

Future<String> _resolveWorkspace(String bridgeApiBaseUrl) async {
  final listApi = HttpThreadListBridgeApi();
  final threads = await listApi
      .fetchThreads(bridgeApiBaseUrl: bridgeApiBaseUrl)
      .timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw TestFailure(
          'Timed out loading /threads from $bridgeApiBaseUrl.',
        ),
      );

  final workspace = threads
      .map((thread) => thread.workspace.trim())
      .firstWhere((candidate) => candidate.isNotEmpty, orElse: () => '');
  if (workspace.isEmpty) {
    fail('Live bridge did not expose any workspace for the status probe.');
  }
  return workspace;
}

String? _eventStatus(BridgeEventEnvelope<Map<String, dynamic>> event) {
  if (event.kind != BridgeEventKind.threadStatusChanged) {
    return null;
  }
  final status = event.payload['status'];
  return status is String && status.trim().isNotEmpty ? status.trim() : null;
}

String _previewMessageText(Map<String, dynamic> payload) {
  final text =
      _messageText(payload)?.replaceAll(RegExp(r'\s+'), ' ').trim() ?? '';
  if (text.length <= 80) {
    return text;
  }
  return '${text.substring(0, 80)}...';
}

String? _messageText(Map<String, dynamic> payload) {
  final text = payload['text'];
  if (text is String && text.trim().isNotEmpty) {
    return text;
  }

  final delta = payload['delta'];
  if (delta is String && delta.trim().isNotEmpty) {
    return delta;
  }

  final output = payload['output'];
  if (output is String && output.trim().isNotEmpty) {
    return output;
  }

  return null;
}

class _StatusOrderProbeAttemptReport {
  const _StatusOrderProbeAttemptReport({
    required this.attempt,
    required this.threadId,
    required this.prompt,
    required this.startedAt,
    required this.didSettle,
    required this.controllerStatus,
    required this.snapshotStatus,
    required this.rawEventCount,
    required this.rawErrors,
    required this.rawTimeline,
    required this.snapshotTimeline,
    required this.controllerTimeline,
    required this.debugLogs,
  });

  final int attempt;
  final String threadId;
  final String prompt;
  final DateTime startedAt;
  final bool didSettle;
  final ThreadStatus? controllerStatus;
  final ThreadStatus snapshotStatus;
  final int rawEventCount;
  final List<Object> rawErrors;
  final List<_RawEventObservation> rawTimeline;
  final List<_StatusObservation> snapshotTimeline;
  final List<_StatusObservation> controllerTimeline;
  final List<String> debugLogs;

  _RawEventObservation? get firstPrematureRawNonRunningStatus {
    final lastStreamingAt = _lastStreamingActivityAt;
    if (lastStreamingAt == null) {
      return null;
    }
    for (final event in rawTimeline) {
      if (event.status == null || event.status == 'running') {
        continue;
      }
      if (!_hasTurnStartedBefore(event.at)) {
        continue;
      }
      if (event.at < lastStreamingAt && _hasStreamingActivityAfter(event.at)) {
        return event;
      }
    }
    return null;
  }

  _StatusObservation? get firstPrematureSnapshotNonRunningStatus {
    for (final observation in snapshotTimeline) {
      if (observation.status == ThreadStatus.running) {
        continue;
      }
      if (!_hasTurnStartedBefore(observation.at)) {
        continue;
      }
      if (_hasStreamingActivityAfter(observation.at)) {
        return observation;
      }
    }
    return null;
  }

  _StatusObservation? get firstPrematureControllerNonRunningStatus {
    for (final observation in controllerTimeline) {
      if (observation.status == ThreadStatus.running) {
        continue;
      }
      if (!_hasTurnStartedBefore(observation.at)) {
        continue;
      }
      if (_hasStreamingActivityAfter(observation.at)) {
        return observation;
      }
    }
    return null;
  }

  Duration? get _lastStreamingActivityAt {
    for (final event in rawTimeline.reversed) {
      if (_isStreamingActivity(event.kind)) {
        return event.at;
      }
    }
    return null;
  }

  bool _hasStreamingActivityAfter(Duration at) {
    for (final event in rawTimeline) {
      if (event.at > at && _isStreamingActivity(event.kind)) {
        return true;
      }
    }
    return false;
  }

  bool _hasTurnStartedBefore(Duration at) {
    for (final event in rawTimeline) {
      if (event.at >= at) {
        break;
      }
      if (event.status == 'running') {
        return true;
      }
    }
    for (final observation in snapshotTimeline) {
      if (observation.at >= at) {
        break;
      }
      if (observation.status == ThreadStatus.running) {
        return true;
      }
    }
    for (final observation in controllerTimeline) {
      if (observation.at >= at) {
        break;
      }
      if (observation.status == ThreadStatus.running) {
        return true;
      }
    }
    return false;
  }

  bool get bridgeLooksStuckRunning =>
      !didSettle &&
      (controllerStatus == ThreadStatus.running ||
          snapshotStatus == ThreadStatus.running);

  bool get hasSuspiciousSymptoms =>
      rawErrors.isNotEmpty ||
      firstPrematureRawNonRunningStatus != null ||
      firstPrematureSnapshotNonRunningStatus != null ||
      firstPrematureControllerNonRunningStatus != null;

  String get likelySource {
    if (rawErrors.isNotEmpty) {
      return 'bridge_stream_error';
    }
    if (firstPrematureRawNonRunningStatus != null) {
      return 'bridge_live_status';
    }
    if (firstPrematureSnapshotNonRunningStatus != null) {
      return 'bridge_snapshot_status';
    }
    if (firstPrematureControllerNonRunningStatus != null) {
      return 'flutter_status_merge';
    }
    if (bridgeLooksStuckRunning) {
      return 'bridge_running_timeout';
    }
    return 'clean';
  }

  String toLogLine() {
    return 'LIVE_STATUS_PROBE_ATTEMPT '
        'attempt=$attempt '
        'thread_id=$threadId '
        'likely_source=$likelySource '
        'did_settle=$didSettle '
        'controller_status=${controllerStatus?.name ?? 'missing'} '
        'snapshot_status=${snapshotStatus.name} '
        'raw_event_count=$rawEventCount '
        'raw_statuses=${_previewStatuses(rawTimeline.where((event) => event.status != null).map((event) => '${event.status}@${event.at.inMilliseconds}ms').toList(growable: false))} '
        'snapshot_statuses=${_previewStatuses(snapshotTimeline.map((event) => '${event.status.name}@${event.at.inMilliseconds}ms').toList(growable: false))} '
        'controller_statuses=${_previewStatuses(controllerTimeline.map((event) => '${event.status.name}@${event.at.inMilliseconds}ms').toList(growable: false))}';
  }

  String toFailureLine() {
    return 'attempt=$attempt '
        'thread_id=$threadId '
        'likely_source=$likelySource '
        'did_settle=$didSettle '
        'controller_status=${controllerStatus?.name ?? 'missing'} '
        'snapshot_status=${snapshotStatus.name} '
        'raw_event_count=$rawEventCount '
        'premature_raw=${firstPrematureRawNonRunningStatus?.describe() ?? 'none'} '
        'premature_snapshot=${firstPrematureSnapshotNonRunningStatus?.describe() ?? 'none'} '
        'premature_controller=${firstPrematureControllerNonRunningStatus?.describe() ?? 'none'} '
        'raw_statuses=${_previewStatuses(rawTimeline.where((event) => event.status != null).map((event) => event.describe()).toList(growable: false))} '
        'tail_raw=${_previewStatuses(rawTimeline.reversed.take(10).toList().reversed.map((event) => event.describe()).toList(growable: false))} '
        'snapshot_statuses=${_previewStatuses(snapshotTimeline.map((event) => event.describe()).toList(growable: false))} '
        'controller_statuses=${_previewStatuses(controllerTimeline.map((event) => event.describe()).toList(growable: false))} '
        'debug=${_previewStatuses(debugLogs)}';
  }

  String _previewStatuses(List<String> values) {
    if (values.isEmpty) {
      return '[]';
    }
    return '[${values.map((value) {
      final sanitized = value.replaceAll('"', "'");
      return sanitized.length <= 120 ? sanitized : '${sanitized.substring(0, 120)}...';
    }).join(' | ')}]';
  }
}

class _StatusSettleResult {
  const _StatusSettleResult({required this.didSettle});

  final bool didSettle;
}

class _RawEventObservation {
  const _RawEventObservation({
    required this.at,
    required this.eventId,
    required this.kind,
    required this.status,
    required this.textPreview,
  });

  final Duration at;
  final String eventId;
  final BridgeEventKind kind;
  final String? status;
  final String textPreview;

  String describe() {
    final suffix = status != null ? ' status=$status' : '';
    final text = textPreview.isEmpty ? '' : ' text="$textPreview"';
    return '${kind.name}@${at.inMilliseconds}ms id=$eventId$suffix$text';
  }
}

class _StatusObservation {
  const _StatusObservation({
    required this.at,
    required this.source,
    required this.status,
  });

  final Duration at;
  final String source;
  final ThreadStatus status;

  String describe() => '$source:${status.name}@${at.inMilliseconds}ms';
}

class _PassthroughHttpOverrides extends HttpOverrides {}

bool _isStreamingActivity(BridgeEventKind kind) {
  return kind != BridgeEventKind.threadStatusChanged;
}

String _resolveBridgeApiBaseUrl() {
  const configured = String.fromEnvironment(
    'LIVE_STATUS_PROBE_BRIDGE_BASE_URL',
  );
  if (configured.isNotEmpty) {
    return configured;
  }

  if (Platform.isAndroid) {
    return 'http://10.0.2.2:3110';
  }

  return 'http://127.0.0.1:3110';
}

int _resolveProbeAttempts() {
  const configured = int.fromEnvironment('LIVE_STATUS_PROBE_ATTEMPTS');
  return configured > 0 ? configured : 5;
}

Duration _resolveProbeTimeout() {
  const configured = int.fromEnvironment('LIVE_STATUS_PROBE_TIMEOUT_SECONDS');
  final seconds = configured > 0 ? configured : 90;
  return Duration(seconds: seconds);
}

String _resolveProbePrompt() {
  const configured = String.fromEnvironment('LIVE_STATUS_PROBE_PROMPT');
  if (configured.isNotEmpty) {
    return configured;
  }

  return 'can you run the tests on emulator in the codex-mobile-companion repo? '
      'please explain what you find while doing it';
}

bool _runLiveStatusProbe() {
  return const bool.fromEnvironment('RUN_LIVE_STATUS_PROBE');
}

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
  Duration step = const Duration(milliseconds: 100),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) {
      return;
    }
    await Future<void>.delayed(step);
  }

  if (!condition()) {
    throw TestFailure('Timed out waiting for an asynchronous condition.');
  }
}
