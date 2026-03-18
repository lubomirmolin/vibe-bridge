import 'package:codex_mobile_companion/features/approvals/application/approvals_queue_controller.dart';
import 'package:codex_mobile_companion/features/approvals/presentation/approval_presenter.dart';
import 'package:codex_mobile_companion/features/settings/application/notification_preferences_controller.dart';
import 'package:codex_mobile_companion/features/settings/application/runtime_access_mode.dart';
import 'package:codex_mobile_companion/features/settings/presentation/settings_page.dart';
import 'package:codex_mobile_companion/features/threads/application/thread_detail_controller.dart';
import 'package:codex_mobile_companion/features/threads/domain/thread_activity_item.dart';
import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ThreadDetailPage extends ConsumerStatefulWidget {
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
  ConsumerState<ThreadDetailPage> createState() => _ThreadDetailPageState();
}

class _ThreadDetailPageState extends ConsumerState<ThreadDetailPage> {
  late final TextEditingController _composerController;
  late final TextEditingController _gitBranchController;

  @override
  void initState() {
    super.initState();
    _composerController = TextEditingController();
    _gitBranchController = TextEditingController();
  }

  @override
  void dispose() {
    _composerController.dispose();
    _gitBranchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final args = ThreadDetailControllerArgs(
      bridgeApiBaseUrl: widget.bridgeApiBaseUrl,
      threadId: widget.threadId,
      initialVisibleTimelineEntries: widget.initialVisibleTimelineEntries,
    );
    final state = ref.watch(threadDetailControllerProvider(args));
    final controller = ref.read(threadDetailControllerProvider(args).notifier);
    final approvalsState = ref.watch(
      approvalsQueueControllerProvider(widget.bridgeApiBaseUrl),
    );
    final runtimeAccessMode = ref.watch(
      runtimeAccessModeProvider(widget.bridgeApiBaseUrl),
    );
    final notificationPreferences = ref.watch(
      notificationPreferencesControllerProvider,
    );

    final approvalsController = ref.read(
      approvalsQueueControllerProvider(widget.bridgeApiBaseUrl).notifier,
    );

    final effectiveAccessMode =
        runtimeAccessMode ??
        state.thread?.accessMode ??
        AccessMode.controlWithApprovals;
    final isReadOnlyMode = effectiveAccessMode == AccessMode.readOnly;
    final controlsEnabled = state.canRunMutatingActions && !isReadOnlyMode;
    final desktopIntegrationControlsEnabled = state.canRunMutatingActions;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Thread detail'),
        actions: [
          IconButton(
            key: const Key('open-device-settings-from-thread-detail'),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (context) =>
                      SettingsPage(bridgeApiBaseUrl: widget.bridgeApiBaseUrl),
                ),
              );
            },
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Open device settings',
          ),
        ],
      ),
      body: SafeArea(
        child: _buildBody(
          context,
          state: state,
          accessMode: effectiveAccessMode,
          controlsEnabled: controlsEnabled,
          desktopIntegrationControlsEnabled: desktopIntegrationControlsEnabled,
          desktopIntegrationEnabled:
              notificationPreferences.desktopIntegrationEnabled,
          showLiveNotificationSuppressedBanner:
              !notificationPreferences.liveActivityNotificationsEnabled,
          onRetry: controller.loadThread,
          onLoadEarlier: controller.loadEarlierHistory,
          onRetryReconnect: controller.retryReconnectCatchUp,
          onOpenOnMac: controller.openOnMac,
          composerController: _composerController,
          gitBranchController: _gitBranchController,
          onSubmitComposer: controller.submitComposerInput,
          onInterruptActiveTurn: controller.interruptActiveTurn,
          onRefreshGitStatus: controller.refreshGitStatus,
          onSwitchBranch: (rawBranch) async {
            final accepted = await controller.switchBranch(rawBranch);
            await approvalsController.loadApprovals(showLoading: false);
            return accepted;
          },
          onPullRepository: () async {
            final accepted = await controller.pullRepository();
            await approvalsController.loadApprovals(showLoading: false);
            return accepted;
          },
          onPushRepository: () async {
            final accepted = await controller.pushRepository();
            await approvalsController.loadApprovals(showLoading: false);
            return accepted;
          },
          threadApprovals: approvalsState.forThread(widget.threadId),
          approvalsErrorMessage: approvalsState.errorMessage,
          canResolveApprovals: approvalsState.canResolveApprovals,
          gitStatus: state.gitStatus,
          isGitStatusLoading: state.isGitStatusLoading,
          isGitMutationInFlight: state.isGitMutationInFlight,
          gitErrorMessage: state.gitErrorMessage,
          gitMutationMessage: state.gitMutationMessage,
          gitControlsUnavailableReason: state.gitControlsUnavailableReason,
          isOpenOnMacInFlight: state.isOpenOnMacInFlight,
          openOnMacMessage: state.openOnMacMessage,
          openOnMacErrorMessage: state.openOnMacErrorMessage,
          onRefreshApprovals: () {
            approvalsController.loadApprovals(showLoading: false);
          },
        ),
      ),
    );
  }
}

