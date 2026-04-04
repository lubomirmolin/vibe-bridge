import 'dart:async';

import 'package:vibe_bridge/foundation/platform/app_platform.dart';
import 'package:vibe_bridge/foundation/startup/local_desktop_bridge_api.dart';
import 'package:vibe_bridge/features/approvals/data/approval_bridge_api.dart';
import 'package:vibe_bridge/features/threads/data/thread_cache_repository.dart';
import 'package:vibe_bridge/features/threads/data/thread_list_bridge_api.dart';
import 'package:vibe_bridge/features/threads/data/thread_live_stream.dart';
import 'package:vibe_bridge/foundation/contracts/bridge_contracts.dart';
import 'package:vibe_bridge/foundation/storage/secure_store.dart';
import 'package:vibe_bridge/features/bridges/application/pairing_controller.dart';
import 'package:vibe_bridge/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'mobile startup resolves to pairing when desktop mode is absent',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appPlatformProvider.overrideWithValue(
              const AppPlatform(isWeb: false, isDesktop: false),
            ),
            secureStoreProvider.overrideWithValue(InMemorySecureStore()),
          ],
          child: const VibeBridgeApp(),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1200));

      expect(find.text('Initialize Pairing'), findsOneWidget);
    },
  );

  testWidgets('desktop startup opens thread list when localhost bridge is up', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appPlatformProvider.overrideWithValue(
            const AppPlatform(isWeb: false, isDesktop: true),
          ),
          localDesktopConfigProvider.overrideWithValue(
            const LocalDesktopConfig(
              enabled: true,
              bridgeApiBaseUrl: 'http://127.0.0.1:3110',
            ),
          ),
          localDesktopBridgeApiProvider.overrideWithValue(
            const _FakeLocalDesktopBridgeApi(
              LocalDesktopBridgeProbeResult.reachable(),
            ),
          ),
          threadListBridgeApiProvider.overrideWithValue(
            _FakeThreadListBridgeApi(),
          ),
          threadCacheRepositoryProvider.overrideWithValue(
            SecureStoreThreadCacheRepository(
              secureStore: InMemorySecureStore(),
              nowUtc: () => DateTime.utc(2026, 3, 25, 12, 0),
            ),
          ),
          approvalBridgeApiProvider.overrideWithValue(
            const _EmptyApprovalBridgeApi(),
          ),
          threadLiveStreamProvider.overrideWithValue(
            const _FakeThreadLiveStream(),
          ),
        ],
        child: const VibeBridgeApp(),
      ),
    );

    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('thread-list-title')), findsOneWidget);
    expect(find.text('Active Threads'), findsOneWidget);
    expect(find.text('Initialize Pairing'), findsNothing);
  });

  testWidgets(
    'desktop startup shows a local bridge recovery screen when localhost is down',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appPlatformProvider.overrideWithValue(
              const AppPlatform(isWeb: false, isDesktop: true),
            ),
            localDesktopConfigProvider.overrideWithValue(
              const LocalDesktopConfig(
                enabled: true,
                bridgeApiBaseUrl: 'http://127.0.0.1:3110',
              ),
            ),
            localDesktopBridgeApiProvider.overrideWithValue(
              const _FakeLocalDesktopBridgeApi(
                LocalDesktopBridgeProbeResult.unreachable(
                  errorMessage: 'bridge is not listening',
                ),
              ),
            ),
          ],
          child: const VibeBridgeApp(),
        ),
      );

      await tester.pump();
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('local-desktop-unavailable-view')),
        findsOneWidget,
      );
      expect(find.text('Local bridge unavailable'), findsOneWidget);
      expect(find.text('bridge is not listening'), findsOneWidget);
      expect(find.text('Initialize Pairing'), findsNothing);
    },
  );
}

class _FakeLocalDesktopBridgeApi implements LocalDesktopBridgeApi {
  const _FakeLocalDesktopBridgeApi(this.result);

  final LocalDesktopBridgeProbeResult result;

  @override
  Future<LocalDesktopBridgeProbeResult> probe({
    required String bridgeApiBaseUrl,
  }) async {
    return result;
  }
}

class _FakeThreadListBridgeApi implements ThreadListBridgeApi {
  @override
  Future<List<ThreadSummaryDto>> fetchThreads({
    required String bridgeApiBaseUrl,
  }) async {
    return const <ThreadSummaryDto>[
      ThreadSummaryDto(
        contractVersion: contractVersion,
        threadId: 'thread-1',
        title: 'Desktop local thread',
        status: ThreadStatus.running,
        updatedAt: '2026-03-25T10:05:00Z',
        workspace: '/workspace/vibe-bridge-companion',
        repository: 'vibe-bridge-companion',
        branch: 'main',
      ),
    ];
  }
}

class _EmptyApprovalBridgeApi implements ApprovalBridgeApi {
  const _EmptyApprovalBridgeApi();

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
    throw UnimplementedError();
  }

  @override
  Future<ApprovalResolutionResponseDto> reject({
    required String bridgeApiBaseUrl,
    required String approvalId,
  }) {
    throw UnimplementedError();
  }
}

class _FakeThreadLiveStream implements ThreadLiveStream {
  const _FakeThreadLiveStream();

  @override
  Future<ThreadLiveSubscription> subscribe({
    required String bridgeApiBaseUrl,
    String? threadId,
    String? afterEventId,
  }) async {
    return ThreadLiveSubscription(
      events: const Stream<BridgeEventEnvelope<Map<String, dynamic>>>.empty(),
      close: () async {},
    );
  }
}
