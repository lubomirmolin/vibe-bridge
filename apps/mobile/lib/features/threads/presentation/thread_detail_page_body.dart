part of 'thread_detail_page.dart';

class _ThreadDetailBody extends StatelessWidget {
  const _ThreadDetailBody({
    required this.state,
    required this.isReadOnlyMode,
    required this.controlsEnabled,
    required this.onInterruptActiveTurn,
    required this.desktopIntegrationEnabled,
    required this.onRetry,
    required this.onRetryReconnect,
    required this.threadApprovals,
    required this.approvalsErrorMessage,
    required this.canResolveApprovals,
    required this.gitErrorMessage,
    required this.gitMutationMessage,
    required this.gitControlsUnavailableReason,
    required this.openOnMacMessage,
    required this.openOnMacErrorMessage,
    required this.hasPinnedComposer,
    required this.onRefreshApprovals,
    required this.onTimelineUserScroll,
    required this.scrollController,
    required this.isTimelineCardExpanded,
    required this.onTimelineCardExpansionChanged,
  });

  final ThreadDetailState state;
  final bool isReadOnlyMode;
  final bool controlsEnabled;
  final Future<bool> Function() onInterruptActiveTurn;
  final bool desktopIntegrationEnabled;
  final Future<void> Function() onRetry;
  final Future<void> Function() onRetryReconnect;
  final List<ApprovalItemState> threadApprovals;
  final String? approvalsErrorMessage;
  final bool canResolveApprovals;
  final String? gitErrorMessage;
  final String? gitMutationMessage;
  final String? gitControlsUnavailableReason;
  final String? openOnMacMessage;
  final String? openOnMacErrorMessage;
  final bool hasPinnedComposer;
  final VoidCallback onRefreshApprovals;
  final ValueChanged<ScrollDirection> onTimelineUserScroll;
  final ScrollController scrollController;
  final bool Function(String id, {required bool defaultValue})
  isTimelineCardExpanded;
  final void Function(String id, bool isExpanded)
  onTimelineCardExpansionChanged;

