import 'dart:async';

import 'package:codex_mobile_companion/foundation/connectivity/live_connection_state.dart';
import 'package:codex_mobile_companion/features/threads/application/thread_list_controller.dart';
import 'package:codex_mobile_companion/features/threads/data/thread_detail_bridge_api.dart';
import 'package:codex_mobile_companion/features/threads/data/thread_live_stream.dart';
import 'package:codex_mobile_companion/features/threads/domain/thread_activity_item.dart';
import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final threadDetailControllerProvider = StateNotifierProvider.autoDispose
    .family<
      ThreadDetailController,
      ThreadDetailState,
      ThreadDetailControllerArgs
    >((ref, args) {
      final threadListController = ref.read(
        threadListControllerProvider(args.bridgeApiBaseUrl).notifier,
      );

      return ThreadDetailController(
        bridgeApiBaseUrl: args.bridgeApiBaseUrl,
        threadId: args.threadId,
        initialVisibleTimelineEntries: args.initialVisibleTimelineEntries,
        bridgeApi: ref.watch(threadDetailBridgeApiProvider),
        liveStream: ref.watch(threadLiveStreamProvider),
        threadListController: threadListController,
      );
    });

class ThreadDetailControllerArgs {
  const ThreadDetailControllerArgs({
    required this.bridgeApiBaseUrl,
    required this.threadId,
    this.initialVisibleTimelineEntries = 80,
  });

  final String bridgeApiBaseUrl;
  final String threadId;
  final int initialVisibleTimelineEntries;

  @override
  bool operator ==(Object other) {
    return other is ThreadDetailControllerArgs &&
        other.bridgeApiBaseUrl == bridgeApiBaseUrl &&
        other.threadId == threadId &&
        other.initialVisibleTimelineEntries == initialVisibleTimelineEntries;
  }

  @override
  int get hashCode =>
      Object.hash(bridgeApiBaseUrl, threadId, initialVisibleTimelineEntries);
}

class ThreadDetailState {
  const ThreadDetailState({
    required this.threadId,
    this.liveConnectionState = LiveConnectionState.connected,
    this.thread,
    this.items = const <ThreadActivityItem>[],
    this.errorMessage,
    this.streamErrorMessage,
    this.staleMessage,
    this.isUnavailable = false,
    this.isLoading = true,
    this.isShowingCachedData = false,
    this.isConnectivityUnavailable = false,
    this.hasMoreBefore = false,
    this.nextBefore,
    this.isLoadingEarlierHistory = false,
    this.isComposerMutationInFlight = false,
    this.isInterruptMutationInFlight = false,
    this.turnControlErrorMessage,
    this.gitStatus,
    this.isGitStatusLoading = false,
    this.isGitMutationInFlight = false,
    this.gitErrorMessage,
    this.gitMutationMessage,
    this.gitControlsUnavailableReason,
    this.isOpenOnMacInFlight = false,
    this.openOnMacMessage,
    this.openOnMacErrorMessage,
  });

  final String threadId;
  final LiveConnectionState liveConnectionState;
  final ThreadDetailDto? thread;
  final List<ThreadActivityItem> items;
  final String? errorMessage;
  final String? streamErrorMessage;
  final String? staleMessage;
  final bool isUnavailable;
  final bool isLoading;
  final bool isShowingCachedData;
  final bool isConnectivityUnavailable;
  final bool hasMoreBefore;
  final String? nextBefore;
  final bool isLoadingEarlierHistory;
  final bool isComposerMutationInFlight;
  final bool isInterruptMutationInFlight;
  final String? turnControlErrorMessage;
  final GitStatusResponseDto? gitStatus;
  final bool isGitStatusLoading;
  final bool isGitMutationInFlight;
  final String? gitErrorMessage;
  final String? gitMutationMessage;
  final String? gitControlsUnavailableReason;
  final bool isOpenOnMacInFlight;
  final String? openOnMacMessage;
  final String? openOnMacErrorMessage;

  bool get hasThread => thread != null;

  bool get hasError => errorMessage != null;

  bool get canRunMutatingActions => !isConnectivityUnavailable;

  bool get hasGitRepositoryContext =>
      gitStatus != null &&
      _isRepositoryContextResolvable(gitStatus!.repository);

  bool get canRunGitMutations =>
      canRunMutatingActions &&
      hasGitRepositoryContext &&
      !isGitStatusLoading &&
      !isGitMutationInFlight;

  bool get isTurnActive => thread?.status == ThreadStatus.running;

  List<ThreadActivityItem> get conversationItems =>
      List<ThreadActivityItem>.unmodifiable(
        items.where(_isConversationTimelineItem),
      );

  int get hiddenHistoryCount => 0;

  bool get canLoadEarlierHistory => hasMoreBefore && !isLoadingEarlierHistory;

  List<ThreadActivityItem> get visibleItems => conversationItems;

