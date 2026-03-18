import 'package:codex_mobile_companion/features/threads/application/thread_detail_controller.dart';
import 'package:codex_mobile_companion/features/threads/domain/thread_activity_item.dart';
import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ThreadDetailPage extends ConsumerWidget {
  const ThreadDetailPage({
    super.key,
    required this.bridgeApiBaseUrl,
    required this.threadId,
    this.initialVisibleTimelineEntries = 20,
  });

  final String bridgeApiBaseUrl;
  final String threadId;
  final int initialVisibleTimelineEntries;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final args = ThreadDetailControllerArgs(
      bridgeApiBaseUrl: bridgeApiBaseUrl,
      threadId: threadId,
      initialVisibleTimelineEntries: initialVisibleTimelineEntries,
    );
    final state = ref.watch(threadDetailControllerProvider(args));
    final controller = ref.read(threadDetailControllerProvider(args).notifier);

    return Scaffold(
      appBar: AppBar(title: const Text('Thread detail')),
      body: SafeArea(
        child: _buildBody(
          context,
          state: state,
          onRetry: controller.loadThread,
          onLoadEarlier: controller.loadEarlierHistory,
          onRetryReconnect: controller.retryReconnectCatchUp,
        ),
      ),
    );
  }
}

Widget _buildBody(
  BuildContext context, {
  required ThreadDetailState state,
  required Future<void> Function() onRetry,
  required VoidCallback onLoadEarlier,
  required Future<void> Function() onRetryReconnect,
}) {
  if (state.isLoading && !state.hasThread) {
    return const _ThreadDetailLoadingState();
  }

  if (state.hasError && !state.hasThread) {
    return _ThreadDetailErrorState(
      isUnavailable: state.isUnavailable,
      message: state.errorMessage ?? 'Couldn’t open this thread right now.',
      onRetry: onRetry,
    );
  }

  final thread = state.thread;
  if (thread == null) {
    return _ThreadDetailErrorState(
      isUnavailable: true,
      message: 'Thread detail is unavailable.',
      onRetry: onRetry,
    );
  }

  return RefreshIndicator(
    onRefresh: onRetry,
    child: ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        _ThreadDetailHeader(thread: thread),
        if (state.staleMessage != null) ...[
          const SizedBox(height: 12),
          _InlineWarning(message: state.staleMessage!),
        ],
        if (!state.canRunMutatingActions) ...[
          const SizedBox(height: 12),
          _MutatingActionsBlockedNotice(onRetryReconnect: onRetryReconnect),
        ],
        if (state.streamErrorMessage != null) ...[
          const SizedBox(height: 12),
          _InlineWarning(message: state.streamErrorMessage!),
        ],
        const SizedBox(height: 16),
        if (state.canLoadEarlierHistory) ...[
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: const Key('load-earlier-history'),
              onPressed: onLoadEarlier,
              icon: const Icon(Icons.history),
              label: Text('Load earlier history (${state.hiddenHistoryCount})'),
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (state.visibleItems.isEmpty)
          const _EmptyTimelineState()
        else
          ...state.visibleItems
              .map((item) => _ThreadActivityCard(item: item))
              .expand((widget) => [widget, const SizedBox(height: 8)]),
      ],
    ),
  );
}

class _ThreadDetailLoadingState extends StatelessWidget {
  const _ThreadDetailLoadingState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 12),
          Text('Loading thread detail…'),
        ],
      ),
    );
  }
}

class _ThreadDetailErrorState extends StatelessWidget {
  const _ThreadDetailErrorState({
    required this.isUnavailable,
    required this.message,
    required this.onRetry,
  });

  final bool isUnavailable;
  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final title = isUnavailable
        ? 'Thread unavailable'
        : 'Couldn’t load thread detail';
    final icon = isUnavailable ? Icons.forum_outlined : Icons.wifi_off_rounded;

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 36),
            const SizedBox(height: 12),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
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

class _ThreadDetailHeader extends StatelessWidget {
  const _ThreadDetailHeader({required this.thread});

