import 'dart:async';

import 'package:vibe_bridge/features/approvals/data/approval_bridge_api.dart';
import 'package:vibe_bridge/features/settings/data/settings_bridge_api.dart';
import 'package:vibe_bridge/features/threads/data/thread_cache_repository.dart';
import 'package:vibe_bridge/features/threads/data/thread_detail_bridge_api.dart';
import 'package:vibe_bridge/features/threads/data/thread_list_bridge_api.dart';
import 'package:vibe_bridge/features/threads/data/thread_live_stream.dart';
import 'package:vibe_bridge/features/threads/presentation/thread_list_page.dart';
import 'package:vibe_bridge/foundation/contracts/bridge_contracts.dart';
import 'package:vibe_bridge/foundation/storage/secure_store.dart';
import 'package:vibe_bridge/foundation/storage/secure_store_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _bridgeApiBaseUrl = 'http://integration.test';
const _existingThreadId = 'thread-existing';
const _createdThreadId = 'thread-plan-new';
const _workspace = '/workspace/codex-mobile-companion';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'creating a new thread in plan mode asks questions and submits answers 1/2/3',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final liveStream = _FakeThreadLiveStream();
      final detailApi = _PlanModeThreadDetailBridgeApi(liveStream: liveStream);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appSecureStoreProvider.overrideWithValue(InMemorySecureStore()),
            threadCacheRepositoryProvider.overrideWithValue(
              SecureStoreThreadCacheRepository(
                secureStore: InMemorySecureStore(),
                nowUtc: () => DateTime.utc(2026, 3, 29, 12, 0),
              ),
            ),
            threadListBridgeApiProvider.overrideWithValue(
              const _FakeThreadListBridgeApi(),
            ),
            threadDetailBridgeApiProvider.overrideWithValue(detailApi),
            threadLiveStreamProvider.overrideWithValue(liveStream),
            approvalBridgeApiProvider.overrideWithValue(
              const _FakeApprovalBridgeApi(),
            ),
            settingsBridgeApiProvider.overrideWithValue(
              const _FakeSettingsBridgeApi(),
            ),
          ],
          child: const MaterialApp(
            home: ThreadListPage(bridgeApiBaseUrl: _bridgeApiBaseUrl),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('thread-list-create-button')));
      await tester.pumpAndSettle();

      final workspaceOption = find.byKey(
        const Key('thread-list-workspace-option-$_workspace'),
      );
      if (workspaceOption.evaluate().isNotEmpty) {
        await tester.tap(workspaceOption);
        await tester.pumpAndSettle();
      }

      expect(find.byKey(const Key('thread-draft-title')), findsOneWidget);
      expect(find.byKey(const Key('turn-composer-submit')), findsOneWidget);

      final railRect = tester.getRect(
        find.byKey(const Key('turn-composer-primary-rail')),
      );
      await tester.tapAt(Offset(railRect.right - 5, railRect.center.dy));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('turn-composer-plan-submit')),
        findsOneWidget,
      );

      await tester.enterText(
        find.byKey(const Key('turn-composer-input')),
        'Plan how to add a mobile walkthrough for plan mode in codex-mobile-companion.',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('turn-composer-plan-submit')));
      await tester.pumpAndSettle();

      expect(detailApi.createThreadCallCount, 1);
      expect(detailApi.createdThreadWorkspaces, equals(<String>[_workspace]));
      expect(detailApi.startTurnCalls.length, 1);
      expect(detailApi.startTurnCalls.single.threadId, _createdThreadId);
      expect(detailApi.startTurnCalls.single.mode, TurnMode.plan);
      expect(
        detailApi.startTurnCalls.single.prompt,
        'Plan how to add a mobile walkthrough for plan mode in codex-mobile-companion.',
      );

      await _pumpUntil(
        tester,
        () => liveStream.subscriptionCountFor(_createdThreadId) >= 1,
        description: 'detail live subscription for created thread',
      );
      await _pumpUntilFound(tester, find.text('Clarify the implementation'));

      expect(
        find.byKey(const Key('turn-composer-attach-button')),
        findsNothing,
      );
      expect(find.byKey(const Key('turn-composer-model-button')), findsNothing);

      await tester.tap(find.text('Bridge'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Detailed'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Integration'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('turn-composer-input')),
        'Keep reconnect and list/detail behavior stable.',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('turn-composer-plan-submit')));
      await tester.pumpAndSettle();

      expect(detailApi.respondCalls.length, 1);
      final response = detailApi.respondCalls.single;
      expect(response.threadId, _createdThreadId);
      expect(response.requestId, 'plan-request-1');
      expect(
        response.answers,
        equals(const <Map<String, String>>[
          <String, String>{'question_id': 'scope', 'option_id': 'bridge'},
          <String, String>{'question_id': 'depth', 'option_id': 'detailed'},
          <String, String>{
            'question_id': 'validation',
            'option_id': 'integration',
          },
        ]),
      );
      expect(
        response.freeText,
        'Keep reconnect and list/detail behavior stable.',
      );
      expect(find.text('Clarify the implementation'), findsNothing);

      debugPrint(
        'PLAN_MODE_RESULT '
        'thread_id=${response.threadId} '
        'mode=${detailApi.startTurnCalls.single.mode.wireValue} '
        'answers=${response.answers.map((entry) => entry['option_id']).join(',')} '
        'free_text=${response.freeText}',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

class _FakeThreadListBridgeApi implements ThreadListBridgeApi {
  const _FakeThreadListBridgeApi();

  @override
  Future<List<ThreadSummaryDto>> fetchThreads({
    required String bridgeApiBaseUrl,
  }) async {
    return const <ThreadSummaryDto>[
      ThreadSummaryDto(
        contractVersion: contractVersion,
        threadId: _existingThreadId,
        title: 'Reconnect fallback polish',
        status: ThreadStatus.completed,
        workspace: _workspace,
        repository: 'codex-mobile-companion',
        branch: 'main',
        updatedAt: '2026-03-29T11:58:00Z',
      ),
    ];
  }
}

class _PlanModeThreadDetailBridgeApi extends ThreadDetailBridgeApi {
  _PlanModeThreadDetailBridgeApi({required this.liveStream});

  final _FakeThreadLiveStream liveStream;
  final List<String> createdThreadWorkspaces = <String>[];
  final List<_StartTurnCall> startTurnCalls = <_StartTurnCall>[];
  final List<_RespondToUserInputCall> respondCalls =
      <_RespondToUserInputCall>[];

  int createThreadCallCount = 0;

  static const ThreadDetailDto _createdThread = ThreadDetailDto(
    contractVersion: contractVersion,
    threadId: _createdThreadId,
    title: 'Plan mode walkthrough',
    status: ThreadStatus.idle,
    workspace: _workspace,
    repository: 'codex-mobile-companion',
    branch: 'main',
    createdAt: '2026-03-29T12:00:00Z',
    updatedAt: '2026-03-29T12:00:00Z',
    source: 'integration-test',
    accessMode: AccessMode.controlWithApprovals,
    lastTurnSummary: '',
  );

  static const PendingUserInputDto _pendingUserInput = PendingUserInputDto(
    requestId: 'plan-request-1',
    title: 'Clarify the implementation',
    detail: 'Choose a concrete plan shape for codex-mobile-companion.',
    questions: <UserInputQuestionDto>[
      UserInputQuestionDto(
        questionId: 'scope',
        prompt: '1. Which area should the plan prioritize?',
        options: <UserInputOptionDto>[
          UserInputOptionDto(
            optionId: 'bridge',
            label: 'Bridge',
            description: '',
            isRecommended: true,
          ),
          UserInputOptionDto(
            optionId: 'mobile',
            label: 'Mobile',
            description: '',
            isRecommended: false,
          ),
          UserInputOptionDto(
            optionId: 'both',
            label: 'Both',
            description: '',
            isRecommended: false,
          ),
        ],
      ),
      UserInputQuestionDto(
        questionId: 'depth',
        prompt: '2. How detailed should the plan be?',
        options: <UserInputOptionDto>[
          UserInputOptionDto(
            optionId: 'sketch',
            label: 'Sketch',
            description: '',
            isRecommended: false,
          ),
          UserInputOptionDto(
            optionId: 'detailed',
            label: 'Detailed',
            description: '',
            isRecommended: true,
          ),
          UserInputOptionDto(
            optionId: 'milestones',
            label: 'Milestones',
            description: '',
            isRecommended: false,
          ),
        ],
      ),
      UserInputQuestionDto(
        questionId: 'validation',
        prompt: '3. What validation should the plan include?',
        options: <UserInputOptionDto>[
          UserInputOptionDto(
            optionId: 'none',
            label: 'None',
            description: '',
            isRecommended: false,
          ),
          UserInputOptionDto(
            optionId: 'widget',
            label: 'Widget',
            description: '',
            isRecommended: false,
          ),
          UserInputOptionDto(
            optionId: 'integration',
            label: 'Integration',
            description: '',
            isRecommended: true,
          ),
        ],
      ),
    ],
  );

  @override
  Future<ThreadSnapshotDto> createThread({
    required String bridgeApiBaseUrl,
    required String workspace,
    required ProviderKind provider,
    String? model,
  }) async {
    createThreadCallCount += 1;
    createdThreadWorkspaces.add(workspace);
    return const ThreadSnapshotDto(
      contractVersion: contractVersion,
      thread: _createdThread,
      entries: <ThreadTimelineEntryDto>[],
      approvals: <ApprovalSummaryDto>[],
    );
  }

  @override
  Future<ThreadDetailDto> fetchThreadDetail({
    required String bridgeApiBaseUrl,
    required String threadId,
  }) async {
    return _createdThread;
  }

  @override
  Future<ThreadTimelinePageDto> fetchThreadTimelinePage({
    required String bridgeApiBaseUrl,
    required String threadId,
    String? before,
    int limit = 50,
  }) async {
    return const ThreadTimelinePageDto(
      contractVersion: contractVersion,
      thread: _createdThread,
      entries: <ThreadTimelineEntryDto>[],
      nextBefore: null,
      hasMoreBefore: false,
    );
  }

  @override
  Future<List<ThreadTimelineEntryDto>> fetchThreadTimeline({
    required String bridgeApiBaseUrl,
    required String threadId,
  }) async {
    return const <ThreadTimelineEntryDto>[];
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
  }) async {
    startTurnCalls.add(
      _StartTurnCall(threadId: threadId, prompt: prompt, mode: mode),
    );
    if (mode == TurnMode.plan) {
      unawaited(
        Future<void>.delayed(const Duration(milliseconds: 80), () {
          liveStream.emit(
            BridgeEventEnvelope<Map<String, dynamic>>(
              contractVersion: contractVersion,
              eventId: 'evt-user-input-1',
              threadId: threadId,
              kind: BridgeEventKind.userInputRequested,
              occurredAt: '2026-03-29T12:00:30Z',
              payload: _pendingUserInput.toJson(),
            ),
          );
        }),
      );
    }
    return TurnMutationResult(
      contractVersion: contractVersion,
      threadId: threadId,
      operation: 'turn_start',
      outcome: 'success',
      message: 'Plan request accepted',
      threadStatus: mode == TurnMode.plan
          ? ThreadStatus.completed
          : ThreadStatus.running,
    );
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
  }) async {
    respondCalls.add(
      _RespondToUserInputCall(
        threadId: threadId,
        requestId: requestId,
        answers: answers
            .map(
              (answer) => <String, String>{
                'question_id': answer.questionId,
                'option_id': answer.optionId,
              },
            )
            .toList(growable: false),
        freeText: freeText,
      ),
    );
    return TurnMutationResult(
      contractVersion: contractVersion,
      threadId: threadId,
      operation: 'turn_respond',
      outcome: 'success',
      message: 'Plan answers accepted',
      threadStatus: ThreadStatus.running,
    );
  }

  @override
  Future<TurnMutationResult> steerTurn({
    required String bridgeApiBaseUrl,
    required String threadId,
    required String instruction,
  }) async {
    throw UnimplementedError('Steer is unused in this integration test.');
  }

  @override
  Future<TurnMutationResult> interruptTurn({
    required String bridgeApiBaseUrl,
    required String threadId,
    String? turnId,
  }) async {
    throw UnimplementedError('Interrupt is unused in this integration test.');
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
      message: 'Open on desktop is not used in this integration test.',
      bestEffort: true,
    );
  }

  @override
  Future<GitStatusResponseDto> fetchGitStatus({
    required String bridgeApiBaseUrl,
    required String threadId,
  }) async {
    return GitStatusResponseDto(
      contractVersion: contractVersion,
      threadId: threadId,
      repository: const RepositoryContextDto(
        workspace: _workspace,
        repository: 'codex-mobile-companion',
        branch: 'main',
        remote: 'origin',
      ),
      status: const GitStatusDto(dirty: false, aheadBy: 0, behindBy: 0),
    );
  }

  @override
  Future<MutationResultResponseDto> switchBranch({
    required String bridgeApiBaseUrl,
    required String threadId,
    required String branch,
  }) async {
    throw UnimplementedError('Branch switching is unused in this test.');
  }

  @override
  Future<MutationResultResponseDto> pullRepository({
    required String bridgeApiBaseUrl,
    required String threadId,
    String? remote,
  }) async {
    throw UnimplementedError('Git pull is unused in this test.');
  }

  @override
  Future<MutationResultResponseDto> pushRepository({
    required String bridgeApiBaseUrl,
    required String threadId,
    String? remote,
  }) async {
    throw UnimplementedError('Git push is unused in this test.');
  }
}