  ThreadDetailState copyWith({
    LiveConnectionState? liveConnectionState,
    ThreadDetailDto? thread,
    bool clearThread = false,
    List<ThreadActivityItem>? items,
    String? errorMessage,
    bool clearErrorMessage = false,
    String? streamErrorMessage,
    bool clearStreamErrorMessage = false,
    String? staleMessage,
    bool clearStaleMessage = false,
    bool? isUnavailable,
    bool? isLoading,
    bool? isShowingCachedData,
    bool? isConnectivityUnavailable,
    bool? hasMoreBefore,
    String? nextBefore,
    bool clearNextBefore = false,
    bool? isLoadingEarlierHistory,
    bool? isComposerMutationInFlight,
    bool? isInterruptMutationInFlight,
    String? turnControlErrorMessage,
    bool clearTurnControlError = false,
    GitStatusResponseDto? gitStatus,
    bool clearGitStatus = false,
    bool? isGitStatusLoading,
    bool? isGitMutationInFlight,
    String? gitErrorMessage,
    bool clearGitErrorMessage = false,
    String? gitMutationMessage,
    bool clearGitMutationMessage = false,
    String? gitControlsUnavailableReason,
    bool clearGitControlsUnavailableReason = false,
    bool? isOpenOnMacInFlight,
    String? openOnMacMessage,
    bool clearOpenOnMacMessage = false,
    String? openOnMacErrorMessage,
    bool clearOpenOnMacErrorMessage = false,
  }) {
    return ThreadDetailState(
      threadId: threadId,
      liveConnectionState: liveConnectionState ?? this.liveConnectionState,
      thread: clearThread ? null : (thread ?? this.thread),
      items: items ?? this.items,
      errorMessage: clearErrorMessage
          ? null
          : (errorMessage ?? this.errorMessage),
      streamErrorMessage: clearStreamErrorMessage
          ? null
          : (streamErrorMessage ?? this.streamErrorMessage),
      staleMessage: clearStaleMessage
          ? null
          : (staleMessage ?? this.staleMessage),
      isUnavailable: isUnavailable ?? this.isUnavailable,
      isLoading: isLoading ?? this.isLoading,
      isShowingCachedData: isShowingCachedData ?? this.isShowingCachedData,
      isConnectivityUnavailable:
          isConnectivityUnavailable ?? this.isConnectivityUnavailable,
      hasMoreBefore: hasMoreBefore ?? this.hasMoreBefore,
      nextBefore: clearNextBefore ? null : (nextBefore ?? this.nextBefore),
      isLoadingEarlierHistory:
          isLoadingEarlierHistory ?? this.isLoadingEarlierHistory,
      isComposerMutationInFlight:
          isComposerMutationInFlight ?? this.isComposerMutationInFlight,
      isInterruptMutationInFlight:
          isInterruptMutationInFlight ?? this.isInterruptMutationInFlight,
      turnControlErrorMessage: clearTurnControlError
          ? null
          : (turnControlErrorMessage ?? this.turnControlErrorMessage),
      gitStatus: clearGitStatus ? null : (gitStatus ?? this.gitStatus),
      isGitStatusLoading: isGitStatusLoading ?? this.isGitStatusLoading,
      isGitMutationInFlight:
          isGitMutationInFlight ?? this.isGitMutationInFlight,
      gitErrorMessage: clearGitErrorMessage
          ? null
          : (gitErrorMessage ?? this.gitErrorMessage),
      gitMutationMessage: clearGitMutationMessage
          ? null
          : (gitMutationMessage ?? this.gitMutationMessage),
      gitControlsUnavailableReason: clearGitControlsUnavailableReason
          ? null
          : (gitControlsUnavailableReason ?? this.gitControlsUnavailableReason),
      isOpenOnMacInFlight: isOpenOnMacInFlight ?? this.isOpenOnMacInFlight,
      openOnMacMessage: clearOpenOnMacMessage
          ? null
          : (openOnMacMessage ?? this.openOnMacMessage),
      openOnMacErrorMessage: clearOpenOnMacErrorMessage
          ? null
          : (openOnMacErrorMessage ?? this.openOnMacErrorMessage),
    );
  }
}

bool _isConversationTimelineItem(ThreadActivityItem item) {
  switch (item.type) {
    case ThreadActivityItemType.lifecycleUpdate:
    case ThreadActivityItemType.securityEvent:
      return false;
    default:
      return true;
  }
}

bool _isExplorationTimelineItem(ThreadActivityItem item) {
  return item.presentation?.groupKind ==
      ThreadActivityPresentationGroupKind.exploration;
}

class ThreadDetailController extends StateNotifier<ThreadDetailState> {
  ThreadDetailController({
    required String bridgeApiBaseUrl,
    required String threadId,
    required int initialVisibleTimelineEntries,
    required ThreadDetailBridgeApi bridgeApi,
    required ThreadLiveStream liveStream,
    required ThreadListController threadListController,
    void Function(String message)? debugLog,
  }) : _bridgeApiBaseUrl = bridgeApiBaseUrl,
       _initialVisibleTimelineEntries = initialVisibleTimelineEntries,
       _bridgeApi = bridgeApi,
       _liveStream = liveStream,
       _threadListController = threadListController,
       _debugLog = debugLog ?? _defaultDebugLog,
       super(ThreadDetailState(threadId: threadId)) {
    loadThread();
  }

  final String _bridgeApiBaseUrl;
  final int _initialVisibleTimelineEntries;
  final ThreadDetailBridgeApi _bridgeApi;
  final ThreadLiveStream _liveStream;
  final ThreadListController _threadListController;
  final void Function(String message) _debugLog;
  final Set<String> _knownEventIds = <String>{};

  ThreadLiveSubscription? _liveSubscription;
  StreamSubscription<BridgeEventEnvelope<Map<String, dynamic>>>?
  _liveEventSubscription;
  Timer? _reconnectTimer;
  Timer? _detailRefreshTimer;
  bool _isReconnectInProgress = false;
  bool _isDetailRefreshInFlight = false;
  bool _shouldRefreshDetailAfterCurrentRequest = false;
  bool _isDisposed = false;
  DateTime? _pendingPromptSubmittedAt;

  Future<void> loadThread() async {
    if (_isDisposed) {
      return;
    }

    _reconnectTimer?.cancel();
    state = state.copyWith(
      isLoading: true,
      isUnavailable: false,
      clearErrorMessage: true,
      clearStreamErrorMessage: true,
      clearStaleMessage: true,
      clearTurnControlError: true,
      isShowingCachedData: false,
      isConnectivityUnavailable: false,
      hasMoreBefore: false,
      clearNextBefore: true,
      isLoadingEarlierHistory: false,
      clearGitStatus: true,
      isGitStatusLoading: false,
      isGitMutationInFlight: false,
      clearGitErrorMessage: true,
      clearGitMutationMessage: true,
      clearGitControlsUnavailableReason: true,
      isOpenOnMacInFlight: false,
      clearOpenOnMacMessage: true,
      clearOpenOnMacErrorMessage: true,
    );

    try {
      await _closeLiveSubscription();
      _knownEventIds.clear();
      final requestedThreadId = state.threadId;

      final detail = await _bridgeApi.fetchThreadDetail(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
        threadId: requestedThreadId,
      );
      if (!_isRequestCurrent(requestedThreadId)) {
        return;
      }
      final scopedDetail = _ensureScopedThreadDetail(
        detail: detail,
        expectedThreadId: requestedThreadId,
        context: 'loading thread detail',
      );

      state = state.copyWith(
        thread: scopedDetail,
        isLoading: true,
        isUnavailable: false,
        clearErrorMessage: true,
        clearStreamErrorMessage: true,
        clearStaleMessage: true,
        clearTurnControlError: true,
        isShowingCachedData: false,
        isConnectivityUnavailable: false,
        hasMoreBefore: false,
        clearNextBefore: true,
        isLoadingEarlierHistory: false,
        clearGitStatus: true,
        isGitStatusLoading: false,
        isGitMutationInFlight: false,
        clearGitErrorMessage: true,
        clearGitMutationMessage: true,
        clearGitControlsUnavailableReason: true,
        isOpenOnMacInFlight: false,
        clearOpenOnMacMessage: true,
        clearOpenOnMacErrorMessage: true,
      );
      _threadListController.syncThreadDetail(scopedDetail);

      final page = await _bridgeApi.fetchThreadTimelinePage(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
        threadId: requestedThreadId,
        limit: _initialVisibleTimelineEntries,
      );
      if (!_isRequestCurrent(requestedThreadId)) {
        return;
      }
      final scopedPage = _ensureScopedTimelinePage(
        page: page,
        expectedThreadId: requestedThreadId,
        context: 'loading thread timeline',
      );

      final items = scopedPage.entries
          .map(ThreadActivityItem.fromTimelineEntry)
          .toList(growable: false);
      _knownEventIds.addAll(items.map((item) => item.eventId));

      if (_isDisposed) {
        return;
      }

      state = state.copyWith(
        thread: scopedDetail,
        items: items,
        liveConnectionState: LiveConnectionState.connected,
        isLoading: true,
        isUnavailable: false,
        clearErrorMessage: true,
        clearStreamErrorMessage: true,
        clearStaleMessage: true,
        clearTurnControlError: true,
        isShowingCachedData: false,
        isConnectivityUnavailable: false,
        hasMoreBefore: scopedPage.hasMoreBefore,
        nextBefore: scopedPage.nextBefore,
        isLoadingEarlierHistory: false,
        clearGitStatus: true,
        isGitStatusLoading: false,
        isGitMutationInFlight: false,
        clearGitErrorMessage: true,
        clearGitMutationMessage: true,
        clearGitControlsUnavailableReason: true,
        isOpenOnMacInFlight: false,
        clearOpenOnMacMessage: true,
        clearOpenOnMacErrorMessage: true,
      );
      await refreshGitStatus(showLoading: false);
      await _startLiveSubscription();
      if (_isDisposed || !_isRequestCurrent(requestedThreadId)) {
        return;
      }
      state = state.copyWith(
        isLoading: false,
        liveConnectionState: LiveConnectionState.connected,
        clearStreamErrorMessage: true,
      );
    } on ThreadDetailBridgeException catch (error) {
      if (_isDisposed) {
        return;
      }

      state = state.copyWith(
        isLoading: false,
        errorMessage: error.message,
        isUnavailable: error.isUnavailable,
        isConnectivityUnavailable: error.isConnectivityError,
        liveConnectionState: error.isConnectivityError
            ? LiveConnectionState.disconnected
            : state.liveConnectionState,
      );
    } catch (_) {
      if (_isDisposed) {
        return;
      }

      state = state.copyWith(
        isLoading: false,
        errorMessage: 'Couldn’t load this thread right now.',
        liveConnectionState: LiveConnectionState.disconnected,
      );
    }
  }

