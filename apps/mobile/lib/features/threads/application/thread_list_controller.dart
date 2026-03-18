import 'dart:async';

import 'package:codex_mobile_companion/features/threads/data/thread_cache_repository.dart';
import 'package:codex_mobile_companion/features/threads/data/thread_list_bridge_api.dart';
import 'package:codex_mobile_companion/features/threads/data/thread_live_stream.dart';
import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final threadListControllerProvider =
    StateNotifierProvider.family<ThreadListController, ThreadListState, String>(
      (ref, bridgeApiBaseUrl) {
        return ThreadListController(
          bridgeApi: ref.watch(threadListBridgeApiProvider),
          cacheRepository: ref.watch(threadCacheRepositoryProvider),
          liveStream: ref.watch(threadLiveStreamProvider),
          bridgeApiBaseUrl: bridgeApiBaseUrl,
        );
      },
    );

class ThreadListState {
  const ThreadListState({
    required this.threads,
    required this.searchQuery,
    this.selectedThreadId,
    this.errorMessage,
    this.staleMessage,
    this.isLoading = false,
    this.isShowingCachedData = false,
  });

  final List<ThreadSummaryDto> threads;
  final String searchQuery;
  final String? selectedThreadId;
  final String? errorMessage;
  final String? staleMessage;
  final bool isLoading;
  final bool isShowingCachedData;

  factory ThreadListState.initial() {
    return const ThreadListState(
      threads: <ThreadSummaryDto>[],
      searchQuery: '',
    );
  }

  List<ThreadSummaryDto> get visibleThreads {
    final normalizedQuery = searchQuery.trim().toLowerCase();
    if (normalizedQuery.isEmpty) {
      return threads;
    }

    return threads
        .where((thread) {
          return thread.threadId.toLowerCase().contains(normalizedQuery) ||
              thread.title.toLowerCase().contains(normalizedQuery) ||
              thread.workspace.toLowerCase().contains(normalizedQuery) ||
              thread.repository.toLowerCase().contains(normalizedQuery) ||
              thread.branch.toLowerCase().contains(normalizedQuery) ||
              thread.status.wireValue.toLowerCase().contains(normalizedQuery);
        })
        .toList(growable: false);
  }

  bool get hasAnyThread => threads.isNotEmpty;

  bool get hasQuery => searchQuery.trim().isNotEmpty;

  bool get hasSelectedThread =>
      selectedThreadId != null && selectedThreadId!.trim().isNotEmpty;

  bool get hasStaleMessage => staleMessage != null && staleMessage!.isNotEmpty;

  bool get isEmptyState =>
      !isLoading && errorMessage == null && threads.isEmpty;

  bool get isFilteredEmptyState =>
      !isLoading &&
      errorMessage == null &&
      threads.isNotEmpty &&
      visibleThreads.isEmpty;

  ThreadListState copyWith({
    List<ThreadSummaryDto>? threads,
    String? searchQuery,
    String? selectedThreadId,
    bool clearSelectedThreadId = false,
    String? errorMessage,
    bool clearErrorMessage = false,
    String? staleMessage,
    bool clearStaleMessage = false,
    bool? isLoading,
    bool? isShowingCachedData,
  }) {
    return ThreadListState(
      threads: threads ?? this.threads,
      searchQuery: searchQuery ?? this.searchQuery,
      selectedThreadId: clearSelectedThreadId
          ? null
          : (selectedThreadId ?? this.selectedThreadId),
      errorMessage: clearErrorMessage
          ? null
          : (errorMessage ?? this.errorMessage),
      staleMessage: clearStaleMessage
          ? null
          : (staleMessage ?? this.staleMessage),
      isLoading: isLoading ?? this.isLoading,
      isShowingCachedData: isShowingCachedData ?? this.isShowingCachedData,
    );
  }
}

class ThreadListController extends StateNotifier<ThreadListState> {
  ThreadListController({
    required ThreadListBridgeApi bridgeApi,
    required ThreadCacheRepository cacheRepository,
    required ThreadLiveStream liveStream,
    required String bridgeApiBaseUrl,
  }) : _bridgeApi = bridgeApi,
       _cacheRepository = cacheRepository,
       _liveStream = liveStream,
       _bridgeApiBaseUrl = bridgeApiBaseUrl,
       super(ThreadListState.initial()) {
    unawaited(_initialize());
  }