Widget _buildBody(
  BuildContext context, {
  required ThreadDetailState state,
  required AccessMode accessMode,
  required bool controlsEnabled,
  required bool desktopIntegrationControlsEnabled,
  required bool desktopIntegrationEnabled,
  required bool showLiveNotificationSuppressedBanner,
  required Future<void> Function() onRetry,
  required VoidCallback onLoadEarlier,
  required Future<void> Function() onRetryReconnect,
  required Future<bool> Function() onOpenOnMac,
  required TextEditingController composerController,
  required TextEditingController gitBranchController,
  required Future<bool> Function(String rawInput) onSubmitComposer,
  required Future<bool> Function() onInterruptActiveTurn,
  required Future<void> Function({bool showLoading}) onRefreshGitStatus,
  required Future<bool> Function(String rawBranch) onSwitchBranch,
  required Future<bool> Function() onPullRepository,
  required Future<bool> Function() onPushRepository,
  required List<ApprovalItemState> threadApprovals,
  required String? approvalsErrorMessage,
  required bool canResolveApprovals,
  required GitStatusResponseDto? gitStatus,
  required bool isGitStatusLoading,
  required bool isGitMutationInFlight,
  required String? gitErrorMessage,
  required String? gitMutationMessage,
  required String? gitControlsUnavailableReason,
  required bool isOpenOnMacInFlight,
  required String? openOnMacMessage,
  required String? openOnMacErrorMessage,
  required VoidCallback onRefreshApprovals,
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

  final isReadOnlyMode = accessMode == AccessMode.readOnly;

  return RefreshIndicator(
    onRefresh: onRetry,
    child: ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        _ThreadDetailHeader(thread: thread),
        const SizedBox(height: 12),
        _AccessModeBanner(accessMode: accessMode),
        if (state.staleMessage != null) ...[
          const SizedBox(height: 12),
          _InlineWarning(message: state.staleMessage!),
        ],
        if (!controlsEnabled) ...[
          const SizedBox(height: 12),
          _MutatingActionsBlockedNotice(
            message: isReadOnlyMode
                ? 'Read-only mode blocks turn and git mutations. Change access mode in settings to continue.'
                : 'Mutating actions are blocked while the bridge or private route is unavailable.',
            onRetryReconnect: isReadOnlyMode ? null : onRetryReconnect,
          ),
        ],
        if (showLiveNotificationSuppressedBanner) ...[
          const SizedBox(height: 12),
          const _InlineInfo(
            message:
                'Live activity notifications are disabled in settings. In-app thread updates continue normally.',
          ),
        ],
        if (state.streamErrorMessage != null) ...[
          const SizedBox(height: 12),
          _InlineWarning(message: state.streamErrorMessage!),
        ],
        const SizedBox(height: 12),
        _TurnControlsCard(
          composerController: composerController,
          isTurnActive: state.isTurnActive,
          controlsEnabled: controlsEnabled,
          isReadOnlyMode: isReadOnlyMode,
          isComposerMutationInFlight: state.isComposerMutationInFlight,
          isInterruptMutationInFlight: state.isInterruptMutationInFlight,
          onSubmitComposer: onSubmitComposer,
          onInterruptActiveTurn: onInterruptActiveTurn,
        ),
        if (state.turnControlErrorMessage != null) ...[
          const SizedBox(height: 12),
          _InlineWarning(message: state.turnControlErrorMessage!),
        ],
        const SizedBox(height: 12),
        _GitControlsCard(
          thread: thread,
          gitStatus: gitStatus,
          gitBranchController: gitBranchController,
          controlsEnabled: controlsEnabled,
          isReadOnlyMode: isReadOnlyMode,
          isGitStatusLoading: isGitStatusLoading,
          isGitMutationInFlight: isGitMutationInFlight,
          gitErrorMessage: gitErrorMessage,
          gitMutationMessage: gitMutationMessage,
          gitControlsUnavailableReason: gitControlsUnavailableReason,
          onRefreshGitStatus: onRefreshGitStatus,
          onSwitchBranch: onSwitchBranch,
          onPullRepository: onPullRepository,
          onPushRepository: onPushRepository,
        ),
        const SizedBox(height: 12),
        _ThreadApprovalsCard(
          approvals: threadApprovals,
          canResolveApprovals: canResolveApprovals,
          errorMessage: approvalsErrorMessage,
          onRefresh: onRefreshApprovals,
        ),
        const SizedBox(height: 12),
        _DesktopIntegrationCard(
          desktopIntegrationEnabled: desktopIntegrationEnabled,
          openOnMacEnabled: desktopIntegrationControlsEnabled,
          isOpeningOnMac: isOpenOnMacInFlight,
          openOnMacMessage: openOnMacMessage,
          openOnMacErrorMessage: openOnMacErrorMessage,
          onOpenOnMac: onOpenOnMac,
        ),
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

class _DesktopIntegrationCard extends StatelessWidget {
  const _DesktopIntegrationCard({
    required this.desktopIntegrationEnabled,
    required this.openOnMacEnabled,
    required this.isOpeningOnMac,
    required this.openOnMacMessage,
    required this.openOnMacErrorMessage,
    required this.onOpenOnMac,
  });

  final bool desktopIntegrationEnabled;
  final bool openOnMacEnabled;
  final bool isOpeningOnMac;
  final String? openOnMacMessage;
  final String? openOnMacErrorMessage;
  final Future<bool> Function() onOpenOnMac;

  @override
  Widget build(BuildContext context) {
    final canOpenOnMac =
        desktopIntegrationEnabled && openOnMacEnabled && !isOpeningOnMac;

    return Card(
      key: const Key('desktop-integration-card'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Desktop integration',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            const Text(
              'Open this thread in Codex.app on Mac. This is best effort: desktop live-refresh may lag, while mobile stays fully usable.',
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const Key('open-on-mac-button'),
              onPressed: canOpenOnMac
                  ? () async {
                      await onOpenOnMac();
                    }
                  : null,
              icon: isOpeningOnMac
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.desktop_windows_outlined),
              label: const Text('Open on Mac'),
            ),
            if (!desktopIntegrationEnabled) ...[
              const SizedBox(height: 8),
              Text(
                'Desktop integration is disabled in settings. Re-enable it to use Open on Mac.',
                key: const Key('desktop-integration-disabled-message'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            if (openOnMacMessage != null) ...[
              const SizedBox(height: 8),
              _InlineInfo(
                key: const Key('open-on-mac-success-message'),
                message: openOnMacMessage!,
              ),
            ],
            if (openOnMacErrorMessage != null) ...[
              const SizedBox(height: 8),
              _InlineWarning(
                key: const Key('open-on-mac-error-message'),
                message: openOnMacErrorMessage!,
              ),
            ],
          ],
        ),
      ),
    );
  }
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

class _AccessModeBanner extends StatelessWidget {
  const _AccessModeBanner({required this.accessMode});

  final AccessMode accessMode;

  @override
  Widget build(BuildContext context) {
    final label = switch (accessMode) {
      AccessMode.readOnly =>
        'Read-only mode: viewing is allowed, but turn and git mutations are blocked.',
      AccessMode.controlWithApprovals =>
        'Control-with-approvals mode: turn controls are enabled and dangerous actions are approval-gated.',
      AccessMode.fullControl =>
        'Full-control mode: turn, approval resolution, and git controls are fully actionable.',
    };

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Text(label),
    );
  }
}

class _TurnControlsCard extends StatelessWidget {
  const _TurnControlsCard({
    required this.composerController,
    required this.isTurnActive,
    required this.controlsEnabled,
    required this.isReadOnlyMode,
    required this.isComposerMutationInFlight,
    required this.isInterruptMutationInFlight,
    required this.onSubmitComposer,
    required this.onInterruptActiveTurn,
  });

  final TextEditingController composerController;
  final bool isTurnActive;
  final bool controlsEnabled;
  final bool isReadOnlyMode;
  final bool isComposerMutationInFlight;
  final bool isInterruptMutationInFlight;
  final Future<bool> Function(String rawInput) onSubmitComposer;
  final Future<bool> Function() onInterruptActiveTurn;

  @override
  Widget build(BuildContext context) {
    final canSubmitComposer =
        controlsEnabled &&
        !isComposerMutationInFlight &&
        !isInterruptMutationInFlight;
    final canInterrupt =
        controlsEnabled &&
        isTurnActive &&
        !isInterruptMutationInFlight &&
        !isComposerMutationInFlight;

    final composerLabel = isTurnActive ? 'Steer turn' : 'Start turn';
    final helperMessage = isReadOnlyMode
        ? 'Read-only mode is active. Turn start, steer, and interrupt are blocked.'
        : isTurnActive
        ? 'Thread is active. Steer the current turn or interrupt it.'
        : 'Thread is idle. Start a new turn from this composer.';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              helperMessage,
              key: const Key('turn-control-mode-message'),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('turn-composer-input'),
              controller: composerController,
              enabled: canSubmitComposer,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.newline,
              decoration: InputDecoration(
                labelText: isTurnActive ? 'Steering instruction' : 'Prompt',
                hintText: isTurnActive
                    ? 'Guide the running turn...'
                    : 'Describe what to do next...',
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    key: const Key('turn-composer-submit'),
                    onPressed: canSubmitComposer
                        ? () async {
                            final success = await onSubmitComposer(
                              composerController.text,
                            );
                            if (success) {
                              composerController.clear();
                            }
                          }
                        : null,
                    icon: isComposerMutationInFlight
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            isTurnActive
                                ? Icons.alt_route_rounded
                                : Icons.play_arrow_rounded,
                          ),
                    label: Text(composerLabel),
                  ),
                ),
                if (isTurnActive) ...[
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    key: const Key('turn-interrupt-button'),
                    onPressed: canInterrupt
                        ? () async {
                            await onInterruptActiveTurn();
                          }
                        : null,
                    icon: isInterruptMutationInFlight
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.stop_circle_outlined),
                    label: const Text('Interrupt'),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _GitControlsCard extends StatelessWidget {
  const _GitControlsCard({
    required this.thread,
    required this.gitStatus,
    required this.gitBranchController,
    required this.controlsEnabled,
    required this.isReadOnlyMode,
    required this.isGitStatusLoading,
    required this.isGitMutationInFlight,
    required this.gitErrorMessage,
    required this.gitMutationMessage,
    required this.gitControlsUnavailableReason,
    required this.onRefreshGitStatus,
    required this.onSwitchBranch,
    required this.onPullRepository,
    required this.onPushRepository,
  });

  final ThreadDetailDto thread;
  final GitStatusResponseDto? gitStatus;
  final TextEditingController gitBranchController;
  final bool controlsEnabled;
  final bool isReadOnlyMode;
  final bool isGitStatusLoading;
  final bool isGitMutationInFlight;
  final String? gitErrorMessage;
  final String? gitMutationMessage;
  final String? gitControlsUnavailableReason;
  final Future<void> Function({bool showLoading}) onRefreshGitStatus;
  final Future<bool> Function(String rawBranch) onSwitchBranch;
  final Future<bool> Function() onPullRepository;
  final Future<bool> Function() onPushRepository;

  @override
  Widget build(BuildContext context) {
    final repositoryContext =
        gitStatus?.repository ??
        RepositoryContextDto(
          workspace: thread.workspace,
          repository: thread.repository,
          branch: thread.branch,
          remote: 'unknown',
        );
    final status = gitStatus?.status;
    final hasResolvedGitStatus = gitStatus != null;
    final hasRepositoryContext =
        hasResolvedGitStatus && _hasRepositoryContext(repositoryContext);
    final canRunGitMutations =
        controlsEnabled &&
        hasResolvedGitStatus &&
        hasRepositoryContext &&
        !isGitStatusLoading &&
        !isGitMutationInFlight;

    final unavailableMessage = isReadOnlyMode
        ? 'Read-only mode blocks git mutations. Change access mode in settings to continue.'
        : !controlsEnabled
        ? 'Git controls are unavailable while the bridge is offline.'
        : !hasResolvedGitStatus
        ? 'Git mutations stay disabled until git status resolves.'
        : gitControlsUnavailableReason ??
              (hasRepositoryContext
                  ? null
                  : 'Git controls are unavailable because this thread has no repository context.');

    return Card(
      key: const Key('git-controls-card'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Git controls',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                IconButton(
                  key: const Key('git-refresh-status'),
                  onPressed: isGitMutationInFlight
                      ? null
                      : () async {
                          await onRefreshGitStatus(showLoading: true);
                        },
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Refresh git status',
                ),
              ],
            ),
            if (isGitStatusLoading) ...[
              const SizedBox(height: 6),
              const LinearProgressIndicator(),
            ],
            const SizedBox(height: 8),
            Text(
              'Repository: ${repositoryContext.repository}',
              key: const Key('git-context-repository'),
            ),
            const SizedBox(height: 2),
            Text(
              'Branch: ${repositoryContext.branch}',
              key: const Key('git-context-branch'),
            ),
            const SizedBox(height: 2),
            Text(
              'Remote: ${repositoryContext.remote}',
              key: const Key('git-context-remote'),
            ),
            const SizedBox(height: 2),
            Text(
              'Workspace: ${repositoryContext.workspace}',
              key: const Key('git-context-workspace'),
            ),
            const SizedBox(height: 8),
            Text(
              status == null
                  ? 'Status unavailable'
                  : 'Status: ${status.dirty ? 'Dirty' : 'Clean'} • Ahead ${status.aheadBy} • Behind ${status.behindBy}',
              key: const Key('git-status-summary'),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('git-branch-input'),
              controller: gitBranchController,
              enabled: canRunGitMutations,
              decoration: const InputDecoration(
                labelText: 'Switch branch',
                hintText: 'feature/my-branch',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    key: const Key('git-branch-switch-button'),
                    onPressed: canRunGitMutations
                        ? () async {
                            final success = await onSwitchBranch(
                              gitBranchController.text,
                            );
                            if (success) {
                              gitBranchController.clear();
                            }
                          }
                        : null,
                    icon: isGitMutationInFlight
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.swap_horiz_rounded),
                    label: const Text('Switch branch'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('git-pull-button'),
                    onPressed: canRunGitMutations
                        ? () async {
                            await onPullRepository();
                          }
                        : null,
                    icon: const Icon(Icons.download_rounded),
                    label: const Text('Pull'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('git-push-button'),
                    onPressed: canRunGitMutations
                        ? () async {
                            await onPushRepository();
                          }
                        : null,
                    icon: const Icon(Icons.upload_rounded),
                    label: const Text('Push'),
                  ),
                ),
              ],
            ),
            if (unavailableMessage != null) ...[
              const SizedBox(height: 8),
              Text(
                unavailableMessage,
                key: const Key('git-controls-unavailable-message'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            if (gitErrorMessage != null) ...[
              const SizedBox(height: 8),
              _InlineWarning(message: gitErrorMessage!),
            ],
            if (gitMutationMessage != null) ...[
              const SizedBox(height: 8),
              _InlineInfo(message: gitMutationMessage!),
            ],
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
                    'Approvals in this thread',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                IconButton(
                  key: const Key('refresh-thread-approvals'),
                  onPressed: onRefresh,
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Refresh approvals',
                ),
              ],
            ),
            Text(
              canResolveApprovals
                  ? 'Full-control mode: pending approvals are actionable from mobile.'
                  : 'Lower-permission mode: approvals are visible but non-actionable from mobile.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (errorMessage != null) ...[
              const SizedBox(height: 8),
              Text(
                errorMessage!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 8),
            if (approvals.isEmpty)
              const Text('No approvals currently linked to this thread.')
            else
              ...approvals.map(
                (item) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainer,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                approvalActionLabel(item.approval.action),
                              ),
                            ),
                            Text(
                              approvalStatusLabel(item.approval.status),
                              key: Key(
                                'thread-approval-status-${item.approval.approvalId}',
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(item.approval.reason),
                        if (item.nonActionableReason != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            item.nonActionableReason!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
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
  const _InlineWarning({super.key, required this.message});

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

class _InlineInfo extends StatelessWidget {
  const _InlineInfo({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colorScheme.primary),
      ),
      child: Text(message),
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
          Text(message),
          if (onRetryReconnect != null) ...[
            const SizedBox(height: 8),
            OutlinedButton(
              key: const Key('retry-reconnect-catchup'),
              onPressed: onRetryReconnect,
              child: const Text('Retry reconnect'),
            ),
          ],
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

bool _hasRepositoryContext(RepositoryContextDto context) {
  final repository = context.repository.trim().toLowerCase();
  final branch = context.branch.trim().toLowerCase();

  if (repository.isEmpty ||
      repository == 'unknown' ||
      repository == 'unknown-repository') {
    return false;
  }

  if (branch.isEmpty || branch == 'unknown') {
    return false;
  }

  return true;
}