  Future<void> loadEarlierHistory() async {
    if (!state.canLoadEarlierHistory) {
      return;
    }

    final requestedThreadId = state.threadId;

    final previousBlockSignatures = _visibleBlockSignatures(state.visibleItems);

    state = state.copyWith(
      isLoadingEarlierHistory: true,
      clearStreamErrorMessage: true,
    );

    try {
      var nextBefore = state.nextBefore;
      var hasMoreBefore = state.hasMoreBefore;
      var items = state.items;
      ThreadDetailDto? latestThread = state.thread;

      while (hasMoreBefore && nextBefore != null) {
        final page = await _bridgeApi.fetchThreadTimelinePage(
          bridgeApiBaseUrl: _bridgeApiBaseUrl,
          threadId: requestedThreadId,
          before: nextBefore,
          limit: _initialVisibleTimelineEntries,
        );
        if (!_isRequestCurrent(requestedThreadId)) {
          return;
        }
        final scopedPage = _ensureScopedTimelinePage(
          page: page,
          expectedThreadId: requestedThreadId,
          context: 'loading older history',
        );
        latestThread = _fresherThreadDetail(
          current: latestThread,
          candidate: scopedPage.thread,
        );
        items = _prependTimelineEntries(items, scopedPage.entries);
        hasMoreBefore = scopedPage.hasMoreBefore;
        nextBefore = scopedPage.nextBefore;

        if (_didRevealNewVisibleBlock(
          previousBlockSignatures: previousBlockSignatures,
          nextItems: items,
        )) {
          break;
        }
      }

      if (_isDisposed) {
        return;
      }

      state = state.copyWith(
        thread: latestThread,
        items: items,
        hasMoreBefore: hasMoreBefore,
        nextBefore: nextBefore,
        isLoadingEarlierHistory: false,
        clearErrorMessage: true,
        clearStreamErrorMessage: true,
        clearStaleMessage: true,
      );
      if (latestThread != null) {
        _threadListController.syncThreadDetail(latestThread);
      }
    } on ThreadDetailBridgeException catch (error) {
      if (_isDisposed || !_isRequestCurrent(requestedThreadId)) {
        return;
      }

      state = state.copyWith(
        isLoadingEarlierHistory: false,
        streamErrorMessage: error.message,
        isConnectivityUnavailable: error.isConnectivityError,
        liveConnectionState: error.isConnectivityError
            ? LiveConnectionState.disconnected
            : state.liveConnectionState,
      );
    } catch (_) {
      if (_isDisposed || !_isRequestCurrent(requestedThreadId)) {
        return;
      }

      state = state.copyWith(
        isLoadingEarlierHistory: false,
        streamErrorMessage: 'Couldn’t load older history right now.',
        liveConnectionState: LiveConnectionState.disconnected,
      );
    }
  }

  Future<void> retryReconnectCatchUp() async {
    _reconnectTimer?.cancel();
    await _runReconnectCatchUp();
  }

  Future<void> _startLiveSubscription() async {
    try {
      final subscription = await _liveStream.subscribe(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
        threadId: state.threadId,
      );
      if (_isDisposed) {
        await subscription.close();
        return;
      }
      _liveSubscription = subscription;

      _liveEventSubscription = subscription.events.listen(
        _handleLiveEvent,
        onError: (_) {
          _handleLiveStreamDisconnected();
        },
        onDone: () {
          _handleLiveStreamDisconnected();
        },
      );

      state = state.copyWith(
        liveConnectionState: LiveConnectionState.connected,
        clearStreamErrorMessage: true,
        clearStaleMessage: true,
        clearTurnControlError: true,
        isShowingCachedData: false,
        isConnectivityUnavailable: false,
      );
    } catch (_) {
      _handleLiveStreamDisconnected();
    }
  }

  void _handleLiveStreamDisconnected() {
    if (_isDisposed) {
      return;
    }

    state = state.copyWith(
      liveConnectionState: LiveConnectionState.disconnected,
      streamErrorMessage:
          'Live updates disconnected. Reconnecting and catching up…',
      staleMessage:
          'Bridge is offline. Current thread content may be stale until reconnect.',
      isShowingCachedData: false,
      isConnectivityUnavailable: true,
      gitControlsUnavailableReason:
          'Git controls are unavailable while reconnecting to the private route.',
    );
    _scheduleReconnectCatchUp();
  }

