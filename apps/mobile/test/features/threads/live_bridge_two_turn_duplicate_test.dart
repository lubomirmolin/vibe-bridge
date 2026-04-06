import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibe_bridge/features/threads/data/thread_detail_bridge_api.dart';
import 'package:vibe_bridge/features/threads/data/thread_list_bridge_api.dart';
import 'package:vibe_bridge/features/threads/data/thread_live_stream.dart';
import 'package:vibe_bridge/foundation/contracts/bridge_contracts.dart';
import 'package:vibe_bridge/foundation/network/bridge_transport_io.dart';

void main() {
  test(
    'live bridge stream stays aligned with bridge history across two turns',
    () async {
      final previousOverrides = HttpOverrides.current;
      HttpOverrides.global = _PassthroughHttpOverrides();
      addTearDown(() {
        HttpOverrides.global = previousOverrides;
      });

      final bridgeApiBaseUrl = _resolveBridgeApiBaseUrl();
      final workspace = await _resolveWorkspace(bridgeApiBaseUrl);
      final detailApi = HttpThreadDetailBridgeApi();
      final liveStream = HttpThreadLiveStream(
        transport: const IoBridgeTransport(),
      );

      final snapshot = await detailApi
          .createThread(
            bridgeApiBaseUrl: bridgeApiBaseUrl,
            workspace: workspace,
            provider: ProviderKind.codex,
          )
          .timeout(
            const Duration(seconds: 15),
            onTimeout: () => throw TestFailure(
              'Timed out creating a Codex thread via $bridgeApiBaseUrl.',
            ),
          );

      final threadId = snapshot.thread.threadId.trim();
      expect(threadId, isNotEmpty);

      final rawEvents = <BridgeEventEnvelope<Map<String, dynamic>>>[];
      final rawErrors = <Object>[];
      final subscription = await liveStream.subscribe(
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        threadId: threadId,
      );
      final eventSubscription = subscription.events.listen(
        rawEvents.add,
        onError: rawErrors.add,
      );

      try {
        final promptOne = _resolveFirstPrompt();
        final promptTwo = _resolveSecondPrompt();
        final turnOne = await _runTurnAndCapture(
          detailApi: detailApi,
          bridgeApiBaseUrl: bridgeApiBaseUrl,
          threadId: threadId,
          prompt: promptOne,
          rawEvents: rawEvents,
          rawErrors: rawErrors,
        );
        debugPrint(turnOne.toLogLine());

        final turnTwo = await _runTurnAndCapture(
          detailApi: detailApi,
          bridgeApiBaseUrl: bridgeApiBaseUrl,
          threadId: threadId,
          prompt: promptTwo,
          rawEvents: rawEvents,
          rawErrors: rawErrors,
        );
        debugPrint(turnTwo.toLogLine());

        final finalHistoryPage = await detailApi.fetchThreadTimelinePage(
          bridgeApiBaseUrl: bridgeApiBaseUrl,
          threadId: threadId,
          limit: 200,
        );
        final rolloutTruth = await _captureRolloutTruth(
          threadId: threadId,
          promptOne: promptOne,
          promptTwo: promptTwo,
          timelineEntries: finalHistoryPage.entries,
        );
        debugPrint(rolloutTruth.toLogLine());

        final failures = <String>[
          if (!turnOne.isClean) turnOne.toFailureLine(),
          if (!turnTwo.isClean) turnTwo.toFailureLine(),
          if (!rolloutTruth.isAligned) rolloutTruth.toFailureLine(),
        ];
        if (failures.isNotEmpty) {
          fail(
            'LIVE_BRIDGE_TWO_TURN_DUPLICATE detected bridge divergence:\n'
            '${failures.join('\n')}',
          );
        }
      } finally {
        await eventSubscription.cancel();
        await subscription.close();
      }
    },
    skip: !_runLiveBridgeTwoTurnProbe(),
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

Future<_TurnReport> _runTurnAndCapture({
  required HttpThreadDetailBridgeApi detailApi,
  required String bridgeApiBaseUrl,
  required String threadId,
  required String prompt,
  required List<BridgeEventEnvelope<Map<String, dynamic>>> rawEvents,
  required List<Object> rawErrors,
}) async {
  final baselineEventIndex = rawEvents.length;

  await detailApi
      .startTurn(
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        threadId: threadId,
        prompt: prompt,
      )
      .timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw TestFailure(
          'Timed out starting a turn for thread $threadId.',
        ),
      );

  final settleResult = await _waitForBridgeTurnToSettle(
    detailApi: detailApi,
    bridgeApiBaseUrl: bridgeApiBaseUrl,
    threadId: threadId,
    rawEvents: rawEvents,
    baselineEventIndex: baselineEventIndex,
  );

  final historyPage = await detailApi
      .fetchThreadTimelinePage(
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        threadId: threadId,
        limit: 200,
      )
      .timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw TestFailure(
          'Timed out loading thread history for $threadId.',
        ),
      );

  final promptCount = _countTimelineMessages(
    historyPage.entries,
    prompt,
    userOnly: true,
  );
  final turnEvents = rawEvents.sublist(baselineEventIndex);
  final rawAssistantTexts = _aggregateRawAssistantTexts(turnEvents);
  final timelineAssistantTexts = _extractTimelineAssistantTexts(
    historyPage.entries,
  );
  final newTimelineAssistantTexts = timelineAssistantTexts
      .skip(settleResult.timelineAssistantCountBeforeTurn)
      .toList(growable: false);

  return _TurnReport(
    threadId: threadId,
    prompt: prompt,
    didSettle: settleResult.didSettle,
    snapshotStatus: settleResult.snapshotStatus,
    rawEventCount: turnEvents.length,
    rawErrors: List<Object>.unmodifiable(rawErrors),
    promptCount: promptCount,
    duplicateAssistantFrameSamples: List<String>.unmodifiable(
      _collectExactDuplicateAssistantFrameSamples(turnEvents),
    ),
    rawAssistantTexts: List<String>.unmodifiable(rawAssistantTexts),
    timelineAssistantTexts: List<String>.unmodifiable(
      newTimelineAssistantTexts,
    ),
  );
}

