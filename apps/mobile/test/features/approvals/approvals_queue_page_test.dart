import 'dart:async';

import 'package:codex_mobile_companion/features/approvals/data/approval_bridge_api.dart';
import 'package:codex_mobile_companion/features/approvals/presentation/approval_detail_page.dart';
import 'package:codex_mobile_companion/features/approvals/presentation/approvals_queue_page.dart';
import 'package:codex_mobile_companion/features/settings/application/runtime_access_mode.dart';
import 'package:codex_mobile_companion/features/threads/data/thread_cache_repository.dart';
import 'package:codex_mobile_companion/features/threads/data/thread_detail_bridge_api.dart';
import 'package:codex_mobile_companion/features/threads/data/thread_list_bridge_api.dart';
import 'package:codex_mobile_companion/features/threads/data/thread_live_stream.dart';
import 'package:codex_mobile_companion/features/threads/presentation/thread_list_page.dart';
import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:codex_mobile_companion/foundation/storage/secure_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'queue and detail show action, origin, and command/file context',
    (tester) async {
      final approvalApi = FakeApprovalBridgeApi(
        accessMode: AccessMode.fullControl,
        approvals: [_pendingApproval()],
      );
      final detailApi = FakeThreadDetailBridgeApi(
        detailByThreadId: {'thread-123': _threadDetail()},
        timelineByThreadId: {'thread-123': _threadTimeline()},
      );

      await _pumpApprovalsApp(
        tester,
        approvalApi: approvalApi,
        detailApi: detailApi,
      );

      expect(find.byKey(const Key('approval-card-approval-1')), findsOneWidget);

      await tester.tap(find.byKey(const Key('approval-card-approval-1')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('approval-detail-action')), findsOneWidget);
      expect(find.text('Git pull'), findsOneWidget);
      expect(
        find.textContaining('Reason: full_control_required'),
        findsOneWidget,
      );
      expect(
        find.textContaining('/workspace/codex-mobile-companion'),
        findsAtLeastNWidgets(1),
      );
      expect(
        find.textContaining('codex-mobile-companion'),
        findsAtLeastNWidgets(1),
      );
      expect(find.textContaining('master (remote: origin)'), findsOneWidget);
      expect(find.textContaining('tail -n 100 app.log'), findsOneWidget);
      expect(find.textContaining('lib/main.dart'), findsOneWidget);
    },
  );

  testWidgets(
    'approval detail loads command and file context from paginated timeline pages without full timeline fetch',
    (tester) async {
      final paginatedTimeline = <ThreadTimelineEntryDto>[
        const ThreadTimelineEntryDto(
          eventId: 'evt-command',
          kind: BridgeEventKind.commandDelta,
          occurredAt: '2026-03-18T10:01:00Z',
          summary: 'Command output',
          payload: {
            'command': 'tail -n 100 app.log',
            'delta': 'running diagnostics...',
          },
        ),
        const ThreadTimelineEntryDto(
          eventId: 'evt-file',
          kind: BridgeEventKind.fileChange,
          occurredAt: '2026-03-18T10:02:00Z',
          summary: 'File change',
          payload: {
            'path': 'lib/main.dart',
            'summary': 'Adjusted parser mapping',
          },
        ),
        for (var index = 0; index < 30; index += 1)
          ThreadTimelineEntryDto(
            eventId: 'evt-message-$index',
            kind: BridgeEventKind.messageDelta,
            occurredAt:
                '2026-03-18T10:${(index + 3).toString().padLeft(2, '0')}:00Z',
            summary: 'Assistant output',
            payload: {'type': 'agentMessage', 'text': 'message-$index'},
          ),
      ];

      final detailApi = FakeThreadDetailBridgeApi(
        detailByThreadId: {'thread-123': _threadDetail()},
        timelineByThreadId: {'thread-123': paginatedTimeline},
      );

      await _pumpApprovalsApp(
        tester,
        approvalApi: FakeApprovalBridgeApi(
          accessMode: AccessMode.fullControl,
          approvals: [_pendingApproval()],
        ),
        detailApi: detailApi,
      );

      await tester.tap(find.byKey(const Key('approval-card-approval-1')));
      await tester.pumpAndSettle();

      expect(find.textContaining('tail -n 100 app.log'), findsOneWidget);
      expect(find.textContaining('lib/main.dart'), findsOneWidget);
      expect(detailApi.fetchThreadTimelineCallCount, 0);
      expect(detailApi.fetchThreadTimelinePageCallCount, greaterThan(1));
    },
  );

  testWidgets('branch-switch approvals show the exact target branch', (
    tester,
  ) async {
    final approvalApi = FakeApprovalBridgeApi(
      accessMode: AccessMode.fullControl,
      approvals: [_branchSwitchApprovalFromBridgeContract()],
    );

    await _pumpApprovalsApp(
      tester,
      approvalApi: approvalApi,
      detailApi: FakeThreadDetailBridgeApi(
        detailByThreadId: {'thread-123': _threadDetail()},
        timelineByThreadId: {'thread-123': _threadTimeline()},
      ),
    );

    await tester.tap(find.byKey(const Key('approval-card-approval-branch')));
    await tester.pumpAndSettle();

    expect(find.text('Target branch: release/hotfix-42'), findsOneWidget);
  });

  testWidgets('full-control mode can approve pending approvals', (
    tester,
  ) async {
    final approvalApi = FakeApprovalBridgeApi(
      accessMode: AccessMode.fullControl,
      approvals: [_pendingApproval()],
    );

    await _pumpApprovalsApp(
      tester,
      approvalApi: approvalApi,
      detailApi: FakeThreadDetailBridgeApi(
        detailByThreadId: {'thread-123': _threadDetail()},
        timelineByThreadId: {'thread-123': _threadTimeline()},
      ),
    );

    await tester.tap(find.byKey(const Key('approval-card-approval-1')));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(const Key('approve-approval-button')),
      300,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('approve-approval-button')));
    await tester.pumpAndSettle();

    expect(
      find.text('Approval was already resolved as approved.'),
      findsOneWidget,
    );
  });

  testWidgets('full-control mode can reject pending approvals', (tester) async {
    final approvalApi = FakeApprovalBridgeApi(
      accessMode: AccessMode.fullControl,
      approvals: [_pendingApproval()],
    );

    await _pumpApprovalsApp(
      tester,
      approvalApi: approvalApi,
      detailApi: FakeThreadDetailBridgeApi(
        detailByThreadId: {'thread-123': _threadDetail()},
        timelineByThreadId: {'thread-123': _threadTimeline()},
      ),
    );

    await tester.tap(find.byKey(const Key('approval-card-approval-1')));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(const Key('reject-approval-button')),
      300,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('reject-approval-button')));
    await tester.pumpAndSettle();

    expect(
      find.text('Approval was already resolved as rejected.'),
      findsOneWidget,
    );
  });

  testWidgets('lower-permission mode keeps approve/reject disabled', (
    tester,
  ) async {
    final approvalApi = FakeApprovalBridgeApi(
      accessMode: AccessMode.controlWithApprovals,
      approvals: [_pendingApproval()],
    );

    await _pumpApprovalsApp(
      tester,
      approvalApi: approvalApi,
      detailApi: FakeThreadDetailBridgeApi(
        detailByThreadId: {'thread-123': _threadDetail()},
        timelineByThreadId: {'thread-123': _threadTimeline()},
      ),
    );

    await tester.tap(find.byKey(const Key('approval-card-approval-1')));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(const Key('approve-approval-button')),
      300,
    );
    await tester.pumpAndSettle();

    final approveButton = tester.widget<ElevatedButton>(
      find.byKey(const Key('approve-approval-button')),
    );
    final rejectButton = tester.widget<ElevatedButton>(
      find.byKey(const Key('reject-approval-button')),
    );

    expect(approveButton.onPressed, isNull);
    expect(rejectButton.onPressed, isNull);
    expect(find.textContaining('only in full-control mode'), findsOneWidget);
  });

  testWidgets(
    'read-only mode keeps approve/reject disabled while approval detail stays visible',
    (tester) async {
      final approvalApi = FakeApprovalBridgeApi(
        accessMode: AccessMode.readOnly,
        approvals: [_pendingApproval()],
      );

      await _pumpApprovalsApp(
        tester,
        approvalApi: approvalApi,
        detailApi: FakeThreadDetailBridgeApi(
          detailByThreadId: {'thread-123': _threadDetail()},
          timelineByThreadId: {'thread-123': _threadTimeline()},
        ),
      );

      await tester.tap(find.byKey(const Key('approval-card-approval-1')));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.byKey(const Key('approve-approval-button')),
        300,
      );
      await tester.pumpAndSettle();

      final approveButton = tester.widget<ElevatedButton>(
        find.byKey(const Key('approve-approval-button')),
      );
      final rejectButton = tester.widget<ElevatedButton>(
        find.byKey(const Key('reject-approval-button')),
      );

      expect(approveButton.onPressed, isNull);
      expect(rejectButton.onPressed, isNull);
      expect(find.textContaining('only in full-control mode'), findsOneWidget);
    },
  );

  testWidgets(
    'read-only mode blocks git switch, pull, and push while thread approvals remain visible',
    (tester) async {
      final approvalApi = FakeApprovalBridgeApi(
        accessMode: AccessMode.readOnly,
        approvals: [_pendingApproval()],
      );

      await _pumpThreadListApp(
        tester,
        approvalApi: approvalApi,
        detailApi: FakeThreadDetailBridgeApi(
          detailByThreadId: {'thread-123': _threadDetail()},
          timelineByThreadId: {'thread-123': _threadTimeline()},
        ),
        listApi: FakeThreadListBridgeApi(threads: [_threadSummary()]),
      );

      await tester.tap(find.byKey(const Key('thread-summary-card-thread-123')));
      await tester.pumpAndSettle();

      expect(find.text('Implement shared contracts'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Pending Approvals'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      expect(find.text('Git pull'), findsOneWidget);
      expect(find.text('Pending'), findsAtLeastNWidgets(1));

      await tester.tap(find.byKey(const Key('git-header-branch-button')));
      await tester.pumpAndSettle();

      final switchButton = tester.widget<FilledButton>(
        find.byKey(const Key('git-branch-switch-button')),
      );
      final navigatorState = tester.state<NavigatorState>(
        find.byType(Navigator).first,
      );
      navigatorState.pop();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('git-header-sync-button')));
      await tester.pumpAndSettle();
      final pullButton = tester.widget<OutlinedButton>(
        find.byKey(const Key('git-pull-button')),
      );
      final pushButton = tester.widget<OutlinedButton>(
        find.byKey(const Key('git-push-button')),
      );
      expect(switchButton.onPressed, isNull);
      expect(pullButton.onPressed, isNull);
      expect(pushButton.onPressed, isNull);
    },
  );

  testWidgets(
    'approval detail mode changes update approve/reject actionability in place',
    (tester) async {
      final approvalApi = FakeApprovalBridgeApi(
        accessMode: AccessMode.fullControl,
        approvals: [_pendingApproval()],
      );

      await _pumpApprovalsApp(
        tester,
        approvalApi: approvalApi,
        detailApi: FakeThreadDetailBridgeApi(
          detailByThreadId: {'thread-123': _threadDetail()},
          timelineByThreadId: {'thread-123': _threadTimeline()},
        ),
      );

      await tester.tap(find.byKey(const Key('approval-card-approval-1')));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.byKey(const Key('approve-approval-button')),
        300,
      );
      await tester.pumpAndSettle();

      var approveButton = tester.widget<ElevatedButton>(
        find.byKey(const Key('approve-approval-button')),
      );
      var rejectButton = tester.widget<ElevatedButton>(
        find.byKey(const Key('reject-approval-button')),
      );

      expect(approveButton.onPressed, isNotNull);
      expect(rejectButton.onPressed, isNotNull);

      final container = ProviderScope.containerOf(
        tester.element(find.byType(ApprovalDetailPage)),
      );
      container
              .read(runtimeAccessModeProvider(_bridgeApiBaseUrl).notifier)
              .state =
          AccessMode.readOnly;
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.byKey(const Key('approve-approval-button')),
        300,
      );
      await tester.pumpAndSettle();

      approveButton = tester.widget<ElevatedButton>(
        find.byKey(const Key('approve-approval-button')),
      );
      rejectButton = tester.widget<ElevatedButton>(
        find.byKey(const Key('reject-approval-button')),
      );

      expect(approveButton.onPressed, isNull);
      expect(rejectButton.onPressed, isNull);
      expect(find.textContaining('only in full-control mode'), findsOneWidget);

      container
              .read(runtimeAccessModeProvider(_bridgeApiBaseUrl).notifier)
              .state =
          AccessMode.fullControl;
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.byKey(const Key('approve-approval-button')),
        300,
      );
      await tester.pumpAndSettle();

      approveButton = tester.widget<ElevatedButton>(
        find.byKey(const Key('approve-approval-button')),
      );
      rejectButton = tester.widget<ElevatedButton>(
        find.byKey(const Key('reject-approval-button')),
      );

      expect(approveButton.onPressed, isNotNull);
      expect(rejectButton.onPressed, isNotNull);
    },
  );

  testWidgets(
    'stale approvals become non-actionable after late resolve attempt',
    (tester) async {
      final approvalApi = FakeApprovalBridgeApi(
        accessMode: AccessMode.fullControl,
        approvals: [_pendingApproval()],
        approveFailureById: {
          'approval-1': const ApprovalResolutionBridgeException(
            message: 'Approval is no longer actionable.',
            statusCode: 409,
            code: 'approval_not_pending',
          ),
        },
        approveFailureResolvedStatusById: {
          'approval-1': ApprovalStatus.approved,
        },
      );

      await _pumpApprovalsApp(
        tester,
        approvalApi: approvalApi,
        detailApi: FakeThreadDetailBridgeApi(
          detailByThreadId: {'thread-123': _threadDetail()},
          timelineByThreadId: {'thread-123': _threadTimeline()},
        ),
      );

      await tester.tap(find.byKey(const Key('approval-card-approval-1')));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.byKey(const Key('approve-approval-button')),
        300,
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('approve-approval-button')));
      await tester.pumpAndSettle();

      expect(
        find.text('Approval is no longer actionable.'),
        findsAtLeastNWidgets(1),
      );
      expect(
        find.textContaining('already resolved as approved'),
        findsAtLeastNWidgets(1),
      );
      expect(approvalApi.fetchApprovalsCallCount, greaterThan(1));
    },
  );

  testWidgets('live approval events refresh the approvals queue', (
    tester,
  ) async {
    final approvalApi = FakeApprovalBridgeApi(
      accessMode: AccessMode.fullControl,
      approvals: const <ApprovalRecordDto>[],
    );
    final liveStream = FakeThreadLiveStream();

    await _pumpApprovalsApp(
      tester,
      approvalApi: approvalApi,
      detailApi: FakeThreadDetailBridgeApi(
        detailByThreadId: {'thread-123': _threadDetail()},
        timelineByThreadId: {'thread-123': _threadTimeline()},
      ),
      liveStream: liveStream,
    );

    expect(find.text('No approvals pending'), findsOneWidget);

    approvalApi.upsertApproval(_pendingApproval());
    liveStream.emit(
      BridgeEventEnvelope<Map<String, dynamic>>(
        contractVersion: contractVersion,
        eventId: 'evt-approval-live-queue',
        threadId: 'thread-123',
        kind: BridgeEventKind.approvalRequested,
        occurredAt: '2026-03-18T10:15:00Z',
        payload: _pendingApproval().toJson(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('approval-card-approval-1')), findsOneWidget);
  });

  testWidgets('live approval events refresh the originating thread surface', (
    tester,
  ) async {
    final approvalApi = FakeApprovalBridgeApi(
      accessMode: AccessMode.fullControl,
      approvals: const <ApprovalRecordDto>[],
    );
    final liveStream = FakeThreadLiveStream();

    await _pumpThreadListApp(
      tester,
      approvalApi: approvalApi,
      detailApi: FakeThreadDetailBridgeApi(
        detailByThreadId: {'thread-123': _threadDetail()},
        timelineByThreadId: {'thread-123': _threadTimeline()},
      ),
      listApi: FakeThreadListBridgeApi(threads: [_threadSummary()]),
      liveStream: liveStream,
    );

    await tester.tap(find.byKey(const Key('thread-summary-card-thread-123')));
    await tester.pumpAndSettle();

    approvalApi.upsertApproval(_pendingApproval());
    liveStream.emit(
      BridgeEventEnvelope<Map<String, dynamic>>(
        contractVersion: contractVersion,
        eventId: 'evt-approval-live-thread',
        threadId: 'thread-123',
        kind: BridgeEventKind.approvalRequested,
        occurredAt: '2026-03-18T10:15:00Z',
        payload: _pendingApproval().toJson(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('Pending Approvals'),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    expect(find.text('Git pull'), findsOneWidget);
    expect(find.text('Pending'), findsAtLeastNWidgets(1));
  });

  testWidgets('approval detail can open the originating thread page', (
    tester,
  ) async {
    final approvalApi = FakeApprovalBridgeApi(
      accessMode: AccessMode.fullControl,
      approvals: [_pendingApproval()],
    );

    await _pumpApprovalsApp(
      tester,
      approvalApi: approvalApi,
      detailApi: FakeThreadDetailBridgeApi(
        detailByThreadId: {'thread-123': _threadDetail()},
        timelineByThreadId: {'thread-123': _threadTimeline()},
      ),
    );
    await tester.tap(find.byKey(const Key('approval-card-approval-1')));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.text('Open originating thread'), 300);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Open originating thread'));
    await tester.pumpAndSettle();

    expect(find.text('Implement shared contracts'), findsOneWidget);
    expect(find.text('Timeline'), findsOneWidget);
  });
}

Future<void> _pumpApprovalsApp(
  WidgetTester tester, {
  required FakeApprovalBridgeApi approvalApi,
  required ThreadDetailBridgeApi detailApi,
  ThreadLiveStream? liveStream,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        approvalBridgeApiProvider.overrideWithValue(approvalApi),
        threadDetailBridgeApiProvider.overrideWithValue(detailApi),
        threadListBridgeApiProvider.overrideWithValue(
          FakeThreadListBridgeApi(threads: [_threadSummary()]),
        ),
        threadLiveStreamProvider.overrideWithValue(
          liveStream ?? FakeThreadLiveStream(),
        ),
        threadCacheRepositoryProvider.overrideWithValue(_newCacheRepository()),
      ],
      child: const MaterialApp(
        home: ApprovalsQueuePage(bridgeApiBaseUrl: _bridgeApiBaseUrl),
      ),
    ),
  );

  await tester.pumpAndSettle();
}

