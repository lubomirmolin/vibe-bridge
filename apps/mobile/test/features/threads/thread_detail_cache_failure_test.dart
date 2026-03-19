import 'dart:async';

import 'package:codex_mobile_companion/features/approvals/data/approval_bridge_api.dart';
import 'package:codex_mobile_companion/features/settings/data/settings_bridge_api.dart';
import 'package:codex_mobile_companion/features/threads/data/thread_cache_repository.dart';
import 'package:codex_mobile_companion/features/threads/data/thread_detail_bridge_api.dart';
import 'package:codex_mobile_companion/features/threads/data/thread_list_bridge_api.dart';
import 'package:codex_mobile_companion/features/threads/data/thread_live_stream.dart';
import 'package:codex_mobile_companion/features/threads/presentation/thread_detail_page.dart';
import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:codex_mobile_companion/foundation/storage/secure_store.dart';
import 'package:codex_mobile_companion/foundation/storage/secure_store_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'detail screen still renders when timeline cache persistence fails',
    (tester) async {
      final detail = _threadDetail();
      final timeline = <ThreadTimelineEntryDto>[
        ThreadTimelineEntryDto(
          eventId: 'evt-1',
          kind: BridgeEventKind.messageDelta,
          occurredAt: '2026-03-19T21:08:19.598412Z',
          summary: 'Assistant output',
          payload: const <String, dynamic>{
            'type': 'agentMessage',
            'role': 'assistant',
            'source': 'assistant',
            'delta': 'Investigating session details loading.',
            'content': [
              {
                'type': 'text',
                'text': 'Investigating session details loading.',
                'text_type': 'output_text',
              },
            ],
          },
        ),
      ];

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appSecureStoreProvider.overrideWithValue(InMemorySecureStore()),
            threadDetailBridgeApiProvider.overrideWithValue(
              _FakeThreadDetailBridgeApi(detail: detail, timeline: timeline),
            ),
            threadListBridgeApiProvider.overrideWithValue(
              _FakeThreadListBridgeApi(
                threads: [
                  ThreadSummaryDto(
                    contractVersion: detail.contractVersion,
                    threadId: detail.threadId,
                    title: detail.title,
                    status: detail.status,
                    workspace: detail.workspace,
                    repository: detail.repository,
                    branch: detail.branch,
                    updatedAt: detail.updatedAt,
                  ),
                ],
              ),
            ),
            approvalBridgeApiProvider.overrideWithValue(
              _EmptyApprovalBridgeApi(),
            ),
            settingsBridgeApiProvider.overrideWithValue(
              _FakeSettingsBridgeApi(),
            ),
            threadLiveStreamProvider.overrideWithValue(_FakeThreadLiveStream()),
            threadCacheRepositoryProvider.overrideWithValue(
              _ThrowingThreadCacheRepository(),
            ),
          ],
          child: MaterialApp(
            home: ThreadDetailPage(
              bridgeApiBaseUrl: 'https://bridge.ts.net',
              threadId: detail.threadId,
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text(detail.title), findsOneWidget);
      expect(find.text("Couldn't load"), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}

class _ThrowingThreadCacheRepository implements ThreadCacheRepository {
  @override
  Future<CachedThreadDetailSnapshot?> readThreadDetail(String threadId) async {
    return null;
  }

  @override
  Future<CachedThreadListSnapshot?> readThreadList() async {
    return null;
  }

  @override
  Future<String?> readSelectedThreadId() async {
    return null;
  }

  @override
  Future<void> saveSelectedThreadId(String threadId) async {}

  @override
  Future<void> saveThreadDetail({
    required ThreadDetailDto detail,
    required List<ThreadTimelineEntryDto> timeline,
  }) async {
    throw StateError('secure store rejected oversized payload');
  }

  @override
  Future<void> saveThreadList(List<ThreadSummaryDto> threads) async {}
}

class _FakeThreadDetailBridgeApi implements ThreadDetailBridgeApi {
  const _FakeThreadDetailBridgeApi({
    required this.detail,
    required this.timeline,
  });

  final ThreadDetailDto detail;
  final List<ThreadTimelineEntryDto> timeline;

  @override
  Future<ThreadDetailDto> fetchThreadDetail({
    required String bridgeApiBaseUrl,
    required String threadId,
  }) async => detail;

  @override
  Future<List<ThreadTimelineEntryDto>> fetchThreadTimeline({
    required String bridgeApiBaseUrl,
    required String threadId,
  }) async => timeline;

  @override
  Future<GitStatusResponseDto> fetchGitStatus({
    required String bridgeApiBaseUrl,
    required String threadId,
  }) async {
    return GitStatusResponseDto(
      contractVersion: detail.contractVersion,
      threadId: detail.threadId,
      repository: RepositoryContextDto(
        workspace: detail.workspace,
        repository: detail.repository,
        branch: detail.branch,
        remote: 'local',
      ),
      status: const GitStatusDto(dirty: false, aheadBy: 0, behindBy: 0),
    );
  }

  @override
  Future<TurnMutationResult> interruptTurn({
    required String bridgeApiBaseUrl,
    required String threadId,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<OpenOnMacResponseDto> openOnMac({
    required String bridgeApiBaseUrl,
    required String threadId,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<MutationResultResponseDto> pullRepository({
    required String bridgeApiBaseUrl,
    required String threadId,
    String? remote,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<MutationResultResponseDto> pushRepository({
    required String bridgeApiBaseUrl,
    required String threadId,
    String? remote,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<TurnMutationResult> startTurn({
    required String bridgeApiBaseUrl,
    required String threadId,
    required String prompt,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<TurnMutationResult> steerTurn({
    required String bridgeApiBaseUrl,
    required String threadId,
    required String instruction,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<MutationResultResponseDto> switchBranch({
    required String bridgeApiBaseUrl,
    required String threadId,
    required String branch,
  }) {
    throw UnimplementedError();
  }
}

class _FakeThreadListBridgeApi implements ThreadListBridgeApi {
  const _FakeThreadListBridgeApi({required this.threads});

  final List<ThreadSummaryDto> threads;

  @override
  Future<List<ThreadSummaryDto>> fetchThreads({
    required String bridgeApiBaseUrl,
  }) async => threads;
}

class _FakeThreadLiveStream implements ThreadLiveStream {
  @override
  Future<ThreadLiveSubscription> subscribe({
    required String bridgeApiBaseUrl,
    String? threadId,
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

class _EmptyApprovalBridgeApi implements ApprovalBridgeApi {
  @override
  Future<ApprovalResolutionResponseDto> approve({
    required String bridgeApiBaseUrl,
    required String approvalId,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<AccessMode> fetchAccessMode({required String bridgeApiBaseUrl}) async {
    return AccessMode.fullControl;
  }

  @override
  Future<List<ApprovalRecordDto>> fetchApprovals({
    required String bridgeApiBaseUrl,
  }) async {
    return const <ApprovalRecordDto>[];
  }

  @override
  Future<ApprovalResolutionResponseDto> reject({
    required String bridgeApiBaseUrl,
    required String approvalId,
  }) {
    throw UnimplementedError();
  }
}

class _FakeSettingsBridgeApi implements SettingsBridgeApi {
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
    required String phoneId,
    required String bridgeId,
    required String sessionToken,
    String actor = 'mobile-device',
  }) async {
    return accessMode;
  }
}

ThreadDetailDto _threadDetail() {
  return const ThreadDetailDto(
    contractVersion: '2026-03-17',
    threadId: 'thread-123',
    title: 'Fix session details loading',
    status: ThreadStatus.completed,
    workspace: '/Users/lubomirmolin/PhpstormProjects/codex-mobile-companion',
    repository: 'codex-mobile-companion',
    branch: 'master',
    createdAt: '2026-03-19T21:07:54.867Z',
    updatedAt: '2026-03-19T21:08:19.598412Z',
    source: 'vscode',
    accessMode: AccessMode.controlWithApprovals,
    lastTurnSummary: 'Investigating session details loading.',
  );
}