  final ThreadDetailDto thread;

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
                    key: const Key('thread-detail-title'),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                const SizedBox(width: 8),
                _StatusBadge(status: thread.status),
              ],
            ),
            const SizedBox(height: 8),
            Text('${thread.repository} • ${thread.branch}'),
            const SizedBox(height: 2),
            Text(
              thread.workspace,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 6),
            Text(
              thread.threadId,
              key: const Key('thread-detail-thread-id'),
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

class _ThreadActivityCard extends StatelessWidget {
  const _ThreadActivityCard({required this.item});

  final ThreadActivityItem item;

  @override
  Widget build(BuildContext context) {
    final style = _activityStyle(context, item.type);

    return Card(
      key: Key('thread-activity-${item.eventId}'),
      color: style.background,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(style.icon, size: 18, color: style.foreground),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    item.title,
                    style: Theme.of(
                      context,
                    ).textTheme.labelLarge?.copyWith(color: style.foreground),
                  ),
                ),
                Text(
                  item.occurredAt,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
            ),
            const SizedBox(height: 8),
            SelectableText(item.body),
          ],
        ),
      ),
    );
  }
}

class _EmptyTimelineState extends StatelessWidget {
  const _EmptyTimelineState();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.history_rounded, size: 32),
            SizedBox(height: 8),
            Text('No timeline entries yet.'),
          ],
        ),
      ),
    );
  }
}

class _InlineWarning extends StatelessWidget {
  const _InlineWarning({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colorScheme.errorContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colorScheme.error),
      ),
      child: Text(message),
    );
  }
}

class _MutatingActionsBlockedNotice extends StatelessWidget {
  const _MutatingActionsBlockedNotice({required this.onRetryReconnect});

  final Future<void> Function() onRetryReconnect;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Mutating actions are blocked while the bridge or private route is unavailable.',
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            key: const Key('retry-reconnect-catchup'),
            onPressed: onRetryReconnect,
            child: const Text('Retry reconnect'),
          ),
        ],
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

class _ActivityStyle {
  const _ActivityStyle({
    required this.icon,
    required this.background,
    required this.foreground,
  });

  final IconData icon;
  final Color background;
  final Color foreground;
}

_ActivityStyle _activityStyle(
  BuildContext context,
  ThreadActivityItemType type,
) {
  final colorScheme = Theme.of(context).colorScheme;

  switch (type) {
    case ThreadActivityItemType.userPrompt:
      return _ActivityStyle(
        icon: Icons.person_outline,
        background: colorScheme.secondaryContainer.withValues(alpha: 0.5),
        foreground: colorScheme.onSecondaryContainer,
      );
    case ThreadActivityItemType.assistantOutput:
      return _ActivityStyle(
        icon: Icons.smart_toy_outlined,
        background: colorScheme.primaryContainer.withValues(alpha: 0.45),
        foreground: colorScheme.onPrimaryContainer,
      );
    case ThreadActivityItemType.planUpdate:
      return _ActivityStyle(
        icon: Icons.map_outlined,
        background: colorScheme.tertiaryContainer.withValues(alpha: 0.45),
        foreground: colorScheme.onTertiaryContainer,
      );
    case ThreadActivityItemType.terminalOutput:
      return _ActivityStyle(
        icon: Icons.terminal,
        background: colorScheme.surfaceContainerHighest,
        foreground: colorScheme.onSurface,
      );
    case ThreadActivityItemType.fileChange:
      return _ActivityStyle(
        icon: Icons.description_outlined,
        background: colorScheme.surfaceContainer,
        foreground: colorScheme.onSurface,
      );
    case ThreadActivityItemType.lifecycleUpdate:
      return _ActivityStyle(
        icon: Icons.pending_actions,
        background: colorScheme.secondaryContainer.withValues(alpha: 0.35),
        foreground: colorScheme.onSecondaryContainer,
      );
    case ThreadActivityItemType.approvalRequest:
      return _ActivityStyle(
        icon: Icons.gpp_maybe_outlined,
        background: colorScheme.errorContainer.withValues(alpha: 0.35),
        foreground: colorScheme.onErrorContainer,
      );
    case ThreadActivityItemType.securityEvent:
      return _ActivityStyle(
        icon: Icons.security,
        background: colorScheme.errorContainer.withValues(alpha: 0.45),
        foreground: colorScheme.onErrorContainer,
      );
    case ThreadActivityItemType.generic:
      return _ActivityStyle(
        icon: Icons.bolt,
        background: colorScheme.surfaceContainerHigh,
        foreground: colorScheme.onSurface,
      );
  }
}