Future<void> _pumpThreadListApp(
  WidgetTester tester, {
  required FakeApprovalBridgeApi approvalApi,
  required ThreadDetailBridgeApi detailApi,
  required ThreadListBridgeApi listApi,
  ThreadLiveStream? liveStream,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        approvalBridgeApiProvider.overrideWithValue(approvalApi),
        threadDetailBridgeApiProvider.overrideWithValue(detailApi),
        threadListBridgeApiProvider.overrideWithValue(listApi),
        threadLiveStreamProvider.overrideWithValue(
          liveStream ?? FakeThreadLiveStream(),
        ),
        threadCacheRepositoryProvider.overrideWithValue(_newCacheRepository()),
      ],
      child: const MaterialApp(
        home: ThreadListPage(bridgeApiBaseUrl: _bridgeApiBaseUrl),
      ),
    ),
  );

  await tester.pumpAndSettle();
}

ThreadCacheRepository _newCacheRepository() {
  return SecureStoreThreadCacheRepository(
    secureStore: InMemorySecureStore(),
    nowUtc: () => DateTime.utc(2026, 3, 18, 10, 0),
  );
}

const _bridgeApiBaseUrl = 'https://bridge.ts.net';

ApprovalRecordDto _pendingApproval() {
  return const ApprovalRecordDto(
    contractVersion: contractVersion,
    approvalId: 'approval-1',
    threadId: 'thread-123',
    action: 'git_pull',
    target: 'git.pull',
    reason: 'full_control_required',
    status: ApprovalStatus.pending,
    requestedAt: '2026-03-18T10:10:00Z',
    resolvedAt: null,
    repository: RepositoryContextDto(
      workspace: '/workspace/codex-mobile-companion',
      repository: 'codex-mobile-companion',
      branch: 'master',
      remote: 'origin',
    ),
    gitStatus: GitStatusDto(dirty: true, aheadBy: 2, behindBy: 1),
  );
}