  void _scheduleReconnectCatchUp() {
    if (_isDisposed || _reconnectTimer?.isActive == true) {
      return;
    }

    _reconnectTimer = Timer(const Duration(seconds: 2), () {
      unawaited(_runReconnectCatchUp());
    });
  }

  Future<void> _runReconnectCatchUp() async {
    if (_isDisposed || _isReconnectInProgress) {
      return;
    }

    _isReconnectInProgress = true;

    try {
      if (state.liveConnectionState == LiveConnectionState.disconnected) {
        state = state.copyWith(
          liveConnectionState: LiveConnectionState.reconnecting,
        );
      }
      await _closeLiveSubscription();
      final requestedThreadId = state.threadId;

      final detail = await _bridgeApi.fetchThreadDetail(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
        threadId: requestedThreadId,
      );
      if (!_isRequestCurrent(requestedThreadId)) {
        return;
      }
      final scopedDetail = _ensureScopedThreadDetail(
        detail: detail,
        expectedThreadId: requestedThreadId,
        context: 'running reconnect catch-up detail refresh',
      );

      state = state.copyWith(
        thread: scopedDetail,
        clearErrorMessage: true,
        clearStreamErrorMessage: true,
        clearStaleMessage: true,
        clearTurnControlError: true,
        isShowingCachedData: false,
        isConnectivityUnavailable: false,
        clearGitStatus: true,
        isGitStatusLoading: false,
        isGitMutationInFlight: false,
        clearGitErrorMessage: true,
        clearGitMutationMessage: true,
        clearGitControlsUnavailableReason: true,
      );
      _threadListController.syncThreadDetail(scopedDetail);

      final page = await _bridgeApi.fetchThreadTimelinePage(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
        threadId: requestedThreadId,
        limit: _initialVisibleTimelineEntries,
      );
      if (!_isRequestCurrent(requestedThreadId)) {
        return;
      }
      final scopedPage = _ensureScopedTimelinePage(
        page: page,
        expectedThreadId: requestedThreadId,
        context: 'running reconnect catch-up timeline refresh',
      );

      final mergedItems = _mergeTimeline(scopedPage.entries);

      if (_isDisposed) {
        return;
      }

      state = state.copyWith(
        thread: scopedDetail,
        items: mergedItems,
        liveConnectionState: LiveConnectionState.connected,
        clearErrorMessage: true,
        clearStreamErrorMessage: true,
        clearStaleMessage: true,
        clearTurnControlError: true,
        isLoading: false,
        isUnavailable: false,
        isShowingCachedData: false,
        isConnectivityUnavailable: false,
        clearGitStatus: true,
        isGitStatusLoading: false,
        isGitMutationInFlight: false,
        clearGitErrorMessage: true,
        clearGitMutationMessage: true,
        clearGitControlsUnavailableReason: true,
      );

      await refreshGitStatus(showLoading: false);
      await _startLiveSubscription();
    } on ThreadDetailBridgeException catch (error) {
      if (_isDisposed) {
        return;
      }

      state = state.copyWith(
        liveConnectionState: LiveConnectionState.disconnected,
        streamErrorMessage: error.message,
        staleMessage:
            'Bridge is offline. Current thread content may be stale until reconnect.',
        isShowingCachedData: false,
        isConnectivityUnavailable: true,
      );
      _scheduleReconnectCatchUp();
    } catch (_) {
      if (_isDisposed) {
        return;
      }

      _scheduleReconnectCatchUp();
    } finally {
      _isReconnectInProgress = false;
    }
  }

  List<ThreadActivityItem> _mergeTimeline(
    List<ThreadTimelineEntryDto> timeline,
  ) {
    if (timeline.isEmpty) {
      return state.items;
    }

    final nextItems = List<ThreadActivityItem>.from(state.items);
    for (final entry in timeline) {
      final nextItem = ThreadActivityItem.fromTimelineEntry(entry);
      final existingIndex = nextItems.indexWhere(
        (item) => item.eventId == entry.eventId,
      );
      if (existingIndex >= 0) {
        nextItems[existingIndex] = nextItem;
      } else {
        nextItems.add(nextItem);
        _knownEventIds.add(entry.eventId);
      }
    }

    return nextItems;
  }

  List<ThreadActivityItem> _prependTimelineEntries(
    List<ThreadActivityItem> currentItems,
    List<ThreadTimelineEntryDto> timeline,
  ) {
    if (timeline.isEmpty) {
      return currentItems;
    }

    final prependedItems = <ThreadActivityItem>[];
    for (final entry in timeline) {
      if (_knownEventIds.contains(entry.eventId)) {
        continue;
      }

      prependedItems.add(ThreadActivityItem.fromTimelineEntry(entry));
      _knownEventIds.add(entry.eventId);
    }

    if (prependedItems.isEmpty) {
      return currentItems;
    }

    return List<ThreadActivityItem>.unmodifiable(<ThreadActivityItem>[
      ...prependedItems,
      ...currentItems,
    ]);
  }

  ThreadDetailDto? _fresherThreadDetail({
    required ThreadDetailDto? current,
    required ThreadDetailDto? candidate,
  }) {
    if (candidate == null) {
      return current;
    }
    if (current == null) {
      return candidate;
    }

    final currentUpdatedAt = DateTime.tryParse(current.updatedAt);
    final candidateUpdatedAt = DateTime.tryParse(candidate.updatedAt);
    if (currentUpdatedAt == null || candidateUpdatedAt == null) {
      return candidate;
    }

    return candidateUpdatedAt.isAfter(currentUpdatedAt) ? candidate : current;
  }

  bool _isRequestCurrent(String requestThreadId) {
    return !_isDisposed && state.threadId == requestThreadId;
  }

  ThreadDetailDto _ensureScopedThreadDetail({
    required ThreadDetailDto detail,
    required String expectedThreadId,
    required String context,
  }) {
    if (detail.threadId == expectedThreadId) {
      return detail;
    }

    throw ThreadDetailBridgeException(
      message:
          'Live thread data fell out of sync while $context. Retry the thread view and reconnect if needed.',
    );
  }

  ThreadTimelinePageDto _ensureScopedTimelinePage({
    required ThreadTimelinePageDto page,
    required String expectedThreadId,
    required String context,
  }) {
    _ensureScopedThreadDetail(
      detail: page.thread,
      expectedThreadId: expectedThreadId,
      context: context,
    );
    return page;
  }

  bool _didRevealNewVisibleBlock({
    required List<String> previousBlockSignatures,
    required List<ThreadActivityItem> nextItems,
  }) {
    final nextVisibleItems = nextItems
        .where(_isConversationTimelineItem)
        .toList(growable: false);
    final nextBlockSignatures = _visibleBlockSignatures(nextVisibleItems);
    return _hasNewLeadingVisibleBlock(
      previousBlockSignatures: previousBlockSignatures,
      nextBlockSignatures: nextBlockSignatures,
    );
  }