Future<_BridgeTurnSettleResult> _waitForBridgeTurnToSettle({
  required HttpThreadDetailBridgeApi detailApi,
  required String bridgeApiBaseUrl,
  required String threadId,
  required List<BridgeEventEnvelope<Map<String, dynamic>>> rawEvents,
  required int baselineEventIndex,
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 90));
  var lastEventCount = rawEvents.length;
  var lastEventAt = DateTime.now();
  var timelineAssistantCountBeforeTurn = 0;

  while (DateTime.now().isBefore(deadline)) {
    if (rawEvents.length != lastEventCount) {
      lastEventCount = rawEvents.length;
      lastEventAt = DateTime.now();
    }

    final detail = await detailApi.fetchThreadDetail(
      bridgeApiBaseUrl: bridgeApiBaseUrl,
      threadId: threadId,
    );
    final historyPage = await detailApi.fetchThreadTimelinePage(
      bridgeApiBaseUrl: bridgeApiBaseUrl,
      threadId: threadId,
      limit: 200,
    );
    final assistantTexts = _extractTimelineAssistantTexts(historyPage.entries);
    timelineAssistantCountBeforeTurn = _countAssistantMessagesBeforeIndex(
      rawEvents,
      baselineEventIndex,
      historyPage.entries,
    );

    final quietFor = DateTime.now().difference(lastEventAt);
    final hasAssistantOutput =
        assistantTexts.length > timelineAssistantCountBeforeTurn;
    final turnLooksSettled =
        hasAssistantOutput &&
        detail.status != ThreadStatus.running &&
        quietFor >= const Duration(seconds: 2);

    if (turnLooksSettled) {
      return _BridgeTurnSettleResult(
        didSettle: true,
        snapshotStatus: detail.status,
        timelineAssistantCountBeforeTurn: timelineAssistantCountBeforeTurn,
      );
    }

    await Future<void>.delayed(const Duration(milliseconds: 250));
  }

  final detail = await detailApi.fetchThreadDetail(
    bridgeApiBaseUrl: bridgeApiBaseUrl,
    threadId: threadId,
  );
  final historyPage = await detailApi.fetchThreadTimelinePage(
    bridgeApiBaseUrl: bridgeApiBaseUrl,
    threadId: threadId,
    limit: 200,
  );
  return _BridgeTurnSettleResult(
    didSettle: false,
    snapshotStatus: detail.status,
    timelineAssistantCountBeforeTurn: _countAssistantMessagesBeforeIndex(
      rawEvents,
      baselineEventIndex,
      historyPage.entries,
    ),
  );
}

