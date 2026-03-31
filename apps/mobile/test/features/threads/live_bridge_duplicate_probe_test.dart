import 'dart:async';
import 'dart:io';

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
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'live duplicate probe compares bridge events, bridge timeline, and flutter controller output',
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
      final reports = <_DuplicateProbeAttemptReport>[];

      for (var attempt = 1; attempt <= attempts; attempt += 1) {
        final report = await _runDuplicateProbeAttempt(
          attempt: attempt,
          bridgeApiBaseUrl: bridgeApiBaseUrl,
          workspace: workspace,
          prompt: prompt,
        );
        reports.add(report);
        debugPrint(report.toLogLine());
      }

      final suspicious = reports.where((report) => report.hasDuplicateSymptoms);
      if (suspicious.isNotEmpty) {
        final summary = suspicious
            .map((report) => report.toFailureLine())
            .join('\n');
        fail('LIVE_DUPLICATE_PROBE detected duplicate symptoms:\n$summary');
      }

      debugPrint(
        'LIVE_DUPLICATE_PROBE_SUMMARY '
        'attempts=$attempts '
        'bridge=$bridgeApiBaseUrl '
        'prompt="${prompt.replaceAll('"', "'")}" '
        'result=clean',
      );
    },
    skip: !_runLiveDuplicateProbe(),
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

Future<_DuplicateProbeAttemptReport> _runDuplicateProbeAttempt({
  required int attempt,
  required String bridgeApiBaseUrl,
  required String workspace,
  required String prompt,
}) async {
  final detailApi = HttpThreadDetailBridgeApi();
  final listApi = HttpThreadListBridgeApi();
  final liveStream = HttpThreadLiveStream(transport: const IoBridgeTransport());
  final debugLogs = <String>[];

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

  final rawEvents = <BridgeEventEnvelope<Map<String, dynamic>>>[];
  final rawErrors = <Object>[];
  final rawSubscription = await liveStream.subscribe(
    bridgeApiBaseUrl: bridgeApiBaseUrl,
    threadId: threadId,
  );
  final rawEventSubscription = rawSubscription.events.listen(
    rawEvents.add,
    onError: rawErrors.add,
  );

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

    final submitted = await detailController.submitComposerInput(prompt);
    if (!submitted) {
      throw TestFailure(
        'Attempt $attempt could not submit the duplicate probe prompt.',
      );
    }

    final settleResult = await _waitForTurnToSettle(
      detailController: detailController,
      rawEvents: rawEvents,
    );

    final snapshotAfterProbe = await detailApi.fetchThreadDetail(
      bridgeApiBaseUrl: bridgeApiBaseUrl,
      threadId: threadId,
    );

    final timelinePage = await detailApi
        .fetchThreadTimelinePage(
          bridgeApiBaseUrl: bridgeApiBaseUrl,
          threadId: threadId,
          limit: 200,
        )
        .timeout(
          const Duration(seconds: 10),
          onTimeout: () => throw TestFailure(
            'Attempt $attempt timed out loading the final timeline for $threadId.',
          ),
        );

    final rawUserCount = _countRawMessages(rawEvents, prompt, userOnly: true);
    final timelineUserCount = _countTimelineMessages(
      timelinePage.entries,
      prompt,
      userOnly: true,
    );
    final controllerUserCount = _countControllerMessages(
      detailController.state.items,
      prompt,
      type: ThreadActivityItemType.userPrompt,
    );

    final rawAssistantTexts = _aggregateRawAssistantTexts(rawEvents);
    final timelineAssistantTexts = _extractTimelineAssistantTexts(
      timelinePage.entries,
    );
    final controllerAssistantTexts = _extractControllerAssistantTexts(
      detailController.state.items,
    );

    return _DuplicateProbeAttemptReport(
      attempt: attempt,
      threadId: threadId,
      prompt: prompt,
      didSettle: settleResult.didSettle,
      controllerStatus: detailController.state.thread?.status,
      snapshotStatus: snapshotAfterProbe.status,
      rawEventCount: rawEvents.length,
      controllerItemCount: detailController.state.items.length,
      rawErrors: List<Object>.unmodifiable(rawErrors),
      rawUserCount: rawUserCount,
      timelineUserCount: timelineUserCount,
      controllerUserCount: controllerUserCount,
      rawAssistantTexts: List<String>.unmodifiable(rawAssistantTexts),
      timelineAssistantTexts: List<String>.unmodifiable(timelineAssistantTexts),
      controllerAssistantTexts: List<String>.unmodifiable(
        controllerAssistantTexts,
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
    fail('Live bridge did not expose any workspace for the duplicate probe.');
  }
  return workspace;
}

Future<_TurnSettleResult> _waitForTurnToSettle({
  required ThreadDetailController detailController,
  required List<BridgeEventEnvelope<Map<String, dynamic>>> rawEvents,
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 45));
  var lastEventCount = rawEvents.length;
  var lastEventAt = DateTime.now();

  while (DateTime.now().isBefore(deadline)) {
    if (rawEvents.length != lastEventCount) {
      lastEventCount = rawEvents.length;
      lastEventAt = DateTime.now();
    }

    final hasAssistantOutput = detailController.state.items.any(
      (item) =>
          item.type == ThreadActivityItemType.assistantOutput &&
          item.body.trim().isNotEmpty,
    );
    final status = detailController.state.thread?.status;
    final quietFor = DateTime.now().difference(lastEventAt);
    final turnLooksSettled =
        hasAssistantOutput &&
        status != ThreadStatus.running &&
        quietFor >= const Duration(seconds: 2);

    if (turnLooksSettled) {
      return _TurnSettleResult(
        didSettle: true,
        controllerStatus: status,
        rawEventCount: rawEvents.length,
        controllerItemCount: detailController.state.items.length,
      );
    }

    await Future<void>.delayed(const Duration(milliseconds: 100));
  }

  return _TurnSettleResult(
    didSettle: false,
    controllerStatus: detailController.state.thread?.status,
    rawEventCount: rawEvents.length,
    controllerItemCount: detailController.state.items.length,
  );
}