  List<String> _visibleBlockSignatures(List<ThreadActivityItem> items) {
    if (items.isEmpty) {
      return const <String>[];
    }

    final signatures = <String>[];
    var index = 0;

    while (index < items.length) {
      final item = items[index];

      if (_isExplorationTimelineItem(item)) {
        var scanIndex = index;
        while (scanIndex < items.length &&
            _isExplorationTimelineItem(items[scanIndex])) {
          scanIndex += 1;
        }

        signatures.add('exploration:${items[scanIndex - 1].eventId}');
        index = scanIndex;
        continue;
      }

      var scanIndex = index + 1;
      while (scanIndex < items.length &&
          _isExplorationTimelineItem(items[scanIndex])) {
        scanIndex += 1;
      }

      signatures.add('activity:${item.eventId}');
      index = scanIndex;
    }

    return List<String>.unmodifiable(signatures);
  }

  bool _hasNewLeadingVisibleBlock({
    required List<String> previousBlockSignatures,
    required List<String> nextBlockSignatures,
  }) {
    var previousIndex = previousBlockSignatures.length - 1;
    var nextIndex = nextBlockSignatures.length - 1;

    while (previousIndex >= 0 &&
        nextIndex >= 0 &&
        previousBlockSignatures[previousIndex] ==
            nextBlockSignatures[nextIndex]) {
      previousIndex -= 1;
      nextIndex -= 1;
    }

    return nextIndex >= 0;
  }

  void _handleLiveEvent(BridgeEventEnvelope<Map<String, dynamic>> event) {
    if (event.threadId != state.threadId) {
      return;
    }

    final existingIndex = state.items.indexWhere(
      (item) => item.eventId == event.eventId,
    );

    if (event.kind == BridgeEventKind.threadStatusChanged) {
      _applyLifecycleStatusUpdate(event);
    }

    final mergedPayload = _mergeLivePayload(
      existingIndex >= 0 ? state.items[existingIndex].payload : null,
      event,
    );
    final mergedEvent = BridgeEventEnvelope<Map<String, dynamic>>(
      contractVersion: event.contractVersion,
      eventId: event.eventId,
      threadId: event.threadId,
      kind: event.kind,
      occurredAt: event.occurredAt,
      payload: mergedPayload,
      annotations: event.annotations,
    );
    final nextItem = ThreadActivityItem.fromLiveEvent(mergedEvent);
    _logLiveEvent(
      event: event,
      mergedPayload: mergedPayload,
      nextItem: nextItem,
    );
    _logPromptResponseIfNeeded(event: event, nextItem: nextItem);
    final nextItems = List<ThreadActivityItem>.from(state.items);
    if (existingIndex >= 0) {
      nextItems[existingIndex] = nextItem;
    } else {
      nextItems.add(nextItem);
    }

    final thread = state.thread;
    if (thread != null && event.kind != BridgeEventKind.threadStatusChanged) {
      final nextSummary = nextItem.body.trim().isEmpty
          ? thread.lastTurnSummary
          : nextItem.body;
      _updateThreadStatus(
        status: thread.status,
        updatedAt: event.occurredAt,
        lastTurnSummary: nextSummary,
      );
      _threadListController.applyThreadStatusUpdate(
        threadId: event.threadId,
        status: thread.status,
        updatedAt: event.occurredAt,
      );
    }

    state = state.copyWith(items: nextItems, clearStreamErrorMessage: true);
    _scheduleThreadDetailRefresh(
      delay: event.kind == BridgeEventKind.threadStatusChanged
          ? const Duration(milliseconds: 200)
          : const Duration(milliseconds: 700),
    );
  }

  void _scheduleThreadDetailRefresh({required Duration delay}) {
    if (_isDisposed || state.thread == null) {
      return;
    }

    _detailRefreshTimer?.cancel();
    _detailRefreshTimer = Timer(delay, () {
      unawaited(_refreshThreadDetailFromBridge());
    });
  }

  Future<void> _refreshThreadDetailFromBridge() async {
    if (_isDisposed) {
      return;
    }
    if (_isDetailRefreshInFlight) {
      _shouldRefreshDetailAfterCurrentRequest = true;
      return;
    }

    final requestedThreadId = state.threadId;
    _isDetailRefreshInFlight = true;

    try {
      final detail = await _bridgeApi.fetchThreadDetail(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
        threadId: requestedThreadId,
      );
      if (!_isRequestCurrent(requestedThreadId)) {
        return;
      }

      final scopedDetail = _ensureScopedThreadDetail(
        detail: detail,
        expectedThreadId: requestedThreadId,
        context: 'refreshing live thread detail',
      );

      if (!_shouldApplyRefreshedThreadDetail(
        current: state.thread,
        refreshed: scopedDetail,
      )) {
        return;
      }

      state = state.copyWith(thread: scopedDetail);
      _threadListController.syncThreadDetail(scopedDetail);
    } on ThreadDetailBridgeException {
      // Keep the current live state when a background metadata refresh fails.
    } catch (_) {
      // Ignore best-effort metadata refresh failures.
    } finally {
      _isDetailRefreshInFlight = false;
      if (_shouldRefreshDetailAfterCurrentRequest && !_isDisposed) {
        _shouldRefreshDetailAfterCurrentRequest = false;
        unawaited(_refreshThreadDetailFromBridge());
      }
    }
  }

  bool _shouldApplyRefreshedThreadDetail({
    required ThreadDetailDto? current,
    required ThreadDetailDto refreshed,
  }) {
    if (current == null) {
      return true;
    }
    if (_threadDetailEquals(current, refreshed)) {
      return false;
    }

    final currentUpdatedAt = DateTime.tryParse(current.updatedAt);
    final refreshedUpdatedAt = DateTime.tryParse(refreshed.updatedAt);
    if (currentUpdatedAt != null &&
        refreshedUpdatedAt != null &&
        refreshedUpdatedAt.isBefore(currentUpdatedAt)) {
      return _isPlaceholderThreadTitle(current.title) &&
          !_isPlaceholderThreadTitle(refreshed.title);
    }

    return true;
  }

  bool _threadDetailEquals(ThreadDetailDto left, ThreadDetailDto right) {
    return left.contractVersion == right.contractVersion &&
        left.threadId == right.threadId &&
        left.title == right.title &&
        left.status == right.status &&
        left.workspace == right.workspace &&
        left.repository == right.repository &&
        left.branch == right.branch &&
        left.createdAt == right.createdAt &&
        left.updatedAt == right.updatedAt &&
        left.source == right.source &&
        left.accessMode == right.accessMode &&
        left.lastTurnSummary == right.lastTurnSummary;
  }