int _countAssistantMessagesBeforeIndex(
  List<BridgeEventEnvelope<Map<String, dynamic>>> rawEvents,
  int baselineEventIndex,
  List<ThreadTimelineEntryDto> entries,
) {
  if (baselineEventIndex <= 0) {
    return 0;
  }

  final priorRawAssistantCount = _aggregateRawAssistantTexts(
    rawEvents.take(baselineEventIndex).toList(growable: false),
  ).length;
  final timelineAssistantCount = _extractTimelineAssistantTexts(entries).length;
  return priorRawAssistantCount.clamp(0, timelineAssistantCount);
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

List<String> _aggregateRawAssistantTexts(
  List<BridgeEventEnvelope<Map<String, dynamic>>> events,
) {
  final mergedByEventId = <String, String>{};

  for (final event in events) {
    if (event.kind != BridgeEventKind.messageDelta ||
        _isUserPayload(event.payload)) {
      continue;
    }

    final nextText = _messageText(event.payload);
    if (nextText == null || nextText.trim().isEmpty) {
      continue;
    }

    final previous = mergedByEventId[event.eventId] ?? '';
    mergedByEventId[event.eventId] = _mergeIncrementalText(
      previous,
      nextText,
      event.payload['replace'] == true,
    );
  }

  return mergedByEventId.values
      .map(_normalizeProbeText)
      .where((text) => text.isNotEmpty)
      .toList(growable: false);
}

List<String> _collectExactDuplicateAssistantFrameSamples(
  List<BridgeEventEnvelope<Map<String, dynamic>>> events,
) {
  final seenFingerprints = <String>{};
  final duplicates = <String>[];

  for (final event in events) {
    if (event.kind != BridgeEventKind.messageDelta ||
        _isUserPayload(event.payload)) {
      continue;
    }

    final fingerprint = jsonEncode(<String, Object?>{
      'eventId': event.eventId,
      'occurredAt': event.occurredAt,
      'payload': event.payload,
    });
    if (!seenFingerprints.add(fingerprint)) {
      final delta = _normalizeProbeText(_messageText(event.payload) ?? '');
      duplicates.add(
        'eventId=${event.eventId} '
        'replace=${event.payload['replace'] == true} '
        'delta="${delta.isEmpty ? '<empty>' : delta}"',
      );
    }
  }

  return duplicates;
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

String _mergeIncrementalText(String existing, String incoming, bool replace) {
  if (replace || existing.isEmpty) {
    return incoming;
  }
  if (incoming.isEmpty) {
    return existing;
  }
  if (incoming == existing || existing.startsWith(incoming)) {
    return existing;
  }
  if (incoming.startsWith(existing)) {
    return incoming;
  }

  final overlap = _longestSuffixPrefixOverlap(existing, incoming);
  if (overlap < 2) {
    return '$existing$incoming';
  }
  return '$existing${incoming.substring(overlap)}';
}

int _longestSuffixPrefixOverlap(String existing, String incoming) {
  final maxOverlap = existing.length < incoming.length
      ? existing.length
      : incoming.length;
  for (var overlap = maxOverlap; overlap >= 1; overlap -= 1) {
    final existingSuffix = existing.substring(existing.length - overlap);
    final incomingPrefix = incoming.substring(0, overlap);
    if (existingSuffix == incomingPrefix) {
      return overlap;
    }
  }
  return 0;
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

Future<_RolloutTruthReport> _captureRolloutTruth({
  required String threadId,
  required String promptOne,
  required String promptTwo,
  required List<ThreadTimelineEntryDto> timelineEntries,
}) async {
  try {
    final nativeThreadId = _nativeThreadId(threadId);
    final codexHome = _resolveCodexHome();
    final sessionIndexContainsThread = await _sessionIndexHasThread(
      codexHome: codexHome,
      nativeThreadId: nativeThreadId,
    );
    final rolloutPath = await _resolveRolloutPath(
      codexHome: codexHome,
      nativeThreadId: nativeThreadId,
    );

    final rolloutUserTexts = <String>[];
    final rolloutAssistantTexts = <String>[];
    if (rolloutPath != null) {
      await _collectRolloutMessages(
        rolloutPath: rolloutPath,
        userTexts: rolloutUserTexts,
        assistantTexts: rolloutAssistantTexts,
      );
    }

    final timelineUserTexts = _extractTimelineUserTexts(timelineEntries);
    final timelineAssistantTexts = _extractTimelineAssistantTexts(
      timelineEntries,
    );

    return _RolloutTruthReport(
      threadId: threadId,
      nativeThreadId: nativeThreadId,
      rolloutPath: rolloutPath,
      sessionIndexContainsThread: sessionIndexContainsThread,
      rolloutPromptOneCount: _countNormalizedTextMatches(
        rolloutUserTexts,
        promptOne,
      ),
      rolloutPromptTwoCount: _countNormalizedTextMatches(
        rolloutUserTexts,
        promptTwo,
      ),
      timelinePromptOneCount: _countNormalizedTextMatches(
        timelineUserTexts,
        promptOne,
      ),
      timelinePromptTwoCount: _countNormalizedTextMatches(
        timelineUserTexts,
        promptTwo,
      ),
      rolloutAssistantTexts: List<String>.unmodifiable(rolloutAssistantTexts),
      timelineAssistantTexts: List<String>.unmodifiable(timelineAssistantTexts),
    );
  } on Object catch (error, stackTrace) {
    return _RolloutTruthReport(
      threadId: threadId,
      nativeThreadId: _nativeThreadId(threadId),
      rolloutPath: null,
      sessionIndexContainsThread: false,
      rolloutPromptOneCount: 0,
      rolloutPromptTwoCount: 0,
      timelinePromptOneCount: 0,
      timelinePromptTwoCount: 0,
      rolloutAssistantTexts: const <String>[],
      timelineAssistantTexts: const <String>[],
      error: '$error\n$stackTrace',
    );
  }
}

Future<bool> _sessionIndexHasThread({
  required String codexHome,
  required String nativeThreadId,
}) async {
  final sessionIndexFile = File('$codexHome/session_index.jsonl');
  if (!await sessionIndexFile.exists()) {
    return false;
  }

  await for (final line
      in sessionIndexFile
          .openRead()
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) {
      continue;
    }
    final parsed = jsonDecode(trimmed);
    if (parsed is! Map<String, dynamic>) {
      continue;
    }
    final id = parsed['id'];
    if (id is String && id.trim() == nativeThreadId) {
      return true;
    }
  }

  return false;
}

Future<String?> _resolveRolloutPath({
  required String codexHome,
  required String nativeThreadId,
}) async {
  final sessionsDir = Directory('$codexHome/sessions');
  if (!await sessionsDir.exists()) {
    return null;
  }

  final candidates = <String>[];
  await for (final entity in sessionsDir.list(recursive: true)) {
    if (entity is! File) {
      continue;
    }
    final path = entity.path;
    if (!path.contains('/rollout-') ||
        !path.endsWith('$nativeThreadId.jsonl')) {
      continue;
    }
    candidates.add(path);
  }

  if (candidates.isEmpty) {
    return null;
  }
  candidates.sort();
  return candidates.last;
}

Future<void> _collectRolloutMessages({
  required String rolloutPath,
  required List<String> userTexts,
  required List<String> assistantTexts,
}) async {
  final rolloutFile = File(rolloutPath);
  if (!await rolloutFile.exists()) {
    return;
  }

  await for (final line
      in rolloutFile
          .openRead()
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) {
      continue;
    }
    final parsed = jsonDecode(trimmed);
    if (parsed is! Map<String, dynamic>) {
      continue;
    }
    if (parsed['type'] != 'response_item') {
      continue;
    }
    final payload = parsed['payload'];
    if (payload is! Map<String, dynamic> || payload['type'] != 'message') {
      continue;
    }
    final role = payload['role'];
    if (role is! String) {
      continue;
    }
    final text = _extractRolloutContentText(payload['content']);
    if (text == null || text.isEmpty) {
      continue;
    }
    if (role == 'user') {
      userTexts.add(text);
    } else if (role == 'assistant') {
      assistantTexts.add(text);
    }
  }
}

String? _extractRolloutContentText(Object? content) {
  if (content is! List) {
    return null;
  }
  final parts = <String>[];
  for (final entry in content) {
    if (entry is! Map<String, dynamic>) {
      continue;
    }
    final text = entry['text'];
    if (text is String && text.trim().isNotEmpty) {
      parts.add(_normalizeProbeText(text));
      continue;
    }
    final outputText = entry['output_text'];
    if (outputText is String && outputText.trim().isNotEmpty) {
      parts.add(_normalizeProbeText(outputText));
    }
  }
  if (parts.isEmpty) {
    return null;
  }
  return _normalizeProbeText(parts.join('\n'));
}

List<String> _extractTimelineUserTexts(List<ThreadTimelineEntryDto> entries) {
  return entries
      .where(
        (entry) =>
            entry.kind == BridgeEventKind.messageDelta &&
            _isUserPayload(entry.payload),
      )
      .map((entry) => _normalizeProbeText(_messageText(entry.payload) ?? ''))
      .where((text) => text.isNotEmpty)
      .toList(growable: false);
}

int _countNormalizedTextMatches(List<String> haystack, String target) {
  final normalizedTarget = _normalizeProbeText(target);
  return haystack
      .where((candidate) => _normalizeProbeText(candidate) == normalizedTarget)
      .length;
}

String _nativeThreadId(String threadId) {
  final separator = threadId.indexOf(':');
  if (separator < 0 || separator + 1 >= threadId.length) {
    return threadId.trim();
  }
  return threadId.substring(separator + 1).trim();
}

String _resolveCodexHome() {
  final fromEnv = Platform.environment['CODEX_HOME']?.trim();
  if (fromEnv != null && fromEnv.isNotEmpty) {
    return fromEnv;
  }

  final home = Platform.environment['HOME']?.trim();
  if (home == null || home.isEmpty) {
    throw StateError('HOME is not available; cannot resolve ~/.codex.');
  }
  return '$home/.codex';
}

class _RolloutTruthReport {
  const _RolloutTruthReport({
    required this.threadId,
    required this.nativeThreadId,
    required this.rolloutPath,
    required this.sessionIndexContainsThread,
    required this.rolloutPromptOneCount,
    required this.rolloutPromptTwoCount,
    required this.timelinePromptOneCount,
    required this.timelinePromptTwoCount,
    required this.rolloutAssistantTexts,
    required this.timelineAssistantTexts,
    this.error,
  });

  final String threadId;
  final String nativeThreadId;
  final String? rolloutPath;
  final bool sessionIndexContainsThread;
  final int rolloutPromptOneCount;
  final int rolloutPromptTwoCount;
  final int timelinePromptOneCount;
  final int timelinePromptTwoCount;
  final List<String> rolloutAssistantTexts;
  final List<String> timelineAssistantTexts;
  final String? error;

  bool get assistantListsMatch =>
      listEquals(rolloutAssistantTexts, timelineAssistantTexts);

  bool get isAligned =>
      error == null &&
      sessionIndexContainsThread &&
      rolloutPath != null &&
      rolloutPromptOneCount == 1 &&
      rolloutPromptTwoCount == 1 &&
      timelinePromptOneCount == 1 &&
      timelinePromptTwoCount == 1 &&
      assistantListsMatch;

  String toLogLine() {
    return 'LIVE_BRIDGE_JSONL_TRUTH '
        'thread_id=$threadId '
        'native_thread_id=$nativeThreadId '
        'session_index_contains_thread=$sessionIndexContainsThread '
        'rollout_path=${rolloutPath ?? "<missing>"} '
        'rollout_prompt_one_count=$rolloutPromptOneCount '
        'rollout_prompt_two_count=$rolloutPromptTwoCount '
        'timeline_prompt_one_count=$timelinePromptOneCount '
        'timeline_prompt_two_count=$timelinePromptTwoCount '
        'assistant_lists_match=$assistantListsMatch '
        'rollout_assistant=${_previewList(rolloutAssistantTexts)} '
        'timeline_assistant=${_previewList(timelineAssistantTexts)} '
        'error=${error ?? "<none>"}';
  }

  String toFailureLine() {
    return 'thread_id=$threadId '
        'native_thread_id=$nativeThreadId '
        'session_index_contains_thread=$sessionIndexContainsThread '
        'rollout_path=${rolloutPath ?? "<missing>"} '
        'rollout_prompt_one_count=$rolloutPromptOneCount '
        'rollout_prompt_two_count=$rolloutPromptTwoCount '
        'timeline_prompt_one_count=$timelinePromptOneCount '
        'timeline_prompt_two_count=$timelinePromptTwoCount '
        'assistant_lists_match=$assistantListsMatch '
        'rollout_assistant=${_previewList(rolloutAssistantTexts)} '
        'timeline_assistant=${_previewList(timelineAssistantTexts)} '
        'error=${error ?? "<none>"}';
  }
}

class _TurnReport {
  const _TurnReport({
    required this.threadId,
    required this.prompt,
    required this.didSettle,
    required this.snapshotStatus,
    required this.rawEventCount,
    required this.rawErrors,
    required this.promptCount,
    required this.duplicateAssistantFrameSamples,
    required this.rawAssistantTexts,
    required this.timelineAssistantTexts,
  });

  final String threadId;
  final String prompt;
  final bool didSettle;
  final ThreadStatus snapshotStatus;
  final int rawEventCount;
  final List<Object> rawErrors;
  final int promptCount;
  final List<String> duplicateAssistantFrameSamples;
  final List<String> rawAssistantTexts;
  final List<String> timelineAssistantTexts;

  int get exactDuplicateAssistantFrameCount =>
      duplicateAssistantFrameSamples.length;

  bool get rawShowsDuplicates =>
      rawAssistantTexts.any(_looksLikeAdjacentDuplicateText);

  bool get timelineShowsDuplicates =>
      timelineAssistantTexts.any(_looksLikeAdjacentDuplicateText);

  bool get streamMatchesHistory =>
      listEquals(rawAssistantTexts, timelineAssistantTexts);

  bool get hasAssistantOutput =>
      rawAssistantTexts.isNotEmpty && timelineAssistantTexts.isNotEmpty;

  bool get isClean =>
      didSettle &&
      rawErrors.isEmpty &&
      hasAssistantOutput &&
      promptCount == 1 &&
      exactDuplicateAssistantFrameCount == 0 &&
      !rawShowsDuplicates &&
      !timelineShowsDuplicates;

  String toLogLine() {
    return 'LIVE_BRIDGE_TWO_TURN '
        'thread_id=$threadId '
        'did_settle=$didSettle '
        'snapshot_status=${snapshotStatus.name} '
        'raw_event_count=$rawEventCount '
        'prompt_count=$promptCount '
        'exact_duplicate_assistant_frames=$exactDuplicateAssistantFrameCount '
        'raw_duplicates=$rawShowsDuplicates '
        'timeline_duplicates=$timelineShowsDuplicates '
        'stream_matches_history=$streamMatchesHistory '
        'prompt="${prompt.replaceAll('"', "'")}" '
        'duplicate_frame_samples=${_previewList(duplicateAssistantFrameSamples)} '
        'raw_assistant=${_previewList(rawAssistantTexts)} '
        'timeline_assistant=${_previewList(timelineAssistantTexts)}';
  }

  String toFailureLine() {
    return 'thread_id=$threadId '
        'did_settle=$didSettle '
        'snapshot_status=${snapshotStatus.name} '
        'raw_event_count=$rawEventCount '
        'prompt_count=$promptCount '
        'raw_errors=${rawErrors.map((error) => error.runtimeType).join(",")} '
        'exact_duplicate_assistant_frames=$exactDuplicateAssistantFrameCount '
        'raw_duplicates=$rawShowsDuplicates '
        'timeline_duplicates=$timelineShowsDuplicates '
        'stream_matches_history=$streamMatchesHistory '
        'prompt="${prompt.replaceAll('"', "'")}" '
        'duplicate_frame_samples=${_previewList(duplicateAssistantFrameSamples)} '
        'raw_assistant=${_previewList(rawAssistantTexts)} '
        'timeline_assistant=${_previewList(timelineAssistantTexts)}';
  }
}

class _BridgeTurnSettleResult {
  const _BridgeTurnSettleResult({
    required this.didSettle,
    required this.snapshotStatus,
    required this.timelineAssistantCountBeforeTurn,
  });

  final bool didSettle;
  final ThreadStatus snapshotStatus;
  final int timelineAssistantCountBeforeTurn;
}

class _PassthroughHttpOverrides extends HttpOverrides {}

String _resolveBridgeApiBaseUrl() {
  const configured = String.fromEnvironment(
    'LIVE_BRIDGE_TWO_TURN_DUPLICATE_BASE_URL',
  );
  if (configured.isNotEmpty) {
    return configured;
  }
  return 'http://127.0.0.1:3110';
}

String _resolveFirstPrompt() {
  const configured = String.fromEnvironment('LIVE_BRIDGE_TWO_TURN_PROMPT_ONE');
  if (configured.isNotEmpty) {
    return configured;
  }
  return 'Inspect only apps/mobile/lib/app_startup_page.dart and '
      'apps/mobile/android/app/src/main/res/drawable/launch_background.xml. '
      'Reply in exactly 2 short sentences. Do not edit any files.';
}

String _resolveSecondPrompt() {
  const configured = String.fromEnvironment('LIVE_BRIDGE_TWO_TURN_PROMPT_TWO');
  if (configured.isNotEmpty) {
    return configured;
  }
  return 'Inspect only packages/codex_ui/lib/src/widgets/animated_bridge_background.dart. '
      'Reply in exactly 2 short sentences. Do not edit any files.';
}

bool _runLiveBridgeTwoTurnProbe() {
  return const bool.fromEnvironment('RUN_LIVE_BRIDGE_TWO_TURN_DUPLICATE');
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
