import 'dart:async';

import 'package:vibe_bridge/features/approvals/data/approval_bridge_api.dart';
import 'package:vibe_bridge/features/settings/data/settings_bridge_api.dart';
import 'package:vibe_bridge/features/threads/data/thread_detail_bridge_api.dart';
import 'package:vibe_bridge/features/threads/data/thread_live_stream.dart';
import 'package:vibe_bridge/features/threads/presentation/thread_detail_page.dart';
import 'package:vibe_bridge/foundation/contracts/bridge_contracts.dart';
import 'package:vibe_bridge/foundation/storage/secure_store.dart';
import 'package:vibe_bridge/foundation/storage/secure_store_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _threadId = 'thread-load-more';
const _pageSize = 40;
const _bridgeApiBaseUrl = 'http://integration.test';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'older history loads the expected messages without jumping the visible anchor',
    (tester) async {
      final detailApi = _PaginatedThreadDetailBridgeApi(
        totalMessageCount: 80,
        pageSize: _pageSize,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appSecureStoreProvider.overrideWithValue(InMemorySecureStore()),
            approvalBridgeApiProvider.overrideWithValue(
              const _FakeApprovalBridgeApi(),
            ),
            settingsBridgeApiProvider.overrideWithValue(
              const _FakeSettingsBridgeApi(),
            ),
            threadDetailBridgeApiProvider.overrideWithValue(detailApi),
            threadLiveStreamProvider.overrideWithValue(
              const _IdleThreadLiveStream(),
            ),
          ],
          child: const MaterialApp(
            home: ThreadDetailPage(
              bridgeApiBaseUrl: _bridgeApiBaseUrl,
              threadId: _threadId,
              initialVisibleTimelineEntries: _pageSize,
            ),
          ),
        ),
      );

      await _pumpUntilFound(
        tester,
        find.byKey(const Key('thread-detail-title')),
        timeout: const Duration(seconds: 15),
      );
      await _pumpUntilFound(
        tester,
        find.text('Integration message 079'),
        timeout: const Duration(seconds: 15),
      );

      expect(detailApi.historyRequests.length, 1);
      expect(detailApi.historyRequests.single.before, isNull);
      expect(detailApi.historyRequests.single.limit, _pageSize);
      expect(find.text('Integration message 039'), findsNothing);

      final anchorFinder = find.text('Integration message 040');
      await _scrollUntilVisibleInThread(tester, anchorFinder);
      await tester.drag(
        find.byKey(const Key('thread-detail-scroll-view')),
        const Offset(0, 120),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await _pumpUntilFound(
        tester,
        anchorFinder,
        timeout: const Duration(seconds: 5),
      );
      final anchorTopBefore = tester.getTopLeft(anchorFinder).dy;
      await _triggerLoadMoreFromAnchor(
        tester,
        detailApi,
        anchorFinder: anchorFinder,
      );
      await _pumpUntil(
        tester,
        () => detailApi.completedHistoryRequests >= 2,
        timeout: const Duration(seconds: 15),
      );
      await tester.pumpAndSettle();

      expect(detailApi.historyRequests.length, 2);
      expect(detailApi.historyRequests[1].before, 'evt-040');
      expect(detailApi.historyRequests[1].limit, _pageSize);

      await _pumpUntilFound(
        tester,
        anchorFinder,
        timeout: const Duration(seconds: 5),
      );
      final anchorTopAfter = tester.getTopLeft(anchorFinder).dy;

      final loadedMessageFinder = find.text('Integration message 039');
      await tester.drag(
        find.byKey(const Key('thread-detail-scroll-view')),
        const Offset(0, 140),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(loadedMessageFinder, findsOneWidget);
      expect(
        tester.getTopLeft(loadedMessageFinder).dy,
        lessThan(tester.getTopLeft(anchorFinder).dy),
      );

      debugPrint(
        'THREAD_LOAD_MORE_RESULT '
        'initial_before=${detailApi.historyRequests.first.before ?? 'null'} '
        'load_more_before=${detailApi.historyRequests[1].before} '
        'anchor_before=${anchorTopBefore.toStringAsFixed(1)} '
        'anchor_after=${anchorTopAfter.toStringAsFixed(1)}',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

class _PaginatedThreadDetailBridgeApi implements ThreadDetailBridgeApi {
  _PaginatedThreadDetailBridgeApi({
    required int totalMessageCount,
    required this.pageSize,
  }) : _entries = List<ThreadTimelineEntryDto>.unmodifiable(
         List<ThreadTimelineEntryDto>.generate(
           totalMessageCount,
           (index) => ThreadTimelineEntryDto(
             eventId: 'evt-${index.toString().padLeft(3, '0')}',
             kind: BridgeEventKind.messageDelta,
             occurredAt:
                 '2026-03-29T12:${(index % 60).toString().padLeft(2, '0')}:${(index % 50).toString().padLeft(2, '0')}Z',
             summary: 'Assistant output',
             payload: <String, dynamic>{
               'type': 'agentMessage',
               'delta':
                   'Integration message ${index.toString().padLeft(3, '0')}',
             },
           ),
         ),
       );

  final int pageSize;
  final List<ThreadTimelineEntryDto> _entries;
  final List<_HistoryRequest> historyRequests = <_HistoryRequest>[];
  int completedHistoryRequests = 0;
  static const _olderHistoryDelay = Duration(milliseconds: 450);

  static const _threadDetail = ThreadDetailDto(
    contractVersion: contractVersion,
    threadId: _threadId,
    title: 'Load more pagination',
    status: ThreadStatus.completed,
    workspace: '/workspace/codex-mobile-companion',
    repository: 'codex-mobile-companion',
    branch: 'main',
    createdAt: '2026-03-29T12:00:00Z',
    updatedAt: '2026-03-29T12:59:00Z',
    source: 'integration-test',
    accessMode: AccessMode.controlWithApprovals,
    lastTurnSummary: 'Pagination regression coverage',
  );

  @override
  Future<ModelCatalogDto> fetchModelCatalog({
    required String bridgeApiBaseUrl,
    required ProviderKind provider,
  }) async {
    return fallbackModelCatalogForProvider(provider);
  }

  @override
  Future<SpeechModelStatusDto> fetchSpeechStatus({
    required String bridgeApiBaseUrl,
  }) async {
    return const SpeechModelStatusDto(
      contractVersion: contractVersion,
      provider: 'fluid_audio',
      modelId: 'parakeet-tdt-0.6b-v3-coreml',
      state: SpeechModelState.unsupported,
    );
  }

  @override
  Future<ThreadDetailDto> fetchThreadDetail({
    required String bridgeApiBaseUrl,
    required String threadId,
  }) async {
    return _threadDetail;
  }

  @override
  Future<ThreadUsageDto> fetchThreadUsage({
    required String bridgeApiBaseUrl,
    required String threadId,
  }) async {
    throw const ThreadUsageBridgeException(
      message: 'Usage is unavailable in this test.',
    );
  }

  @override
  Future<ThreadTimelinePageDto> fetchThreadTimelinePage({
    required String bridgeApiBaseUrl,
    required String threadId,
    String? before,
    int limit = 50,
  }) async {
    historyRequests.add(_HistoryRequest(before: before, limit: limit));
    if (before != null) {
      await Future<void>.delayed(_olderHistoryDelay);
    }

    final endIndex = before == null
        ? _entries.length
        : _entries.indexWhere((entry) => entry.eventId == before);
    final normalizedEndIndex = endIndex < 0 ? _entries.length : endIndex;
    final startIndex = normalizedEndIndex - limit < 0
        ? 0
        : normalizedEndIndex - limit;
    final pageEntries = _entries.sublist(startIndex, normalizedEndIndex);
    final hasMoreBefore = startIndex > 0;

    completedHistoryRequests += 1;
    return ThreadTimelinePageDto(
      contractVersion: contractVersion,
      thread: _threadDetail,
      entries: pageEntries,
      nextBefore: hasMoreBefore ? _entries[startIndex].eventId : null,
      hasMoreBefore: hasMoreBefore,
    );
  }

  @override
  Future<List<ThreadTimelineEntryDto>> fetchThreadTimeline({
    required String bridgeApiBaseUrl,
    required String threadId,
  }) async {
    return _entries;
  }

  @override
  Future<ThreadSnapshotDto> createThread({
    required String bridgeApiBaseUrl,
    required String workspace,
    required ProviderKind provider,
    String? model,
  }) {
    throw UnimplementedError('Thread creation is unused in this test.');
  }

  @override
  Future<TurnMutationResult> startTurn({
    required String bridgeApiBaseUrl,
    required String threadId,
    required String prompt,
    TurnMode mode = TurnMode.act,
    List<String> images = const <String>[],
    String? model,
    String? effort,
  }) {
    throw UnimplementedError('Turn submission is unused in this test.');
  }

  @override
  Future<TurnMutationResult> respondToUserInput({
    required String bridgeApiBaseUrl,
    required String threadId,
    required String requestId,
    List<UserInputAnswerDto> answers = const <UserInputAnswerDto>[],
    String? freeText,
    String? model,
    String? effort,
  }) {
    throw UnimplementedError('Plan responses are unused in this test.');
  }

  @override
  Future<TurnMutationResult> steerTurn({
    required String bridgeApiBaseUrl,
    required String threadId,
    required String instruction,
  }) {
    throw UnimplementedError('Turn steering is unused in this test.');
  }

  @override
  Future<TurnMutationResult> interruptTurn({
    required String bridgeApiBaseUrl,
    required String threadId,
    String? turnId,
  }) {
    throw UnimplementedError('Turn interruption is unused in this test.');
  }

  @override
  Future<TurnMutationResult> startCommitAction({
    required String bridgeApiBaseUrl,
    required String threadId,
    String? model,
    String? effort,
  }) {
    throw UnimplementedError('Commit is unused in this test.');
  }

  @override
  Future<OpenOnMacResponseDto> openOnMac({
    required String bridgeApiBaseUrl,
    required String threadId,
  }) async {
    return OpenOnMacResponseDto(
      contractVersion: contractVersion,
      threadId: threadId,
      attemptedUrl: 'codex://thread/$threadId',
      message: 'Open on Mac is unavailable in this integration test.',
      bestEffort: true,
    );
  }

  @override
  Future<GitStatusResponseDto> fetchGitStatus({
    required String bridgeApiBaseUrl,
    required String threadId,
  }) async {
    return const GitStatusResponseDto(
      contractVersion: contractVersion,
      threadId: _threadId,
      repository: RepositoryContextDto(
        workspace: '/workspace/codex-mobile-companion',
        repository: 'codex-mobile-companion',
        branch: 'main',
        remote: 'origin',
      ),
      status: GitStatusDto(dirty: false, aheadBy: 0, behindBy: 0),
    );
  }

  @override
  Future<MutationResultResponseDto> switchBranch({
    required String bridgeApiBaseUrl,
    required String threadId,
    required String branch,
  }) {
    throw UnimplementedError('Branch switching is unused in this test.');
  }

  @override
  Future<MutationResultResponseDto> pullRepository({
    required String bridgeApiBaseUrl,
    required String threadId,
    String? remote,
  }) {
    throw UnimplementedError('Pull is unused in this test.');
  }

  @override
  Future<MutationResultResponseDto> pushRepository({
    required String bridgeApiBaseUrl,
    required String threadId,
    String? remote,
  }) {
    throw UnimplementedError('Push is unused in this test.');
  }

  @override
  Future<SpeechTranscriptionResultDto> transcribeAudio({
    required String bridgeApiBaseUrl,
    required List<int> audioBytes,
    String fileName = 'voice-message.wav',
  }) {
    throw UnimplementedError('Speech transcription is unused in this test.');
  }
}

class _HistoryRequest {
  const _HistoryRequest({required this.before, required this.limit});

  final String? before;
  final int limit;
}

class _IdleThreadLiveStream implements ThreadLiveStream {
  const _IdleThreadLiveStream();

  @override
  Future<ThreadLiveSubscription> subscribe({
    required String bridgeApiBaseUrl,
    String? threadId,
    String? afterEventId,
  }) async {
    final controller =
        StreamController<BridgeEventEnvelope<Map<String, dynamic>>>();
    return ThreadLiveSubscription(
      events: controller.stream,
      close: () async {
        await controller.close();
      },
    );
  }
}

class _FakeApprovalBridgeApi implements ApprovalBridgeApi {
  const _FakeApprovalBridgeApi();

  @override
  Future<AccessMode> fetchAccessMode({required String bridgeApiBaseUrl}) async {
    return AccessMode.controlWithApprovals;
  }

  @override
  Future<List<ApprovalRecordDto>> fetchApprovals({
    required String bridgeApiBaseUrl,
  }) async {
    return const <ApprovalRecordDto>[];
  }

  @override
  Future<ApprovalResolutionResponseDto> approve({
    required String bridgeApiBaseUrl,
    required String approvalId,
  }) {
    throw UnimplementedError('Approval resolution is unused in this test.');
  }

  @override
  Future<ApprovalResolutionResponseDto> reject({
    required String bridgeApiBaseUrl,
    required String approvalId,
  }) {
    throw UnimplementedError('Approval resolution is unused in this test.');
  }
}

class _FakeSettingsBridgeApi implements SettingsBridgeApi {
  const _FakeSettingsBridgeApi();

  @override
  Future<AccessMode> fetchAccessMode({required String bridgeApiBaseUrl}) async {
    return AccessMode.controlWithApprovals;
  }

  @override
  Future<List<SecurityEventRecordDto>> fetchSecurityEvents({
    required String bridgeApiBaseUrl,
  }) async {
    return const <SecurityEventRecordDto>[];
  }

  @override
  Future<AccessMode> setAccessMode({
    required String bridgeApiBaseUrl,
    required AccessMode accessMode,
    String? phoneId,
    String? bridgeId,
    String? sessionToken,
    String? localSessionKind,
    String actor = 'mobile-device',
  }) async {
    return accessMode;
  }
}

Future<void> _scrollUntilVisibleInThread(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final scrollable = find.byKey(const Key('thread-detail-scroll-view'));
  final endTime = DateTime.now().add(timeout);

  while (DateTime.now().isBefore(endTime)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isNotEmpty) {
      return;
    }

    await tester.drag(scrollable, const Offset(0, 240));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  throw TestFailure('Timed out bringing $finder into view.');
}

Future<void> _triggerLoadMoreFromAnchor(
  WidgetTester tester,
  _PaginatedThreadDetailBridgeApi detailApi, {
  required Finder anchorFinder,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final scrollable = find.byKey(const Key('thread-detail-scroll-view'));
  final endTime = DateTime.now().add(timeout);

  while (DateTime.now().isBefore(endTime)) {
    if (detailApi.historyRequests.length >= 2) {
      return;
    }

    await tester.drag(scrollable, const Offset(0, 120));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  throw TestFailure('Timed out waiting for older history to load.');
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final endTime = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(endTime)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (condition()) {
      return;
    }
  }

  throw TestFailure('Timed out waiting for condition.');
}

Future<void> _pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final endTime = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(endTime)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isNotEmpty) {
      return;
    }
  }

  throw TestFailure('Timed out waiting for $finder.');
}
