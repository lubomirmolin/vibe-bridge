import 'dart:async';

import 'package:codex_mobile_companion/features/approvals/data/approval_bridge_api.dart';
import 'package:codex_mobile_companion/features/approvals/presentation/approvals_queue_page.dart';
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
        find.textContaining('Workspace: /workspace/codex-mobile-companion'),
        findsAtLeastNWidgets(1),
      );
      expect(
        find.textContaining('Repository: codex-mobile-companion'),
        findsAtLeastNWidgets(1),
      );
      expect(find.textContaining('Current branch: master'), findsOneWidget);
      expect(find.textContaining('Remote: origin'), findsOneWidget);
      expect(find.textContaining('tail -n 100 app.log'), findsOneWidget);
      expect(find.textContaining('lib/main.dart'), findsOneWidget);
    },
  );

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

    expect(find.textContaining('approved'), findsAtLeastNWidgets(1));
    expect(
      find.textContaining('already resolved as approved'),
      findsAtLeastNWidgets(1),
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

    final approveButton = tester.widget<FilledButton>(
      find.byKey(const Key('approve-approval-button')),
    );
    final rejectButton = tester.widget<OutlinedButton>(
      find.byKey(const Key('reject-approval-button')),
    );

    expect(approveButton.onPressed, isNull);
    expect(rejectButton.onPressed, isNull);
    expect(find.textContaining('only in full-control mode'), findsOneWidget);
  });

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
    },
  );

  testWidgets('resolved approvals sync from queue to thread context panel', (
    tester,
  ) async {
    final approvalApi = FakeApprovalBridgeApi(
      accessMode: AccessMode.fullControl,
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

    await tester.tap(find.byKey(const Key('open-approvals-queue')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('approval-card-approval-1')));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(const Key('approve-approval-button')),
      300,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('approve-approval-button')));
    await tester.pumpAndSettle();

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('thread-summary-card-thread-123')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('thread-approval-status-approval-1')),
      findsOneWidget,
    );
    expect(find.text('Approved'), findsAtLeastNWidgets(1));
  });
}

Future<void> _pumpApprovalsApp(
  WidgetTester tester, {
  required FakeApprovalBridgeApi approvalApi,
  required ThreadDetailBridgeApi detailApi,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        approvalBridgeApiProvider.overrideWithValue(approvalApi),
        threadDetailBridgeApiProvider.overrideWithValue(detailApi),
        threadListBridgeApiProvider.overrideWithValue(
          FakeThreadListBridgeApi(threads: [_threadSummary()]),
        ),
        threadLiveStreamProvider.overrideWithValue(FakeThreadLiveStream()),
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
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        approvalBridgeApiProvider.overrideWithValue(approvalApi),
        threadDetailBridgeApiProvider.overrideWithValue(detailApi),
        threadListBridgeApiProvider.overrideWithValue(listApi),
        threadLiveStreamProvider.overrideWithValue(FakeThreadLiveStream()),
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
  }) : _accessMode = accessMode,
       _approvalsById = {
         for (final approval in approvals) approval.approvalId: approval,
       };

  final AccessMode _accessMode;
  final Map<String, ApprovalRecordDto> _approvalsById;
  final Map<String, ApprovalResolutionBridgeException> approveFailureById;
  final Map<String, ApprovalResolutionBridgeException> rejectFailureById;

  @override
  Future<AccessMode> fetchAccessMode({required String bridgeApiBaseUrl}) async {
    return _accessMode;
  }

  @override
  Future<List<ApprovalRecordDto>> fetchApprovals({
    required String bridgeApiBaseUrl,
  }) async {
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
      throw failure;
    }

    return _resolve(approvalId: approvalId, approved: true);
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
    return timelineByThreadId[threadId] ?? <ThreadTimelineEntryDto>[];
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
  Future<TurnMutationResult> startTurn({
    required String bridgeApiBaseUrl,
    required String threadId,
    required String prompt,
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
  @override
  Future<ThreadLiveSubscription> subscribe({
    required String bridgeApiBaseUrl,
    required String threadId,
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