ApprovalRecordDto _branchSwitchApprovalFromBridgeContract() {
  return ApprovalRecordDto.fromJson(<String, dynamic>{
    'contract_version': contractVersion,
    'approval_id': 'approval-branch',
    'thread_id': 'thread-123',
    'action': 'git_branch_switch',
    'target': 'release/hotfix-42',
    'reason': 'full_control_required',
    'status': 'pending',
    'requested_at': '2026-03-18T10:11:00Z',
    'resolved_at': null,
    'repository': <String, dynamic>{
      'workspace': '/workspace/codex-mobile-companion',
      'repository': 'codex-mobile-companion',
      'branch': 'master',
      'remote': 'origin',
    },
    'git_status': <String, dynamic>{
      'dirty': true,
      'ahead_by': 2,
      'behind_by': 1,
    },
  });
}

ThreadSummaryDto _threadSummary() {
  return const ThreadSummaryDto(
    contractVersion: contractVersion,
    threadId: 'thread-123',
    title: 'Implement shared contracts',
    status: ThreadStatus.running,
    workspace: '/workspace/codex-mobile-companion',
    repository: 'codex-mobile-companion',
    branch: 'master',
    updatedAt: '2026-03-18T10:00:00Z',
  );
}

ThreadDetailDto _threadDetail() {
  return const ThreadDetailDto(
    contractVersion: contractVersion,
    threadId: 'thread-123',
    title: 'Implement shared contracts',
    status: ThreadStatus.running,
    workspace: '/workspace/codex-mobile-companion',
    repository: 'codex-mobile-companion',
    branch: 'master',
    createdAt: '2026-03-18T09:45:00Z',
    updatedAt: '2026-03-18T10:00:00Z',
    source: 'cli',
    accessMode: AccessMode.fullControl,
    lastTurnSummary: 'Normalize event payloads',
  );
}

