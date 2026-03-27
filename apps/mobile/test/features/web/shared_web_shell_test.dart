import 'dart:async';
import 'dart:typed_data';

import 'package:vibe_bridge/app_startup_page.dart';
import 'package:vibe_bridge/features/approvals/data/approval_bridge_api.dart';
import 'package:vibe_bridge/features/settings/data/settings_bridge_api.dart';
import 'package:vibe_bridge/features/threads/data/thread_cache_repository.dart';
import 'package:vibe_bridge/features/threads/data/thread_detail_bridge_api.dart';
import 'package:vibe_bridge/features/threads/data/thread_list_bridge_api.dart';
import 'package:vibe_bridge/features/threads/data/thread_live_stream.dart';
import 'package:vibe_bridge/features/threads/presentation/thread_detail_page.dart';
import 'package:vibe_bridge/features/threads/presentation/thread_list_page.dart';
import 'package:vibe_bridge/foundation/contracts/bridge_contracts.dart';
import 'package:vibe_bridge/foundation/media/speech_capture.dart';
import 'package:vibe_bridge/foundation/platform/app_platform.dart';
import 'package:vibe_bridge/foundation/startup/local_desktop_bridge_api.dart';
import 'package:vibe_bridge/foundation/storage/secure_store.dart';
import 'package:vibe_bridge/foundation/storage/secure_store_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('startup routes web localhost into the shared thread list', (
    tester,
  ) async {
    await _setDisplaySize(tester, const Size(1400, 900));

    await tester.pumpWidget(
      ProviderScope(
        overrides:
            _baseOverrides(
              threadListApi: _FakeThreadListBridgeApi(_sampleThreads()),
            )..addAll(<Override>[
              appPlatformProvider.overrideWithValue(
                const AppPlatform(isWeb: true, isDesktop: false),
              ),
              localDesktopConfigProvider.overrideWithValue(
                const LocalDesktopConfig(
                  enabled: true,
                  bridgeApiBaseUrl: 'http://127.0.0.1:3110',
                ),
              ),
              localDesktopBridgeApiProvider.overrideWithValue(
                const _FakeLocalDesktopBridgeApi.reachable(),
              ),
            ]),
        child: const MaterialApp(home: AppStartupPage()),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.byKey(const Key('thread-wide-left-pane')), findsOneWidget);
    expect(find.text('Implement shared contracts'), findsOneWidget);
  });

  testWidgets('shared thread list keeps the wide inline layout on web', (
    tester,
  ) async {
    await _setDisplaySize(tester, const Size(1400, 900));

    await tester.pumpWidget(
      ProviderScope(
        overrides: _baseOverrides(
          threadListApi: _FakeThreadListBridgeApi(_sampleThreads()),
        ),
        child: const MaterialApp(
          home: ThreadListPage(bridgeApiBaseUrl: 'http://127.0.0.1:3110'),
        ),
      ),
    );

    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('thread-summary-card-thread-123')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('thread-wide-left-pane')), findsOneWidget);
    expect(find.byKey(const Key('thread-detail-title')), findsOneWidget);
    expect(find.text('Implement shared contracts'), findsWidgets);
  });

  testWidgets('shared thread detail applies live updates on web', (
    tester,
  ) async {
    final liveStream = _FakeThreadLiveStream();

    await tester.pumpWidget(
      ProviderScope(
        overrides: _baseOverrides(
          threadListApi: _FakeThreadListBridgeApi(_sampleThreads()),
          detailApi: _FakeThreadDetailBridgeApi(
            detail: _threadDetail(status: ThreadStatus.completed),
          ),
          liveStream: liveStream,
        ),
        child: const MaterialApp(
          home: ThreadDetailPage(
            bridgeApiBaseUrl: 'http://127.0.0.1:3110',
            threadId: 'thread-123',
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    liveStream.emit(
      BridgeEventEnvelope<Map<String, dynamic>>(
        contractVersion: contractVersion,
        eventId: 'evt-live-web',
        threadId: 'thread-123',
        kind: BridgeEventKind.messageDelta,
        occurredAt: '2026-03-18T10:02:00Z',
        payload: const <String, dynamic>{'delta': 'Web live update'},
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Web live update'), findsOneWidget);
  });

  testWidgets(
    'shared detail shows in-place browser capability errors without a browser-only page',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides:
              _baseOverrides(
                threadListApi: _FakeThreadListBridgeApi(_sampleThreads()),
                detailApi: _FakeThreadDetailBridgeApi(
                  detail: _threadDetail(status: ThreadStatus.completed),
                  speechStatus: const SpeechModelStatusDto(
                    contractVersion: contractVersion,
                    provider: 'fluid_audio',
                    modelId: 'parakeet-tdt-0.6b-v3-coreml',
                    state: SpeechModelState.ready,
                  ),
                ),
              )..add(
                speechCaptureProvider.overrideWithValue(
                  const _UnsupportedSpeechCapture(),
                ),
              ),
          child: const MaterialApp(
            home: ThreadDetailPage(
              bridgeApiBaseUrl: 'http://127.0.0.1:3110',
              threadId: 'thread-123',
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('turn-composer-input')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('turn-composer-speech-toggle')));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(
        find.text('Voice capture is unavailable in this browser.'),
        findsOneWidget,
      );
      expect(find.byType(ThreadDetailPage), findsOneWidget);
    },
  );
}

List<Override> _baseOverrides({
  _FakeThreadListBridgeApi? threadListApi,
  _FakeThreadDetailBridgeApi? detailApi,
  _FakeThreadLiveStream? liveStream,
}) {
  final store = InMemorySecureStore();
  return <Override>[
    appSecureStoreProvider.overrideWithValue(store),
    threadCacheRepositoryProvider.overrideWithValue(
      SecureStoreThreadCacheRepository(
        secureStore: store,
        nowUtc: () => DateTime.utc(2026, 3, 18, 10),
      ),
    ),
    threadListBridgeApiProvider.overrideWithValue(
      threadListApi ?? _FakeThreadListBridgeApi(_sampleThreads()),
    ),
    threadDetailBridgeApiProvider.overrideWithValue(
      detailApi ?? _FakeThreadDetailBridgeApi(detail: _threadDetail()),
    ),
    threadLiveStreamProvider.overrideWithValue(
      liveStream ?? _FakeThreadLiveStream(),
    ),
    approvalBridgeApiProvider.overrideWithValue(
      const _EmptyApprovalBridgeApi(),
    ),
    settingsBridgeApiProvider.overrideWithValue(const _FakeSettingsBridgeApi()),
  ];
}

Future<void> _setDisplaySize(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

List<ThreadSummaryDto> _sampleThreads() {
  return const <ThreadSummaryDto>[
    ThreadSummaryDto(
      contractVersion: contractVersion,
      threadId: 'thread-123',
      title: 'Implement shared contracts',
      status: ThreadStatus.completed,
      workspace: '/workspace/vibe-bridge-companion',
      repository: 'vibe-bridge-companion',
      branch: 'main',
      updatedAt: '2026-03-18T10:00:00Z',
    ),
  ];
}

ThreadDetailDto _threadDetail({ThreadStatus status = ThreadStatus.completed}) {
  return ThreadDetailDto(
    contractVersion: contractVersion,
    threadId: 'thread-123',
    title: 'Implement shared contracts',
    status: status,
    workspace: '/workspace/vibe-bridge-companion',
    repository: 'vibe-bridge-companion',
    branch: 'main',
    createdAt: '2026-03-18T09:45:00Z',
    updatedAt: '2026-03-18T10:00:00Z',
    source: 'cli',
    accessMode: AccessMode.controlWithApprovals,
    lastTurnSummary: 'Normalize event payloads',
  );
}

class _FakeLocalDesktopBridgeApi implements LocalDesktopBridgeApi {
  const _FakeLocalDesktopBridgeApi.reachable()
    : _result = const LocalDesktopBridgeProbeResult.reachable();

  final LocalDesktopBridgeProbeResult _result;

  @override
  Future<LocalDesktopBridgeProbeResult> probe({
    required String bridgeApiBaseUrl,
  }) async {
    return _result;
  }
}

class _FakeThreadListBridgeApi implements ThreadListBridgeApi {
  const _FakeThreadListBridgeApi(this.threads);

  final List<ThreadSummaryDto> threads;

  @override
  Future<List<ThreadSummaryDto>> fetchThreads({
    required String bridgeApiBaseUrl,
  }) async {
    return threads;
  }
}

class _FakeThreadDetailBridgeApi implements ThreadDetailBridgeApi {
  const _FakeThreadDetailBridgeApi({
    required this.detail,
    this.speechStatus = const SpeechModelStatusDto(
      contractVersion: contractVersion,
      provider: 'fluid_audio',
      modelId: 'parakeet-tdt-0.6b-v3-coreml',
      state: SpeechModelState.unsupported,
      lastError: 'Speech transcription is unavailable in this build.',
    ),
  });

  final ThreadDetailDto detail;
  final SpeechModelStatusDto speechStatus;

  @override
  Future<ThreadSnapshotDto> createThread({
    required String bridgeApiBaseUrl,
    required String workspace,
    String? model,
  }) async {
    return ThreadSnapshotDto(
      contractVersion: contractVersion,
      thread: detail,
      entries: const <ThreadTimelineEntryDto>[],
      approvals: const <ApprovalSummaryDto>[],
      gitStatus: _threadGitStatus,
    );
  }

  @override
  Future<ThreadDetailDto> fetchThreadDetail({
    required String bridgeApiBaseUrl,
    required String threadId,
  }) async {
    return detail;
  }

  @override
  Future<ThreadTimelinePageDto> fetchThreadTimelinePage({
    required String bridgeApiBaseUrl,
    required String threadId,
    String? before,
    int limit = 50,
  }) async {
    return ThreadTimelinePageDto(
      contractVersion: contractVersion,
      thread: detail,
      entries: <ThreadTimelineEntryDto>[],
      nextBefore: null,
      hasMoreBefore: false,
    );
  }

  @override
  Future<ModelCatalogDto> fetchModelCatalog({
    required String bridgeApiBaseUrl,
  }) async {
    return fallbackModelCatalog;
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
    List<String> images = const <String>[],
    String? model,
    String? effort,
  }) async {
    return TurnMutationResult(
      contractVersion: contractVersion,
      threadId: threadId,
      operation: 'start',
      outcome: 'accepted',
      message: 'Accepted',
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
      operation: 'steer',
      outcome: 'accepted',
      message: 'Accepted',
      threadStatus: ThreadStatus.running,
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
      operation: 'interrupt',
      outcome: 'accepted',
      message: 'Accepted',
      threadStatus: ThreadStatus.completed,
    );
  }

  @override
  Future<TurnMutationResult> startCommitAction({
    required String bridgeApiBaseUrl,
    required String threadId,
    String? model,
    String? effort,
  }) async {
    return TurnMutationResult(
      contractVersion: contractVersion,
      threadId: threadId,
      operation: 'commit',
      outcome: 'accepted',
      message: 'Accepted',
      threadStatus: ThreadStatus.running,
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
      repository: _repositoryContext,
      status: _gitStatus,
    );
  }

  @override
  Future<MutationResultResponseDto> switchBranch({
    required String bridgeApiBaseUrl,
    required String threadId,
    required String branch,
  }) async {
    return _mutationResult(
      threadId: threadId,
      operation: 'branch-switch',
      threadStatus: ThreadStatus.completed,
    );
  }

  @override
  Future<MutationResultResponseDto> pullRepository({
    required String bridgeApiBaseUrl,
    required String threadId,
    String? remote,
  }) async {
    return _mutationResult(
      threadId: threadId,
      operation: 'pull',
      threadStatus: ThreadStatus.completed,
    );
  }

  @override
  Future<MutationResultResponseDto> pushRepository({
    required String bridgeApiBaseUrl,
    required String threadId,
    String? remote,
  }) async {
    return _mutationResult(
      threadId: threadId,
      operation: 'push',
      threadStatus: ThreadStatus.completed,
    );
  }

  @override
  Future<SpeechModelStatusDto> fetchSpeechStatus({
    required String bridgeApiBaseUrl,
  }) async {
    return speechStatus;
  }

  @override
  Future<SpeechTranscriptionResultDto> transcribeAudio({
    required String bridgeApiBaseUrl,
    required List<int> audioBytes,
    String fileName = 'voice-message.wav',
  }) async {
    return const SpeechTranscriptionResultDto(
      contractVersion: contractVersion,
      provider: 'fluid_audio',
      modelId: 'parakeet-tdt-0.6b-v3-coreml',
      text: 'Transcript',
      durationMs: 250,
    );
  }

  @override
  Future<OpenOnMacResponseDto> openOnMac({
    required String bridgeApiBaseUrl,
    required String threadId,
  }) async {
    throw const ThreadOpenOnMacBridgeException(
      message: 'Open-on-host is unavailable in this build.',
    );
  }
}

class _FakeThreadLiveStream implements ThreadLiveStream {
  final List<
    (String?, StreamController<BridgeEventEnvelope<Map<String, dynamic>>>)
  >
  _subscriptions =
      <
        (String?, StreamController<BridgeEventEnvelope<Map<String, dynamic>>>)
      >[];

  @override
  Future<ThreadLiveSubscription> subscribe({
    required String bridgeApiBaseUrl,
    String? threadId,
  }) async {
    final controller =
        StreamController<BridgeEventEnvelope<Map<String, dynamic>>>.broadcast();
    _subscriptions.add((threadId, controller));
    return ThreadLiveSubscription(
      events: controller.stream,
      close: () async {
        _subscriptions.removeWhere((entry) => identical(entry.$2, controller));
        await controller.close();
      },
    );
  }

  void emit(BridgeEventEnvelope<Map<String, dynamic>> event) {
    for (final (threadId, controller) in _subscriptions) {
      if (threadId == null || threadId == event.threadId) {
        controller.add(event);
      }
    }
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
  }) => throw UnimplementedError();

  @override
  Future<ApprovalResolutionResponseDto> reject({
    required String bridgeApiBaseUrl,
    required String approvalId,
  }) => throw UnimplementedError();
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

class _UnsupportedSpeechCapture implements SpeechCapture {
  const _UnsupportedSpeechCapture();

  @override
  Stream<SpeechCaptureAmplitude> amplitudeStream(Duration interval) {
    return const Stream<SpeechCaptureAmplitude>.empty();
  }

  @override
  Future<void> dispose() async {}

  @override
  Future<bool> hasPermission() async {
    throw const SpeechCaptureException(
      message: 'Voice capture is unavailable in this browser.',
      code: 'speech_capture_unsupported',
    );
  }

  @override
  Future<void> start() async {
    throw const SpeechCaptureException(
      message: 'Voice capture is unavailable in this browser.',
      code: 'speech_capture_unsupported',
    );
  }

  @override
  Future<SpeechCaptureResult> stop() async {
    return SpeechCaptureResult(bytes: Uint8List(0));
  }
}

const ThreadGitStatusDto _threadGitStatus = ThreadGitStatusDto(
  workspace: '/workspace/vibe-bridge-companion',
  repository: 'vibe-bridge-companion',
  branch: 'main',
  remote: 'origin',
  dirty: false,
  aheadBy: 0,
  behindBy: 0,
);

const RepositoryContextDto _repositoryContext = RepositoryContextDto(
  workspace: '/workspace/vibe-bridge-companion',
  repository: 'vibe-bridge-companion',
  branch: 'main',
  remote: 'origin',
);

const GitStatusDto _gitStatus = GitStatusDto(
  dirty: false,
  aheadBy: 0,
  behindBy: 0,
);

MutationResultResponseDto _mutationResult({
  required String threadId,
  required String operation,
  required ThreadStatus threadStatus,
}) {
  return MutationResultResponseDto(
    contractVersion: contractVersion,
    threadId: threadId,
    operation: operation,
    outcome: 'accepted',
    message: 'Accepted',
    threadStatus: threadStatus,
    repository: _repositoryContext,
    status: _gitStatus,
  );
}
