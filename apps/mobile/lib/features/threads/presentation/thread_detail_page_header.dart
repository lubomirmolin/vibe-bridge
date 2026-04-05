part of 'thread_detail_page.dart';

class _ThreadDetailHeader extends StatelessWidget {
  const _ThreadDetailHeader({
    required this.state,
    required this.hasPendingApprovals,
    required this.gitControls,
    required this.canOpenOnMac,
    required this.onBackWhenLoaded,
    required this.onBackWhenUnavailable,
    required this.onOpenGitBranchSheet,
    required this.onOpenGitSyncSheet,
    required this.onOpenOnMac,
    required this.onOpenDiff,
    required this.onOpenDiagnostics,
    required this.onToggleSidebar,
    required this.onToggleDiff,
    required this.onOpenSettings,
    required this.isHeaderCollapsed,
    required this.showBackButton,
    required this.isSidebarVisible,
    required this.isDiffVisible,
  });

  final ThreadDetailState state;
  final bool hasPendingApprovals;
  final _ResolvedGitControls gitControls;
  final bool canOpenOnMac;
  final VoidCallback onBackWhenLoaded;
  final VoidCallback onBackWhenUnavailable;
  final Future<void> Function() onOpenGitBranchSheet;
  final Future<void> Function() onOpenGitSyncSheet;
  final Future<void> Function() onOpenOnMac;
  final Future<void> Function() onOpenDiff;
  final Future<void> Function() onOpenDiagnostics;
  final VoidCallback? onToggleSidebar;
  final VoidCallback? onToggleDiff;
  final VoidCallback? onOpenSettings;
  final ValueListenable<bool> isHeaderCollapsed;
  final bool showBackButton;
  final bool isSidebarVisible;
  final bool isDiffVisible;

  @override
  Widget build(BuildContext context) {
    return _LoadedThreadDetailHeader(
      state: state,
      hasPendingApprovals: hasPendingApprovals,
      gitControls: gitControls,
      canOpenOnMac: canOpenOnMac,
      onBack: state.thread == null ? onBackWhenUnavailable : onBackWhenLoaded,
      onOpenGitBranchSheet: onOpenGitBranchSheet,
      onOpenGitSyncSheet: onOpenGitSyncSheet,
      onOpenOnMac: onOpenOnMac,
      onOpenDiff: onOpenDiff,
      onOpenDiagnostics: onOpenDiagnostics,
      onToggleSidebar: onToggleSidebar,
      onToggleDiff: onToggleDiff,
      onOpenSettings: onOpenSettings,
      isHeaderCollapsed: isHeaderCollapsed,
      connectionState: state.liveConnectionState,
      connectionDetail: _threadDetailConnectionBannerDetail(state),
      showBackButton: showBackButton,
      isSidebarVisible: isSidebarVisible,
      isDiffVisible: isDiffVisible,
    );
  }
}

class _LoadedThreadDetailHeader extends StatelessWidget {
  const _LoadedThreadDetailHeader({
    required this.state,
    required this.hasPendingApprovals,
    required this.gitControls,
    required this.canOpenOnMac,
    required this.onBack,
    required this.onOpenGitBranchSheet,
    required this.onOpenGitSyncSheet,
    required this.onOpenOnMac,
    required this.onOpenDiff,
    required this.onOpenDiagnostics,
    required this.onToggleSidebar,
    required this.onToggleDiff,
    required this.onOpenSettings,
    required this.isHeaderCollapsed,
    required this.connectionState,
    required this.connectionDetail,
    required this.showBackButton,
    required this.isSidebarVisible,
    required this.isDiffVisible,
  });

  final ThreadDetailState state;
  final bool hasPendingApprovals;
  final _ResolvedGitControls gitControls;
  final bool canOpenOnMac;
  final VoidCallback onBack;
  final Future<void> Function() onOpenGitBranchSheet;
  final Future<void> Function() onOpenGitSyncSheet;
  final Future<void> Function() onOpenOnMac;
  final Future<void> Function() onOpenDiff;
  final Future<void> Function() onOpenDiagnostics;
  final VoidCallback? onToggleSidebar;
  final VoidCallback? onToggleDiff;
  final VoidCallback? onOpenSettings;
  final ValueListenable<bool> isHeaderCollapsed;
  final LiveConnectionState connectionState;
  final String? connectionDetail;
  final bool showBackButton;
  final bool isSidebarVisible;
  final bool isDiffVisible;

