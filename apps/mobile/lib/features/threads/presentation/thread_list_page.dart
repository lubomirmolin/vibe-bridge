import 'dart:async';

import 'package:codex_mobile_companion/features/threads/application/thread_list_controller.dart';
import 'package:codex_mobile_companion/features/threads/presentation/thread_detail_page.dart';
import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:codex_mobile_companion/foundation/theme/app_theme.dart';
import 'package:codex_mobile_companion/foundation/theme/liquid_styles.dart';
import 'package:codex_mobile_companion/shared/widgets/badges.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

class ThreadListPage extends ConsumerStatefulWidget {
  const ThreadListPage({super.key, required this.bridgeApiBaseUrl});

  final String bridgeApiBaseUrl;

  @override
  ConsumerState<ThreadListPage> createState() => _ThreadListPageState();
}

class _ThreadListPageState extends ConsumerState<ThreadListPage> {
  late final TextEditingController _searchController;
  final Set<String> _collapsedGroupIds = <String>{};
  bool _didRestoreSelectedThread = false;

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

  void _restoreSelectedThreadIfNeeded(
    ThreadListState state,
    ThreadListController controller,
  ) {
    if (_didRestoreSelectedThread ||
        !state.hasSelectedThread ||
        state.isLoading) {
      return;
    }

    _didRestoreSelectedThread = true;
    final selectedThreadId = state.selectedThreadId!;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_openThreadDetail(controller, selectedThreadId));
    });
  }

  Future<void> _openThreadDetail(
    ThreadListController controller,
    String threadId,
  ) async {
    _didRestoreSelectedThread = true;
    await controller.selectThread(threadId);
    if (!mounted) return;

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => ThreadDetailPage(
          bridgeApiBaseUrl: widget.bridgeApiBaseUrl,
          threadId: threadId,
        ),
      ),
    );
  }

  bool _isGroupCollapsed(ThreadListState state, String groupId) {
    if (state.hasQuery) {
      return false;
    }
    return _collapsedGroupIds.contains(groupId);
  }

  void _toggleGroupCollapsed(String groupId) {
    setState(() {
      if (_collapsedGroupIds.contains(groupId)) {
        _collapsedGroupIds.remove(groupId);
      } else {
        _collapsedGroupIds.add(groupId);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(
      threadListControllerProvider(widget.bridgeApiBaseUrl),
    );
    final controller = ref.read(
      threadListControllerProvider(widget.bridgeApiBaseUrl).notifier,
    );

    _restoreSelectedThreadIfNeeded(state, controller);

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SafeArea(
        child: Column(
          children: [
            // Sticky Header matching React ThreadListScreen
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              color: AppTheme.background.withValues(alpha: 0.8),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: PhosphorIcon(
                      PhosphorIcons.caretLeft(PhosphorIconsStyle.bold),
                      size: 20,
                      color: AppTheme.textMuted,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Threads',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w500,
                        letterSpacing: -0.5,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // Search Bar
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
              child: Container(
                decoration: LiquidStyles.liquidGlass.copyWith(
                  borderRadius: BorderRadius.circular(16),
                ),
                child: TextField(
                  key: const Key('thread-search-input'),
                  controller: _searchController,
                  onChanged: controller.updateSearchQuery,
                  style: const TextStyle(
                    color: AppTheme.textMain,
                    fontSize: 14,
                  ),
                  decoration: InputDecoration(
                    hintText: 'Search sessions...',
                    hintStyle: const TextStyle(color: AppTheme.textSubtle),
                    prefixIcon: Padding(
                      padding: const EdgeInsets.all(12.0),
                      child: PhosphorIcon(
                        PhosphorIcons.magnifyingGlass(),
                        size: 20,
                        color: AppTheme.textSubtle,
                      ),
                    ),
                    suffixIcon: state.hasQuery
                        ? IconButton(
                            onPressed: () {
                              _searchController.clear();
                              controller.clearSearchQuery();
                            },
                            icon: PhosphorIcon(
                              PhosphorIcons.x(),
                              size: 16,
                              color: AppTheme.textSubtle,
                            ),
                          )
                        : null,
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                  ),
                ),
              ),
            ),

            if (state.hasStaleMessage)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
                child: _StaleDataBanner(message: state.staleMessage!),
              ),

            Expanded(child: _buildBody(state, controller)),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(ThreadListState state, ThreadListController controller) {
    if (state.isLoading && !state.hasAnyThread) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: AppTheme.emerald),
            SizedBox(height: 16),
            Text(
              'Loading threads...',
              style: TextStyle(
                color: AppTheme.textMuted,
                fontSize: 13,
                fontFamily: 'JetBrains Mono',
              ),
            ),
          ],
        ),
      );
    }

    if (state.errorMessage != null && !state.hasAnyThread) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              PhosphorIcon(
                PhosphorIcons.wifiX(),
                size: 48,
                color: AppTheme.rose,
              ),
              const SizedBox(height: 16),
              const Text(
                'Couldn\'t load threads',
                style: TextStyle(
                  color: AppTheme.textMain,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                state.errorMessage!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppTheme.textMuted),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.surfaceZinc800,
                  foregroundColor: AppTheme.textMain,
                ),
                onPressed: controller.loadThreads,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (state.isEmptyState || state.isFilteredEmptyState) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              PhosphorIcon(
                state.isEmptyState
                    ? PhosphorIcons.chatTeardropText()
                    : PhosphorIcons.magnifyingGlassMinus(),
                size: 48,
                color: AppTheme.textSubtle,
              ),
              const SizedBox(height: 16),
              Text(
                state.isEmptyState ? 'No threads yet' : 'No matching threads',
                style: const TextStyle(
                  color: AppTheme.textMain,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                state.isEmptyState
                    ? 'Start a turn on your Mac, then pull to refresh this list.'
                    : 'Try a different search term or clear the filter.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppTheme.textMuted),
              ),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      color: AppTheme.emerald,
      backgroundColor: AppTheme.surfaceZinc800,
      onRefresh: controller.loadThreads,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        itemCount: state.visibleGroups.length,
        separatorBuilder: (context, index) => const SizedBox(height: 24),
        itemBuilder: (context, index) {
          final group = state.visibleGroups[index];
          return _ThreadWorkspaceSection(
            group: group,
            isCollapsed: _isGroupCollapsed(state, group.groupId),
            onToggleCollapsed: () => _toggleGroupCollapsed(group.groupId),
            onOpenDetail: (threadId) =>
                unawaited(_openThreadDetail(controller, threadId)),
          );
        },
      ),
    );
  }
}

