import 'dart:async';
import 'dart:math' as math;

import 'package:codex_mobile_companion/features/approvals/presentation/approvals_queue_page.dart';
import 'package:codex_mobile_companion/features/threads/application/thread_list_controller.dart';
import 'package:codex_mobile_companion/features/threads/presentation/thread_detail_page.dart';
import 'package:codex_mobile_companion/features/threads/presentation/thread_git_diff_page.dart';
import 'package:codex_mobile_companion/foundation/connectivity/live_connection_state.dart';
import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:codex_mobile_companion/foundation/layout/adaptive_layout.dart';
import 'package:codex_ui/codex_ui.dart';
import 'package:codex_mobile_companion/shared/widgets/badges.dart';
import 'package:codex_mobile_companion/shared/widgets/connection_status_banner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

class ThreadListPage extends ConsumerStatefulWidget {
  const ThreadListPage({
    super.key,
    required this.bridgeApiBaseUrl,
    this.autoOpenPreviouslySelectedThread = false,
  });

  final String bridgeApiBaseUrl;
  final bool autoOpenPreviouslySelectedThread;

  @override
  ConsumerState<ThreadListPage> createState() => _ThreadListPageState();
}

class _ThreadListPageState extends ConsumerState<ThreadListPage> {
  static const int _defaultVisibleThreadsPerGroup = 3;

