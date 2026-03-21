import 'dart:async';

import 'package:codex_mobile_companion/foundation/connectivity/live_connection_state.dart';
import 'package:codex_mobile_companion/features/threads/application/thread_list_controller.dart';
import 'package:codex_mobile_companion/features/threads/data/thread_detail_bridge_api.dart';
import 'package:codex_mobile_companion/features/threads/data/thread_live_stream.dart';
import 'package:codex_mobile_companion/features/threads/domain/thread_activity_item.dart';
import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
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
    this.liveConnectionState = LiveConnectionState.reconnecting,
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
  }) : _bridgeApiBaseUrl = bridgeApiBaseUrl,
       _initialVisibleTimelineEntries = initialVisibleTimelineEntries,
       _bridgeApi = bridgeApi,
       _liveStream = liveStream,
       _threadListController = threadListController,
       super(ThreadDetailState(threadId: threadId)) {
    loadThread();
  }

  final String _bridgeApiBaseUrl;
  final int _initialVisibleTimelineEntries;
  final ThreadDetailBridgeApi _bridgeApi;
  final ThreadLiveStream _liveStream;
  final ThreadListController _threadListController;
  final Set<String> _knownEventIds = <String>{};

  ThreadLiveSubscription? _liveSubscription;
  StreamSubscription<BridgeEventEnvelope<Map<String, dynamic>>>?
  _liveEventSubscription;
  Timer? _reconnectTimer;
  bool _isReconnectInProgress = false;
  bool _isDisposed = false;

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
        liveConnectionState: LiveConnectionState.reconnecting,
        isLoading: false,
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

      _threadListController.syncThreadDetail(scopedDetail);
      await refreshGitStatus(showLoading: true);
      await _startLiveSubscription();
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
      liveConnectionState: LiveConnectionState.reconnecting,
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
      );

      _threadListController.syncThreadDetail(scopedDetail);
      await refreshGitStatus(showLoading: false);
      await _startLiveSubscription();
    } on ThreadDetailBridgeException catch (error) {
      if (_isDisposed) {
        return;
      }

      state = state.copyWith(
        liveConnectionState: LiveConnectionState.reconnecting,
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
    } else {
      final thread = state.thread;
      if (thread != null) {
        _updateThreadStatus(
          status: thread.status,
          updatedAt: event.occurredAt,
          lastTurnSummary: thread.lastTurnSummary,
        );
        _threadListController.applyThreadStatusUpdate(
          threadId: event.threadId,
          status: thread.status,
          updatedAt: event.occurredAt,
        );
      }
    }

    final nextItem = ThreadActivityItem.fromLiveEvent(event);
    final nextItems = List<ThreadActivityItem>.from(state.items);
    if (existingIndex >= 0) {
      nextItems[existingIndex] = nextItem;
    } else {
      nextItems.add(nextItem);
      _knownEventIds.add(event.eventId);
    }

    state = state.copyWith(items: nextItems, clearStreamErrorMessage: true);
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

  Future<bool> submitComposerInput(String rawInput) async {
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
    if (input.isEmpty) {
      state = state.copyWith(
        turnControlErrorMessage: state.isTurnActive
            ? 'Enter steering instructions before sending.'
            : 'Enter a prompt to start a turn.',
      );
      return false;
    }

    state = state.copyWith(
      isComposerMutationInFlight: true,
      clearTurnControlError: true,
    );

    try {
      final mutationResult = state.isTurnActive
          ? await _bridgeApi.steerTurn(
              bridgeApiBaseUrl: _bridgeApiBaseUrl,
              threadId: state.threadId,
              instruction: input,
            )
          : await _bridgeApi.startTurn(
              bridgeApiBaseUrl: _bridgeApiBaseUrl,
              threadId: state.threadId,
              prompt: input,
            );

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
    final thread = state.thread;
    if (thread == null) {
      return false;
    }

    if (!state.canRunMutatingActions) {
      state = state.copyWith(
        openOnMacErrorMessage:
            'Open-on-Mac is unavailable while the bridge is offline.',
        clearOpenOnMacMessage: true,
      );
      return false;
    }

    state = state.copyWith(
      isOpenOnMacInFlight: true,
      clearOpenOnMacMessage: true,
      clearOpenOnMacErrorMessage: true,
    );

    try {
      final result = await _bridgeApi.openOnMac(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
        threadId: state.threadId,
      );

      state = state.copyWith(
        isOpenOnMacInFlight: false,
        openOnMacMessage: result.message,
        clearOpenOnMacErrorMessage: true,
      );
      return true;
    } on ThreadOpenOnMacBridgeException catch (error) {
      state = state.copyWith(
        isOpenOnMacInFlight: false,
        openOnMacErrorMessage: error.message,
        clearOpenOnMacMessage: true,
      );
      return false;
    } catch (_) {
      state = state.copyWith(
        isOpenOnMacInFlight: false,
        openOnMacErrorMessage:
            'Couldn’t open this thread in Codex.app right now.',
        clearOpenOnMacMessage: true,
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
    if (state.thread == null || state.isConnectivityUnavailable) {
      state = state.copyWith(
        clearGitStatus: true,
        isGitStatusLoading: false,
        isGitMutationInFlight: false,
        clearGitErrorMessage: true,
        clearGitMutationMessage: showLoading,
        gitControlsUnavailableReason: state.isConnectivityUnavailable
            ? 'Git controls are unavailable while reconnecting to the private route.'
            : 'Git status is unavailable until thread context loads.',
      );
      return;
    }

    if (showLoading) {
      state = state.copyWith(
        isGitStatusLoading: true,
        clearGitErrorMessage: true,
        clearGitControlsUnavailableReason: true,
      );
    }

    try {
      final gitStatus = await _bridgeApi.fetchGitStatus(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
        threadId: state.threadId,
      );

      _syncThreadWithRepositoryContext(gitStatus.repository);

      state = state.copyWith(
        gitStatus: gitStatus,
        isGitStatusLoading: false,
        clearGitErrorMessage: showLoading,
        clearGitControlsUnavailableReason: true,
      );

      if (!_isRepositoryContextResolvable(gitStatus.repository)) {
        state = state.copyWith(
          gitControlsUnavailableReason:
              'Git controls are unavailable because this thread has no repository context.',
        );
      }
    } on ThreadGitBridgeException catch (error) {
      state = state.copyWith(
        clearGitStatus: true,
        isGitStatusLoading: false,
        gitErrorMessage: error.message,
        gitControlsUnavailableReason:
            error.statusCode == 404 || error.code == 'not_found'
            ? 'Git controls are unavailable because this thread is not in a repository context.'
            : null,
      );
    } catch (_) {
      state = state.copyWith(
        clearGitStatus: true,
        isGitStatusLoading: false,
        gitErrorMessage: 'Couldn’t load git status right now.',
      );
    }
  }

  Future<bool> switchBranch(String rawBranch) async {
    final thread = state.thread;
    if (thread == null) {
      return false;
    }

    if (!state.canRunMutatingActions) {
      state = state.copyWith(
        gitErrorMessage:
            'Git controls are unavailable while the bridge is offline.',
      );
      return false;
    }

    final branch = rawBranch.trim();
    if (branch.isEmpty) {
      state = state.copyWith(
        gitErrorMessage:
            'Bad request (client validation): branch name cannot be blank.',
        clearGitMutationMessage: true,
      );
      return false;
    }

    if (!state.hasGitRepositoryContext) {
      state = state.copyWith(
        gitErrorMessage:
            'Git controls are unavailable because this thread has no repository context.',
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
      state = state.copyWith(
        isGitMutationInFlight: false,
        gitMutationMessage: mutationResult.message,
        clearGitErrorMessage: true,
      );
      await refreshGitStatus(showLoading: false);
      return true;
    } on ThreadGitApprovalRequiredException catch (error) {
      _applyGitApprovalRequired(error);
      state = state.copyWith(
        isGitMutationInFlight: false,
        clearGitErrorMessage: true,
      );
      await refreshGitStatus(showLoading: false);
      return true;
    } on ThreadGitMutationBridgeException catch (error) {
      state = state.copyWith(
        isGitMutationInFlight: false,
        gitErrorMessage: error.message,
        clearGitMutationMessage: true,
      );
      await refreshGitStatus(showLoading: false);
      return false;
    } catch (_) {
      state = state.copyWith(
        isGitMutationInFlight: false,
        gitErrorMessage: 'Couldn’t switch branch right now.',
        clearGitMutationMessage: true,
      );
      await refreshGitStatus(showLoading: false);
      return false;
    }
  }

  Future<bool> pullRepository() async {
    if (!state.canRunMutatingActions) {
      state = state.copyWith(
        gitErrorMessage:
            'Git controls are unavailable while the bridge is offline.',
      );
      return false;
    }

    final repository = state.gitStatus?.repository;
    if (repository == null || !_isRepositoryContextResolvable(repository)) {
      state = state.copyWith(
        gitErrorMessage:
            'Git controls are unavailable because this thread has no repository context.',
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
        remote: repository.remote,
      );

      _applyGitMutationResult(mutationResult);
      state = state.copyWith(
        isGitMutationInFlight: false,
        gitMutationMessage: mutationResult.message,
        clearGitErrorMessage: true,
      );
      await refreshGitStatus(showLoading: false);
      return true;
    } on ThreadGitApprovalRequiredException catch (error) {
      _applyGitApprovalRequired(error);
      state = state.copyWith(
        isGitMutationInFlight: false,
        clearGitErrorMessage: true,
      );
      await refreshGitStatus(showLoading: false);
      return true;
    } on ThreadGitMutationBridgeException catch (error) {
      state = state.copyWith(
        isGitMutationInFlight: false,
        gitErrorMessage: error.message,
        clearGitMutationMessage: true,
      );
      await refreshGitStatus(showLoading: false);
      return false;
    } catch (_) {
      state = state.copyWith(
        isGitMutationInFlight: false,
        gitErrorMessage: 'Couldn’t run pull right now.',
        clearGitMutationMessage: true,
      );
      await refreshGitStatus(showLoading: false);
      return false;
    }
  }

  Future<bool> pushRepository() async {
    if (!state.canRunMutatingActions) {
      state = state.copyWith(
        gitErrorMessage:
            'Git controls are unavailable while the bridge is offline.',
      );
      return false;
    }

    final repository = state.gitStatus?.repository;
    if (repository == null || !_isRepositoryContextResolvable(repository)) {
      state = state.copyWith(
        gitErrorMessage:
            'Git controls are unavailable because this thread has no repository context.',
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
        remote: repository.remote,
      );

      _applyGitMutationResult(mutationResult);
      state = state.copyWith(
        isGitMutationInFlight: false,
        gitMutationMessage: mutationResult.message,
        clearGitErrorMessage: true,
      );
      await refreshGitStatus(showLoading: false);
      return true;
    } on ThreadGitApprovalRequiredException catch (error) {
      _applyGitApprovalRequired(error);
      state = state.copyWith(
        isGitMutationInFlight: false,
        clearGitErrorMessage: true,
      );
      await refreshGitStatus(showLoading: false);
      return true;
    } on ThreadGitMutationBridgeException catch (error) {
      state = state.copyWith(
        isGitMutationInFlight: false,
        gitErrorMessage: error.message,
        clearGitMutationMessage: true,
      );
      await refreshGitStatus(showLoading: false);
      return false;
    } catch (_) {
      state = state.copyWith(
        isGitMutationInFlight: false,
        gitErrorMessage: 'Couldn’t run push right now.',
        clearGitMutationMessage: true,
      );
      await refreshGitStatus(showLoading: false);
      return false;
    }
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

  void _applyGitMutationResult(MutationResultResponseDto mutationResult) {
    state = state.copyWith(
      gitStatus: GitStatusResponseDto(
        contractVersion: mutationResult.contractVersion,
        threadId: mutationResult.threadId,
        repository: mutationResult.repository,
        status: mutationResult.status,
      ),
      clearGitControlsUnavailableReason: true,
    );

    _syncThreadWithRepositoryContext(
      mutationResult.repository,
      status: mutationResult.threadStatus,
      updatedAt: DateTime.now().toUtc().toIso8601String(),
      lastTurnSummary: mutationResult.message,
    );
  }

  void _applyGitApprovalRequired(ThreadGitApprovalRequiredException gate) {
    final approval = gate.approval;
    state = state.copyWith(
      gitStatus: GitStatusResponseDto(
        contractVersion: approval.contractVersion,
        threadId: approval.threadId,
        repository: approval.repository,
        status: approval.gitStatus,
      ),
      gitMutationMessage: _pendingGitApprovalMessage(approval),
      clearGitErrorMessage: true,
      clearGitControlsUnavailableReason: true,
    );

    _syncThreadWithRepositoryContext(approval.repository);
  }

  void _syncThreadWithRepositoryContext(
    RepositoryContextDto repositoryContext, {
    ThreadStatus? status,
    String? updatedAt,
    String? lastTurnSummary,
  }) {
    final thread = state.thread;
    if (thread == null) {
      return;
    }

    final resolvedStatus = status ?? thread.status;
    final resolvedUpdatedAt = updatedAt ?? thread.updatedAt;
    final resolvedLastTurnSummary = lastTurnSummary ?? thread.lastTurnSummary;

    final updatedThread = ThreadDetailDto(
      contractVersion: thread.contractVersion,
      threadId: thread.threadId,
      title: thread.title,
      status: resolvedStatus,
      workspace: repositoryContext.workspace,
      repository: repositoryContext.repository,
      branch: repositoryContext.branch,
      createdAt: thread.createdAt,
      updatedAt: resolvedUpdatedAt,
      source: thread.source,
      accessMode: thread.accessMode,
      lastTurnSummary: resolvedLastTurnSummary,
    );

    state = state.copyWith(thread: updatedThread);
    _threadListController.syncThreadDetail(updatedThread);
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

  @override
  void dispose() {
    _isDisposed = true;
    _reconnectTimer?.cancel();
    unawaited(_closeLiveSubscription());
    super.dispose();
  }
}

String _pendingGitApprovalMessage(ApprovalRecordDto approval) {
  switch (approval.action) {
    case 'git_branch_switch':
      return 'Branch switch to ${approval.target} is pending approval for ${approval.repository.repository} (current branch: ${approval.repository.branch}).';
    case 'git_pull':
      return 'Pull from ${approval.target} is pending approval for ${approval.repository.repository} on ${approval.repository.branch}.';
    case 'git_push':
      return 'Push to ${approval.target} is pending approval for ${approval.repository.repository} on ${approval.repository.branch}.';
    default:
      return 'Action is pending approval: ${approval.action} (${approval.target}).';
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