class _StaleDataBanner extends StatelessWidget {
  const _StaleDataBanner({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.rose.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.rose.withValues(alpha: 0.3)),
      ),
      child: Text(
        message,
        style: const TextStyle(color: AppTheme.rose, fontSize: 13),
      ),
    );
  }
}

class _ThreadWorkspaceSection extends StatelessWidget {
  const _ThreadWorkspaceSection({
    required this.group,
    required this.isCollapsed,
    required this.onToggleCollapsed,
    required this.onOpenDetail,
  });

  final ThreadWorkspaceGroup group;
  final bool isCollapsed;
  final VoidCallback onToggleCollapsed;
  final ValueChanged<String> onOpenDetail;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: Key('thread-folder-group-${group.groupId}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          key: Key('thread-folder-toggle-${group.groupId}'),
          onTap: onToggleCollapsed,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                PhosphorIcon(
                  PhosphorIcons.folderSimple(),
                  size: 18,
                  color: AppTheme.textMuted,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    group.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppTheme.textMuted,
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.3,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  '${group.threads.length}',
                  style: GoogleFonts.jetBrainsMono(
                    color: AppTheme.textSubtle,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 8),
                PhosphorIcon(
                  isCollapsed
                      ? PhosphorIcons.caretRight(PhosphorIconsStyle.bold)
                      : PhosphorIcons.caretDown(PhosphorIconsStyle.bold),
                  size: 14,
                  color: AppTheme.textSubtle,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          child: isCollapsed
              ? const SizedBox.shrink()
              : Column(
                  children: [
                    for (
                      var index = 0;
                      index < group.threads.length;
                      index++
                    ) ...[
                      _ThreadSummaryCard(
                        thread: group.threads[index],
                        onOpenDetail: () =>
                            onOpenDetail(group.threads[index].threadId),
                      ),
                      if (index < group.threads.length - 1)
                        const SizedBox(height: 12),
                    ],
                  ],
                ),
        ),
      ],
    );
  }
}

class _ThreadSummaryCard extends StatelessWidget {
  const _ThreadSummaryCard({required this.thread, required this.onOpenDetail});

  final ThreadSummaryDto thread;
  final VoidCallback onOpenDetail;

  @override
  Widget build(BuildContext context) {
    BadgeVariant variant;
    String statusText;

    switch (thread.status) {
      case ThreadStatus.running:
        variant = BadgeVariant.active;
        statusText = 'ACTIVE';
        break;
      case ThreadStatus.failed:
        variant = BadgeVariant.danger;
        statusText = 'FAILED';
        break;
      case ThreadStatus.interrupted:
        variant = BadgeVariant.warning;
        statusText = 'INTERRUPTED';
        break;
      case ThreadStatus.completed:
        variant = BadgeVariant.defaultVariant;
        statusText = 'COMPLETED';
        break;
      case ThreadStatus.idle:
        variant = BadgeVariant.defaultVariant;
        statusText = 'IDLE';
        break;
    }

    return GestureDetector(
      key: Key('thread-summary-card-${thread.threadId}'),
      onTap: onOpenDetail,
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: LiquidStyles.liquidGlass.copyWith(
          borderRadius: BorderRadius.circular(24),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    thread.title,
                    style: const TextStyle(
                      color: AppTheme.textMain,
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      letterSpacing: -0.5,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                StatusBadge(text: statusText, variant: variant),
              ],
            ),
            const SizedBox(height: 16),

            // Sub details using Phosphor icons
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _DetailRow(
                  icon: PhosphorIcons.folderSimple(),
                  text: thread.repository,
                ),
                const SizedBox(height: 8),
                _DetailRow(
                  icon: PhosphorIcons.gitBranch(),
                  text: thread.branch,
                ),
                const SizedBox(height: 8),
                _DetailRow(
                  icon: PhosphorIcons.terminalWindow(),
                  text: thread.workspace,
                ),
              ],
            ),

            const SizedBox(height: 20),
            Container(height: 1, color: Colors.white.withValues(alpha: 0.05)),
            const SizedBox(height: 16),

            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  thread.threadId.length > 8
                      ? thread.threadId.substring(0, 8)
                      : thread.threadId,
                  style: GoogleFonts.jetBrainsMono(
                    color: AppTheme.textSubtle,
                    fontSize: 10,
                  ),
                ),
                Text(
                  _formatDate(DateTime.parse(thread.updatedAt)),
                  style: GoogleFonts.jetBrainsMono(
                    color: AppTheme.textSubtle,
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _formatDate(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}

class _DetailRow extends StatelessWidget {
  final IconData icon;
  final String text;

  const _DetailRow({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        PhosphorIcon(icon, size: 14, color: AppTheme.textSubtle),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: GoogleFonts.jetBrainsMono(
              color: AppTheme.textSubtle,
              fontSize: 12,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