  final ThreadListBridgeApi _bridgeApi;
  final ThreadCacheRepository _cacheRepository;
  final ThreadLiveStream _liveStream;
  final String _bridgeApiBaseUrl;
  final Set<String> _knownLiveEventIds = <String>{};

  ThreadLiveSubscription? _liveSubscription;
  StreamSubscription<BridgeEventEnvelope<Map<String, dynamic>>>?
  _liveEventSubscription;
  Timer? _reconnectTimer;
  bool _isReconnectInProgress = false;
  bool _isDisposed = false;

  Future<void> _initialize() async {
    await _restoreSelectedThreadId();
    await _restoreCachedThreadList();
    await loadThreads();
    await _startLiveSubscription();
  }

  Future<void> _restoreSelectedThreadId() async {
    final selectedThreadId = await _cacheRepository.readSelectedThreadId();
    if (selectedThreadId == null) {
      return;
    }

    state = state.copyWith(selectedThreadId: selectedThreadId);
  }

  Future<void> _restoreCachedThreadList() async {
    final cached = await _cacheRepository.readThreadList();
    if (cached == null || cached.threads.isEmpty) {
      return;
    }

    state = state.copyWith(
      threads: cached.threads,
      staleMessage:
          'Showing cached threads while reconnecting to the private bridge path.',
      isShowingCachedData: true,
    );
  }

  Future<void> loadThreads() async {
    state = state.copyWith(
      isLoading: true,
      clearErrorMessage: true,
      clearStaleMessage: true,
      isShowingCachedData: false,
    );

    try {
      final threads = await _bridgeApi.fetchThreads(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
      );
      await _cacheRepository.saveThreadList(threads);

      state = state.copyWith(
        threads: threads,
        clearErrorMessage: true,
        clearStaleMessage: true,
        isLoading: false,
        isShowingCachedData: false,
      );
    } on ThreadListBridgeException catch (error) {
      if (error.isConnectivityError) {
        final cachedList = await _cacheRepository.readThreadList();
        if (cachedList != null && cachedList.threads.isNotEmpty) {
          state = state.copyWith(
            threads: cachedList.threads,
            staleMessage:
                'Bridge is offline. Showing cached threads. Mutating actions stay blocked until reconnect.',
            clearErrorMessage: true,
            isLoading: false,
            isShowingCachedData: true,
          );
          return;
        }

        if (state.threads.isNotEmpty) {
          state = state.copyWith(
            staleMessage:
                'Bridge is offline. Showing cached threads. Mutating actions stay blocked until reconnect.',
            clearErrorMessage: true,
            isLoading: false,
            isShowingCachedData: true,
          );
          return;
        }
      }

      state = state.copyWith(errorMessage: error.message, isLoading: false);
    } catch (_) {
      state = state.copyWith(
        errorMessage: 'Couldn’t load threads from the bridge.',
        isLoading: false,
      );
    }
  }

  Future<void> selectThread(String threadId) async {
    final normalizedThreadId = threadId.trim();
    if (normalizedThreadId.isEmpty) {
      return;
    }

    state = state.copyWith(selectedThreadId: normalizedThreadId);
    await _cacheRepository.saveSelectedThreadId(normalizedThreadId);
  }

  void updateSearchQuery(String searchQuery) {
    state = state.copyWith(searchQuery: searchQuery);
  }

  void clearSearchQuery() {
    updateSearchQuery('');
  }

  void syncThreadDetail(ThreadDetailDto detail) {
    _updateThreadSummary(
      threadId: detail.threadId,
      transform: (thread) {
        return ThreadSummaryDto(
          contractVersion: thread.contractVersion,
          threadId: thread.threadId,
          title: detail.title,
          status: detail.status,
          workspace: detail.workspace,
          repository: detail.repository,
          branch: detail.branch,
          updatedAt: detail.updatedAt,
        );
      },
    );
  }

  void applyThreadStatusUpdate({
    required String threadId,
    required ThreadStatus status,
    String? updatedAt,
  }) {
    _updateThreadSummary(
      threadId: threadId,
      transform: (thread) {
        return ThreadSummaryDto(
          contractVersion: thread.contractVersion,
          threadId: thread.threadId,
          title: thread.title,
          status: status,
          workspace: thread.workspace,
          repository: thread.repository,
          branch: thread.branch,
          updatedAt: updatedAt ?? thread.updatedAt,
        );
      },
    );
  }

