import 'dart:async';

import 'package:vibe_bridge/foundation/connectivity/live_connection_state.dart';
import 'package:vibe_bridge/features/threads/data/thread_cache_repository.dart';
import 'package:vibe_bridge/features/threads/data/thread_list_bridge_api.dart';
import 'package:vibe_bridge/features/threads/data/thread_live_stream.dart';
import 'package:vibe_bridge/foundation/contracts/bridge_contracts.dart';
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

class ThreadWorkspaceGroup {
  const ThreadWorkspaceGroup({
    required this.groupId,
    required this.label,
    required this.workspacePath,
    required this.threads,
  });

  final String groupId;
  final String label;
  final String workspacePath;
  final List<ThreadSummaryDto> threads;
}

class ThreadListState {
  const ThreadListState({
    required this.threads,
    required this.searchQuery,
    required this.liveConnectionState,
    this.selectedThreadId,
    this.errorMessage,
    this.staleMessage,
    this.isLoading = false,
    this.isShowingCachedData = false,
  });

  final List<ThreadSummaryDto> threads;
  final String searchQuery;
  final LiveConnectionState liveConnectionState;
  final String? selectedThreadId;
  final String? errorMessage;
  final String? staleMessage;
  final bool isLoading;
  final bool isShowingCachedData;