  bool _isPlaceholderThreadTitle(String title) {
    final normalized = title.trim().toLowerCase();
    return normalized.isEmpty ||
        normalized == 'untitled thread' ||
        normalized == 'new thread' ||
        normalized == 'fresh session';
  }

  void _applyLifecycleStatusUpdate(
    BridgeEventEnvelope<Map<String, dynamic>> event,
  ) {
    final rawStatus = event.payload['status'];
    if (rawStatus is! String || rawStatus.trim().isEmpty) {
      return;
    }

    ThreadStatus? status;
    try {
      status = threadStatusFromWire(rawStatus.trim());
    } on FormatException {
      return;
    }

    final thread = state.thread;
    if (thread == null) {
      return;
    }

    _updateThreadStatus(
      status: status,
      updatedAt: event.occurredAt,
      lastTurnSummary: thread.lastTurnSummary,
    );
    _threadListController.applyThreadStatusUpdate(
      threadId: thread.threadId,
      status: status,
      updatedAt: event.occurredAt,
    );
  }

  Future<bool> submitComposerInput(
    String rawInput, {
    List<String> images = const <String>[],
    String? model,
    String? reasoningEffort,
  }) async {
    final thread = state.thread;
    if (thread == null) {
      return false;
    }

    if (!state.canRunMutatingActions) {
      state = state.copyWith(
        turnControlErrorMessage:
            'Turn controls are unavailable while the bridge is offline.',
      );
      return false;
    }

    final input = rawInput.trim();
    final normalizedImages = images
        .map((image) => image.trim())
        .where((image) => image.isNotEmpty)
        .toList(growable: false);
    if (input.isEmpty && normalizedImages.isEmpty) {
      state = state.copyWith(
        turnControlErrorMessage: state.isTurnActive
            ? 'Active-turn steering is unavailable in this build. Interrupt the turn or wait for it to finish before sending a new prompt.'
            : 'Enter a prompt or attach an image to start a turn.',
      );
      return false;
    }

    if (state.isTurnActive) {
      state = state.copyWith(
        turnControlErrorMessage:
            'Active-turn steering is unavailable in this build. Interrupt the turn or wait for it to finish before sending a new prompt.',
      );
      return false;
    }

    state = state.copyWith(
      isComposerMutationInFlight: true,
      clearTurnControlError: true,
    );

    try {
      final mutationResult = await _bridgeApi.startTurn(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
        threadId: state.threadId,
        prompt: input,
        images: normalizedImages,
        model: model,
        effort: reasoningEffort,
      );

      _pendingPromptSubmittedAt = DateTime.now();
      _applyTurnMutationResult(mutationResult);
      state = state.copyWith(
        isComposerMutationInFlight: false,
        clearTurnControlError: true,
      );
      return true;
    } on ThreadTurnBridgeException catch (error) {
      state = state.copyWith(
        isComposerMutationInFlight: false,
        turnControlErrorMessage: error.message,
      );
      return false;
    } catch (_) {
      state = state.copyWith(
        isComposerMutationInFlight: false,
        turnControlErrorMessage:
            'Couldn’t update the turn right now. Please try again.',
      );
      return false;
    }
  }

  Future<bool> openOnMac() async {
    state = state.copyWith(
      isOpenOnMacInFlight: false,
      openOnMacMessage: null,
      openOnMacErrorMessage: 'Open-on-Mac is unavailable in this build.',
      clearOpenOnMacMessage: true,
    );
    return false;
  }

  Future<bool> submitCommitAction({
    String? model,
    String? reasoningEffort,
  }) async {
    final thread = state.thread;
    if (thread == null) {
      return false;
    }

    if (!state.canRunMutatingActions) {
      state = state.copyWith(
        turnControlErrorMessage:
            'Turn controls are unavailable while the bridge is offline.',
      );
      return false;
    }

    if (state.isTurnActive) {
      state = state.copyWith(
        turnControlErrorMessage:
            'Interrupt the active turn or wait for it to finish before starting Commit.',
      );
      return false;
    }

    state = state.copyWith(
      isComposerMutationInFlight: true,
      clearTurnControlError: true,
    );

    try {
      final mutationResult = await _bridgeApi.startCommitAction(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
        threadId: state.threadId,
        model: model,
        effort: reasoningEffort,
      );

      _pendingPromptSubmittedAt = DateTime.now();
      _applyTurnMutationResult(mutationResult);
      state = state.copyWith(
        isComposerMutationInFlight: false,
        clearTurnControlError: true,
      );
      return true;
    } on ThreadTurnBridgeException catch (error) {
      state = state.copyWith(
        isComposerMutationInFlight: false,
        turnControlErrorMessage: error.message,
      );
      return false;
    } catch (_) {
      state = state.copyWith(
        isComposerMutationInFlight: false,
        turnControlErrorMessage:
            'Couldn’t start Commit right now. Please try again.',
      );
      return false;
    }
  }

  Future<bool> interruptActiveTurn() async {
    if (!state.isTurnActive) {
      return false;
    }

    if (!state.canRunMutatingActions) {
      state = state.copyWith(
        turnControlErrorMessage:
            'Turn controls are unavailable while the bridge is offline.',
      );
      return false;
    }

    state = state.copyWith(
      isInterruptMutationInFlight: true,
      clearTurnControlError: true,
    );

    try {
      final mutationResult = await _bridgeApi.interruptTurn(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
        threadId: state.threadId,
      );
      _applyTurnMutationResult(mutationResult);
      state = state.copyWith(
        isInterruptMutationInFlight: false,
        clearTurnControlError: true,
      );
      return true;
    } on ThreadTurnBridgeException catch (error) {
      state = state.copyWith(
        isInterruptMutationInFlight: false,
        turnControlErrorMessage: 'Interrupt failed: ${error.message}',
      );
      return false;
    } catch (_) {
      state = state.copyWith(
        isInterruptMutationInFlight: false,
        turnControlErrorMessage:
            'Interrupt failed. The turn is still active. Please try again.',
      );
      return false;
    }
  }