int _countRawMessages(
  List<BridgeEventEnvelope<Map<String, dynamic>>> events,
  String targetText, {
  required bool userOnly,
}) {
  final normalizedTarget = _normalizeProbeText(targetText);
  return events.where((event) {
    if (event.kind != BridgeEventKind.messageDelta) {
      return false;
    }
    if (userOnly && !_isUserPayload(event.payload)) {
      return false;
    }
    if (!userOnly && _isUserPayload(event.payload)) {
      return false;
    }

    return _normalizeProbeText(_messageText(event.payload) ?? '') ==
        normalizedTarget;
  }).length;
}

int _countTimelineMessages(
  List<ThreadTimelineEntryDto> entries,
  String targetText, {
  required bool userOnly,
}) {
  final normalizedTarget = _normalizeProbeText(targetText);
  return entries.where((entry) {
    if (entry.kind != BridgeEventKind.messageDelta) {
      return false;
    }
    if (userOnly && !_isUserPayload(entry.payload)) {
      return false;
    }
    if (!userOnly && _isUserPayload(entry.payload)) {
      return false;
    }

    return _normalizeProbeText(_messageText(entry.payload) ?? '') ==
        normalizedTarget;
  }).length;
}

int _countControllerMessages(
  List<ThreadActivityItem> items,
  String targetText, {
  required ThreadActivityItemType type,
}) {
  final normalizedTarget = _normalizeProbeText(targetText);
  return items.where((item) {
    return item.type == type &&
        _normalizeProbeText(item.body) == normalizedTarget;
  }).length;
}

List<String> _aggregateRawAssistantTexts(
  List<BridgeEventEnvelope<Map<String, dynamic>>> events,
) {
  final mergedByEventId = <String, String>{};

  for (final event in events) {
    if (event.kind != BridgeEventKind.messageDelta ||
        _isUserPayload(event.payload)) {
      continue;
    }

    final eventId = event.eventId;
    final payload = event.payload;
    final nextText = _messageText(payload);
    if (nextText == null || nextText.trim().isEmpty) {
      continue;
    }

    final replace = payload['replace'] == true;
    final previous = mergedByEventId[eventId] ?? '';
    mergedByEventId[eventId] = replace ? nextText : '$previous$nextText';
  }

  return mergedByEventId.values
      .map(_normalizeProbeText)
      .where((text) => text.isNotEmpty)
      .toList(growable: false);
}

