import 'package:codex_mobile_companion/features/threads/application/thread_list_controller.dart';
import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ThreadListPage extends ConsumerStatefulWidget {
  const ThreadListPage({super.key, required this.bridgeApiBaseUrl});

  final String bridgeApiBaseUrl;

  @override
  ConsumerState<ThreadListPage> createState() => _ThreadListPageState();
}

class _ThreadListPageState extends ConsumerState<ThreadListPage> {
  late final TextEditingController _searchController;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(
      threadListControllerProvider(widget.bridgeApiBaseUrl),
    );
    final controller = ref.read(
      threadListControllerProvider(widget.bridgeApiBaseUrl).notifier,
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Threads')),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              child: TextField(
                key: const Key('thread-search-input'),
                controller: _searchController,
                onChanged: controller.updateSearchQuery,
                decoration: InputDecoration(
                  labelText: 'Search threads',
                  hintText:
                      'Search by title, repo, workspace, branch, or status',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: state.hasQuery
                      ? IconButton(
                          onPressed: () {
                            _searchController.clear();
                            controller.clearSearchQuery();
                          },
                          icon: const Icon(Icons.clear),
                          tooltip: 'Clear search',
                        )
                      : null,
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
            Expanded(child: _buildBody(state, controller)),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(ThreadListState state, ThreadListController controller) {
    if (state.isLoading && !state.hasAnyThread) {
      return const _ThreadListLoadingState();
    }

    if (state.errorMessage != null && !state.hasAnyThread) {
      return _ThreadListErrorState(
        message: state.errorMessage!,
        onRetry: controller.loadThreads,
      );
    }

    if (state.isEmptyState) {
      return const _ThreadListEmptyState();
    }

    if (state.isFilteredEmptyState) {
      return _ThreadListFilteredEmptyState(
        onClearFilter: () {
          _searchController.clear();
          controller.clearSearchQuery();
        },
      );
    }

    return RefreshIndicator(
      onRefresh: controller.loadThreads,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: state.visibleThreads.length,
        separatorBuilder: (context, index) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final thread = state.visibleThreads[index];
          return _ThreadSummaryCard(thread: thread);
        },
      ),
    );
  }
}

class _ThreadListLoadingState extends StatelessWidget {
  const _ThreadListLoadingState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 12),
          Text('Loading threads…'),
        ],
      ),
    );
  }
}

class _ThreadListErrorState extends StatelessWidget {
  const _ThreadListErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.wifi_off_rounded,
              size: 36,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 12),
            Text(
              'Couldn’t load threads',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

class _ThreadListEmptyState extends StatelessWidget {
  const _ThreadListEmptyState();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.all(24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.forum_outlined, size: 36),
            SizedBox(height: 12),
            Text('No threads yet'),
            SizedBox(height: 8),
            Text(
              'Start a turn on your Mac, then pull to refresh this list.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _ThreadListFilteredEmptyState extends StatelessWidget {
  const _ThreadListFilteredEmptyState({required this.onClearFilter});

  final VoidCallback onClearFilter;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.search_off_rounded, size: 36),
            const SizedBox(height: 12),
            const Text('No matching threads'),
            const SizedBox(height: 8),
            const Text(
              'Try a different search term or clear the filter.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: onClearFilter,
              child: const Text('Clear filter'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ThreadSummaryCard extends StatelessWidget {
  const _ThreadSummaryCard({required this.thread});

  final ThreadSummaryDto thread;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    thread.title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                const SizedBox(width: 8),
                _StatusBadge(status: thread.status),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              '${thread.repository} • ${thread.branch}',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 2),
            Text(
              thread.workspace,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 6),
            Text(
              thread.threadId,
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(fontFamily: 'monospace'),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});

  final ThreadStatus status;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    final (label, foreground, background) = switch (status) {
      ThreadStatus.running => (
        'Running',
        colorScheme.primary,
        colorScheme.primaryContainer,
      ),
      ThreadStatus.idle => (
        'Idle',
        colorScheme.secondary,
        colorScheme.secondaryContainer,
      ),
      ThreadStatus.completed => (
        'Completed',
        colorScheme.tertiary,
        colorScheme.tertiaryContainer,
      ),
      ThreadStatus.interrupted => (
        'Interrupted',
        colorScheme.onSurface,
        colorScheme.surfaceContainerHighest,
      ),
      ThreadStatus.failed => (
        'Failed',
        colorScheme.error,
        colorScheme.errorContainer,
      ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: Theme.of(
          context,
        ).textTheme.labelMedium?.copyWith(color: foreground),
      ),
    );
  }
}