  Future<void> refreshGitStatus({bool showLoading = true}) async {
    final thread = state.thread;
    if (thread == null) {
      return;
    }
    final requestedThreadId = state.threadId;

    state = state.copyWith(
      isGitStatusLoading: showLoading,
      clearGitErrorMessage: true,
      clearGitMutationMessage: showLoading,
      clearGitControlsUnavailableReason: true,
    );

    try {
      final gitStatus = await _bridgeApi.fetchGitStatus(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
        threadId: requestedThreadId,
      );
      if (!_isRequestCurrent(requestedThreadId)) {
        return;
      }
      final unavailableReason =
          _isRepositoryContextResolvable(gitStatus.repository)
          ? null
          : 'Git controls are unavailable for this thread.';
      state = state.copyWith(
        gitStatus: gitStatus,
        isGitStatusLoading: false,
        clearGitErrorMessage: true,
        clearGitMutationMessage: true,
        clearGitControlsUnavailableReason: unavailableReason == null,
        gitControlsUnavailableReason: unavailableReason,
      );
    } on ThreadGitBridgeException catch (error) {
      if (_isDisposed || !_isRequestCurrent(requestedThreadId)) {
        return;
      }
      state = state.copyWith(
        clearGitStatus: state.gitStatus == null,
        isGitStatusLoading: false,
        gitErrorMessage: showLoading ? error.message : null,
        clearGitErrorMessage: !showLoading,
        clearGitMutationMessage: true,
        clearGitControlsUnavailableReason: false,
        gitControlsUnavailableReason: error.message,
      );
    } catch (_) {
      if (_isDisposed || !_isRequestCurrent(requestedThreadId)) {
        return;
      }
      state = state.copyWith(
        clearGitStatus: state.gitStatus == null,
        isGitStatusLoading: false,
        gitErrorMessage: showLoading
            ? 'Couldn’t load git status right now.'
            : null,
        clearGitErrorMessage: !showLoading,
        clearGitMutationMessage: true,
        clearGitControlsUnavailableReason: false,
        gitControlsUnavailableReason: 'Couldn’t load git status right now.',
      );
    }
  }

  Future<bool> switchBranch(String rawBranch) async {
    if (!state.canRunMutatingActions) {
      state = state.copyWith(
        gitErrorMessage:
            'Git controls are unavailable while the bridge is offline.',
        clearGitMutationMessage: true,
      );
      return false;
    }

    final branch = rawBranch.trim();
    if (branch.isEmpty) {
      state = state.copyWith(
        gitErrorMessage: 'Enter a branch name.',
        clearGitMutationMessage: true,
      );
      return false;
    }

    state = state.copyWith(
      isGitMutationInFlight: true,
      clearGitErrorMessage: true,
      clearGitMutationMessage: true,
    );

    try {
      final mutationResult = await _bridgeApi.switchBranch(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
        threadId: state.threadId,
        branch: branch,
      );
      _applyGitMutationResult(mutationResult);
      return true;
    } on ThreadGitApprovalRequiredException catch (error) {
      state = state.copyWith(
        isGitMutationInFlight: false,
        clearGitErrorMessage: true,
        gitMutationMessage: error.message,
      );
      return true;
    } on ThreadGitMutationBridgeException catch (error) {
      state = state.copyWith(
        isGitMutationInFlight: false,
        gitErrorMessage: error.message,
        clearGitMutationMessage: true,
      );
      return false;
    } catch (_) {
      state = state.copyWith(
        isGitMutationInFlight: false,
        gitErrorMessage: 'Couldn’t switch branches right now.',
        clearGitMutationMessage: true,
      );
      return false;
    }
  }

  Future<bool> pullRepository() async {
    if (!state.canRunMutatingActions) {
      state = state.copyWith(
        gitErrorMessage:
            'Git controls are unavailable while the bridge is offline.',
        clearGitMutationMessage: true,
      );
      return false;
    }

    state = state.copyWith(
      isGitMutationInFlight: true,
      clearGitErrorMessage: true,
      clearGitMutationMessage: true,
    );

    try {
      final mutationResult = await _bridgeApi.pullRepository(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
        threadId: state.threadId,
      );
      _applyGitMutationResult(mutationResult);
      return true;
    } on ThreadGitApprovalRequiredException catch (error) {
      state = state.copyWith(
        isGitMutationInFlight: false,
        clearGitErrorMessage: true,
        gitMutationMessage: error.message,
      );
      return true;
    } on ThreadGitMutationBridgeException catch (error) {
      state = state.copyWith(
        isGitMutationInFlight: false,
        gitErrorMessage: error.message,
        clearGitMutationMessage: true,
      );
      return false;
    } catch (_) {
      state = state.copyWith(
        isGitMutationInFlight: false,
        gitErrorMessage: 'Couldn’t pull the repository right now.',
        clearGitMutationMessage: true,
      );
      return false;
    }
  }

  Future<bool> pushRepository() async {
    if (!state.canRunMutatingActions) {
      state = state.copyWith(
        gitErrorMessage:
            'Git controls are unavailable while the bridge is offline.',
        clearGitMutationMessage: true,
      );
      return false;
    }

    state = state.copyWith(
      isGitMutationInFlight: true,
      clearGitErrorMessage: true,
      clearGitMutationMessage: true,
    );

    try {
      final mutationResult = await _bridgeApi.pushRepository(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
        threadId: state.threadId,
      );
      _applyGitMutationResult(mutationResult);
      return true;
    } on ThreadGitApprovalRequiredException catch (error) {
      state = state.copyWith(
        isGitMutationInFlight: false,
        clearGitErrorMessage: true,
        gitMutationMessage: error.message,
      );
      return true;
    } on ThreadGitMutationBridgeException catch (error) {
      state = state.copyWith(
        isGitMutationInFlight: false,
        gitErrorMessage: error.message,
        clearGitMutationMessage: true,
      );
      return false;
    } catch (_) {
      state = state.copyWith(
        isGitMutationInFlight: false,
        gitErrorMessage: 'Couldn’t push the repository right now.',
        clearGitMutationMessage: true,
      );
      return false;
    }
  }

  void _applyGitMutationResult(MutationResultResponseDto mutationResult) {
    final thread = state.thread;
    final nextUpdatedAt = DateTime.now().toUtc().toIso8601String();
    final nextGitStatus = GitStatusResponseDto(
      contractVersion: mutationResult.contractVersion,
      threadId: mutationResult.threadId,
      repository: mutationResult.repository,
      status: mutationResult.status,
    );

    ThreadDetailDto? nextThread = thread;
    if (thread != null) {
      nextThread = ThreadDetailDto(
        contractVersion: thread.contractVersion,
        threadId: thread.threadId,
        title: thread.title,
        status: mutationResult.threadStatus,
        workspace: thread.workspace,
        repository: mutationResult.repository.repository,
        branch: mutationResult.repository.branch,
        createdAt: thread.createdAt,
        updatedAt: nextUpdatedAt,
        source: thread.source,
        accessMode: thread.accessMode,
        lastTurnSummary: mutationResult.message,
      );
      _threadListController.syncThreadDetail(nextThread);
    }

    state = state.copyWith(
      thread: nextThread,
      gitStatus: nextGitStatus,
      isGitStatusLoading: false,
      isGitMutationInFlight: false,
      clearGitErrorMessage: true,
      gitMutationMessage: mutationResult.message,
      clearGitControlsUnavailableReason: true,
    );
  }