List<String> _extractTimelineAssistantTexts(
  List<ThreadTimelineEntryDto> entries,
) {
  return entries
      .where(
        (entry) =>
            entry.kind == BridgeEventKind.messageDelta &&
            !_isUserPayload(entry.payload),
      )
      .map((entry) => _normalizeProbeText(_messageText(entry.payload) ?? ''))
      .where((text) => text.isNotEmpty)
      .toList(growable: false);
}

List<String> _extractControllerAssistantTexts(List<ThreadActivityItem> items) {
  return items
      .where((item) => item.type == ThreadActivityItemType.assistantOutput)
      .map((item) => _normalizeProbeText(item.body))
      .where((text) => text.isNotEmpty)
      .toList(growable: false);
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

  final content = payload['content'];
  if (content is List) {
    final parts = <String>[];
    for (final entry in content) {
      if (entry is! Map<String, dynamic>) {
        continue;
      }
      final part = entry['text'];
      if (part is String && part.trim().isNotEmpty) {
        parts.add(part.trim());
      }
    }
    if (parts.isNotEmpty) {
      return parts.join('\n');
    }
  }

  return null;
}

bool _isUserPayload(Map<String, dynamic> payload) {
  final role = payload['role'];
  if (role is String && role.toLowerCase() == 'user') {
    return true;
  }

  final source = payload['source'];
  if (source is String && source.toLowerCase() == 'user') {
    return true;
  }

  final type = payload['type'];
  return type is String && type == 'userMessage';
}

String _normalizeProbeText(String text) {
  return text.replaceAll(RegExp(r'\s+'), ' ').trim();
}

bool _looksLikeAdjacentDuplicateText(String text) {
  final normalized = _normalizeProbeText(text);
  if (normalized.length < 16) {
    return false;
  }

  final maxWindow = normalized.length ~/ 2;
  for (var window = 8; window <= maxWindow; window += 1) {
    for (var index = 0; index + (window * 2) <= normalized.length; index += 1) {
      final left = normalized.substring(index, index + window);
      final right = normalized.substring(index + window, index + (window * 2));
      if (left == right && left.trim().length >= 8) {
        return true;
      }
    }
  }

  return false;
}

class _DuplicateProbeAttemptReport {
  const _DuplicateProbeAttemptReport({
    required this.attempt,
    required this.threadId,
    required this.prompt,
    required this.didSettle,
    required this.controllerStatus,
    required this.snapshotStatus,
    required this.rawEventCount,
    required this.controllerItemCount,
    required this.rawErrors,
    required this.rawUserCount,
    required this.timelineUserCount,
    required this.controllerUserCount,
    required this.rawAssistantTexts,
    required this.timelineAssistantTexts,
    required this.controllerAssistantTexts,
    required this.debugLogs,
  });

  final int attempt;
  final String threadId;
  final String prompt;
  final bool didSettle;
  final ThreadStatus? controllerStatus;
  final ThreadStatus snapshotStatus;
  final int rawEventCount;
  final int controllerItemCount;
  final List<Object> rawErrors;
  final int rawUserCount;
  final int timelineUserCount;
  final int controllerUserCount;
  final List<String> rawAssistantTexts;
  final List<String> timelineAssistantTexts;
  final List<String> controllerAssistantTexts;
  final List<String> debugLogs;

  bool get bridgeLooksStuckRunning =>
      !didSettle &&
      (controllerStatus == ThreadStatus.running ||
          snapshotStatus == ThreadStatus.running);

  bool get bridgeShowsDuplicatePrompt =>
      rawUserCount > 1 || timelineUserCount > 1;

  bool get flutterShowsDuplicatePrompt =>
      controllerUserCount > 1 && !bridgeShowsDuplicatePrompt;

  bool get bridgeShowsDuplicatedAssistantText =>
      rawAssistantTexts.any(_looksLikeAdjacentDuplicateText) ||
      timelineAssistantTexts.any(_looksLikeAdjacentDuplicateText);