class _FakeThreadLiveStream implements ThreadLiveStream {
  final List<_StreamListener> _listeners = <_StreamListener>[];

  @override
  Future<ThreadLiveSubscription> subscribe({
    required String bridgeApiBaseUrl,
    String? threadId,
    String? afterEventId,
  }) async {
    final controller =
        StreamController<BridgeEventEnvelope<Map<String, dynamic>>>();
    final listener = _StreamListener(
      threadId: threadId,
      controller: controller,
    );
    _listeners.add(listener);
    return ThreadLiveSubscription(
      events: controller.stream,
      close: () async {
        _listeners.remove(listener);
        await controller.close();
      },
    );
  }

  int subscriptionCountFor(String? threadId) {
    return _listeners.where((listener) => listener.threadId == threadId).length;
  }

  void emit(BridgeEventEnvelope<Map<String, dynamic>> event) {
    for (final listener in List<_StreamListener>.from(_listeners)) {
      if (listener.threadId == null || listener.threadId == event.threadId) {
        listener.controller.add(event);
      }
    }
  }
}

class _StreamListener {
  const _StreamListener({required this.threadId, required this.controller});

  final String? threadId;
  final StreamController<BridgeEventEnvelope<Map<String, dynamic>>> controller;
}

class _StartTurnCall {
  const _StartTurnCall({
    required this.threadId,
    required this.prompt,
    required this.mode,
  });