  @override
  Widget build(BuildContext context) {
    final gitControlsUnavailableReason = this.gitControlsUnavailableReason;
    final gitErrorMessage = this.gitErrorMessage;
    final gitMutationMessage = this.gitMutationMessage;
    final openOnMacMessage = this.openOnMacMessage;
    final openOnMacErrorMessage = this.openOnMacErrorMessage;

    if (state.isLoading && !state.hasThread) {
      return const Center(
        child: CircularProgressIndicator(color: AppTheme.emerald),
      );
    }

    if (state.hasError && !state.hasThread) {
      return _ThreadDetailErrorState(
        isUnavailable: state.isUnavailable,
        message: state.errorMessage ?? 'Couldn\'t load',
        onRetry: onRetry,
      );
    }

    final thread = state.thread;
    if (thread == null) {
      return _ThreadDetailErrorState(
        isUnavailable: true,
        message: 'Thread unavailable',
        onRetry: onRetry,
      );
    }

    final timelineBlocks = buildThreadTimelineBlocks(state.visibleItems);
    final leadingChildren = _buildLeadingChildren(
      state: state,
      controlsEnabled: controlsEnabled,
      isReadOnlyMode: isReadOnlyMode,
      desktopIntegrationEnabled: desktopIntegrationEnabled,
      gitControlsUnavailableReason: gitControlsUnavailableReason,
      gitErrorMessage: gitErrorMessage,
      gitMutationMessage: gitMutationMessage,
      openOnMacMessage: openOnMacMessage,
      openOnMacErrorMessage: openOnMacErrorMessage,
    );
    final trailingChildren = _buildTrailingChildren(
      state: state,
      controlsEnabled: controlsEnabled,
    );
    final timelineItemCount =
        state.isInitialTimelineLoading || state.visibleItems.isEmpty
        ? 1
        : timelineBlocks.length * 2;
    final itemCount =
        leadingChildren.length + timelineItemCount + trailingChildren.length;

    return RefreshIndicator(
      color: AppTheme.emerald,
      backgroundColor: AppTheme.surfaceZinc800,
      onRefresh: onRetry,
      child: NotificationListener<UserScrollNotification>(
        onNotification: (notification) {
          if (notification.direction != ScrollDirection.idle) {
            onTimelineUserScroll(notification.direction);
          }
          return false;
        },
        child: ListView.builder(
          controller: scrollController,
          key: const Key('thread-detail-scroll-view'),
          cacheExtent: 1400,
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          padding: EdgeInsets.only(
            left: 24,
            right: 24,
            bottom: hasPinnedComposer ? 140 : 16,
            top: 212,
          ),
          itemCount: itemCount,
          itemBuilder: (context, index) {
            Widget child;
            if (index < leadingChildren.length) {
              child = leadingChildren[index];
            } else if (index < leadingChildren.length + timelineItemCount) {
              child = _buildTimelineChild(
                state: state,
                timelineBlocks: timelineBlocks,
                timelineIndex: index - leadingChildren.length,
              );
            } else {
              child =
                  trailingChildren[index -
                      leadingChildren.length -
                      timelineItemCount];
            }

            return Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: _ThreadDetailPageState._sessionContentMaxWidth,
                ),
                child: SizedBox(
                  key: index == 0
                      ? const Key('thread-detail-session-content')
                      : null,
                  width: double.infinity,
                  child: child,
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  List<Widget> _buildLeadingChildren({
    required ThreadDetailState state,
    required bool controlsEnabled,
    required bool isReadOnlyMode,
    required bool desktopIntegrationEnabled,
    required String? gitControlsUnavailableReason,
    required String? gitErrorMessage,
    required String? gitMutationMessage,
    required String? openOnMacMessage,
    required String? openOnMacErrorMessage,
  }) {
    return <Widget>[
      const SizedBox(height: 16),
      if (!controlsEnabled) ...[
        const SizedBox(height: 12),
        _MutatingActionsBlockedNotice(
          message: isReadOnlyMode
              ? 'Read-only mode blocks turn and git mutations.'
              : 'Mutating actions are blocked while bridge is offline.',
          onRetryReconnect: isReadOnlyMode ? null : onRetryReconnect,
        ),
      ],
      if (state.turnControlErrorMessage != null) ...[
        const SizedBox(height: 12),
        _InlineWarning(message: state.turnControlErrorMessage!),
      ],
      if (gitControlsUnavailableReason != null) ...[
        const SizedBox(height: 12),
        KeyedSubtree(
          key: const Key('git-controls-unavailable-message'),
          child: _InlineWarning(message: gitControlsUnavailableReason),
        ),
      ],
      if (gitErrorMessage != null) ...[
        const SizedBox(height: 12),
        _InlineWarning(message: gitErrorMessage),
      ],
      if (gitMutationMessage != null) ...[
        const SizedBox(height: 12),
        _InlineInfo(message: gitMutationMessage),
      ],
      if (!desktopIntegrationEnabled) ...[
        const SizedBox(height: 12),
        const KeyedSubtree(
          key: Key('desktop-integration-disabled-message'),
          child: _InlineWarning(
            message: 'Desktop integration is disabled in settings.',
          ),
        ),
      ],
      if (openOnMacMessage != null) ...[
        const SizedBox(height: 12),
        KeyedSubtree(
          key: const Key('open-on-mac-success-message'),
          child: _InlineInfo(message: openOnMacMessage),
        ),
      ],
      if (openOnMacErrorMessage != null) ...[
        const SizedBox(height: 12),
        KeyedSubtree(
          key: const Key('open-on-mac-error-message'),
          child: _InlineWarning(message: openOnMacErrorMessage),
        ),
      ],
      if (threadApprovals.isNotEmpty || approvalsErrorMessage != null) ...[
        const SizedBox(height: 16),
        _ThreadApprovalsCard(
          approvals: threadApprovals,
          canResolveApprovals: canResolveApprovals,
          errorMessage: approvalsErrorMessage,
          onRefresh: onRefreshApprovals,
        ),
      ],
      const SizedBox(height: 32),
      const Text(
        'Timeline',
        style: TextStyle(
          color: AppTheme.textSubtle,
          fontSize: 13,
          letterSpacing: 1.2,
        ),
      ),
      const SizedBox(height: 16),
      if (state.isLoadingEarlierHistory) ...[
        const _InlineInfo(message: 'Loading older history…'),
        const SizedBox(height: 12),
      ],
    ];
  }

  Widget _buildTimelineChild({
    required ThreadDetailState state,
    required List<ThreadTimelineBlock> timelineBlocks,
    required int timelineIndex,
  }) {
    if (state.isInitialTimelineLoading) {
      return const _TimelineLoadingState();
    }
    if (state.visibleItems.isEmpty) {
      return const _EmptyTimelineState();
    }
    if (timelineIndex.isOdd) {
      return const SizedBox(height: 12);
    }

    final block = timelineBlocks[timelineIndex ~/ 2];
    return KeyedSubtree(
      key: ValueKey(_timelineBlockKey(block)),
      child: _ThreadTimelineBlockView(
        block: block,
        isTimelineCardExpanded: isTimelineCardExpanded,
        onTimelineCardExpansionChanged: onTimelineCardExpansionChanged,
      ),
    );
  }

  List<Widget> _buildTrailingChildren({
    required ThreadDetailState state,
    required bool controlsEnabled,
  }) {
    return <Widget>[
      if (!state.isInitialTimelineLoading && state.visibleItems.isNotEmpty)
        const SizedBox(height: 12),
      if (state.isTurnActive) ...[
        _ChatLoadingMessageCard(
          phaseLabel: _runningTurnPhaseLabel(state.visibleItems),
          controlsEnabled: controlsEnabled,
          isInterruptMutationInFlight: state.isInterruptMutationInFlight,
          onInterruptActiveTurn: onInterruptActiveTurn,
        ),
        const SizedBox(height: 12),
      ],
    ];
  }

  String _timelineBlockKey(ThreadTimelineBlock block) {
    final item = block.item;
    if (item != null) {
      return 'activity:${item.eventId}';
    }

    final exploration = block.exploration;
    if (exploration != null) {
      return 'exploration:${exploration.sourceEventIds.join("|")}';
    }

    final workSummary = block.workSummary;
    if (workSummary != null) {
      return 'work-summary:${workSummary.anchorEventId}';
    }

    return 'timeline-block';
  }
}

class _ThreadTimelineBlockView extends StatelessWidget {
  const _ThreadTimelineBlockView({
    required this.block,
    required this.isTimelineCardExpanded,
    required this.onTimelineCardExpansionChanged,
  });

  final ThreadTimelineBlock block;
  final bool Function(String id, {required bool defaultValue})
  isTimelineCardExpanded;
  final void Function(String id, bool isExpanded)
  onTimelineCardExpansionChanged;

  @override
  Widget build(BuildContext context) {
    if (block.workSummary != null) {
      return _WorkSummaryCard(
        summary: block.workSummary!,
        isTimelineCardExpanded: isTimelineCardExpanded,
        onTimelineCardExpansionChanged: onTimelineCardExpansionChanged,
      );
    }

    if (block.item != null) {
      return _ThreadActivityCard(
        item: block.item!,
        exploration: block.exploration,
        isTimelineCardExpanded: isTimelineCardExpanded,
        onTimelineCardExpansionChanged: onTimelineCardExpansionChanged,
      );
    }

    return _ExploredFilesCard(
      exploration: block.exploration!,
      isExpanded: isTimelineCardExpanded(
        _explorationExpansionId(block.exploration!),
        defaultValue: true,
      ),
      onExpansionChanged: (isExpanded) => onTimelineCardExpansionChanged(
        _explorationExpansionId(block.exploration!),
        isExpanded,
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
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            PhosphorIcon(
              isUnavailable ? PhosphorIcons.database() : PhosphorIcons.wifiX(),
              size: 48,
              color: AppTheme.rose,
            ),
            const SizedBox(height: 16),
            Text(
              isUnavailable ? 'Unavailable' : 'Couldn\'t load',
              style: const TextStyle(
                color: AppTheme.textMain,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppTheme.textMuted),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.surfaceZinc800,
                foregroundColor: AppTheme.textMain,
              ),
              onPressed: onRetry,
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ThreadApprovalsCard extends StatelessWidget {
  const _ThreadApprovalsCard({
    required this.approvals,
    required this.canResolveApprovals,
    required this.errorMessage,
    required this.onRefresh,
  });

  final List<ApprovalItemState> approvals;
  final bool canResolveApprovals;
  final String? errorMessage;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppTheme.amber.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppTheme.amber.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              PhosphorIcon(
                PhosphorIcons.shieldWarning(),
                color: AppTheme.amber,
                size: 20,
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Pending Approvals',
                  style: TextStyle(
                    color: AppTheme.amber,
                    fontWeight: FontWeight.w600,
                    fontSize: 16,
                  ),
                ),
              ),
              IconButton(
                onPressed: onRefresh,
                icon: PhosphorIcon(
                  PhosphorIcons.arrowsClockwise(),
                  color: AppTheme.amber,
                  size: 20,
                ),
              ),
            ],
          ),
          if (errorMessage != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                errorMessage!,
                style: const TextStyle(color: AppTheme.rose, fontSize: 13),
              ),
            ),
          const SizedBox(height: 12),
          ...approvals.map(
            (item) => Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black26,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        approvalActionLabel(item.approval.action),
                        style: const TextStyle(
                          color: AppTheme.textMain,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      Text(
                        approvalStatusLabel(item.approval.status),
                        key: Key(
                          'thread-approval-status-${item.approval.approvalId}',
                        ),
                        style: GoogleFonts.jetBrainsMono(
                          color: AppTheme.textSubtle,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    item.approval.reason,
                    style: const TextStyle(
                      color: AppTheme.textMuted,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TimelineLoadingState extends StatelessWidget {
  const _TimelineLoadingState();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      key: Key('thread-detail-timeline-loading-state'),
      padding: EdgeInsets.symmetric(vertical: 40),
      child: Center(
        child: Column(
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: AppTheme.emerald,
              ),
            ),
            SizedBox(height: 16),
            Text(
              'Loading timeline…',
              style: TextStyle(color: AppTheme.textMuted),
            ),
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
      padding: EdgeInsets.symmetric(vertical: 40),
      child: Center(
        child: Column(
          children: [
            Icon(Icons.history_rounded, size: 32, color: AppTheme.textSubtle),
            SizedBox(height: 16),
            Text(
              'No timeline entries yet.',
              style: TextStyle(color: AppTheme.textMuted),
            ),
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
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.rose.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.rose.withValues(alpha: 0.3)),
      ),
      child: Text(
        message,
        style: const TextStyle(color: AppTheme.rose, fontSize: 13),
      ),
    );
  }
}

class _InlineInfo extends StatelessWidget {
  const _InlineInfo({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.emerald.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.emerald.withValues(alpha: 0.3)),
      ),
      child: Text(
        message,
        style: const TextStyle(color: AppTheme.emerald, fontSize: 13),
      ),
    );
  }
}

class _MutatingActionsBlockedNotice extends StatelessWidget {
  const _MutatingActionsBlockedNotice({
    required this.message,
    required this.onRetryReconnect,
  });

  final String message;
  final Future<void> Function()? onRetryReconnect;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.surfaceZinc800,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            message,
            style: const TextStyle(color: AppTheme.textMuted, fontSize: 13),
          ),
          if (onRetryReconnect != null) ...[
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: onRetryReconnect,
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Colors.white12),
              ),
              child: const Text(
                'Retry reconnect',
                style: TextStyle(color: AppTheme.textMain),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