  late final TextEditingController _searchController;
  late final ProviderSubscription<ThreadListState> _threadListSubscription;
  final Set<String> _collapsedGroupIds = <String>{};
  final Set<String> _expandedThreadGroupIds = <String>{};
  bool _didRestoreInitialSelectedThread = false;
  bool _isWideThreadListHidden = false;
  bool _isWideDiffPaneVisible = false;
  _WideThreadWorkspaceSelection? _wideSelection;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
    _threadListSubscription = ref.listenManual<ThreadListState>(
      threadListControllerProvider(widget.bridgeApiBaseUrl),
      (previous, next) {
        _maybeRestoreInitiallySelectedThread(next);
      },
      fireImmediately: true,
    );
  }

  @override
  void dispose() {
    _threadListSubscription.close();
    _searchController.dispose();
    super.dispose();
  }

  bool _isWideLayoutForContext() {
    final mediaQuery = MediaQuery.maybeOf(context);
    if (mediaQuery == null) {
      return false;
    }
    return AdaptiveLayoutInfo.fromMediaQuery(mediaQuery).isWideLayout;
  }

  Future<void> _openThreadDetail(
    ThreadListController controller,
    String threadId, {
    bool forceWideSelection = false,
  }) async {
    await controller.selectThread(threadId);
    if (!mounted) return;

    if (forceWideSelection || _isWideLayoutForContext()) {
      setState(() {
        _wideSelection = _WideThreadWorkspaceSelection.thread(threadId);
        _isWideDiffPaneVisible = false;
      });
      return;
    }

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => ThreadDetailPage(
          bridgeApiBaseUrl: widget.bridgeApiBaseUrl,
          threadId: threadId,
        ),
      ),
    );
  }

  void _maybeRestoreInitiallySelectedThread(ThreadListState state) {
    if (_didRestoreInitialSelectedThread || !mounted) return;
    if (!widget.autoOpenPreviouslySelectedThread) return;

    final selectedThreadId = state.selectedThreadId?.trim();
    if (selectedThreadId == null || selectedThreadId.isEmpty) {
      return;
    }
    if (state.isLoading && !state.hasAnyThread) {
      return;
    }
    if (!state.threads.any((thread) => thread.threadId == selectedThreadId)) {
      return;
    }

    _didRestoreInitialSelectedThread = true;
    if (_isWideLayoutForContext()) {
      return;
    }

    final controller = ref.read(
      threadListControllerProvider(widget.bridgeApiBaseUrl).notifier,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      unawaited(_openThreadDetail(controller, selectedThreadId));
    });
  }

  Future<void> _openDraftThread(ThreadWorkspaceGroup group) async {
    if (_isWideLayoutForContext()) {
      setState(() {
        _wideSelection = _WideThreadWorkspaceSelection.draft(group);
        _isWideDiffPaneVisible = false;
      });
      return;
    }

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ThreadDetailPage.draft(
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
    final layout = AdaptiveLayoutInfo.fromMediaQuery(MediaQuery.of(context));

    if (!layout.isWideLayout) {
      return Scaffold(
        backgroundColor: AppTheme.background,
        body: SafeArea(
          child: _ThreadListSurface(
            bridgeApiBaseUrl: widget.bridgeApiBaseUrl,
            state: state,
            controller: controller,
            searchController: _searchController,
            visibleThreadsPerGroup: _defaultVisibleThreadsPerGroup,
            isGroupCollapsed: (groupId) => _isGroupCollapsed(state, groupId),
            isGroupThreadListExpanded: (groupId) =>
                _isGroupThreadListExpanded(state, groupId),
            onToggleGroupCollapsed: _toggleGroupCollapsed,
            onToggleGroupThreadExpansion: _toggleGroupThreadExpansion,
            onOpenThread: (threadId) => _openThreadDetail(controller, threadId),
            onCreateThread: state.isLoading
                ? null
                : () => _startNewThread(state),
            onBack: () => Navigator.of(context).pop(),
          ),
        ),
      );
    }

    final selectedThreadId =
        _wideSelection?.threadId ?? state.selectedThreadId?.trim();
    return Scaffold(
      backgroundColor: AppTheme.background,
      drawerEdgeDragWidth: 24,
      drawer: Drawer(
        backgroundColor: AppTheme.background,
        width: math.min(MediaQuery.of(context).size.width * 0.68, 420),
        child: SafeArea(
          child: _ThreadListSurface(
            bridgeApiBaseUrl: widget.bridgeApiBaseUrl,
            state: state,
            controller: controller,
            searchController: _searchController,
            visibleThreadsPerGroup: _defaultVisibleThreadsPerGroup,
            isGroupCollapsed: (groupId) => _isGroupCollapsed(state, groupId),
            isGroupThreadListExpanded: (groupId) =>
                _isGroupThreadListExpanded(state, groupId),
            onToggleGroupCollapsed: _toggleGroupCollapsed,
            onToggleGroupThreadExpansion: _toggleGroupThreadExpansion,
            onOpenThread: (threadId) async {
              Navigator.of(context).pop();
              await _openThreadDetail(
                controller,
                threadId,
                forceWideSelection: true,
              );
            },
            onCreateThread: state.isLoading
                ? null
                : () async {
                    Navigator.of(context).pop();
                    await _startNewThread(state);
                  },
          ),
        ),
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final useFullWidth = layout.hasSeparatingFold;
            final bodyWidth = useFullWidth
                ? constraints.maxWidth
                : layout.constrainedContentWidth(constraints.maxWidth);
            final persistentPaneWidth = layout.hasSeparatingFold
                ? layout.verticalFoldBounds!.left
                : math.min(math.max(bodyWidth * 0.34, 340), 430).toDouble();
            final paneGap = layout.hasSeparatingFold
                ? layout.verticalFoldBounds!.width
                : 1.0;

            return Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                width: bodyWidth,
                child: Row(
                  children: [
                    AnimatedContainer(
                      key: const Key('thread-wide-left-pane'),
                      duration: const Duration(milliseconds: 240),
                      curve: Curves.easeInOutCubic,
                      width: _isWideThreadListHidden ? 0 : persistentPaneWidth,
                      child: ClipRect(
                        child: IgnorePointer(
                          ignoring: _isWideThreadListHidden,
                          child: DecoratedBox(
                            decoration: const BoxDecoration(
                              border: Border(
                                right: BorderSide(color: Colors.white10),
                              ),
                            ),
                            child: _ThreadListSurface(
                              bridgeApiBaseUrl: widget.bridgeApiBaseUrl,
                              state: state,
                              controller: controller,
                              searchController: _searchController,
                              visibleThreadsPerGroup:
                                  _defaultVisibleThreadsPerGroup,
                              isGroupCollapsed: (groupId) =>
                                  _isGroupCollapsed(state, groupId),
                              isGroupThreadListExpanded: (groupId) =>
                                  _isGroupThreadListExpanded(state, groupId),
                              onToggleGroupCollapsed: _toggleGroupCollapsed,
                              onToggleGroupThreadExpansion:
                                  _toggleGroupThreadExpansion,
                              onOpenThread: (threadId) => _openThreadDetail(
                                controller,
                                threadId,
                                forceWideSelection: true,
                              ),
                              onCreateThread: state.isLoading
                                  ? null
                                  : () => _startNewThread(state),
                              selectedThreadId: selectedThreadId,
                            ),
                          ),
                        ),
                      ),
                    ),
                    AnimatedContainer(
                      key: const Key('thread-wide-gap'),
                      duration: const Duration(milliseconds: 240),
                      curve: Curves.easeInOutCubic,
                      width: _isWideThreadListHidden ? 0 : paneGap,
                    ),
                    Expanded(
                      child: _WideThreadWorkspacePane(
                        bridgeApiBaseUrl: widget.bridgeApiBaseUrl,
                        selection: _wideSelection,
                        selectedThreadId: selectedThreadId,
                        onOpenDiff: () {
                          setState(() {
                            _isWideDiffPaneVisible = !_isWideDiffPaneVisible;
                            _isWideThreadListHidden = _isWideDiffPaneVisible;
                          });
                        },
                        onToggleSidebar: () {
                          setState(() {
                            if (_isWideDiffPaneVisible) {
                              _isWideDiffPaneVisible = false;
                              _isWideThreadListHidden = false;
                            } else {
                              _isWideThreadListHidden =
                                  !_isWideThreadListHidden;
                            }
                          });
                        },
                        isSidebarVisible: !_isWideThreadListHidden,
                        isDiffVisible: _isWideDiffPaneVisible,
                        onDraftCreated: (transition) {
                          setState(() {
                            _wideSelection =
                                _WideThreadWorkspaceSelection.createdThread(
                                  transition,
                                );
                          });
                        },
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _ThreadListSurface extends StatelessWidget {
  const _ThreadListSurface({
    required this.bridgeApiBaseUrl,
    required this.state,
    required this.controller,
    required this.searchController,
    required this.visibleThreadsPerGroup,
    required this.isGroupCollapsed,
    required this.isGroupThreadListExpanded,
    required this.onToggleGroupCollapsed,
    required this.onToggleGroupThreadExpansion,
    required this.onOpenThread,
    required this.onCreateThread,
    this.onBack,
    this.selectedThreadId,
  });

  final String bridgeApiBaseUrl;
  final ThreadListState state;
  final ThreadListController controller;
  final TextEditingController searchController;
  final int visibleThreadsPerGroup;
  final bool Function(String groupId) isGroupCollapsed;
  final bool Function(String groupId) isGroupThreadListExpanded;
  final ValueChanged<String> onToggleGroupCollapsed;
  final ValueChanged<String> onToggleGroupThreadExpansion;
  final ValueChanged<String> onOpenThread;
  final VoidCallback? onCreateThread;
  final VoidCallback? onBack;
  final String? selectedThreadId;

  bool get _isWidePane => onBack == null;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          color: AppTheme.background.withValues(alpha: 0.8),
          child: Row(
            children: [
              if (onBack != null)
                IconButton(
                  onPressed: onBack,
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
                    builder: (context) =>
                        ApprovalsQueuePage(bridgeApiBaseUrl: bridgeApiBaseUrl),
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
                onPressed: onCreateThread,
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
          state: _threadListConnectionBannerState(state.liveConnectionState),
          detail: _threadListConnectionBannerDetail(state),
          compact: true,
          margin: EdgeInsets.fromLTRB(24, 0, 24, _isWidePane ? 8 : 4),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
          child: Container(
            decoration: BoxDecoration(
              color: AppTheme.surfaceZinc800.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
            ),
            child: TextField(
              key: const Key('thread-search-input'),
              controller: searchController,
              onChanged: controller.updateSearchQuery,
              style: const TextStyle(color: AppTheme.textMain, fontSize: 14),
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
                          searchController.clear();
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
        Expanded(
          child: _ThreadListBody(
            state: state,
            controller: controller,
            visibleThreadsPerGroup: visibleThreadsPerGroup,
            isGroupCollapsed: isGroupCollapsed,
            isGroupThreadListExpanded: isGroupThreadListExpanded,
            onToggleGroupCollapsed: onToggleGroupCollapsed,
            onToggleGroupThreadExpansion: onToggleGroupThreadExpansion,
            onOpenThread: onOpenThread,
            selectedThreadId: selectedThreadId,
          ),
        ),
      ],
    );
  }
}

class _ThreadListBody extends StatelessWidget {
  const _ThreadListBody({
    required this.state,
    required this.controller,
    required this.visibleThreadsPerGroup,
    required this.isGroupCollapsed,
    required this.isGroupThreadListExpanded,
    required this.onToggleGroupCollapsed,
    required this.onToggleGroupThreadExpansion,
    required this.onOpenThread,
    this.selectedThreadId,
  });

  final ThreadListState state;
  final ThreadListController controller;
  final int visibleThreadsPerGroup;
  final bool Function(String groupId) isGroupCollapsed;
  final bool Function(String groupId) isGroupThreadListExpanded;
  final ValueChanged<String> onToggleGroupCollapsed;
  final ValueChanged<String> onToggleGroupThreadExpansion;
  final ValueChanged<String> onOpenThread;
  final String? selectedThreadId;

  @override
  Widget build(BuildContext context) {
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
            isCollapsed: isGroupCollapsed(group.groupId),
            isThreadListExpanded: isGroupThreadListExpanded(group.groupId),
            visibleThreadLimit: visibleThreadsPerGroup,
            selectedThreadId: selectedThreadId,
            onToggleCollapsed: () => onToggleGroupCollapsed(group.groupId),
            onToggleThreadExpansion: () =>
                onToggleGroupThreadExpansion(group.groupId),
            onOpenDetail: onOpenThread,
          );
        },
      ),
    );
  }
}

class _WideThreadWorkspacePane extends StatelessWidget {
  const _WideThreadWorkspacePane({
    required this.bridgeApiBaseUrl,
    required this.selection,
    required this.selectedThreadId,
    required this.onOpenDiff,
    required this.onToggleSidebar,
    required this.isSidebarVisible,
    required this.isDiffVisible,
    required this.onDraftCreated,
  });

  final String bridgeApiBaseUrl;
  final _WideThreadWorkspaceSelection? selection;
  final String? selectedThreadId;
  final VoidCallback onOpenDiff;
  final VoidCallback onToggleSidebar;
  final bool isSidebarVisible;
  final bool isDiffVisible;
  final ValueChanged<ThreadDraftCreatedTransition> onDraftCreated;

  @override
  Widget build(BuildContext context) {
    final availableWidth = MediaQuery.of(context).size.width;
    final diffPaneWidth = math.min(
      math.max(availableWidth * 0.34, 360.0),
      560.0,
    );

    return Row(
      children: [
        Expanded(
          child: _WideThreadDetailPane(
            bridgeApiBaseUrl: bridgeApiBaseUrl,
            selection: selection,
            selectedThreadId: selectedThreadId,
            onOpenDiff: onOpenDiff,
            onToggleSidebar: onToggleSidebar,
            isSidebarVisible: isSidebarVisible,
            isDiffVisible: isDiffVisible,
            onDraftCreated: onDraftCreated,
          ),
        ),
        AnimatedContainer(
          key: const Key('thread-wide-right-diff-pane'),
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeInOutCubic,
          width: isDiffVisible && (selectedThreadId?.isNotEmpty ?? false)
              ? diffPaneWidth
              : 0,
          child: ClipRect(
            child: IgnorePointer(
              ignoring: !isDiffVisible,
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  border: Border(left: BorderSide(color: Colors.white10)),
                ),
                child: (selectedThreadId?.isNotEmpty ?? false)
                    ? ThreadGitDiffPane(
                        key: ValueKey('thread-wide-diff-$selectedThreadId'),
                        bridgeApiBaseUrl: bridgeApiBaseUrl,
                        threadId: selectedThreadId!,
                        onClose: onOpenDiff,
                      )
                    : const SizedBox.shrink(),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _WideThreadDetailPane extends StatelessWidget {
  const _WideThreadDetailPane({
    required this.bridgeApiBaseUrl,
    required this.selection,
    required this.selectedThreadId,
    required this.onOpenDiff,
    required this.onToggleSidebar,
    required this.isSidebarVisible,
    required this.isDiffVisible,
    required this.onDraftCreated,
  });

  final String bridgeApiBaseUrl;
  final _WideThreadWorkspaceSelection? selection;
  final String? selectedThreadId;
  final VoidCallback onOpenDiff;
  final VoidCallback onToggleSidebar;
  final bool isSidebarVisible;
  final bool isDiffVisible;
  final ValueChanged<ThreadDraftCreatedTransition> onDraftCreated;

  @override
  Widget build(BuildContext context) {
    final draftGroup = selection?.draftGroup;
    if (draftGroup != null) {
      return ThreadDetailPage.draft(
        key: ValueKey('thread-draft-${draftGroup.groupId}'),
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        draftWorkspacePath: draftGroup.workspacePath,
        draftWorkspaceLabel: draftGroup.label,
        showBackButton: false,
        embedInScaffold: false,
        onDraftThreadCreated: onDraftCreated,
        onToggleSidebar: onToggleSidebar,
        isSidebarVisible: isSidebarVisible,
      );
    }

    if (selectedThreadId?.isNotEmpty ?? false) {
      return ThreadDetailPage(
        key: ValueKey(
          'thread-wide-detail-${selection?.presentationKey ?? selectedThreadId}',
        ),
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        threadId: selectedThreadId,
        initialComposerInput: selection?.initialComposerInput,
        initialAttachedImages:
            selection?.initialAttachedImages ?? const <XFile>[],
        initialSelectedModel: selection?.initialSelectedModel,
        initialSelectedReasoningEffort:
            selection?.initialSelectedReasoningEffort,
        showBackButton: false,
        embedInScaffold: false,
        onOpenDiff: onOpenDiff,
        onToggleSidebar: onToggleSidebar,
        isSidebarVisible: isSidebarVisible,
        onToggleDiff: onOpenDiff,
        isDiffVisible: isDiffVisible,
      );
    }

    return const _WideThreadEmptyState();
  }
}

class _WideThreadEmptyState extends StatelessWidget {
  const _WideThreadEmptyState();

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('thread-list-wide-placeholder'),
      color: AppTheme.background,
      padding: const EdgeInsets.all(32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Container(
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(
              color: AppTheme.surfaceZinc900,
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: Colors.white10),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppTheme.surfaceZinc800,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: PhosphorIcon(
                    PhosphorIcons.chatCircleDots(PhosphorIconsStyle.duotone),
                    color: AppTheme.emerald,
                    size: 24,
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  'Pick a thread or start a new session',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.6,
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  'The right pane stays ready for live detail, composer controls, and approvals as soon as you select a thread from the workspace list.',
                  style: TextStyle(
                    color: AppTheme.textMuted,
                    fontSize: 15,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _WideThreadWorkspaceSelection {
  const _WideThreadWorkspaceSelection._({
    this.threadId,
    this.draftGroup,
    this.initialComposerInput,
    this.initialAttachedImages = const [],
    this.initialSelectedModel,
    this.initialSelectedReasoningEffort,
    this.presentationKey,
  });

  factory _WideThreadWorkspaceSelection.thread(String threadId) {
    return _WideThreadWorkspaceSelection._(
      threadId: threadId,
      presentationKey: threadId,
    );
  }

  factory _WideThreadWorkspaceSelection.draft(ThreadWorkspaceGroup draftGroup) {
    return _WideThreadWorkspaceSelection._(
      draftGroup: draftGroup,
      presentationKey: 'draft-${draftGroup.groupId}',
    );
  }

  factory _WideThreadWorkspaceSelection.createdThread(
    ThreadDraftCreatedTransition transition,
  ) {
    return _WideThreadWorkspaceSelection._(
      threadId: transition.threadId,
      initialComposerInput: transition.initialComposerInput,
      initialAttachedImages: transition.initialAttachedImages,
      initialSelectedModel: transition.initialSelectedModel,
      initialSelectedReasoningEffort: transition.initialSelectedReasoningEffort,
      presentationKey:
          '${transition.threadId}-${DateTime.now().microsecondsSinceEpoch}',
    );
  }

  final String? threadId;
  final ThreadWorkspaceGroup? draftGroup;
  final String? initialComposerInput;
  final List<XFile> initialAttachedImages;
  final String? initialSelectedModel;
  final String? initialSelectedReasoningEffort;
  final String? presentationKey;
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

class _ThreadWorkspaceSection extends StatelessWidget {
  const _ThreadWorkspaceSection({
    required this.group,
    required this.isCollapsed,
    required this.isThreadListExpanded,
    required this.visibleThreadLimit,
    required this.onToggleCollapsed,
    required this.onToggleThreadExpansion,
    required this.onOpenDetail,
    this.selectedThreadId,
  });

  final ThreadWorkspaceGroup group;
  final bool isCollapsed;
  final bool isThreadListExpanded;
  final int visibleThreadLimit;
  final VoidCallback onToggleCollapsed;
  final VoidCallback onToggleThreadExpansion;
  final ValueChanged<String> onOpenDetail;
  final String? selectedThreadId;

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
                Flexible(
                  child: Text(
                    group.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.jetBrainsMono(
                      color: AppTheme.textMuted,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
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
                        isSelected:
                            visibleThreads[index].threadId == selectedThreadId,
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
  const _ThreadSummaryCard({
    required this.thread,
    required this.onOpenDetail,
    this.isSelected = false,
  });

  final ThreadSummaryDto thread;
  final VoidCallback onOpenDetail;
  final bool isSelected;

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
      borderRadius: BorderRadius.circular(18),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? AppTheme.surfaceZinc800.withValues(alpha: 0.92)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: isSelected
                ? AppTheme.emerald.withValues(alpha: 0.35)
                : Colors.transparent,
          ),
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
                      const SizedBox(width: 8),
                      Flexible(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            PhosphorIcon(
                              PhosphorIcons.clock(),
                              size: 14,
                              color: AppTheme.textSubtle,
                            ),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                _formatDate(DateTime.parse(thread.updatedAt)),
                                style: GoogleFonts.jetBrainsMono(
                                  color: AppTheme.textSubtle,
                                  fontSize: 11,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
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