List<ThreadTimelineEntryDto> _threadTimeline() {
  return const [
    ThreadTimelineEntryDto(
      eventId: 'evt-command',
      kind: BridgeEventKind.commandDelta,
      occurredAt: '2026-03-18T10:08:00Z',
      summary: 'Command output',
      payload: {
        'command': 'tail -n 100 app.log',
        'delta': 'running diagnostics...',
      },
    ),
    ThreadTimelineEntryDto(
      eventId: 'evt-file',
      kind: BridgeEventKind.fileChange,
      occurredAt: '2026-03-18T10:09:00Z',
      summary: 'File change',
      payload: {'path': 'lib/main.dart', 'summary': 'Adjusted parser mapping'},
    ),
  ];
}

class FakeApprovalBridgeApi implements ApprovalBridgeApi {
  FakeApprovalBridgeApi({
    required AccessMode accessMode,
    required List<ApprovalRecordDto> approvals,
    this.approveFailureById =
        const <String, ApprovalResolutionBridgeException>{},
    this.rejectFailureById =
        const <String, ApprovalResolutionBridgeException>{},
    this.approveFailureResolvedStatusById = const <String, ApprovalStatus>{},
  }) : _accessMode = accessMode,
       _approvalsById = {
         for (final approval in approvals) approval.approvalId: approval,
       };