  factory ThreadListState.initial() {
    return const ThreadListState(
      threads: <ThreadSummaryDto>[],
      searchQuery: '',
      liveConnectionState: LiveConnectionState.connected,
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

  List<ThreadWorkspaceGroup> get visibleGroups {
    final groups = <String, List<ThreadSummaryDto>>{};

    for (final thread in visibleThreads) {
      groups
          .putIfAbsent(_workspaceGroupId(thread), () => <ThreadSummaryDto>[])
          .add(thread);
    }

    return groups.entries
        .map((entry) {
          final representative = entry.value.first;
          return ThreadWorkspaceGroup(
            groupId: entry.key,
            label: _workspaceGroupLabel(representative),
            workspacePath: representative.workspace.trim(),
            threads: List<ThreadSummaryDto>.unmodifiable(entry.value),
          );
        })
        .toList(growable: false);
  }

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
    LiveConnectionState? liveConnectionState,
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
      liveConnectionState: liveConnectionState ?? this.liveConnectionState,
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

  bool get _canMutateState => mounted && !_isDisposed;

  Future<void> _initialize() async {
    await _restoreSelectedThreadId();
    await _restoreCachedThreadList();
    await loadThreads();
    await _startLiveSubscription();
  }

  Future<void> _restoreSelectedThreadId() async {
    final selectedThreadId = await _cacheRepository.readSelectedThreadId();
    if (!_canMutateState || selectedThreadId == null) {
      return;
    }

    state = state.copyWith(selectedThreadId: selectedThreadId);
  }

  Future<void> _restoreCachedThreadList() async {
    final cached = await _cacheRepository.readThreadList();
    if (!_canMutateState || cached == null || cached.threads.isEmpty) {
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
    if (!_canMutateState) {
      return;
    }
    state = state.copyWith(
      isLoading: true,
      clearErrorMessage: true,
      clearStaleMessage: true,
      isShowingCachedData: false,
    );

    try {
      final fetchedThreads = await _bridgeApi.fetchThreads(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
      );
      final threads = _mergeFetchedThreadsPreservingNewerState(fetchedThreads);
      await _persistThreadListBestEffort(threads);
      if (!_canMutateState) {
        return;
      }

      state = state.copyWith(
        threads: threads,
        clearErrorMessage: true,
        clearStaleMessage: true,
        isLoading: false,
        isShowingCachedData: false,
        liveConnectionState: LiveConnectionState.connected,
      );
    } on ThreadListBridgeException catch (error) {
      if (!_canMutateState) {
        return;
      }
      if (error.isConnectivityError) {
        final cachedList = await _cacheRepository.readThreadList();
        if (!_canMutateState) {
          return;
        }
        if (cachedList != null && cachedList.threads.isNotEmpty) {
          state = state.copyWith(
            threads: cachedList.threads,
            staleMessage:
                'Bridge is offline. Showing cached threads. Mutating actions stay blocked until reconnect.',
            clearErrorMessage: true,
            isLoading: false,
            isShowingCachedData: true,
            liveConnectionState: LiveConnectionState.disconnected,
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
            liveConnectionState: LiveConnectionState.disconnected,
          );
          return;
        }
      }

      state = state.copyWith(
        errorMessage: error.message,
        isLoading: false,
        liveConnectionState: error.isConnectivityError
            ? LiveConnectionState.disconnected
            : state.liveConnectionState,
      );
    } catch (_) {
      if (!_canMutateState) {
        return;
      }
      state = state.copyWith(
        errorMessage: 'Couldn’t load threads from the bridge.',
        isLoading: false,
        liveConnectionState: LiveConnectionState.disconnected,
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
    final nextSummary = ThreadSummaryDto(
      contractVersion: detail.contractVersion,
      threadId: detail.threadId,
      title: detail.title,
      status: detail.status,
      workspace: detail.workspace,
      repository: detail.repository,
      branch: detail.branch,
      updatedAt: detail.updatedAt,
    );

    final index = state.threads.indexWhere(
      (thread) => thread.threadId == detail.threadId,
    );
    if (index < 0) {
      final nextThreads = <ThreadSummaryDto>[nextSummary, ...state.threads];
      state = state.copyWith(threads: nextThreads);
      unawaited(_cacheRepository.saveThreadList(nextThreads));
      return;
    }

    final nextThreads = List<ThreadSummaryDto>.from(state.threads);
    nextThreads[index] = nextSummary;
    state = state.copyWith(threads: nextThreads);
    unawaited(_cacheRepository.saveThreadList(nextThreads));
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
      if (!_canMutateState) {
        await subscription.close();
        return;
      }
      _liveSubscription = subscription;
      if (!state.hasStaleMessage && state.errorMessage == null) {
        state = state.copyWith(
          liveConnectionState: LiveConnectionState.connected,
        );
      }
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

  List<ThreadSummaryDto> _mergeFetchedThreadsPreservingNewerState(
    List<ThreadSummaryDto> fetchedThreads,
  ) {
    if (state.threads.isEmpty || fetchedThreads.isEmpty) {
      return fetchedThreads;
    }

    final currentByThreadId = <String, ThreadSummaryDto>{
      for (final thread in state.threads) thread.threadId: thread,
    };

    return fetchedThreads
        .map((fetchedThread) {
          final currentThread = currentByThreadId[fetchedThread.threadId];
          if (currentThread == null) {
            return fetchedThread;
          }

          if (_isCurrentThreadSummaryNewerOrEqual(
            current: currentThread,
            incoming: fetchedThread,
          )) {
            return currentThread;
          }

          return fetchedThread;
        })
        .toList(growable: false);
  }

  bool _isCurrentThreadSummaryNewerOrEqual({
    required ThreadSummaryDto current,
    required ThreadSummaryDto incoming,
  }) {
    final currentUpdatedAt = DateTime.tryParse(current.updatedAt);
    final incomingUpdatedAt = DateTime.tryParse(incoming.updatedAt);
    if (currentUpdatedAt == null || incomingUpdatedAt == null) {
      return false;
    }

    return !currentUpdatedAt.isBefore(incomingUpdatedAt);
  }

  void _handleLiveStreamDisconnected() {
    if (_isDisposed) {
      return;
    }

    state = state.copyWith(
      staleMessage:
          'Live thread updates are reconnecting. Pull to refresh if statuses look stale.',
      isShowingCachedData: true,
      liveConnectionState: LiveConnectionState.disconnected,
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
      if (_canMutateState &&
          state.liveConnectionState == LiveConnectionState.disconnected) {
        state = state.copyWith(
          liveConnectionState: LiveConnectionState.reconnecting,
        );
      }
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
      final fetchedThreads = await _bridgeApi.fetchThreads(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
      );
      final threads = _mergeFetchedThreadsPreservingNewerState(fetchedThreads);
      await _persistThreadListBestEffort(threads);
      if (!_canMutateState) {
        return false;
      }

      state = state.copyWith(
        threads: threads,
        clearErrorMessage: true,
        clearStaleMessage: true,
        isLoading: false,
        isShowingCachedData: false,
        liveConnectionState: LiveConnectionState.connected,
      );

      return true;
    } on ThreadListBridgeException catch (error) {
      if (!_canMutateState) {
        return false;
      }
      if (error.isConnectivityError) {
        if (state.threads.isNotEmpty) {
          state = state.copyWith(
            staleMessage:
                'Bridge is offline. Showing cached threads. Mutating actions stay blocked until reconnect.',
            clearErrorMessage: true,
            isLoading: false,
            isShowingCachedData: true,
            liveConnectionState: LiveConnectionState.disconnected,
          );
        } else {
          state = state.copyWith(
            errorMessage: error.message,
            isLoading: false,
            isShowingCachedData: false,
            liveConnectionState: LiveConnectionState.disconnected,
          );
        }

        return false;
      }

      state = state.copyWith(
        errorMessage: error.message,
        isLoading: false,
        liveConnectionState: LiveConnectionState.disconnected,
      );
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

  Future<void> _persistThreadListBestEffort(
    List<ThreadSummaryDto> threads,
  ) async {
    try {
      await _cacheRepository.saveThreadList(threads);
    } catch (_) {
      // Keep the live thread list usable even if local persistence is unavailable.
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

String _workspaceGroupId(ThreadSummaryDto thread) {
  final workspacePath = thread.workspace.trim();
  if (workspacePath.isNotEmpty) {
    return workspacePath;
  }

  final repository = thread.repository.trim();
  if (repository.isNotEmpty) {
    return 'repository:$repository';
  }

  return 'thread:${thread.threadId}';
}

String _workspaceGroupLabel(ThreadSummaryDto thread) {
  final workspacePath = thread.workspace.trim();
  if (workspacePath.isEmpty) {
    final repository = thread.repository.trim();
    return repository.isNotEmpty ? repository : 'Unknown workspace';
  }

  final normalizedPath = workspacePath.replaceAll('\\', '/');
  final segments = normalizedPath
      .split('/')
      .where((segment) => segment.isNotEmpty)
      .toList(growable: false);
  if (segments.isEmpty) {
    return workspacePath;
  }

  return segments.last;
}
