import 'package:codex_mobile_companion/features/threads/data/thread_list_bridge_api.dart';
import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final threadListControllerProvider =
    StateNotifierProvider.family<ThreadListController, ThreadListState, String>((
      ref,
      bridgeApiBaseUrl,
    ) {
      return ThreadListController(
        bridgeApi: ref.watch(threadListBridgeApiProvider),
        bridgeApiBaseUrl: bridgeApiBaseUrl,
      );
    });

class ThreadListState {
  const ThreadListState({
    required this.threads,
    required this.searchQuery,
    this.errorMessage,
    this.isLoading = false,
  });

  final List<ThreadSummaryDto> threads;
  final String searchQuery;
  final String? errorMessage;
  final bool isLoading;

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
    String? errorMessage,
    bool clearErrorMessage = false,
    bool? isLoading,
  }) {
    return ThreadListState(
      threads: threads ?? this.threads,
      searchQuery: searchQuery ?? this.searchQuery,
      errorMessage: clearErrorMessage
          ? null
          : (errorMessage ?? this.errorMessage),
      isLoading: isLoading ?? this.isLoading,
    );
  }
}

class ThreadListController extends StateNotifier<ThreadListState> {
  ThreadListController({
    required ThreadListBridgeApi bridgeApi,
    required String bridgeApiBaseUrl,
  }) : _bridgeApi = bridgeApi,
       _bridgeApiBaseUrl = bridgeApiBaseUrl,
       super(ThreadListState.initial()) {
    loadThreads();
  }

  final ThreadListBridgeApi _bridgeApi;
  final String _bridgeApiBaseUrl;

  Future<void> loadThreads() async {
    state = state.copyWith(isLoading: true, clearErrorMessage: true);

    try {
      final threads = await _bridgeApi.fetchThreads(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
      );
      state = state.copyWith(
        threads: threads,
        clearErrorMessage: true,
        isLoading: false,
      );
    } on ThreadListBridgeException catch (error) {
      state = state.copyWith(errorMessage: error.message, isLoading: false);
    } catch (_) {
      state = state.copyWith(
        errorMessage: 'Couldn’t load threads from the bridge.',
        isLoading: false,
      );
    }
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
    final index = state.threads.indexWhere((thread) => thread.threadId == threadId);
    if (index < 0) {
      return;
    }

    final updatedThread = transform(state.threads[index]);
    final nextThreads = List<ThreadSummaryDto>.from(state.threads);
    nextThreads[index] = updatedThread;
    state = state.copyWith(threads: nextThreads);
  }
}
