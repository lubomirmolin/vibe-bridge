import 'dart:async';

import 'package:codex_mobile_companion/features/threads/application/thread_list_controller.dart';
import 'package:codex_mobile_companion/features/threads/data/thread_detail_bridge_api.dart';
import 'package:codex_mobile_companion/features/threads/data/thread_live_stream.dart';
import 'package:codex_mobile_companion/features/threads/domain/thread_activity_item.dart';
import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final threadDetailControllerProvider = StateNotifierProvider.autoDispose
    .family<ThreadDetailController, ThreadDetailState, ThreadDetailControllerArgs>(
      (ref, args) {
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
      },
    );

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
  int get hashCode => Object.hash(
    bridgeApiBaseUrl,
    threadId,
    initialVisibleTimelineEntries,
  );
}

class ThreadDetailState {
  const ThreadDetailState({
    required this.threadId,
    this.thread,
    this.items = const <ThreadActivityItem>[],
    this.errorMessage,
    this.streamErrorMessage,
    this.isUnavailable = false,
    this.isLoading = true,
    this.visibleItemCount = 0,
  });

  final String threadId;
  final ThreadDetailDto? thread;
  final List<ThreadActivityItem> items;
  final String? errorMessage;
  final String? streamErrorMessage;
  final bool isUnavailable;
  final bool isLoading;
  final int visibleItemCount;

  bool get hasThread => thread != null;

  bool get hasError => errorMessage != null;

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
    bool? isUnavailable,
    bool? isLoading,
    int? visibleItemCount,
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
      isUnavailable: isUnavailable ?? this.isUnavailable,
      isLoading: isLoading ?? this.isLoading,
      visibleItemCount: visibleItemCount ?? this.visibleItemCount,
    );
  }
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

  Future<void> loadThread() async {
    state = state.copyWith(
      isLoading: true,
      isUnavailable: false,
      clearErrorMessage: true,
      clearStreamErrorMessage: true,
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

      final items = timeline
          .map(ThreadActivityItem.fromTimelineEntry)
          .toList(growable: false);
      _knownEventIds.addAll(items.map((item) => item.eventId));

      final visibleItemCount = items.isEmpty
          ? 0
          : items.length < _initialVisibleTimelineEntries
          ? items.length
          : _initialVisibleTimelineEntries;

      state = state.copyWith(
        thread: detail,
        items: items,
        visibleItemCount: visibleItemCount,
        isLoading: false,
        isUnavailable: false,
        clearErrorMessage: true,
        clearStreamErrorMessage: true,
      );

      _threadListController.syncThreadDetail(detail);
      await _startLiveSubscription();
    } on ThreadDetailBridgeException catch (error) {
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

    final nextVisibleCount = state.visibleItemCount + _initialVisibleTimelineEntries;
    state = state.copyWith(
      visibleItemCount: nextVisibleCount > state.items.length
          ? state.items.length
          : nextVisibleCount,
    );
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
          state = state.copyWith(
            streamErrorMessage:
                'Live updates disconnected. Pull to retry thread history.',
          );
        },
      );
    } catch (_) {
      state = state.copyWith(
        streamErrorMessage:
            'Live updates are unavailable. Pull to refresh thread history.',
      );
    }
  }

  void _handleLiveEvent(BridgeEventEnvelope<Map<String, dynamic>> event) {
    if (event.threadId != state.threadId || _knownEventIds.contains(event.eventId)) {
      return;
    }

    if (event.kind == BridgeEventKind.threadStatusChanged) {
      _applyLifecycleStatusUpdate(event);
    }

    final nextItems = List<ThreadActivityItem>.from(state.items)
      ..add(ThreadActivityItem.fromLiveEvent(event));
    _knownEventIds.add(event.eventId);

    final previousItemCount = state.items.length;
    final shouldExpandVisibleWindow = state.visibleItemCount >= previousItemCount;
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

    final updatedThread = ThreadDetailDto(
      contractVersion: thread.contractVersion,
      threadId: thread.threadId,
      title: thread.title,
      status: status,
      workspace: thread.workspace,
      repository: thread.repository,
      branch: thread.branch,
      createdAt: thread.createdAt,
      updatedAt: event.occurredAt,
      source: thread.source,
      accessMode: thread.accessMode,
      lastTurnSummary: thread.lastTurnSummary,
    );

    state = state.copyWith(thread: updatedThread);
    _threadListController.applyThreadStatusUpdate(
      threadId: updatedThread.threadId,
      status: status,
      updatedAt: event.occurredAt,
    );
  }

  Future<void> _closeLiveSubscription() async {
    await _liveEventSubscription?.cancel();
    _liveEventSubscription = null;
    await _liveSubscription?.close();
    _liveSubscription = null;
  }

  @override
  void dispose() {
    unawaited(_closeLiveSubscription());
    super.dispose();
  }
}