  final AccessMode _accessMode;
  final Map<String, ApprovalRecordDto> _approvalsById;
  final Map<String, ApprovalResolutionBridgeException> approveFailureById;
  final Map<String, ApprovalResolutionBridgeException> rejectFailureById;
  final Map<String, ApprovalStatus> approveFailureResolvedStatusById;
  int fetchApprovalsCallCount = 0;

  @override
  Future<AccessMode> fetchAccessMode({required String bridgeApiBaseUrl}) async {
    return _accessMode;
  }

  @override
  Future<List<ApprovalRecordDto>> fetchApprovals({
    required String bridgeApiBaseUrl,
  }) async {
    fetchApprovalsCallCount += 1;
    final approvals = _approvalsById.values.toList(growable: false)
      ..sort((left, right) => right.requestedAt.compareTo(left.requestedAt));
    return approvals;
  }

  @override
  Future<ApprovalResolutionResponseDto> approve({
    required String bridgeApiBaseUrl,
    required String approvalId,
  }) async {
    final failure = approveFailureById[approvalId];
    if (failure != null) {
      final updatedStatus = approveFailureResolvedStatusById[approvalId];
      if (updatedStatus != null) {
        final current = _approvalsById[approvalId];
        if (current != null) {
          _approvalsById[approvalId] = ApprovalRecordDto(
            contractVersion: current.contractVersion,
            approvalId: current.approvalId,
            threadId: current.threadId,
            action: current.action,
            target: current.target,
            reason: current.reason,
            status: updatedStatus,
            requestedAt: current.requestedAt,
            resolvedAt: '2026-03-18T10:12:30Z',
            repository: current.repository,
            gitStatus: current.gitStatus,
          );
        }
      }
      throw failure;
    }

    return _resolve(approvalId: approvalId, approved: true);
  }

