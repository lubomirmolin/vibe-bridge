import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vibe_bridge/features/threads/application/thread_detail_controller.dart';
import 'package:vibe_bridge/features/threads/application/thread_list_controller.dart';
import 'package:vibe_bridge/features/threads/data/thread_detail_bridge_api.dart';
import 'package:vibe_bridge/features/threads/data/thread_list_bridge_api.dart';
import 'package:vibe_bridge/features/threads/data/thread_live_stream.dart';
import 'package:vibe_bridge/features/threads/domain/thread_activity_item.dart';
import 'package:vibe_bridge/features/threads/presentation/thread_list_page.dart';
import 'package:vibe_bridge/foundation/contracts/bridge_contracts.dart';
import 'package:vibe_bridge/foundation/network/bridge_transport_io.dart';
import 'package:vibe_bridge/foundation/storage/secure_store.dart';
import 'package:vibe_bridge/foundation/storage/secure_store_provider.dart';

import 'support/live_codex_turn_wait.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'real bridge Codex diagnostics probe captures duplicate user messages and missing tool items after a second turn',
    (tester) async {
      final bridgeApiBaseUrl = _resolveBridgeApiBaseUrl();
      await _requireAndroidLoopbackDevice(bridgeApiBaseUrl);

      final workspacePath = _resolveWorkspacePath();
      final threadApi = HttpThreadDetailBridgeApi();
      final threadListApi = HttpThreadListBridgeApi();

      await _ensureWorkspaceAvailable(
        threadApi: threadApi,
        threadListApi: threadListApi,
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        workspacePath: workspacePath,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appSecureStoreProvider.overrideWithValue(InMemorySecureStore()),
          ],
          child: MaterialApp(
            home: ThreadListPage(
              bridgeApiBaseUrl: bridgeApiBaseUrl,
              autoOpenPreviouslySelectedThread: false,
            ),
          ),
        ),
      );

      await _pumpUntilFound(
        tester,
        find.byKey(const Key('thread-list-create-button')),
        timeout: const Duration(seconds: 20),
      );

      await tester.tap(find.byKey(const Key('thread-list-create-button')));
      await tester.pumpAndSettle();

      await _selectWorkspaceForDraft(tester, workspacePath: workspacePath);
      await _pumpUntilFound(
        tester,
        find.byKey(const Key('thread-draft-title')),
        timeout: const Duration(seconds: 12),
      );

      final firstPrompt = _buildFirstProbePrompt();
      final secondPrompt = _buildSecondProbePrompt();

      await _submitPrompt(tester, prompt: firstPrompt);

      final createdThreadId = await _waitForSelectedThreadId(
        tester,
        bridgeApiBaseUrl,
        expectedPrefix: 'codex:',
        timeout: const Duration(seconds: 25),
      );

      await waitForCodexTurnCompletion(
        tester,
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        threadId: createdThreadId,
        promptLabel: 'first',
        expectedPrompt: firstPrompt,
        expectedUserPromptCount: 1,
      );
      await _waitForThreadControllerToSettle(
        tester,
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        threadId: createdThreadId,
      );

      final args = ThreadDetailControllerArgs(
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        threadId: createdThreadId,
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp)),
      );
      final baselineState = container.read(threadDetailControllerProvider(args));
      final baselineControllerIds = baselineState.items
          .map((item) => item.eventId)
          .toSet();

      final baselineTimelinePage = await threadApi.fetchThreadTimelinePage(
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        threadId: createdThreadId,
        limit: 300,
      );
      final baselineTimelineIds = baselineTimelinePage.entries
          .map((entry) => entry.eventId)
          .toSet();

      final liveStream = HttpThreadLiveStream(
        transport: const IoBridgeTransport(),
      );
      final liveSubscription = await liveStream.subscribe(
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        threadId: createdThreadId,
      );
      final rawEvents = <BridgeEventEnvelope<Map<String, dynamic>>>[];
      final rawEventSubscription = liveSubscription.events.listen(rawEvents.add);

      try {
        await _submitPrompt(tester, prompt: secondPrompt);

        await waitForCodexTurnCompletion(
          tester,
          bridgeApiBaseUrl: bridgeApiBaseUrl,
          threadId: createdThreadId,
          promptLabel: 'second',
          expectedPrompt: secondPrompt,
          expectedUserPromptCount: 2,
        );
        await _waitForThreadControllerToSettle(
          tester,
          bridgeApiBaseUrl: bridgeApiBaseUrl,
          threadId: createdThreadId,
        );
        await tester.pump(const Duration(seconds: 2));
      } finally {
        await rawEventSubscription.cancel();
        await liveSubscription.close();
      }

      final finalState = container.read(threadDetailControllerProvider(args));
      final finalTimelinePage = await threadApi.fetchThreadTimelinePage(
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        threadId: createdThreadId,
        limit: 300,
      );
      final finalSnapshot = await fetchThreadSnapshotJson(
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        threadId: createdThreadId,
      );

      final newControllerItems = finalState.items
          .where((item) => !baselineControllerIds.contains(item.eventId))
          .toList(growable: false);
      final newTimelineEntries = finalTimelinePage.entries
          .where((entry) => !baselineTimelineIds.contains(entry.eventId))
          .toList(growable: false);
      final snapshotEntries =
          (finalSnapshot['entries'] as List<dynamic>? ?? const <dynamic>[])
              .whereType<Map<String, dynamic>>()
              .toList(growable: false);

      final report = _TwoTurnDiagnosticsReport(
        threadId: createdThreadId,
        firstPrompt: firstPrompt,
        secondPrompt: secondPrompt,
        controllerStatus: finalState.thread?.status.wireValue ?? 'unknown',
        snapshotStatus:
            ((finalSnapshot['thread'] as Map<String, dynamic>?)?['status']
                        as String?)
                    ?.trim() ??
                'unknown',
        rawSecondTurnEvents: rawEvents
            .map(_RawEventDiagnostic.fromEvent)
            .toList(growable: false),
        newTimelineEntries: newTimelineEntries
            .map(_TimelineEntryDiagnostic.fromEntry)
            .toList(growable: false),
        newControllerItems: newControllerItems
            .map(_ControllerItemDiagnostic.fromItem)
            .toList(growable: false),
        snapshotUserPrompts: _extractSnapshotUserPrompts(snapshotEntries),
        timelineUserPrompts: _extractTimelineUserPrompts(finalTimelinePage.entries),
        controllerUserPrompts: _extractControllerUserPrompts(finalState.items),
        snapshotToolEntries: _countSnapshotToolEntries(snapshotEntries),
        timelineToolEntries: _countTimelineToolEntries(finalTimelinePage.entries),
        controllerToolItems: _countControllerToolItems(finalState.items),
      );

      debugPrint('LIVE_CODEX_TWO_TURN_DIAGNOSTICS_START');
      debugPrint(const JsonEncoder.withIndent('  ').convert(report.toJson()));
      debugPrint('LIVE_CODEX_TWO_TURN_DIAGNOSTICS_END');

      final normalizedSecondPrompt = _normalizeText(secondPrompt);
      final controllerSecondPromptCount = report.controllerUserPrompts
          .where((prompt) => prompt == normalizedSecondPrompt)
          .length;
      final timelineSecondPromptCount = report.timelineUserPrompts
          .where((prompt) => prompt == normalizedSecondPrompt)
          .length;

      if (controllerSecondPromptCount > 1 || timelineSecondPromptCount > 1) {
        fail(
          'Detected duplicate second-turn user prompt. '
          'controller_count=$controllerSecondPromptCount '
          'timeline_count=$timelineSecondPromptCount '
          'thread_id=$createdThreadId',
        );
      }

      if (report.timelineToolEntries > 0 && report.controllerToolItems == 0) {
        fail(
          'Bridge timeline contains tool/file activity but Flutter controller rendered none. '
          'timeline_tool_entries=${report.timelineToolEntries} '
          'controller_tool_items=${report.controllerToolItems} '
          'thread_id=$createdThreadId',
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

const String _defaultFirstProbePrompt =
    'Review this repository README as an open-source landing page. '
    'Inspect the local README.md and any nearby repo context you need. '
    'Reply in exactly 3 short bullet points. '
    'Do not edit files and do not ask for approval.';

const String _defaultSecondProbePrompt =
    'I was thinking like R2 explorer ... the github repo has nice readme';

String _buildFirstProbePrompt() {
  const configured = String.fromEnvironment(
    'LIVE_CODEX_THREAD_CREATION_PROMPT_ONE',
  );
  if (configured.isNotEmpty) {
    return configured;
  }
  return _defaultFirstProbePrompt;
}

String _buildSecondProbePrompt() {
  const configured = String.fromEnvironment(
    'LIVE_CODEX_THREAD_CREATION_PROMPT_TWO',
  );
  if (configured.isNotEmpty) {
    return configured;
  }
  return _defaultSecondProbePrompt;
}

String _resolveBridgeApiBaseUrl() {
  const configured = String.fromEnvironment(
    'LIVE_CODEX_THREAD_CREATION_BRIDGE_BASE_URL',
  );
  if (configured.isNotEmpty) {
    return configured;
  }

  return 'http://10.0.2.2:3110';
}

String _resolveWorkspacePath() {
  const configured = String.fromEnvironment(
    'LIVE_CODEX_THREAD_CREATION_WORKSPACE',
  );
  if (configured.isNotEmpty) {
    return configured;
  }

  return '/Users/lubomirmolin/PhpstormProjects/codex-mobile-companion';
}

Future<void> _requireAndroidLoopbackDevice(String bridgeApiBaseUrl) async {
  if (!Platform.isAndroid) {
    fail(
      'This live bridge integration test only supports Android devices. '
      'Run it with `flutter drive --driver=test_driver/integration_test.dart --target=integration_test/live_codex_two_turn_diagnostics_test.dart -d <android-device-id>`.',
    );
  }

  final androidInfo = await DeviceInfoPlugin().androidInfo;
  if (androidInfo.isPhysicalDevice &&
      !_usesLoopbackBridgeUrl(bridgeApiBaseUrl)) {
    fail(
      'This live bridge integration test only supports physical Android devices '
      'when the bridge URL is loopback-backed via `adb reverse`, for example '
      '`http://127.0.0.1:3310`.',
    );
  }
}

bool _usesLoopbackBridgeUrl(String bridgeApiBaseUrl) {
  final uri = Uri.tryParse(bridgeApiBaseUrl);
  final host = uri?.host.trim().toLowerCase() ?? '';
  return host == '127.0.0.1' || host == 'localhost';
}

Future<void> _ensureWorkspaceAvailable({
  required HttpThreadDetailBridgeApi threadApi,
  required HttpThreadListBridgeApi threadListApi,
  required String bridgeApiBaseUrl,
  required String workspacePath,
}) async {
  final threads = await threadListApi.fetchThreads(
    bridgeApiBaseUrl: bridgeApiBaseUrl,
  );
  final hasWorkspace = threads.any(
    (thread) => thread.workspace.trim() == workspacePath,
  );
  if (hasWorkspace) {
    return;
  }

  await threadApi.createThread(
    bridgeApiBaseUrl: bridgeApiBaseUrl,
    workspace: workspacePath,
    provider: ProviderKind.codex,
  );
}

Future<void> _selectWorkspaceForDraft(
  WidgetTester tester, {
  required String workspacePath,
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  final preferredOption = find.byKey(
    Key('thread-list-workspace-option-$workspacePath'),
  );

  while (DateTime.now().isBefore(deadline)) {
    if (find.byKey(const Key('thread-draft-title')).evaluate().isNotEmpty) {
      return;
    }

    if (preferredOption.evaluate().isNotEmpty) {
      await tester.tap(preferredOption);
      await tester.pumpAndSettle();
      return;
    }

    final anyWorkspaceOption = find.byWidgetPredicate((widget) {
      return widget.key is Key &&
          (widget.key as Key).toString().contains(
            'thread-list-workspace-option-',
          );
    });
    if (anyWorkspaceOption.evaluate().isNotEmpty) {
      await tester.tap(anyWorkspaceOption.first);
      await tester.pumpAndSettle();
      return;
    }

    await tester.pump(const Duration(milliseconds: 150));
  }

  fail('Timed out waiting for draft workspace selection or direct draft open.');
}

Future<void> _submitPrompt(
  WidgetTester tester, {
  required String prompt,
}) async {
  await _pumpUntilFound(
    tester,
    find.byKey(const Key('turn-composer-input')),
    timeout: const Duration(seconds: 20),
  );
  await _pumpUntilFound(
    tester,
    find.byKey(const Key('turn-composer-submit')),
    timeout: const Duration(seconds: 20),
  );

  await tester.enterText(find.byKey(const Key('turn-composer-input')), prompt);
  await tester.pump();
  await tester.tap(find.byKey(const Key('turn-composer-submit')));
  await tester.pump();
  _tryHideTestKeyboard(tester);
  await tester.pumpAndSettle();
}

Future<String> _waitForSelectedThreadId(
  WidgetTester tester,
  String bridgeApiBaseUrl, {
  String? expectedPrefix,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final container = ProviderScope.containerOf(
    tester.element(find.byType(MaterialApp)),
  );
  final deadline = DateTime.now().add(timeout);

  while (DateTime.now().isBefore(deadline)) {
    final state = container.read(
      threadListControllerProvider(bridgeApiBaseUrl),
    );
    final selectedThreadId = state.selectedThreadId?.trim();
    if (selectedThreadId != null &&
        selectedThreadId.isNotEmpty &&
        (expectedPrefix == null ||
            selectedThreadId.startsWith(expectedPrefix))) {
      return selectedThreadId;
    }
    await tester.pump(const Duration(milliseconds: 150));
  }

  fail(
    'Timed out waiting for selected thread id'
    '${expectedPrefix == null ? '' : ' with prefix $expectedPrefix'}.',
  );
}

Future<void> _waitForThreadControllerToSettle(
  WidgetTester tester, {
  required String bridgeApiBaseUrl,
  required String threadId,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final args = ThreadDetailControllerArgs(
    bridgeApiBaseUrl: bridgeApiBaseUrl,
    threadId: threadId,
  );
  final container = ProviderScope.containerOf(
    tester.element(find.byType(MaterialApp)),
  );
  final deadline = DateTime.now().add(timeout);

  while (DateTime.now().isBefore(deadline)) {
    final state = container.read(threadDetailControllerProvider(args));
    if (!state.isLoading &&
        state.hasThread &&
        !state.isComposerMutationInFlight) {
      return;
    }
    await tester.pump(const Duration(milliseconds: 200));
  }

  final state = container.read(threadDetailControllerProvider(args));
  fail(
    'Timed out waiting for thread detail controller to settle for $threadId. '
    'isLoading=${state.isLoading} '
    'hasThread=${state.hasThread} '
    'isComposerMutationInFlight=${state.isComposerMutationInFlight} '
    'status=${state.thread?.status.wireValue}',
  );
}

List<String> _extractSnapshotUserPrompts(List<Map<String, dynamic>> entries) {
  return entries
      .where((entry) => entry['kind'] == BridgeEventKind.messageDelta.wireValue)
      .map((entry) => entry['payload'])
      .whereType<Map<String, dynamic>>()
      .where((payload) => (payload['role'] as String?)?.trim() == 'user')
      .map(_extractPayloadText)
      .where((text) => text.isNotEmpty)
      .toList(growable: false);
}

List<String> _extractTimelineUserPrompts(List<ThreadTimelineEntryDto> entries) {
  return entries
      .map(ThreadActivityItem.fromTimelineEntry)
      .where((item) => item.type == ThreadActivityItemType.userPrompt)
      .map((item) => _normalizeText(item.body))
      .where((text) => text.isNotEmpty)
      .toList(growable: false);
}

List<String> _extractControllerUserPrompts(List<ThreadActivityItem> items) {
  return items
      .where((item) => item.type == ThreadActivityItemType.userPrompt)
      .map((item) => _normalizeText(item.body))
      .where((text) => text.isNotEmpty)
      .toList(growable: false);
}

int _countSnapshotToolEntries(List<Map<String, dynamic>> entries) {
  return entries.where((entry) {
    final kind = entry['kind'] as String?;
    return kind == BridgeEventKind.commandDelta.wireValue ||
        kind == BridgeEventKind.fileChange.wireValue;
  }).length;
}

int _countTimelineToolEntries(List<ThreadTimelineEntryDto> entries) {
  return entries.where((entry) {
    return entry.kind == BridgeEventKind.commandDelta ||
        entry.kind == BridgeEventKind.fileChange;
  }).length;
}

int _countControllerToolItems(List<ThreadActivityItem> items) {
  return items.where((item) {
    return item.type == ThreadActivityItemType.terminalOutput ||
        item.type == ThreadActivityItemType.fileChange;
  }).length;
}

String _extractPayloadText(Map<String, dynamic> payload) {
  final delta = _normalizeText((payload['delta'] as String?) ?? '');
  if (delta.isNotEmpty) {
    return delta;
  }
  final text = _normalizeText((payload['text'] as String?) ?? '');
  if (text.isNotEmpty) {
    return text;
  }
  final content = payload['content'];
  if (content is! List<dynamic>) {
    return '';
  }
  final buffer = StringBuffer();
  for (final part in content) {
    if (part is! Map<String, dynamic>) {
      continue;
    }
    final text = part['text'];
    if (text is String && text.trim().isNotEmpty) {
      buffer.write(text);
    }
  }
  return _normalizeText(buffer.toString());
}

String _normalizeText(String text) {
  return text.replaceAll(RegExp(r'\s+'), ' ').trim();
}

String _previewText(String text, {int maxChars = 120}) {
  final normalized = _normalizeText(text);
  if (normalized.length <= maxChars) {
    return normalized;
  }
  return '${normalized.substring(0, maxChars)}...';
}

Future<void> _pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isNotEmpty) {
      return;
    }
  }

  fail('Timed out waiting for finder: $finder');
}

void _tryHideTestKeyboard(WidgetTester tester) {
  final dynamic binding = tester.binding;
  try {
    binding.testTextInput.hide();
  } catch (_) {
    // Ignore keyboard teardown failures on device runs.
  }
}

class _TwoTurnDiagnosticsReport {
  const _TwoTurnDiagnosticsReport({
    required this.threadId,
    required this.firstPrompt,
    required this.secondPrompt,
    required this.controllerStatus,
    required this.snapshotStatus,
    required this.rawSecondTurnEvents,
    required this.newTimelineEntries,
    required this.newControllerItems,
    required this.snapshotUserPrompts,
    required this.timelineUserPrompts,
    required this.controllerUserPrompts,
    required this.snapshotToolEntries,
    required this.timelineToolEntries,
    required this.controllerToolItems,
  });

  final String threadId;
  final String firstPrompt;
  final String secondPrompt;
  final String controllerStatus;
  final String snapshotStatus;
  final List<_RawEventDiagnostic> rawSecondTurnEvents;
  final List<_TimelineEntryDiagnostic> newTimelineEntries;
  final List<_ControllerItemDiagnostic> newControllerItems;
  final List<String> snapshotUserPrompts;
  final List<String> timelineUserPrompts;
  final List<String> controllerUserPrompts;
  final int snapshotToolEntries;
  final int timelineToolEntries;
  final int controllerToolItems;

  Map<String, Object?> toJson() {
    return {
      'thread_id': threadId,
      'first_prompt': firstPrompt,
      'second_prompt': secondPrompt,
      'controller_status': controllerStatus,
      'snapshot_status': snapshotStatus,
      'snapshot_user_prompts': snapshotUserPrompts,
      'timeline_user_prompts': timelineUserPrompts,
      'controller_user_prompts': controllerUserPrompts,
      'snapshot_tool_entries': snapshotToolEntries,
      'timeline_tool_entries': timelineToolEntries,
      'controller_tool_items': controllerToolItems,
      'raw_second_turn_events': rawSecondTurnEvents
          .map((entry) => entry.toJson())
          .toList(growable: false),
      'new_timeline_entries': newTimelineEntries
          .map((entry) => entry.toJson())
          .toList(growable: false),
      'new_controller_items': newControllerItems
          .map((entry) => entry.toJson())
          .toList(growable: false),
    };
  }
}

class _RawEventDiagnostic {
  const _RawEventDiagnostic({
    required this.eventId,
    required this.kind,
    required this.role,
    required this.preview,
  });

  final String eventId;
  final String kind;
  final String? role;
  final String preview;

  factory _RawEventDiagnostic.fromEvent(
    BridgeEventEnvelope<Map<String, dynamic>> event,
  ) {
    final payload = event.payload;
    return _RawEventDiagnostic(
      eventId: event.eventId,
      kind: event.kind.wireValue,
      role: payload['role'] as String?,
      preview: _previewText(_extractPayloadText(payload)),
    );
  }

  Map<String, Object?> toJson() {
    return {
      'event_id': eventId,
      'kind': kind,
      'role': role,
      'preview': preview,
    };
  }
}

class _TimelineEntryDiagnostic {
  const _TimelineEntryDiagnostic({
    required this.eventId,
    required this.kind,
    required this.summary,
    required this.bodyPreview,
  });

  final String eventId;
  final String kind;
  final String summary;
  final String bodyPreview;

  factory _TimelineEntryDiagnostic.fromEntry(ThreadTimelineEntryDto entry) {
    final item = ThreadActivityItem.fromTimelineEntry(entry);
    return _TimelineEntryDiagnostic(
      eventId: entry.eventId,
      kind: entry.kind.wireValue,
      summary: _previewText(entry.summary),
      bodyPreview: _previewText(item.body),
    );
  }

  Map<String, Object?> toJson() {
    return {
      'event_id': eventId,
      'kind': kind,
      'summary': summary,
      'body_preview': bodyPreview,
    };
  }
}

class _ControllerItemDiagnostic {
  const _ControllerItemDiagnostic({
    required this.eventId,
    required this.type,
    required this.title,
    required this.bodyPreview,
  });

  final String eventId;
  final String type;
  final String title;
  final String bodyPreview;

  factory _ControllerItemDiagnostic.fromItem(ThreadActivityItem item) {
    return _ControllerItemDiagnostic(
      eventId: item.eventId,
      type: item.type.name,
      title: item.title,
      bodyPreview: _previewText(item.body),
    );
  }

  Map<String, Object?> toJson() {
    return {
      'event_id': eventId,
      'type': type,
      'title': title,
      'body_preview': bodyPreview,
    };
  }
}
