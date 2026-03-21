import 'dart:async';

import 'package:codex_mobile_companion/features/approvals/presentation/approvals_queue_page.dart';
import 'package:codex_mobile_companion/features/threads/application/thread_list_controller.dart';
import 'package:codex_mobile_companion/features/threads/presentation/thread_detail_page.dart';
import 'package:codex_mobile_companion/foundation/connectivity/live_connection_state.dart';
import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:codex_mobile_companion/foundation/theme/app_theme.dart';
import 'package:codex_mobile_companion/shared/widgets/badges.dart';
import 'package:codex_mobile_companion/shared/widgets/connection_status_banner.dart';
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
  static const int _defaultVisibleThreadsPerGroup = 3;

  late final TextEditingController _searchController;
  final Set<String> _collapsedGroupIds = <String>{};
  final Set<String> _expandedThreadGroupIds = <String>{};

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

  Future<void> _openThreadDetail(
    ThreadListController controller,
    String threadId,
  ) async {
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

  Future<void> _openDraftThread(ThreadWorkspaceGroup group) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => ThreadDetailPage.draft(
          bridgeApiBaseUrl: widget.bridgeApiBaseUrl,
          draftWorkspacePath: group.workspacePath,
          draftWorkspaceLabel: group.label,
        ),
      ),
    );
  }

  List<ThreadWorkspaceGroup> _availableWorkspaceGroups(ThreadListState state) {
    if (state.visibleGroups.isNotEmpty) {
      return state.visibleGroups
          .where((group) => group.workspacePath.trim().isNotEmpty)
          .toList(growable: false);
    }

    final groups = <String, List<ThreadSummaryDto>>{};
    for (final thread in state.threads) {
      final workspacePath = thread.workspace.trim();
      final groupId = workspacePath.isEmpty
          ? 'repository:${thread.repository.trim()}'
          : workspacePath;
      groups.putIfAbsent(groupId, () => <ThreadSummaryDto>[]).add(thread);
    }

    return groups.entries
        .map((entry) {
          final representative = entry.value.first;
          final workspacePath = representative.workspace.trim();
          final workspaceLabel = _workspaceLabelForThread(representative);
          return ThreadWorkspaceGroup(
            groupId: entry.key,
            label: workspaceLabel,
            workspacePath: workspacePath,
            threads: List<ThreadSummaryDto>.unmodifiable(entry.value),
          );
        })
        .where((group) => group.workspacePath.trim().isNotEmpty)
        .toList(growable: false);
  }

  Future<void> _startNewThread(ThreadListState state) async {
    final groups = _availableWorkspaceGroups(state);
    if (groups.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No workspace is available to start a new thread.'),
        ),
      );
      return;
    }

    if (groups.length == 1) {
      await _openDraftThread(groups.first);
      return;
    }

    final selectedGroup = await showModalBottomSheet<ThreadWorkspaceGroup>(
      context: context,
      backgroundColor: AppTheme.background,
      builder: (context) => _NewThreadWorkspaceSheet(groups: groups),
    );
    if (!mounted || selectedGroup == null) {
      return;
    }

    await _openDraftThread(selectedGroup);
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

  bool _isGroupThreadListExpanded(ThreadListState state, String groupId) {
    if (state.hasQuery) {
      return true;
    }
    return _expandedThreadGroupIds.contains(groupId);
  }

  void _toggleGroupThreadExpansion(String groupId) {
    setState(() {
      if (_expandedThreadGroupIds.contains(groupId)) {
        _expandedThreadGroupIds.remove(groupId);
      } else {
        _expandedThreadGroupIds.add(groupId);
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

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SafeArea(
        child: Column(
          children: [
            // Sticky Header matching React ThreadListScreen
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
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
                  IconButton(
                    key: const Key('open-approvals-queue'),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (context) => ApprovalsQueuePage(
                          bridgeApiBaseUrl: widget.bridgeApiBaseUrl,
                        ),
                      ),
                    ),
                    icon: PhosphorIcon(
                      PhosphorIcons.shieldWarning(PhosphorIconsStyle.duotone),
                      size: 20,
                      color: AppTheme.amber,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'ACTIVE THREADS',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 1.0,
                        color: AppTheme.textMain,
                      ),
                    ),
                  ),
                  IconButton(
                    key: const Key('thread-list-create-button'),
                    onPressed: state.isLoading
                        ? null
                        : () => _startNewThread(state),
                    icon: PhosphorIcon(
                      PhosphorIcons.plus(PhosphorIconsStyle.bold),
                      size: 20,
                      color: AppTheme.textMain,
                    ),
                  ),
                ],
              ),
            ),
            ConnectionStatusBanner(
              state: _threadListConnectionBannerState(
                state.liveConnectionState,
              ),
              detail: _threadListConnectionBannerDetail(state),
              compact: true,
              margin: const EdgeInsets.fromLTRB(24, 0, 24, 4),
            ),

            // Search Bar
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
              child: Container(
                decoration: BoxDecoration(
                  color: AppTheme.surfaceZinc800.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.05),
                  ),
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
                    hintText: 'Search threads...',
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

            Expanded(child: _buildBody(state, controller)),
          ],
        ),
      ),
    );
  }

  ConnectionBannerState _threadListConnectionBannerState(
    LiveConnectionState state,
  ) {
    switch (state) {
      case LiveConnectionState.connected:
        return ConnectionBannerState.connected;
      case LiveConnectionState.reconnecting:
        return ConnectionBannerState.reconnecting;
      case LiveConnectionState.disconnected:
        return ConnectionBannerState.disconnected;
    }
  }

  String _threadListConnectionBannerDetail(ThreadListState state) {
    switch (state.liveConnectionState) {
      case LiveConnectionState.connected:
        return 'Thread socket is live.';
      case LiveConnectionState.reconnecting:
        return state.staleMessage ?? 'Live updates dropped. Reconnecting now.';
      case LiveConnectionState.disconnected:
        return state.errorMessage ??
            state.staleMessage ??
            'Bridge is offline. Thread updates are unavailable.';
    }
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
            isThreadListExpanded: _isGroupThreadListExpanded(
              state,
              group.groupId,
            ),
            visibleThreadLimit: _defaultVisibleThreadsPerGroup,
            onToggleCollapsed: () => _toggleGroupCollapsed(group.groupId),
            onToggleThreadExpansion: () =>
                _toggleGroupThreadExpansion(group.groupId),
            onOpenDetail: (threadId) =>
                unawaited(_openThreadDetail(controller, threadId)),
          );
        },
      ),
    );
  }
}