  final String threadId;
  final String prompt;
  final TurnMode mode;
}

class _RespondToUserInputCall {
  const _RespondToUserInputCall({
    required this.threadId,
    required this.requestId,
    required this.answers,
    required this.freeText,
  });

  final String threadId;
  final String requestId;
  final List<Map<String, String>> answers;
  final String? freeText;
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
  }) async {
    throw UnimplementedError('Approvals are unused in this integration test.');
  }

  @override
  Future<ApprovalResolutionResponseDto> reject({
    required String bridgeApiBaseUrl,
    required String approvalId,
  }) async {
    throw UnimplementedError('Approvals are unused in this integration test.');
  }
}

class _FakeSettingsBridgeApi implements SettingsBridgeApi {
  const _FakeSettingsBridgeApi();

  @override
  Future<AccessMode> fetchAccessMode({required String bridgeApiBaseUrl}) async {
    return AccessMode.controlWithApprovals;
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

  @override
  Future<List<SecurityEventRecordDto>> fetchSecurityEvents({
    required String bridgeApiBaseUrl,
  }) async {
    return const <SecurityEventRecordDto>[];
  }
}

Future<void> _pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  await _pumpUntil(
    tester,
    () => finder.evaluate().isNotEmpty,
    description: 'finder $finder',
    timeout: timeout,
  );
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  required String description,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (condition()) {
      return;
    }
  }
  fail('Timed out waiting for $description.');
}
