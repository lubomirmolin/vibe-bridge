part of 'thread_detail_page.dart';

class _ThreadDetailHeader extends StatelessWidget {
  const _ThreadDetailHeader({
    required this.state,
    required this.accessMode,
    required this.hasPendingApprovals,
    required this.gitControls,
    required this.canOpenOnMac,
    required this.onBackWhenLoaded,
    required this.onBackWhenUnavailable,
    required this.onOpenGitBranchSheet,
    required this.onOpenGitSyncSheet,
    required this.onOpenOnMac,
  });

  final ThreadDetailState state;
  final AccessMode accessMode;
  final bool hasPendingApprovals;
  final _ResolvedGitControls gitControls;
  final bool canOpenOnMac;
  final VoidCallback onBackWhenLoaded;
  final VoidCallback onBackWhenUnavailable;
  final Future<void> Function() onOpenGitBranchSheet;
  final Future<void> Function() onOpenGitSyncSheet;
  final Future<void> Function() onOpenOnMac;

  @override
  Widget build(BuildContext context) {
    if (state.thread == null) {
      return _UnavailableThreadDetailHeader(onBack: onBackWhenUnavailable);
    }

    return _LoadedThreadDetailHeader(
      state: state,
      accessMode: accessMode,
      hasPendingApprovals: hasPendingApprovals,
      gitControls: gitControls,
      canOpenOnMac: canOpenOnMac,
      onBack: onBackWhenLoaded,
      onOpenGitBranchSheet: onOpenGitBranchSheet,
      onOpenGitSyncSheet: onOpenGitSyncSheet,
      onOpenOnMac: onOpenOnMac,
    );
  }
}

class _LoadedThreadDetailHeader extends StatelessWidget {
  const _LoadedThreadDetailHeader({
    required this.state,
    required this.accessMode,
    required this.hasPendingApprovals,
    required this.gitControls,
    required this.canOpenOnMac,
    required this.onBack,
    required this.onOpenGitBranchSheet,
    required this.onOpenGitSyncSheet,
    required this.onOpenOnMac,
  });

  final ThreadDetailState state;
  final AccessMode accessMode;
  final bool hasPendingApprovals;
  final _ResolvedGitControls gitControls;
  final bool canOpenOnMac;
  final VoidCallback onBack;
  final Future<void> Function() onOpenGitBranchSheet;
  final Future<void> Function() onOpenGitSyncSheet;
  final Future<void> Function() onOpenOnMac;