  void upsertApproval(ApprovalRecordDto approval) {
    _approvalsById[approval.approvalId] = approval;
  }

  @override
  Future<ApprovalResolutionResponseDto> reject({
    required String bridgeApiBaseUrl,
    required String approvalId,
  }) async {
    final failure = rejectFailureById[approvalId];
    if (failure != null) {
      throw failure;
    }

    return _resolve(approvalId: approvalId, approved: false);
  }

  ApprovalResolutionResponseDto _resolve({
    required String approvalId,
    required bool approved,
  }) {
    final current = _approvalsById[approvalId];
    if (current == null) {
      throw const ApprovalResolutionBridgeException(
        message: 'Approval request was not found.',
        statusCode: 404,
        code: 'approval_not_found',
      );
    }

    final status = approved ? ApprovalStatus.approved : ApprovalStatus.rejected;
    final updated = ApprovalRecordDto(
      contractVersion: current.contractVersion,
      approvalId: current.approvalId,
      threadId: current.threadId,
      action: current.action,
      target: current.target,
      reason: current.reason,
      status: status,
      requestedAt: current.requestedAt,
      resolvedAt: '2026-03-18T10:12:00Z',
      repository: current.repository,
      gitStatus: current.gitStatus,
    );
    _approvalsById[approvalId] = updated;

    return ApprovalResolutionResponseDto(
      contractVersion: contractVersion,
      approval: updated,
      mutationResult: approved
          ? MutationResultResponseDto(
              contractVersion: contractVersion,
              threadId: current.threadId,
              operation: current.action,
              outcome: 'success',
              message: '${current.action} resumed after approval',
              threadStatus: ThreadStatus.running,
              repository: current.repository,
              status: current.gitStatus,
            )
          : null,
    );
  }
}