class _ThreadWorkspaceSection extends StatelessWidget {
  const _ThreadWorkspaceSection({
    required this.group,
    required this.isCollapsed,
    required this.isThreadListExpanded,
    required this.visibleThreadLimit,
    required this.onToggleCollapsed,
    required this.onToggleThreadExpansion,
    required this.onOpenDetail,
  });

  final ThreadWorkspaceGroup group;
  final bool isCollapsed;
  final bool isThreadListExpanded;
  final int visibleThreadLimit;
  final VoidCallback onToggleCollapsed;
  final VoidCallback onToggleThreadExpansion;
  final ValueChanged<String> onOpenDetail;

  @override
  Widget build(BuildContext context) {
    final hasHiddenThreads = group.threads.length > visibleThreadLimit;
    final visibleThreads = isThreadListExpanded
        ? group.threads
        : group.threads.take(visibleThreadLimit).toList(growable: false);

    return Column(
      key: Key('thread-folder-group-${group.groupId}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          key: Key('thread-folder-toggle-${group.groupId}'),
          onTap: onToggleCollapsed,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                PhosphorIcon(
                  PhosphorIcons.folder(PhosphorIconsStyle.fill),
                  size: 18,
                  color: AppTheme.emerald,
                ),
                const SizedBox(width: 10),
                Text(
                  group.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.jetBrainsMono(
                    color: AppTheme.textMuted,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Container(
                    height: 1,
                    color: Colors.white.withValues(alpha: 0.05),
                  ),
                ),
                const SizedBox(width: 16),
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
                      index < visibleThreads.length;
                      index++
                    ) ...[
                      _ThreadSummaryCard(
                        thread: visibleThreads[index],
                        onOpenDetail: () =>
                            onOpenDetail(visibleThreads[index].threadId),
                      ),
                      if (index < visibleThreads.length - 1)
                        const SizedBox(height: 4),
                    ],
                    if (hasHiddenThreads) ...[
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          key: Key('thread-group-show-more-${group.groupId}'),
                          onPressed: onToggleThreadExpansion,
                          style: TextButton.styleFrom(
                            foregroundColor: AppTheme.emerald,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 0,
                              vertical: 6,
                            ),
                            textStyle: GoogleFonts.jetBrainsMono(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          child: Text(
                            isThreadListExpanded ? 'Show less' : 'Show more',
                          ),
                        ),
                      ),
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

    return InkWell(
      key: Key('thread-summary-card-${thread.threadId}'),
      onTap: onOpenDetail,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
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
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                StatusBadge(text: statusText, variant: variant),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Row(
                    children: [
                      PhosphorIcon(
                        PhosphorIcons.gitBranch(),
                        size: 14,
                        color: AppTheme.textSubtle,
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          thread.branch,
                          style: GoogleFonts.jetBrainsMono(
                            color: AppTheme.textSubtle,
                            fontSize: 11,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 16),
                      PhosphorIcon(
                        PhosphorIcons.clock(),
                        size: 14,
                        color: AppTheme.textSubtle,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        _formatDate(DateTime.parse(thread.updatedAt)),
                        style: GoogleFonts.jetBrainsMono(
                          color: AppTheme.textSubtle,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  thread.threadId.length > 8
                      ? thread.threadId.substring(0, 8)
                      : thread.threadId,
                  style: GoogleFonts.jetBrainsMono(
                    color: AppTheme.textSubtle,
                    fontSize: 11,
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

class _NewThreadWorkspaceSheet extends StatelessWidget {
  const _NewThreadWorkspaceSheet({required this.groups});

  final List<ThreadWorkspaceGroup> groups;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'New Thread',
              style: TextStyle(
                color: AppTheme.textMain,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Choose the workspace for the new session.',
              style: TextStyle(color: AppTheme.textMuted, fontSize: 14),
            ),
            const SizedBox(height: 16),
            for (final group in groups) ...[
              ListTile(
                key: Key('thread-list-workspace-option-${group.groupId}'),
                contentPadding: EdgeInsets.zero,
                leading: PhosphorIcon(
                  PhosphorIcons.folderSimple(),
                  color: AppTheme.textMuted,
                ),
                title: Text(
                  group.label,
                  style: const TextStyle(color: AppTheme.textMain),
                ),
                subtitle: Text(
                  group.workspacePath,
                  style: GoogleFonts.jetBrainsMono(
                    color: AppTheme.textSubtle,
                    fontSize: 11,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => Navigator.of(context).pop(group),
              ),
              if (group != groups.last)
                Divider(color: Colors.white.withValues(alpha: 0.06)),
            ],
          ],
        ),
      ),
    );
  }
}

String _workspaceLabelForThread(ThreadSummaryDto thread) {
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