  @override
  Widget build(BuildContext context) {
    final thread = state.thread!;
    final connectivityColor = state.isConnectivityUnavailable ? AppTheme.rose : AppTheme.emerald;
    final accessModePresentation = _accessModePresentation(accessMode);

    return Container(
      padding: const EdgeInsets.only(top: 0, right: 16, bottom: 8),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.white10)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: connectivityColor,
                        shape: BoxShape.circle,
                        boxShadow: [BoxShadow(color: connectivityColor, blurRadius: 10, spreadRadius: 2)],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      !state.isConnectivityUnavailable ? 'CONNECTED' : 'DISCONNECTED',
                      style: GoogleFonts.jetBrainsMono(
                        color: !state.isConnectivityUnavailable ? AppTheme.textSubtle : AppTheme.rose,
                        fontSize: 10,
                        letterSpacing: 1.0,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                Container(
                  key: const Key('thread-detail-access-mode-badge'),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      PhosphorIcon(
                        accessModePresentation.icon,
                        size: 12,
                        color: accessModePresentation.color,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        accessModePresentation.label,
                        key: const Key('thread-detail-access-mode-label'),
                        style: GoogleFonts.jetBrainsMono(
                          color: accessModePresentation.color,
                          fontSize: 10,
                          letterSpacing: 1.0,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Row(
            children: [
              IconButton(
                onPressed: onBack,
                icon: PhosphorIcon(
                  PhosphorIcons.caretLeft(PhosphorIconsStyle.bold),
                  size: 24,
                  color: AppTheme.textMuted,
                ),
              ),
              Expanded(
                child: Text(
                  thread.title,
                  key: const Key('thread-detail-title'),
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w500, letterSpacing: -0.5),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(left: 36),
            child: SingleChildScrollView(
              key: const Key('thread-detail-metadata-scroll'),
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  PhosphorIcon(PhosphorIcons.folderSimple(), size: 14, color: AppTheme.textSubtle),
                  const SizedBox(width: 6),
                  Text(
                    thread.repository,
                    style: GoogleFonts.jetBrainsMono(color: AppTheme.textSubtle, fontSize: 12),
                  ),
                  const SizedBox(width: 8),
                  const Text('•', style: TextStyle(color: AppTheme.textSubtle)),
                  const SizedBox(width: 8),
                  StatusBadge(
                    text: _threadStatusLabel(thread.status),
                    variant: thread.status == ThreadStatus.running
                        ? BadgeVariant.active
                        : BadgeVariant.defaultVariant,
                  ),
                  if (hasPendingApprovals) ...[
                    const SizedBox(width: 8),
                    const Text('•', style: TextStyle(color: AppTheme.textSubtle)),
                    const SizedBox(width: 8),
                    PhosphorIcon(PhosphorIcons.shieldWarning(), size: 14, color: AppTheme.amber),
                    const SizedBox(width: 6),
                    Text(
                      'Approvals Req.',
                      style: GoogleFonts.jetBrainsMono(color: AppTheme.amber, fontSize: 12),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.only(left: 36),
            child: Row(
              children: [
                Expanded(
                  flex: 3,
                  child: FilledButton.tonalIcon(
                    key: const Key('git-header-branch-button'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      backgroundColor: AppTheme.surfaceZinc800.withValues(alpha: 0.5),
                      foregroundColor: AppTheme.textMain,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                        side: BorderSide(color: Colors.white.withValues(alpha: 0.05)),
                      ),
                    ),
                    onPressed: () async {
                      await onOpenGitBranchSheet();
                    },
                    icon: PhosphorIcon(
                      PhosphorIcons.gitBranch(),
                      size: 16,
                      color: gitControls.hasDirtyWorkingTree ? AppTheme.amber : AppTheme.textSubtle,
                    ),
                    label: Text(
                      gitControls.repositoryContext.branch,
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
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      backgroundColor: AppTheme.surfaceZinc800.withValues(alpha: 0.5),
                      foregroundColor: AppTheme.textMain,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                        side: BorderSide(color: Colors.white.withValues(alpha: 0.05)),
                      ),
                    ),
                    onPressed: () async {
                      await onOpenGitSyncSheet();
                    },
                    icon: PhosphorIcon(PhosphorIcons.arrowsClockwise(), size: 16, color: AppTheme.textSubtle),
                    label: Text(
                      gitControls.syncLabel,
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
                    backgroundColor: AppTheme.surfaceZinc800.withValues(alpha: 0.5),
                    foregroundColor: AppTheme.textMain,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                      side: BorderSide(color: Colors.white.withValues(alpha: 0.05)),
                    ),
                  ),
                  onPressed: canOpenOnMac
                      ? () async {
                          await onOpenOnMac();
                        }
                      : null,
                  child: state.isOpenOnMacInFlight
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.textMain),
                        )
                      : PhosphorIcon(PhosphorIcons.monitor(), size: 18, color: AppTheme.textMain),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _UnavailableThreadDetailHeader extends StatelessWidget {
  const _UnavailableThreadDetailHeader({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.white10)),
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: onBack,
            icon: PhosphorIcon(
              PhosphorIcons.caretLeft(PhosphorIconsStyle.bold),
              size: 20,
              color: AppTheme.textMuted,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Session Details',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w500, letterSpacing: -0.5),
            ),
          ),
        ],
      ),
    );
  }
}

_AccessModePresentation _accessModePresentation(AccessMode accessMode) {
  switch (accessMode) {
    case AccessMode.readOnly:
      return _AccessModePresentation(
        label: 'Read Only',
        icon: PhosphorIcons.lock(),
        color: AppTheme.textSubtle,
      );
    case AccessMode.controlWithApprovals:
      return _AccessModePresentation(
        label: 'Gated Mode',
        icon: PhosphorIcons.shieldCheck(),
        color: AppTheme.amber,
      );
    case AccessMode.fullControl:
      return _AccessModePresentation(
        label: 'Full Control',
        icon: PhosphorIcons.lightning(),
        color: AppTheme.emerald,
      );
  }
}

class _AccessModePresentation {
  const _AccessModePresentation({required this.label, required this.icon, required this.color});

  final String label;
  final IconData icon;
  final Color color;
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
      return hasResolvedGitStatus ? 'Status unavailable' : 'Resolving git status';
    }
    final dirty = status!.dirty ? 'Dirty' : 'Clean';
    return 'Status: $dirty • Ahead ${status!.aheadBy} • Behind ${status!.behindBy}';
  }
}

class _GitBranchSheet extends StatelessWidget {
  const _GitBranchSheet({
    required this.gitControls,
    required this.gitBranchController,
    required this.onSwitchBranch,
  });

  final _ResolvedGitControls gitControls;
  final TextEditingController gitBranchController;
  final Future<bool> Function(String rawBranch) onSwitchBranch;

  @override
  Widget build(BuildContext context) {
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
              style: TextStyle(color: AppTheme.textMain, fontWeight: FontWeight.w600, fontSize: 18),
            ),
            const SizedBox(height: 16),
            Text(
              'Repository: ${gitControls.repositoryContext.repository}',
              style: const TextStyle(color: AppTheme.textMuted, fontSize: 13),
            ),
            const SizedBox(height: 4),
            Text(
              'Branch: ${gitControls.repositoryContext.branch}',
              style: const TextStyle(color: AppTheme.textMuted, fontSize: 13),
            ),
            const SizedBox(height: 4),
            Text(
              'Remote: ${gitControls.repositoryContext.remote}',
              style: const TextStyle(color: AppTheme.textMuted, fontSize: 13),
            ),
            const SizedBox(height: 4),
            Text(
              gitControls.statusLabel,
              style: TextStyle(
                color: gitControls.hasDirtyWorkingTree ? AppTheme.amber : AppTheme.textMuted,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('git-branch-input'),
                    controller: gitBranchController,
                    enabled: gitControls.canRunGitMutations,
                    style: const TextStyle(color: AppTheme.textMain, fontSize: 14),
                    decoration: InputDecoration(
                      hintText: 'Branch name...',
                      hintStyle: const TextStyle(color: AppTheme.textSubtle),
                      filled: true,
                      fillColor: Colors.black26,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  key: const Key('git-branch-switch-button'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.surfaceZinc800,
                    foregroundColor: AppTheme.textMain,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  ),
                  onPressed: gitControls.canRunGitMutations
                      ? () async {
                          final success = await onSwitchBranch(gitBranchController.text);
                          if (success) {
                            gitBranchController.clear();
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
              style: TextStyle(color: AppTheme.textMain, fontWeight: FontWeight.w600, fontSize: 18),
            ),
            const SizedBox(height: 16),
            Text(
              gitControls.statusLabel,
              style: TextStyle(
                color: gitControls.hasDirtyWorkingTree ? AppTheme.amber : AppTheme.textMuted,
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
                    icon: PhosphorIcon(PhosphorIcons.downloadSimple(), size: 16),
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