class FakeThreadDetailBridgeApi implements ThreadDetailBridgeApi {
  FakeThreadDetailBridgeApi({
    required this.detailByThreadId,
    required this.timelineByThreadId,
  });

  final Map<String, ThreadDetailDto> detailByThreadId;
  final Map<String, List<ThreadTimelineEntryDto>> timelineByThreadId;
  int fetchThreadTimelineCallCount = 0;
  int fetchThreadTimelinePageCallCount = 0;

  @override
  Future<ModelCatalogDto> fetchModelCatalog({
    required String bridgeApiBaseUrl,
  }) async {
    return fallbackModelCatalog;
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
  Future<SpeechTranscriptionResultDto> transcribeAudio({
    required String bridgeApiBaseUrl,
    required List<int> audioBytes,
    String fileName = 'voice-message.wav',
  }) async {
    throw const ThreadSpeechBridgeException(message: 'Speech is unused here.');
  }

  @override
  Future<ThreadSnapshotDto> createThread({
    required String bridgeApiBaseUrl,
    required String workspace,
    String? model,
  }) async {
    throw const ThreadCreateBridgeException(
      message: 'Thread creation is not used in approvals tests.',
    );
  }

  @override
  Future<ThreadDetailDto> fetchThreadDetail({
    required String bridgeApiBaseUrl,
    required String threadId,
  }) async {
    final detail = detailByThreadId[threadId];
    if (detail == null) {
      throw const ThreadDetailBridgeException(
        message: 'Thread unavailable',
        isUnavailable: true,
      );
    }
    return detail;
  }

  @override
  Future<List<ThreadTimelineEntryDto>> fetchThreadTimeline({
    required String bridgeApiBaseUrl,
    required String threadId,
  }) async {
    fetchThreadTimelineCallCount += 1;
    return timelineByThreadId[threadId] ?? <ThreadTimelineEntryDto>[];
  }

  @override
  Future<ThreadTimelinePageDto> fetchThreadTimelinePage({
    required String bridgeApiBaseUrl,
    required String threadId,
    String? before,
    int limit = 50,
  }) async {
    fetchThreadTimelinePageCallCount += 1;
    final detail = detailByThreadId[threadId];
    if (detail == null) {
      throw const ThreadDetailBridgeException(
        message: 'Thread unavailable',
        isUnavailable: true,
      );
    }

    final entries =
        timelineByThreadId[threadId] ?? const <ThreadTimelineEntryDto>[];
    final endIndex = before == null
        ? entries.length
        : entries.indexWhere((entry) => entry.eventId == before);
    final normalizedEndIndex = endIndex < 0 ? entries.length : endIndex;
    final startIndex = normalizedEndIndex - limit < 0
        ? 0
        : normalizedEndIndex - limit;
    final pageEntries = entries.sublist(startIndex, normalizedEndIndex);
    final hasMoreBefore = startIndex > 0;
    return ThreadTimelinePageDto(
      contractVersion: contractVersion,
      thread: detail,
      entries: pageEntries,
      nextBefore: hasMoreBefore ? entries[startIndex].eventId : null,
      hasMoreBefore: hasMoreBefore,
    );
  }

  @override
  Future<TurnMutationResult> interruptTurn({
    required String bridgeApiBaseUrl,
    required String threadId,
  }) async {
    return TurnMutationResult(
      contractVersion: contractVersion,
      threadId: threadId,
      operation: 'turn_interrupt',
      outcome: 'success',
      message: 'interrupt sent',
      threadStatus: ThreadStatus.interrupted,
    );
  }

  @override
  Future<TurnMutationResult> startCommitAction({
    required String bridgeApiBaseUrl,
    required String threadId,
    String? model,
    String? effort,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<TurnMutationResult> startTurn({
    required String bridgeApiBaseUrl,
    required String threadId,
    required String prompt,
    List<String> images = const <String>[],
    String? model,
    String? effort,
  }) async {
    return TurnMutationResult(
      contractVersion: contractVersion,
      threadId: threadId,
      operation: 'turn_start',
      outcome: 'success',
      message: 'started',
      threadStatus: ThreadStatus.running,
    );
  }

  @override
  Future<TurnMutationResult> steerTurn({
    required String bridgeApiBaseUrl,
    required String threadId,
    required String instruction,
  }) async {
    return TurnMutationResult(
      contractVersion: contractVersion,
      threadId: threadId,
      operation: 'turn_steer',
      outcome: 'success',
      message: 'steered',
      threadStatus: ThreadStatus.running,
    );
  }

  @override
  Future<GitStatusResponseDto> fetchGitStatus({
    required String bridgeApiBaseUrl,
    required String threadId,
  }) async {
    final detail = await fetchThreadDetail(
      bridgeApiBaseUrl: bridgeApiBaseUrl,
      threadId: threadId,
    );
    return GitStatusResponseDto(
      contractVersion: contractVersion,
      threadId: threadId,
      repository: RepositoryContextDto(
        workspace: detail.workspace,
        repository: detail.repository,
        branch: detail.branch,
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
    final detail = await fetchThreadDetail(
      bridgeApiBaseUrl: bridgeApiBaseUrl,
      threadId: threadId,
    );
    return MutationResultResponseDto(
      contractVersion: contractVersion,
      threadId: threadId,
      operation: 'git_branch_switch',
      outcome: 'success',
      message: 'Switched branch to $branch',
      threadStatus: detail.status,
      repository: RepositoryContextDto(
        workspace: detail.workspace,
        repository: detail.repository,
        branch: branch,
        remote: 'origin',
      ),
      status: const GitStatusDto(dirty: false, aheadBy: 0, behindBy: 0),
    );
  }

  @override
  Future<MutationResultResponseDto> pullRepository({
    required String bridgeApiBaseUrl,
    required String threadId,
    String? remote,
  }) async {
    final detail = await fetchThreadDetail(
      bridgeApiBaseUrl: bridgeApiBaseUrl,
      threadId: threadId,
    );
    return MutationResultResponseDto(
      contractVersion: contractVersion,
      threadId: threadId,
      operation: 'git_pull',
      outcome: 'success',
      message: 'Pull complete',
      threadStatus: detail.status,
      repository: RepositoryContextDto(
        workspace: detail.workspace,
        repository: detail.repository,
        branch: detail.branch,
        remote: remote ?? 'origin',
      ),
      status: const GitStatusDto(dirty: false, aheadBy: 0, behindBy: 0),
    );
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
      message:
          'Requested Codex.app to open the matching shared thread. Desktop refresh is best effort; mobile remains fully usable.',
      bestEffort: true,
    );
  }

  @override
  Future<MutationResultResponseDto> pushRepository({
    required String bridgeApiBaseUrl,
    required String threadId,
    String? remote,
  }) async {
    final detail = await fetchThreadDetail(
      bridgeApiBaseUrl: bridgeApiBaseUrl,
      threadId: threadId,
    );
    return MutationResultResponseDto(
      contractVersion: contractVersion,
      threadId: threadId,
      operation: 'git_push',
      outcome: 'success',
      message: 'Push complete',
      threadStatus: detail.status,
      repository: RepositoryContextDto(
        workspace: detail.workspace,
        repository: detail.repository,
        branch: detail.branch,
        remote: remote ?? 'origin',
      ),
      status: const GitStatusDto(dirty: false, aheadBy: 0, behindBy: 0),
    );
  }
}

class FakeThreadListBridgeApi implements ThreadListBridgeApi {
  FakeThreadListBridgeApi({required this.threads});

  final List<ThreadSummaryDto> threads;

  @override
  Future<List<ThreadSummaryDto>> fetchThreads({
    required String bridgeApiBaseUrl,
  }) async {
    return threads;
  }
}

class FakeThreadLiveStream implements ThreadLiveStream {
  final List<StreamController<BridgeEventEnvelope<Map<String, dynamic>>>>
  _controllers =
      <StreamController<BridgeEventEnvelope<Map<String, dynamic>>>>[];

  @override
  Future<ThreadLiveSubscription> subscribe({
    required String bridgeApiBaseUrl,
    String? threadId,
  }) async {
    final controller =
        StreamController<BridgeEventEnvelope<Map<String, dynamic>>>();
    _controllers.add(controller);
    return ThreadLiveSubscription(
      events: controller.stream,
      close: () async {
        _controllers.remove(controller);
        if (!controller.isClosed) {
          await controller.close();
        }
      },
    );
  }

  void emit(BridgeEventEnvelope<Map<String, dynamic>> event) {
    for (final controller
        in List<
          StreamController<BridgeEventEnvelope<Map<String, dynamic>>>
        >.from(_controllers)) {
      if (!controller.isClosed) {
        controller.add(event);
      }
    }
  }
}