  void _updateThreadSummary({
    required String threadId,
    required ThreadSummaryDto Function(ThreadSummaryDto thread) transform,
  }) {
    final index = state.threads.indexWhere(
      (thread) => thread.threadId == threadId,
    );
    if (index < 0) {
      return;
    }

    final updatedThread = transform(state.threads[index]);
    final nextThreads = List<ThreadSummaryDto>.from(state.threads);
    nextThreads[index] = updatedThread;
    state = state.copyWith(threads: nextThreads);
    unawaited(_cacheRepository.saveThreadList(nextThreads));
  }

  Future<void> _startLiveSubscription() async {
    try {
      final subscription = await _liveStream.subscribe(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
      );
      _liveSubscription = subscription;
      _liveEventSubscription = subscription.events.listen(
        _handleLiveEvent,
        onError: (_) {
          _handleLiveStreamDisconnected();
        },
        onDone: _handleLiveStreamDisconnected,
      );
    } catch (_) {
      _handleLiveStreamDisconnected();
    }
  }

  void _handleLiveEvent(BridgeEventEnvelope<Map<String, dynamic>> event) {
    if (_knownLiveEventIds.contains(event.eventId)) {
      return;
    }
    _knownLiveEventIds.add(event.eventId);

    if (!_containsThread(event.threadId)) {
      unawaited(loadThreads());
      return;
    }

    if (event.kind == BridgeEventKind.threadStatusChanged) {
      final rawStatus = event.payload['status'];
      if (rawStatus is String && rawStatus.trim().isNotEmpty) {
        try {
          final status = threadStatusFromWire(rawStatus.trim());
          applyThreadStatusUpdate(
            threadId: event.threadId,
            status: status,
            updatedAt: event.occurredAt,
          );
          return;
        } on FormatException {
          // Fall through to timestamp-only activity update.
        }
      }
    }

    _touchThreadActivity(threadId: event.threadId, updatedAt: event.occurredAt);
  }

  void _touchThreadActivity({
    required String threadId,
    required String updatedAt,
  }) {
    _updateThreadSummary(
      threadId: threadId,
      transform: (thread) {
        return ThreadSummaryDto(
          contractVersion: thread.contractVersion,
          threadId: thread.threadId,
          title: thread.title,
          status: thread.status,
          workspace: thread.workspace,
          repository: thread.repository,
          branch: thread.branch,
          updatedAt: updatedAt,
        );
      },
    );
  }

  bool _containsThread(String threadId) {
    return state.threads.any((thread) => thread.threadId == threadId);
  }

  void _handleLiveStreamDisconnected() {
    if (_isDisposed) {
      return;
    }

    state = state.copyWith(
      staleMessage:
          'Live thread updates are reconnecting. Pull to refresh if statuses look stale.',
      isShowingCachedData: true,
    );
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_isDisposed || _reconnectTimer?.isActive == true) {
      return;
    }

    _reconnectTimer = Timer(const Duration(seconds: 2), () {
      unawaited(_runReconnect());
    });
  }

  Future<void> _runReconnect() async {
    if (_isDisposed || _isReconnectInProgress) {
      return;
    }

    _isReconnectInProgress = true;
    try {
      await _closeLiveSubscription();
      await _startLiveSubscription();
      final didCatchUp = await _catchUpThreadListAfterReconnect();
      if (!didCatchUp) {
        _scheduleReconnect();
      }
    } catch (_) {
      _scheduleReconnect();
    } finally {
      _isReconnectInProgress = false;
    }
  }

  Future<bool> _catchUpThreadListAfterReconnect() async {
    try {
      final threads = await _bridgeApi.fetchThreads(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
      );
      await _cacheRepository.saveThreadList(threads);

      state = state.copyWith(
        threads: threads,
        clearErrorMessage: true,
        clearStaleMessage: true,
        isLoading: false,
        isShowingCachedData: false,
      );

      return true;
    } on ThreadListBridgeException catch (error) {
      if (error.isConnectivityError) {
        if (state.threads.isNotEmpty) {
          state = state.copyWith(
            staleMessage:
                'Bridge is offline. Showing cached threads. Mutating actions stay blocked until reconnect.',
            clearErrorMessage: true,
            isLoading: false,
            isShowingCachedData: true,
          );
        } else {
          state = state.copyWith(
            errorMessage: error.message,
            isLoading: false,
            isShowingCachedData: false,
          );
        }

        return false;
      }

      state = state.copyWith(errorMessage: error.message, isLoading: false);
      return true;
    } catch (_) {
      return false;
    }
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
      // Ignore already-closed websocket teardown failures.
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