  bool get flutterShowsDuplicatedAssistantText =>
      controllerAssistantTexts.any(_looksLikeAdjacentDuplicateText) &&
      !bridgeShowsDuplicatedAssistantText;

  bool get hasDuplicateSymptoms =>
      rawErrors.isNotEmpty ||
      bridgeLooksStuckRunning ||
      bridgeShowsDuplicatePrompt ||
      flutterShowsDuplicatePrompt ||
      bridgeShowsDuplicatedAssistantText ||
      flutterShowsDuplicatedAssistantText;

  String get likelySource {
    if (rawErrors.isNotEmpty) {
      return 'bridge_stream_error';
    }
    if (bridgeLooksStuckRunning) {
      return 'bridge_running_timeout';
    }
    if (bridgeShowsDuplicatePrompt || bridgeShowsDuplicatedAssistantText) {
      return 'bridge';
    }
    if (flutterShowsDuplicatePrompt || flutterShowsDuplicatedAssistantText) {
      return 'flutter';
    }
    return 'clean';
  }

  String toLogLine() {
    return 'LIVE_DUPLICATE_PROBE_ATTEMPT '
        'attempt=$attempt '
        'thread_id=$threadId '
        'likely_source=$likelySource '
        'did_settle=$didSettle '
        'controller_status=${controllerStatus?.name ?? 'missing'} '
        'snapshot_status=${snapshotStatus.name} '
        'raw_event_count=$rawEventCount '
        'controller_item_count=$controllerItemCount '
        'raw_user_count=$rawUserCount '
        'timeline_user_count=$timelineUserCount '
        'controller_user_count=$controllerUserCount '
        'raw_assistant=${_previewList(rawAssistantTexts)} '
        'timeline_assistant=${_previewList(timelineAssistantTexts)} '
        'controller_assistant=${_previewList(controllerAssistantTexts)}';
  }

  String toFailureLine() {
    return 'attempt=$attempt '
        'thread_id=$threadId '
        'likely_source=$likelySource '
        'did_settle=$didSettle '
        'controller_status=${controllerStatus?.name ?? 'missing'} '
        'snapshot_status=${snapshotStatus.name} '
        'raw_event_count=$rawEventCount '
        'controller_item_count=$controllerItemCount '
        'raw_user_count=$rawUserCount '
        'timeline_user_count=$timelineUserCount '
        'controller_user_count=$controllerUserCount '
        'raw_errors=${rawErrors.map((error) => error.runtimeType).join(",")} '
        'raw_assistant=${_previewList(rawAssistantTexts)} '
        'timeline_assistant=${_previewList(timelineAssistantTexts)} '
        'controller_assistant=${_previewList(controllerAssistantTexts)} '
        'debug=${_previewList(debugLogs)}';
  }

  String _previewList(List<String> values) {
    if (values.isEmpty) {
      return '[]';
    }
    return '[${values.map((value) {
      final sanitized = value.replaceAll('"', "'");
      return sanitized.length <= 80 ? sanitized : '${sanitized.substring(0, 80)}...';
    }).join(' | ')}]';
  }
}

class _TurnSettleResult {
  const _TurnSettleResult({
    required this.didSettle,
    required this.controllerStatus,
    required this.rawEventCount,
    required this.controllerItemCount,
  });

  final bool didSettle;
  final ThreadStatus? controllerStatus;
  final int rawEventCount;
  final int controllerItemCount;
}

class _PassthroughHttpOverrides extends HttpOverrides {}

String _resolveBridgeApiBaseUrl() {
  const configured = String.fromEnvironment(
    'LIVE_DUPLICATE_PROBE_BRIDGE_BASE_URL',
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
  const configured = int.fromEnvironment('LIVE_DUPLICATE_PROBE_ATTEMPTS');
  return configured > 0 ? configured : 5;
}

String _resolveProbePrompt() {
  const configured = String.fromEnvironment('LIVE_DUPLICATE_PROBE_PROMPT');
  if (configured.isNotEmpty) {
    return configured;
  }

  return 'how are we doing the thread title?';
}

bool _runLiveDuplicateProbe() {
  return const bool.fromEnvironment('RUN_LIVE_DUPLICATE_PROBE');
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
