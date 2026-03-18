import 'dart:async';

import 'package:codex_mobile_companion/features/threads/application/thread_list_controller.dart';
import 'package:codex_mobile_companion/features/threads/data/thread_cache_repository.dart';
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
        cacheRepository: ref.watch(threadCacheRepositoryProvider),
        liveStream: ref.watch(threadLiveStreamProvider),
        threadListController: threadListController,
      );
    });

class ThreadDetailControllerArgs {
  const ThreadDetailControllerArgs({
    required this.bridgeApiBaseUrl,
    required this.threadId,
    this.initialVisibleTimelineEntries = 20,
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
    this.thread,
    this.items = const <ThreadActivityItem>[],
    this.errorMessage,
    this.streamErrorMessage,
    this.staleMessage,
    this.isUnavailable = false,
    this.isLoading = true,
    this.isShowingCachedData = false,
    this.isConnectivityUnavailable = false,
    this.visibleItemCount = 0,
    this.isComposerMutationInFlight = false,
    this.isInterruptMutationInFlight = false,
    this.turnControlErrorMessage,
  });

  final String threadId;
  final ThreadDetailDto? thread;
  final List<ThreadActivityItem> items;
  final String? errorMessage;
  final String? streamErrorMessage;
  final String? staleMessage;
  final bool isUnavailable;
  final bool isLoading;
  final bool isShowingCachedData;
  final bool isConnectivityUnavailable;
  final int visibleItemCount;
  final bool isComposerMutationInFlight;
  final bool isInterruptMutationInFlight;
  final String? turnControlErrorMessage;

  bool get hasThread => thread != null;

  bool get hasError => errorMessage != null;

  bool get canRunMutatingActions => !isConnectivityUnavailable;

  bool get isTurnActive => thread?.status == ThreadStatus.running;

  int get hiddenHistoryCount {
    if (items.length <= visibleItemCount) {
      return 0;
    }

    return items.length - visibleItemCount;
  }

  bool get canLoadEarlierHistory => hiddenHistoryCount > 0;

  List<ThreadActivityItem> get visibleItems {
    if (items.isEmpty) {
      return const <ThreadActivityItem>[];
    }

    if (visibleItemCount <= 0 || visibleItemCount >= items.length) {
      return List<ThreadActivityItem>.unmodifiable(items);
    }

    return List<ThreadActivityItem>.unmodifiable(
      items.sublist(items.length - visibleItemCount),
    );
  }

  ThreadDetailState copyWith({
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
    int? visibleItemCount,
    bool? isComposerMutationInFlight,
    bool? isInterruptMutationInFlight,
    String? turnControlErrorMessage,
    bool clearTurnControlError = false,
  }) {
    return ThreadDetailState(
      threadId: threadId,
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
      visibleItemCount: visibleItemCount ?? this.visibleItemCount,
      isComposerMutationInFlight:
          isComposerMutationInFlight ?? this.isComposerMutationInFlight,
      isInterruptMutationInFlight:
          isInterruptMutationInFlight ?? this.isInterruptMutationInFlight,
      turnControlErrorMessage: clearTurnControlError
          ? null
          : (turnControlErrorMessage ?? this.turnControlErrorMessage),
    );
  }
}

class ThreadDetailController extends StateNotifier<ThreadDetailState> {
  ThreadDetailController({
    required String bridgeApiBaseUrl,
    required String threadId,
    required int initialVisibleTimelineEntries,
    required ThreadDetailBridgeApi bridgeApi,
    required ThreadCacheRepository cacheRepository,
    required ThreadLiveStream liveStream,
    required ThreadListController threadListController,
  }) : _bridgeApiBaseUrl = bridgeApiBaseUrl,
       _initialVisibleTimelineEntries = initialVisibleTimelineEntries,
       _bridgeApi = bridgeApi,
       _cacheRepository = cacheRepository,
       _liveStream = liveStream,
       _threadListController = threadListController,
       super(ThreadDetailState(threadId: threadId)) {
    loadThread();
  }