  @override
  Widget build(BuildContext context) {
    final thread = state.thread;
    final hasThread = thread != null;
    final showSidebarToggle = onToggleSidebar != null;
    final leadingInset = showBackButton || showSidebarToggle ? 36.0 : 16.0;
    final title = thread == null
        ? 'Session Details'
        : (thread.title.trim().isEmpty
              ? 'Untitled thread'
              : thread.title.trim());
    final repositoryLabel = thread?.repository ?? 'Repository unavailable';
    final statusLabel = hasThread ? _threadStatusLabel(thread.status) : 'Idle';
    final branchLabel = hasThread
        ? gitControls.repositoryContext.branch
        : 'Branch unavailable';
    final syncLabel = hasThread ? gitControls.syncLabel : 'Sync';
    return Container(
      padding: const EdgeInsets.only(top: 0, right: 16, bottom: 8),
      decoration: const BoxDecoration(
        color: AppTheme.background,
        border: Border(bottom: BorderSide(color: Colors.white10)),
      ),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: _ThreadDetailPageState._sessionContentMaxWidth,
          ),
          child: SizedBox(
            width: double.infinity,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (showBackButton)
                      IconButton(
                        key: const Key('thread-detail-back-button'),
                        onPressed: onBack,
                        icon: PhosphorIcon(
                          PhosphorIcons.caretLeft(PhosphorIconsStyle.bold),
                          size: 20,
                          color: AppTheme.textMuted,
                        ),
                      )
                    else if (showSidebarToggle)
                      IconButton(
                        key: const Key('thread-detail-sidebar-toggle'),
                        onPressed: onToggleSidebar,
                        icon: PhosphorIcon(
                          PhosphorIcons.sidebarSimple(
                            isSidebarVisible
                                ? PhosphorIconsStyle.fill
                                : PhosphorIconsStyle.regular,
                          ),
                          size: 20,
                          color: AppTheme.textMuted,
                        ),
                      )
                    else
                      const SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        title,
                        key: const Key('thread-detail-title'),
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          color: AppTheme.textMain,
                          fontWeight: FontWeight.w500,
                          letterSpacing: -0.5,
                          fontSize: 18,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (onToggleDiff != null)
                      IconButton(
                        key: const Key('thread-detail-diff-toggle'),
                        onPressed: onToggleDiff,
                        icon: PhosphorIcon(
                          PhosphorIcons.gitDiff(
                            isDiffVisible
                                ? PhosphorIconsStyle.fill
                                : PhosphorIconsStyle.regular,
                          ),
                          size: 20,
                          color: isDiffVisible
                              ? AppTheme.emerald
                              : AppTheme.textMuted,
                        ),
                      ),
                    if (onOpenSettings != null)
                      IconButton(
                        key: const Key('thread-detail-settings-toggle'),
                        onPressed: onOpenSettings,
                        icon: PhosphorIcon(
                          PhosphorIcons.slidersHorizontal(),
                          size: 20,
                          color: AppTheme.textMuted,
                        ),
                      ),
                    IconButton(
                      key: const Key('thread-detail-diagnostics-toggle'),
                      onPressed: onOpenDiagnostics,
                      icon: PhosphorIcon(
                        PhosphorIcons.bug(),
                        size: 20,
                        color: AppTheme.textMuted,
                      ),
                    ),
                  ],
                ),
                Padding(
                  padding: EdgeInsets.only(left: leadingInset),
                  child: SingleChildScrollView(
                    key: const Key('thread-detail-metadata-scroll'),
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        PhosphorIcon(
                          PhosphorIcons.folderSimple(),
                          size: 14,
                          color: AppTheme.textSubtle,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          repositoryLabel,
                          style: GoogleFonts.jetBrainsMono(
                            color: AppTheme.textSubtle,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Text(
                          '•',
                          style: TextStyle(color: AppTheme.textSubtle),
                        ),
                        const SizedBox(width: 8),
                        StatusBadge(
                          text: statusLabel,
                          variant: thread?.status == ThreadStatus.running
                              ? BadgeVariant.active
                              : BadgeVariant.defaultVariant,
                        ),
                        if (hasThread && hasPendingApprovals) ...[
                          const SizedBox(width: 8),
                          const Text(
                            '•',
                            style: TextStyle(color: AppTheme.textSubtle),
                          ),
                          const SizedBox(width: 8),
                          PhosphorIcon(
                            PhosphorIcons.shieldWarning(),
                            size: 14,
                            color: AppTheme.amber,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'Approvals Req.',
                            style: GoogleFonts.jetBrainsMono(
                              color: AppTheme.amber,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                ConnectionStatusBanner(
                  state: _threadDetailConnectionBannerState(connectionState),
                  detail: connectionDetail,
                  compact: true,
                  margin: EdgeInsets.fromLTRB(leadingInset, 12, 0, 0),
                ),
                ValueListenableBuilder<bool>(
                  valueListenable: isHeaderCollapsed,
                  builder: (context, isCollapsed, child) {
                    return AnimatedSize(
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeInOut,
                      alignment: Alignment.topCenter,
                      child: isCollapsed
                          ? const SizedBox(width: double.infinity)
                          : child!,
                    );
                  },
                  child: Column(
                    children: [
                      const SizedBox(height: 16),
                      Padding(
                        padding: EdgeInsets.only(left: leadingInset),
                        child: Row(
                          children: [
                            Expanded(
                              flex: 3,
                              child: FilledButton.tonalIcon(
                                key: const Key('git-header-branch-button'),
                                style: FilledButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 10,
                                  ),
                                  backgroundColor: AppTheme.surfaceZinc800
                                      .withValues(alpha: 0.5),
                                  disabledBackgroundColor: AppTheme
                                      .surfaceZinc800
                                      .withValues(alpha: 0.5),
                                  foregroundColor: AppTheme.textMain,
                                  disabledForegroundColor: AppTheme.textMain,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8),
                                    side: BorderSide(
                                      color: Colors.white.withValues(
                                        alpha: 0.05,
                                      ),
                                    ),
                                  ),
                                ),
                                onPressed: hasThread
                                    ? () async {
                                        await onOpenGitBranchSheet();
                                      }
                                    : null,
                                icon: PhosphorIcon(
                                  PhosphorIcons.gitBranch(),
                                  size: 16,
                                  color:
                                      hasThread &&
                                          gitControls.hasDirtyWorkingTree
                                      ? AppTheme.amber
                                      : AppTheme.textSubtle,
                                ),
                                label: Text(
                                  branchLabel,
                                  style: const TextStyle(fontSize: 13),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              flex: 2,
                              child: FilledButton.tonalIcon(
                                key: const Key('git-header-sync-button'),
                                style: FilledButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 10,
                                  ),
                                  backgroundColor: AppTheme.surfaceZinc800
                                      .withValues(alpha: 0.5),
                                  disabledBackgroundColor: AppTheme
                                      .surfaceZinc800
                                      .withValues(alpha: 0.5),
                                  foregroundColor: AppTheme.textMain,
                                  disabledForegroundColor: AppTheme.textMain,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8),
                                    side: BorderSide(
                                      color: Colors.white.withValues(
                                        alpha: 0.05,
                                      ),
                                    ),
                                  ),
                                ),
                                onPressed: hasThread
                                    ? () async {
                                        await onOpenGitSyncSheet();
                                      }
                                    : null,
                                icon: PhosphorIcon(
                                  PhosphorIcons.arrowsClockwise(),
                                  size: 16,
                                  color: AppTheme.textSubtle,
                                ),
                                label: Text(
                                  syncLabel,
                                  style: const TextStyle(fontSize: 13),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            FilledButton.tonal(
                              key: const Key('open-on-mac-button'),
                              style: FilledButton.styleFrom(
                                minimumSize: const Size(44, 44),
                                padding: const EdgeInsets.all(10),
                                backgroundColor: AppTheme.surfaceZinc800
                                    .withValues(alpha: 0.5),
                                disabledBackgroundColor: AppTheme.surfaceZinc800
                                    .withValues(alpha: 0.5),
                                foregroundColor: AppTheme.textMain,
                                disabledForegroundColor: AppTheme.textMain,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                  side: BorderSide(
                                    color: Colors.white.withValues(alpha: 0.05),
                                  ),
                                ),
                              ),
                              onPressed: hasThread && canOpenOnMac
                                  ? () async {
                                      await onOpenOnMac();
                                    }
                                  : null,
                              child: hasThread && state.isOpenOnMacInFlight
                                  ? const SizedBox.square(
                                      dimension: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: AppTheme.textMain,
                                      ),
                                    )
                                  : PhosphorIcon(
                                      PhosphorIcons.monitor(),
                                      size: 18,
                                      color: AppTheme.textMain,
                                    ),
                            ),
                          ],
                        ),
                      ),
                    ],
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

String _threadStatusLabel(ThreadStatus value) {
  switch (value) {
    case ThreadStatus.running:
      return 'Running';
    case ThreadStatus.interrupted:
      return 'Interrupted';
    case ThreadStatus.idle:
      return 'Idle';
    case ThreadStatus.completed:
      return 'Completed';
    case ThreadStatus.failed:
      return 'Failed';
  }
}

class _ResolvedGitControls {
  const _ResolvedGitControls({
    required this.repositoryContext,
    required this.status,
    required this.hasResolvedGitStatus,
    required this.canRunGitMutations,
    required this.unavailableMessage,
  });

  factory _ResolvedGitControls.resolve({
    required ThreadDetailDto? thread,
    required GitStatusResponseDto? gitStatus,
    required bool controlsEnabled,
    required bool isReadOnlyMode,
    required bool isGitStatusLoading,
    required bool isGitMutationInFlight,
    required String? gitControlsUnavailableReason,
  }) {
    final repositoryContext =
        gitStatus?.repository ??
        RepositoryContextDto(
          workspace: thread?.workspace ?? '',
          repository: thread?.repository ?? 'unknown',
          branch: thread?.branch ?? 'unknown',
          remote: 'unknown',
        );
    final status = gitStatus?.status;
    final hasResolvedGitStatus = gitStatus != null;

    final repository = repositoryContext.repository.trim().toLowerCase();
    final branch = repositoryContext.branch.trim().toLowerCase();
    final hasRepositoryContext =
        hasResolvedGitStatus &&
        repository.isNotEmpty &&
        repository != 'unknown' &&
        branch.isNotEmpty &&
        branch != 'unknown';

    final canRunGitMutations =
        controlsEnabled &&
        hasResolvedGitStatus &&
        hasRepositoryContext &&
        !isGitStatusLoading &&
        !isGitMutationInFlight;

    final unavailableMessage = isReadOnlyMode
        ? 'Read-only mode blocks git mutations.'
        : !controlsEnabled
        ? 'Git controls unavailable (offline).'
        : gitControlsUnavailableReason;

    return _ResolvedGitControls(
      repositoryContext: repositoryContext,
      status: status,
      hasResolvedGitStatus: hasResolvedGitStatus,
      canRunGitMutations: canRunGitMutations,
      unavailableMessage: unavailableMessage,
    );
  }

  final RepositoryContextDto repositoryContext;
  final GitStatusDto? status;
  final bool hasResolvedGitStatus;
  final bool canRunGitMutations;
  final String? unavailableMessage;

  bool get hasDirtyWorkingTree => status?.dirty ?? false;

  String get syncLabel {
    if (status == null) {
      return 'Sync';
    }
    final aheadBy = status!.aheadBy;
    final behindBy = status!.behindBy;
    if (aheadBy == 0 && behindBy == 0) {
      return 'Up to date';
    }
    return '↑$aheadBy ↓$behindBy';
  }

  String get statusLabel {
    if (status == null) {
      return hasResolvedGitStatus
          ? 'Status unavailable'
          : 'Resolving git status';
    }
    final dirty = status!.dirty ? 'Dirty' : 'Clean';
    return 'Status: $dirty • Ahead ${status!.aheadBy} • Behind ${status!.behindBy}';
  }
}

class _GitBranchSheet extends StatefulWidget {
  const _GitBranchSheet({
    required this.gitControls,
    required this.gitBranchController,
    required this.onSwitchBranch,
    required this.canStartCommit,
    required this.onStartCommitAction,
  });

  final _ResolvedGitControls gitControls;
  final TextEditingController gitBranchController;
  final Future<bool> Function(String rawBranch) onSwitchBranch;
  final bool canStartCommit;
  final Future<bool> Function() onStartCommitAction;

  @override
  State<_GitBranchSheet> createState() => _GitBranchSheetState();
}

class _GitBranchSheetState extends State<_GitBranchSheet> {
  bool _isCommitSubmitting = false;

  @override
  Widget build(BuildContext context) {
    final commitEnabled = widget.canStartCommit && !_isCommitSubmitting;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 24,
          top: 24,
          right: 24,
          bottom: MediaQuery.of(context).viewInsets.bottom + 24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Git',
              style: TextStyle(
                color: AppTheme.textMain,
                fontWeight: FontWeight.w600,
                fontSize: 18,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Repository: ${widget.gitControls.repositoryContext.repository}',
              style: const TextStyle(color: AppTheme.textMuted, fontSize: 13),
            ),
            const SizedBox(height: 4),
            Text(
              'Branch: ${widget.gitControls.repositoryContext.branch}',
              style: const TextStyle(color: AppTheme.textMuted, fontSize: 13),
            ),
            const SizedBox(height: 4),
            Text(
              'Remote: ${widget.gitControls.repositoryContext.remote}',
              style: const TextStyle(color: AppTheme.textMuted, fontSize: 13),
            ),
            const SizedBox(height: 4),
            Text(
              widget.gitControls.statusLabel,
              style: TextStyle(
                color: widget.gitControls.hasDirtyWorkingTree
                    ? AppTheme.amber
                    : AppTheme.textMuted,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('git-branch-input'),
                    controller: widget.gitBranchController,
                    enabled:
                        widget.gitControls.canRunGitMutations &&
                        !_isCommitSubmitting,
                    style: const TextStyle(
                      color: AppTheme.textMain,
                      fontSize: 14,
                    ),
                    decoration: InputDecoration(
                      hintText: 'Branch name...',
                      hintStyle: const TextStyle(color: AppTheme.textSubtle),
                      filled: true,
                      fillColor: Colors.black26,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 0,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  key: const Key('git-branch-switch-button'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.surfaceZinc800,
                    foregroundColor: AppTheme.textMain,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                  ),
                  onPressed:
                      widget.gitControls.canRunGitMutations &&
                          !_isCommitSubmitting
                      ? () async {
                          final success = await widget.onSwitchBranch(
                            widget.gitBranchController.text,
                          );
                          if (success) {
                            widget.gitBranchController.clear();
                            if (context.mounted) {
                              Navigator.of(context).pop();
                            }
                          }
                        }
                      : null,
                  child: const Text('Checkout'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                key: const Key('git-branch-commit-button'),
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.surfaceZinc800.withValues(
                    alpha: 0.7,
                  ),
                  foregroundColor: AppTheme.textMain,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                ),
                onPressed: commitEnabled
                    ? () async {
                        final navigator = Navigator.of(context);
                        setState(() {
                          _isCommitSubmitting = true;
                        });
                        final success = await widget.onStartCommitAction();
                        if (!mounted) {
                          return;
                        }
                        setState(() {
                          _isCommitSubmitting = false;
                        });
                        if (success) {
                          navigator.pop();
                        }
                      }
                    : null,
                icon: _isCommitSubmitting
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppTheme.textMain,
                        ),
                      )
                    : PhosphorIcon(
                        PhosphorIcons.gitCommit(),
                        size: 16,
                        color: AppTheme.textSubtle,
                      ),
                label: const Text('Commit'),
              ),
            ),
            if (widget.gitControls.unavailableMessage != null) ...[
              const SizedBox(height: 12),
              Text(
                widget.gitControls.unavailableMessage!,
                style: const TextStyle(color: AppTheme.rose, fontSize: 13),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _GitSyncSheet extends StatelessWidget {
  const _GitSyncSheet({
    required this.gitControls,
    required this.onRefreshGitStatus,
    required this.onPullRepository,
    required this.onPushRepository,
  });

  final _ResolvedGitControls gitControls;
  final Future<void> Function({bool showLoading}) onRefreshGitStatus;
  final Future<bool> Function() onPullRepository;
  final Future<bool> Function() onPushRepository;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Sync',
              style: TextStyle(
                color: AppTheme.textMain,
                fontWeight: FontWeight.w600,
                fontSize: 18,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              gitControls.statusLabel,
              style: TextStyle(
                color: gitControls.hasDirtyWorkingTree
                    ? AppTheme.amber
                    : AppTheme.textMuted,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              key: const Key('git-refresh-button'),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Colors.white12),
                foregroundColor: AppTheme.textMain,
              ),
              onPressed: () async {
                await onRefreshGitStatus(showLoading: true);
                if (context.mounted) {
                  Navigator.of(context).pop();
                }
              },
              icon: PhosphorIcon(PhosphorIcons.arrowsClockwise(), size: 16),
              label: const Text('Refresh status'),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('git-pull-button'),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.white12),
                      foregroundColor: AppTheme.textMain,
                    ),
                    onPressed: gitControls.canRunGitMutations
                        ? () async {
                            await onPullRepository();
                            if (context.mounted) {
                              Navigator.of(context).pop();
                            }
                          }
                        : null,
                    icon: PhosphorIcon(
                      PhosphorIcons.downloadSimple(),
                      size: 16,
                    ),
                    label: const Text('Pull'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('git-push-button'),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.white12),
                      foregroundColor: AppTheme.textMain,
                    ),
                    onPressed: gitControls.canRunGitMutations
                        ? () async {
                            await onPushRepository();
                            if (context.mounted) {
                              Navigator.of(context).pop();
                            }
                          }
                        : null,
                    icon: PhosphorIcon(PhosphorIcons.uploadSimple(), size: 16),
                    label: const Text('Push'),
                  ),
                ),
              ],
            ),
            if (gitControls.unavailableMessage != null) ...[
              const SizedBox(height: 12),
              Text(
                gitControls.unavailableMessage!,
                style: const TextStyle(color: AppTheme.rose, fontSize: 13),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