  void _applyTurnMutationResult(TurnMutationResult mutationResult) {
    final thread = state.thread;
    if (thread == null) {
      return;
    }

    final updatedAt = DateTime.now().toUtc().toIso8601String();
    _updateThreadStatus(
      status: mutationResult.threadStatus,
      updatedAt: updatedAt,
      lastTurnSummary: mutationResult.message,
    );
    _threadListController.applyThreadStatusUpdate(
      threadId: thread.threadId,
      status: mutationResult.threadStatus,
      updatedAt: updatedAt,
    );
  }

  void _updateThreadStatus({
    required ThreadStatus status,
    required String updatedAt,
    required String lastTurnSummary,
  }) {
    final thread = state.thread;
    if (thread == null) {
      return;
    }

    state = state.copyWith(
      thread: ThreadDetailDto(
        contractVersion: thread.contractVersion,
        threadId: thread.threadId,
        title: thread.title,
        status: status,
        workspace: thread.workspace,
        repository: thread.repository,
        branch: thread.branch,
        createdAt: thread.createdAt,
        updatedAt: updatedAt,
        source: thread.source,
        accessMode: thread.accessMode,
        lastTurnSummary: lastTurnSummary,
      ),
    );

    if (status != ThreadStatus.running) {
      _pendingPromptSubmittedAt = null;
    }
  }

  void _logPromptResponseIfNeeded({
    required BridgeEventEnvelope<Map<String, dynamic>> event,
    required ThreadActivityItem nextItem,
  }) {
    final submittedAt = _pendingPromptSubmittedAt;
    if (submittedAt == null) {
      return;
    }
    if (event.kind != BridgeEventKind.messageDelta) {
      return;
    }
    if (nextItem.type != ThreadActivityItemType.assistantOutput) {
      return;
    }

    final visibleText = nextItem.body.trim();
    if (visibleText.isEmpty) {
      return;
    }

    final elapsedMs = DateTime.now().difference(submittedAt).inMilliseconds;
    _debugLog(
      'thread_detail_response_received '
      'threadId=${state.threadId} '
      'eventId=${event.eventId} '
      'elapsedMs=$elapsedMs '
      'chars=${visibleText.length}',
    );
    _pendingPromptSubmittedAt = null;
  }

  void _logLiveEvent({
    required BridgeEventEnvelope<Map<String, dynamic>> event,
    required Map<String, dynamic> mergedPayload,
    required ThreadActivityItem nextItem,
  }) {
    if (event.kind != BridgeEventKind.messageDelta) {
      return;
    }

    final delta = event.payload['delta'];
    final mergedTextValue = mergedPayload['text'];
    final deltaLength = delta is String ? delta.length : 0;
    final mergedTextLength = mergedTextValue is String
        ? mergedTextValue.length
        : 0;
    final renderedBodyLength = nextItem.body.length;
    _debugLog(
      'thread_detail_live_event '
      'threadId=${state.threadId} '
      'eventId=${event.eventId} '
      'kind=${event.kind.wireValue} '
      'deltaChars=$deltaLength '
      'mergedTextChars=$mergedTextLength '
      'renderedBodyChars=$renderedBodyLength '
      'replace=${event.payload['replace'] == true}',
    );
  }

  Map<String, dynamic> _mergeLivePayload(
    Map<String, dynamic>? currentPayload,
    BridgeEventEnvelope<Map<String, dynamic>> event,
  ) {
    final payload = Map<String, dynamic>.from(currentPayload ?? const {});
    payload.addAll(event.payload);

    switch (event.kind) {
      case BridgeEventKind.messageDelta:
        payload['replace'] = event.payload['replace'] == true;
        _mergeIncrementalField(payload, 'text');
        payload['type'] = payload['type'] ?? 'message';
        break;
      case BridgeEventKind.planDelta:
        payload['replace'] = event.payload['replace'] == true;
        _mergeIncrementalField(payload, 'text');
        payload['type'] = payload['type'] ?? 'plan';
        break;
      case BridgeEventKind.commandDelta:
        payload['replace'] = event.payload['replace'] == true;
        _mergeIncrementalField(payload, 'output');
        payload['output'] ??= payload['aggregatedOutput'];
        payload['aggregatedOutput'] = payload['output'];
        payload['type'] = payload['type'] ?? 'command';
        break;
      case BridgeEventKind.fileChange:
        payload['replace'] = event.payload['replace'] == true;
        _mergeIncrementalField(payload, 'resolved_unified_diff');
        payload['resolved_unified_diff'] ??= payload['output'];
        payload['type'] = payload['type'] ?? 'file_change';
        break;
      case BridgeEventKind.threadStatusChanged:
      case BridgeEventKind.approvalRequested:
      case BridgeEventKind.securityAudit:
        break;
    }

    return payload;
  }

  void _mergeIncrementalField(
    Map<String, dynamic> payload,
    String canonicalField,
  ) {
    final replace = payload['replace'] == true;
    final delta = payload['delta'];
    final nextDelta = delta is String ? delta : '';
    final existingValue = payload[canonicalField];
    final existingText = existingValue is String ? existingValue : '';

    if (nextDelta.isEmpty) {
      if (existingText.isEmpty) {
        final fallback = payload['text'];
        if (fallback is String && fallback.isNotEmpty) {
          payload[canonicalField] = fallback;
        }
      }
      return;
    }

    payload[canonicalField] = replace ? nextDelta : '$existingText$nextDelta';
  }

  Future<void> _closeLiveSubscription() async {
    await _liveEventSubscription?.cancel();
    _liveEventSubscription = null;

    final subscription = _liveSubscription;
    _liveSubscription = null;
    if (subscription == null) {
      return;
    }

    try {
      await subscription.close();
    } catch (_) {
      // Ignore teardown failures from already-closed sockets/streams.
    }
  }

  static void _defaultDebugLog(String message) {
    debugPrint(message);
  }

  @override
  void dispose() {
    _isDisposed = true;
    _reconnectTimer?.cancel();
    _detailRefreshTimer?.cancel();
    unawaited(_closeLiveSubscription());
    super.dispose();
  }
}

bool _isRepositoryContextResolvable(RepositoryContextDto context) {
  final repository = context.repository.trim().toLowerCase();
  final branch = context.branch.trim().toLowerCase();

  if (repository.isEmpty ||
      repository == 'unknown' ||
      repository == 'unknown-repository') {
    return false;
  }

  if (branch.isEmpty || branch == 'unknown') {
    return false;
  }

  return true;
}