  final String _bridgeApiBaseUrl;
  final int _initialVisibleTimelineEntries;
  final ThreadDetailBridgeApi _bridgeApi;
  final ThreadCacheRepository _cacheRepository;
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
    );

    try {
      await _closeLiveSubscription();
      _knownEventIds.clear();

      final detail = await _bridgeApi.fetchThreadDetail(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
        threadId: state.threadId,
      );
      final timeline = await _bridgeApi.fetchThreadTimeline(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
        threadId: state.threadId,
      );

      await _cacheRepository.saveThreadDetail(
        detail: detail,
        timeline: timeline,
      );

      final items = timeline
          .map(ThreadActivityItem.fromTimelineEntry)
          .toList(growable: false);
      _knownEventIds.addAll(items.map((item) => item.eventId));

      final visibleItemCount = _initialVisibleCount(items.length);

      state = state.copyWith(
        thread: detail,
        items: items,
        visibleItemCount: visibleItemCount,
        isLoading: false,
        isUnavailable: false,
        clearErrorMessage: true,
        clearStreamErrorMessage: true,
        clearStaleMessage: true,
        clearTurnControlError: true,
        isShowingCachedData: false,
        isConnectivityUnavailable: false,
      );

      _threadListController.syncThreadDetail(detail);
      await _startLiveSubscription();
    } on ThreadDetailBridgeException catch (error) {
      if (error.isConnectivityError) {
        final loadedFromCache = await _loadFromCachedThreadSnapshot(
          bridgeMessage: error.message,
        );
        if (loadedFromCache) {
          _scheduleReconnectCatchUp();
          return;
        }
      }

      state = state.copyWith(
        isLoading: false,
        errorMessage: error.message,
        isUnavailable: error.isUnavailable,
      );
    } catch (_) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: 'Couldn’t load this thread right now.',
      );
    }
  }

  void loadEarlierHistory() {
    if (!state.canLoadEarlierHistory) {
      return;
    }

    final nextVisibleCount =
        state.visibleItemCount + _initialVisibleTimelineEntries;
    state = state.copyWith(
      visibleItemCount: nextVisibleCount > state.items.length
          ? state.items.length
          : nextVisibleCount,
    );
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
      streamErrorMessage:
          'Live updates disconnected. Reconnecting and catching up…',
      staleMessage:
          'Bridge is offline. Showing cached thread content. Mutating actions are blocked until reconnect.',
      isShowingCachedData: true,
      isConnectivityUnavailable: true,
    );
  }

  void _scheduleReconnectCatchUp() {
    if (_isDisposed ||
        _isReconnectInProgress ||
        _reconnectTimer?.isActive == true) {
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

      final detail = await _bridgeApi.fetchThreadDetail(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
        threadId: state.threadId,
      );
      final timeline = await _bridgeApi.fetchThreadTimeline(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
        threadId: state.threadId,
      );

      final mergedItems = _mergeTimeline(timeline);

      await _cacheRepository.saveThreadDetail(
        detail: detail,
        timeline: timeline,
      );

      state = state.copyWith(
        thread: detail,
        items: mergedItems,
        visibleItemCount: _nextVisibleCountForMergedItems(
          previousVisibleItemCount: state.visibleItemCount,
          previousItemCount: state.items.length,
          nextItemCount: mergedItems.length,
        ),
        clearErrorMessage: true,
        clearStreamErrorMessage: true,
        clearStaleMessage: true,
        clearTurnControlError: true,
        isLoading: false,
        isUnavailable: false,
        isShowingCachedData: false,
        isConnectivityUnavailable: false,
      );

      _threadListController.syncThreadDetail(detail);
      await _startLiveSubscription();
    } on ThreadDetailBridgeException catch (error) {
      if (!error.isConnectivityError) {
        state = state.copyWith(
          streamErrorMessage: error.message,
          staleMessage:
              'Bridge is offline. Showing cached thread content. Mutating actions are blocked until reconnect.',
          isShowingCachedData: true,
          isConnectivityUnavailable: true,
        );
      }
      _scheduleReconnectCatchUp();
    } catch (_) {
      _scheduleReconnectCatchUp();
    } finally {
      _isReconnectInProgress = false;
    }
  }

  Future<bool> _loadFromCachedThreadSnapshot({
    required String bridgeMessage,
  }) async {
    final cachedSnapshot = await _cacheRepository.readThreadDetail(
      state.threadId,
    );
    if (cachedSnapshot == null) {
      return false;
    }

    final items = cachedSnapshot.timeline
        .map(ThreadActivityItem.fromTimelineEntry)
        .toList(growable: false);

    _knownEventIds
      ..clear()
      ..addAll(items.map((item) => item.eventId));

    state = state.copyWith(
      thread: cachedSnapshot.detail,
      items: items,
      visibleItemCount: _initialVisibleCount(items.length),
      clearErrorMessage: true,
      streamErrorMessage: bridgeMessage,
      staleMessage:
          'Bridge is offline. Showing cached thread content. Mutating actions are blocked until reconnect.',
      isLoading: false,
      isUnavailable: false,
      isShowingCachedData: true,
      isConnectivityUnavailable: true,
    );

    _threadListController.syncThreadDetail(cachedSnapshot.detail);
    return true;
  }

  List<ThreadActivityItem> _mergeTimeline(
    List<ThreadTimelineEntryDto> timeline,
  ) {
    if (timeline.isEmpty) {
      return state.items;
    }

    final nextItems = List<ThreadActivityItem>.from(state.items);
    for (final entry in timeline) {
      if (_knownEventIds.contains(entry.eventId)) {
        continue;
      }

      nextItems.add(ThreadActivityItem.fromTimelineEntry(entry));
      _knownEventIds.add(entry.eventId);
    }

    return nextItems;
  }

  int _initialVisibleCount(int itemCount) {
    if (itemCount <= 0) {
      return 0;
    }

    return itemCount < _initialVisibleTimelineEntries
        ? itemCount
        : _initialVisibleTimelineEntries;
  }

  int _nextVisibleCountForMergedItems({
    required int previousVisibleItemCount,
    required int previousItemCount,
    required int nextItemCount,
  }) {
    final shouldExpandVisibleWindow =
        previousVisibleItemCount >= previousItemCount;
    if (!shouldExpandVisibleWindow) {
      return previousVisibleItemCount > nextItemCount
          ? nextItemCount
          : previousVisibleItemCount;
    }

    final delta = nextItemCount - previousItemCount;
    final candidate = previousVisibleItemCount + (delta > 0 ? delta : 0);
    return candidate > nextItemCount ? nextItemCount : candidate;
  }

  void _handleLiveEvent(BridgeEventEnvelope<Map<String, dynamic>> event) {
    if (event.threadId != state.threadId ||
        _knownEventIds.contains(event.eventId)) {
      return;
    }

    if (event.kind == BridgeEventKind.threadStatusChanged) {
      _applyLifecycleStatusUpdate(event);
    }

    final nextItems = List<ThreadActivityItem>.from(state.items)
      ..add(ThreadActivityItem.fromLiveEvent(event));
    _knownEventIds.add(event.eventId);

    final previousItemCount = state.items.length;
    final shouldExpandVisibleWindow =
        state.visibleItemCount >= previousItemCount;
    final nextVisibleCount = shouldExpandVisibleWindow
        ? state.visibleItemCount + 1
        : state.visibleItemCount;

    state = state.copyWith(
      items: nextItems,
      visibleItemCount: nextVisibleCount > nextItems.length
          ? nextItems.length
          : nextVisibleCount,
      clearStreamErrorMessage: true,
    );
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
