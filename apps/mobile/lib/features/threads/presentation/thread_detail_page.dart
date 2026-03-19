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
import 'package:codex_mobile_companion/foundation/theme/app_theme.dart';
import 'package:codex_mobile_companion/foundation/theme/liquid_styles.dart';
import 'package:codex_mobile_companion/shared/widgets/badges.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:google_fonts/google_fonts.dart';

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
    final approvalsState = ref.watch(approvalsQueueControllerProvider(widget.bridgeApiBaseUrl));
    final runtimeAccessMode = ref.watch(runtimeAccessModeProvider(widget.bridgeApiBaseUrl));
    final notificationPreferences = ref.watch(notificationPreferencesControllerProvider);

    final approvalsController = ref.read(approvalsQueueControllerProvider(widget.bridgeApiBaseUrl).notifier);

    final effectiveAccessMode = runtimeAccessMode ?? state.thread?.accessMode ?? AccessMode.controlWithApprovals;
    final isReadOnlyMode = effectiveAccessMode == AccessMode.readOnly;
    final controlsEnabled = state.canRunMutatingActions && !isReadOnlyMode;
    final desktopIntegrationControlsEnabled = state.canRunMutatingActions;

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SafeArea(
        child: Column(
          children: [
            // Sticky Header
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: Colors.white10)),
              ),
              child: Row(
                children: [
                   IconButton(
                     onPressed: () => Navigator.of(context).pop(),
                     icon: PhosphorIcon(PhosphorIcons.caretLeft(PhosphorIconsStyle.bold), size: 20, color: AppTheme.textMuted),
                   ),
                   const SizedBox(width: 8),
                   Expanded(
                     child: Text(
                       'Session Details', 
                       style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w500, letterSpacing: -0.5)
                     )
                   ),
                   IconButton(
                     onPressed: () => Navigator.of(context).push(
                       MaterialPageRoute<void>(
                         builder: (context) => SettingsPage(bridgeApiBaseUrl: widget.bridgeApiBaseUrl),
                       ),
                     ),
                     icon: PhosphorIcon(PhosphorIcons.gear()),
                   ),
                ],
              ),
            ),
            
            Expanded(
              child: _buildBody(
                context,
                state: state,
                accessMode: effectiveAccessMode,
                controlsEnabled: controlsEnabled,
                desktopIntegrationControlsEnabled: desktopIntegrationControlsEnabled,
                desktopIntegrationEnabled: notificationPreferences.desktopIntegrationEnabled,
                showLiveNotificationSuppressedBanner: !notificationPreferences.liveActivityNotificationsEnabled,
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
          ],
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
    return const Center(child: CircularProgressIndicator(color: AppTheme.emerald));
  }

  if (state.hasError && !state.hasThread) {
    return _ThreadDetailErrorState(isUnavailable: state.isUnavailable, message: state.errorMessage ?? 'Couldn\'t load', onRetry: onRetry);
  }

  final thread = state.thread;
  if (thread == null) {
    return _ThreadDetailErrorState(isUnavailable: true, message: 'Thread unavailable', onRetry: onRetry);
  }

  final isReadOnlyMode = accessMode == AccessMode.readOnly;

  return RefreshIndicator(
    color: AppTheme.emerald,
    backgroundColor: AppTheme.surfaceZinc800,
    onRefresh: onRetry,
    child: ListView(
      physics: const AlwaysScrollableScrollPhysics(parent: const BouncingScrollPhysics()),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      children: [
        _ThreadDetailHeader(thread: thread),
        const SizedBox(height: 16),
        _AccessModeBanner(accessMode: accessMode),
        
        if (state.staleMessage != null) ...[
          const SizedBox(height: 12),
          _InlineWarning(message: state.staleMessage!),
        ],
        if (!controlsEnabled) ...[
          const SizedBox(height: 12),
          _MutatingActionsBlockedNotice(
            message: isReadOnlyMode
                ? 'Read-only mode blocks turn and git mutations.'
                : 'Mutating actions are blocked while bridge is offline.',
            onRetryReconnect: isReadOnlyMode ? null : onRetryReconnect,
          ),
        ],
        if (showLiveNotificationSuppressedBanner) ...[
          const SizedBox(height: 12),
          const _InlineInfo(message: 'Live activity notifications are disabled.'),
        ],
        if (state.streamErrorMessage != null) ...[
          const SizedBox(height: 12),
          _InlineWarning(message: state.streamErrorMessage!),
        ],
        
        const SizedBox(height: 16),
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
        
        const SizedBox(height: 16),
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
        
        if (threadApprovals.isNotEmpty || approvalsErrorMessage != null) ...[
          const SizedBox(height: 16),
           _ThreadApprovalsCard(
              approvals: threadApprovals,
              canResolveApprovals: canResolveApprovals,
              errorMessage: approvalsErrorMessage,
              onRefresh: onRefreshApprovals,
           ),
        ],

        const SizedBox(height: 16),
        _DesktopIntegrationCard(
          desktopIntegrationEnabled: desktopIntegrationEnabled,
          openOnMacEnabled: desktopIntegrationControlsEnabled,
          isOpeningOnMac: isOpenOnMacInFlight,
          openOnMacMessage: openOnMacMessage,
          openOnMacErrorMessage: openOnMacErrorMessage,
          onOpenOnMac: onOpenOnMac,
        ),
        
        const SizedBox(height: 32),
        const Text('Timeline', style: TextStyle(color: AppTheme.textSubtle, fontSize: 13, letterSpacing: 1.2)),
        const SizedBox(height: 16),

        if (state.canLoadEarlierHistory) ...[
          OutlinedButton.icon(
             key: const Key('load-earlier-history'),
             onPressed: onLoadEarlier,
             icon: const Icon(Icons.history, color: AppTheme.textMuted),
             label: Text('Load earlier history (${state.hiddenHistoryCount})', style: const TextStyle(color: AppTheme.textMuted)),
             style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.white12)),
          ),
          const SizedBox(height: 16),
        ],
        
        if (state.visibleItems.isEmpty)
          const _EmptyTimelineState()
        else
          ...state.visibleItems
              .map((item) => _ThreadActivityCard(item: item))
              .expand((widget) => [widget, const SizedBox(height: 12)]),
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
    final canOpenOnMac = desktopIntegrationEnabled && openOnMacEnabled && !isOpeningOnMac;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: LiquidStyles.liquidGlass.copyWith(borderRadius: BorderRadius.circular(20)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
               PhosphorIcon(PhosphorIcons.monitor(), color: AppTheme.textMain, size: 20),
               const SizedBox(width: 8),
               const Text('Desktop integration', style: TextStyle(color: AppTheme.textMain, fontWeight: FontWeight.w500, fontSize: 16)),
            ],
          ),
          const SizedBox(height: 8),
          const Text('Open this thread in Codex.app on Mac.', style: TextStyle(color: AppTheme.textMuted, fontSize: 13)),
          const SizedBox(height: 16),
          
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.surfaceZinc800,
              foregroundColor: AppTheme.textMain,
              elevation: 0,
            ),
            onPressed: canOpenOnMac ? () async { await onOpenOnMac(); } : null,
            icon: isOpeningOnMac
                ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.textMain))
                : PhosphorIcon(PhosphorIcons.arrowSquareOut()),
            label: const Text('Open on Mac'),
          ),

          if (!desktopIntegrationEnabled) ...[
            const SizedBox(height: 12),
            const Text('Desktop integration is disabled in settings.', style: TextStyle(color: AppTheme.rose, fontSize: 13)),
          ],
          if (openOnMacMessage != null) ...[
            const SizedBox(height: 12),
            _InlineInfo(message: openOnMacMessage!),
          ],
          if (openOnMacErrorMessage != null) ...[
            const SizedBox(height: 12),
            _InlineWarning(message: openOnMacErrorMessage!),
          ],
        ],
      ),
    );
  }
}

class _ThreadDetailErrorState extends StatelessWidget {
  const _ThreadDetailErrorState({required this.isUnavailable, required this.message, required this.onRetry});

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
            PhosphorIcon(isUnavailable ? PhosphorIcons.database() : PhosphorIcons.wifiX(), size: 48, color: AppTheme.rose),
            const SizedBox(height: 16),
            Text(isUnavailable ? 'Unavailable' : 'Couldn\'t load', style: const TextStyle(color: AppTheme.textMain, fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(message, textAlign: TextAlign.center, style: const TextStyle(color: AppTheme.textMuted)),
            const SizedBox(height: 24),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.surfaceZinc800, foregroundColor: AppTheme.textMain),
              onPressed: onRetry, 
              child: const Text('Retry')
            ),
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
    BadgeVariant variant = BadgeVariant.defaultVariant;
    String statusText = 'IDLE';

    switch (thread.status) {
      case ThreadStatus.running: variant = BadgeVariant.active; statusText = 'ACTIVE'; break;
      case ThreadStatus.failed: variant = BadgeVariant.danger; statusText = 'FAILED'; break;
      case ThreadStatus.interrupted: variant = BadgeVariant.warning; statusText = 'INTERRUPTED'; break;
      case ThreadStatus.completed: variant = BadgeVariant.defaultVariant; statusText = 'COMPLETED'; break;
      case ThreadStatus.idle:
      default: break;
    }

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: LiquidStyles.liquidGlass.copyWith(borderRadius: BorderRadius.circular(24)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  thread.title,
                  style: const TextStyle(color: AppTheme.textMain, fontSize: 18, fontWeight: FontWeight.w500, letterSpacing: -0.5),
                ),
              ),
              const SizedBox(width: 8),
              StatusBadge(text: statusText, variant: variant),
            ],
          ),
          const SizedBox(height: 16),
          _DetailRow(icon: PhosphorIcons.folderSimple(), text: thread.repository),
          const SizedBox(height: 8),
          _DetailRow(icon: PhosphorIcons.gitBranch(), text: thread.branch),
          const SizedBox(height: 8),
          _DetailRow(icon: PhosphorIcons.terminalWindow(), text: thread.workspace),
          const SizedBox(height: 16),
          Text(
            thread.threadId,
            style: GoogleFonts.jetBrainsMono(color: AppTheme.textSubtle, fontSize: 10),
          ),
        ],
      ),
    );
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
            style: GoogleFonts.jetBrainsMono(color: AppTheme.textSubtle, fontSize: 12),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

class _AccessModeBanner extends StatelessWidget {
  const _AccessModeBanner({required this.accessMode});

  final AccessMode accessMode;

  @override
  Widget build(BuildContext context) {
    final String label;
    final PhosphorIcon icon;
    final Color color;

    switch (accessMode) {
      case AccessMode.readOnly:
        label = 'Read Only: Mutations Blocked';
        icon = PhosphorIcon(PhosphorIcons.lock(), color: AppTheme.textSubtle);
        color = AppTheme.textSubtle;
        break;
      case AccessMode.controlWithApprovals:
        label = 'Approval Gated Mode';
        icon = PhosphorIcon(PhosphorIcons.shieldCheck(), color: AppTheme.amber);
        color = AppTheme.amber;
        break;
      case AccessMode.fullControl:
        label = 'Full Control Enabled';
        icon = PhosphorIcon(PhosphorIcons.lightning(), color: AppTheme.emerald);
        color = AppTheme.emerald;
        break;
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.2)),
      ),
      child: Row(
        children: [
           icon,
           const SizedBox(width: 12),
           Expanded(child: Text(label, style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w500))),
        ],
      ),
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
    final canSubmitComposer = controlsEnabled && !isComposerMutationInFlight && !isInterruptMutationInFlight;
    final canInterrupt = controlsEnabled && isTurnActive && !isInterruptMutationInFlight && !isComposerMutationInFlight;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppTheme.surfaceZinc800.withOpacity(0.5),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
               PhosphorIcon(PhosphorIcons.keyboard(), color: AppTheme.textMain, size: 20),
               const SizedBox(width: 8),
               Text(isTurnActive ? 'Steer active turn' : 'Start new turn', style: const TextStyle(color: AppTheme.textMain, fontWeight: FontWeight.w500, fontSize: 16)),
            ],
          ),
          const SizedBox(height: 16),
          
          TextField(
            controller: composerController,
            enabled: canSubmitComposer,
            minLines: 1,
            maxLines: 4,
            textInputAction: TextInputAction.newline,
            style: const TextStyle(color: AppTheme.textMain, fontSize: 14),
            decoration: InputDecoration(
              hintText: isTurnActive ? 'Guide the agent...' : 'Describe task...',
              hintStyle: const TextStyle(color: AppTheme.textSubtle),
              filled: true,
              fillColor: Colors.black26,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              contentPadding: const EdgeInsets.all(16),
            ),
          ),
          
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: isTurnActive ? AppTheme.surfaceZinc800 : AppTheme.emerald,
                    foregroundColor: isTurnActive ? AppTheme.textMain : Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: canSubmitComposer ? () async {
                    final success = await onSubmitComposer(composerController.text);
                    if (success) composerController.clear();
                  } : null,
                  icon: isComposerMutationInFlight
                      ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                      : PhosphorIcon(isTurnActive ? PhosphorIcons.chatTeardrop() : PhosphorIcons.play()),
                  label: Text(isTurnActive ? 'Steer' : 'Start turn'),
                ),
              ),
              if (isTurnActive) ...[
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.rose.withOpacity(0.2),
                    foregroundColor: AppTheme.rose,
                    padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: canInterrupt ? () async { await onInterruptActiveTurn(); } : null,
                  icon: isInterruptMutationInFlight
                      ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.rose))
                      : PhosphorIcon(PhosphorIcons.stopCircle()),
                  label: const Text('Interrupt'),
                ),
              ],
            ],
          ),
        ],
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
    // Determine git state
    final repositoryContext = gitStatus?.repository ?? RepositoryContextDto(workspace: thread.workspace, repository: thread.repository, branch: thread.branch, remote: 'unknown');
    final status = gitStatus?.status;
    final hasResolvedGitStatus = gitStatus != null;
    
    final repository = repositoryContext.repository.trim().toLowerCase();
    final branch = repositoryContext.branch.trim().toLowerCase();
    final hasRepositoryContext = hasResolvedGitStatus && repository.isNotEmpty && repository != 'unknown' && branch.isNotEmpty && branch != 'unknown';

    final canRunGitMutations = controlsEnabled && hasResolvedGitStatus && hasRepositoryContext && !isGitStatusLoading && !isGitMutationInFlight;

    final unavailableMessage = isReadOnlyMode
        ? 'Read-only mode blocks git mutations.'
        : !controlsEnabled
        ? 'Git controls unavailable (offline).'
        : gitControlsUnavailableReason;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppTheme.surfaceZinc800.withOpacity(0.3),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
               PhosphorIcon(PhosphorIcons.gitBranch(), color: AppTheme.textMain, size: 20),
               const SizedBox(width: 8),
               const Expanded(child: Text('Git Status', style: TextStyle(color: AppTheme.textMain, fontWeight: FontWeight.w500, fontSize: 16))),
               IconButton(
                 onPressed: isGitMutationInFlight ? null : () async { await onRefreshGitStatus(showLoading: true); },
                 icon: PhosphorIcon(PhosphorIcons.arrowsClockwise(), color: AppTheme.textSubtle, size: 20),
               ),
            ],
          ),
          
          if (isGitStatusLoading) const LinearProgressIndicator(color: AppTheme.emerald, backgroundColor: Colors.transparent),
          
          const SizedBox(height: 12),
          Container(
             padding: const EdgeInsets.all(12),
             decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(12)),
             child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                   _DetailRow(icon: PhosphorIcons.gitBranch(), text: repositoryContext.branch),
                   if (status != null) ...[
                      const SizedBox(height: 8),
                      Row(
                         children: [
                           PhosphorIcon(status.dirty ? PhosphorIcons.warningCircle() : PhosphorIcons.checkCircle(), size: 14, color: status.dirty ? AppTheme.amber : AppTheme.emerald),
                           const SizedBox(width: 8),
                           Text(status.dirty ? 'Uncommitted changes' : 'Clean working tree', style: TextStyle(color: status.dirty ? AppTheme.amber : AppTheme.emerald, fontSize: 12)),
                         ]
                      ),
                   ]
                ]
             )
          ),

          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: gitBranchController,
                  enabled: canRunGitMutations,
                  style: const TextStyle(color: AppTheme.textMain, fontSize: 14),
                  decoration: InputDecoration(
                    hintText: 'Branch name...',
                    hintStyle: const TextStyle(color: AppTheme.textSubtle),
                    filled: true,
                    fillColor: Colors.black26,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: AppTheme.surfaceZinc800, foregroundColor: AppTheme.textMain, padding: const EdgeInsets.symmetric(vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                onPressed: canRunGitMutations ? () async {
                  final success = await onSwitchBranch(gitBranchController.text);
                  if (success) gitBranchController.clear();
                } : null,
                child: const Text('Checkout'),
              ),
            ],
          ),
          
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.white12), foregroundColor: AppTheme.textMain, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                  onPressed: canRunGitMutations ? onPullRepository : null,
                  icon: PhosphorIcon(PhosphorIcons.downloadSimple(), size: 16),
                  label: const Text('Pull'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.white12), foregroundColor: AppTheme.textMain, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                  onPressed: canRunGitMutations ? onPushRepository : null,
                  icon: PhosphorIcon(PhosphorIcons.uploadSimple(), size: 16),
                  label: const Text('Push'),
                ),
              ),
            ],
          ),

          if (unavailableMessage != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(unavailableMessage, style: const TextStyle(color: AppTheme.rose, fontSize: 13))),
          if (gitErrorMessage != null) Padding(padding: const EdgeInsets.only(top: 12), child: _InlineWarning(message: gitErrorMessage!)),
          if (gitMutationMessage != null) Padding(padding: const EdgeInsets.only(top: 12), child: _InlineInfo(message: gitMutationMessage!)),
        ],
      ),
    );
  }
}

class _ThreadApprovalsCard extends StatelessWidget {
  const _ThreadApprovalsCard({required this.approvals, required this.canResolveApprovals, required this.errorMessage, required this.onRefresh});

  final List<ApprovalItemState> approvals;
  final bool canResolveApprovals;
  final String? errorMessage;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    // Complex approval widgets adapted to match the dark theme
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: AppTheme.amber.withOpacity(0.1), borderRadius: BorderRadius.circular(20), border: Border.all(color: AppTheme.amber.withOpacity(0.2))),
      child: Column(
         crossAxisAlignment: CrossAxisAlignment.start,
         children: [
            Row(
               children: [
                  PhosphorIcon(PhosphorIcons.shieldWarning(), color: AppTheme.amber, size: 20),
                  const SizedBox(width: 8),
                  const Expanded(child: Text('Pending Approvals', style: TextStyle(color: AppTheme.amber, fontWeight: FontWeight.w600, fontSize: 16))),
                  IconButton(onPressed: onRefresh, icon: PhosphorIcon(PhosphorIcons.arrowsClockwise(), color: AppTheme.amber, size: 20)),
               ]
            ),
            if (errorMessage != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(errorMessage!, style: const TextStyle(color: AppTheme.rose, fontSize: 13))),
            const SizedBox(height: 12),
            ...approvals.map((item) => Container(
               margin: const EdgeInsets.only(bottom: 8),
               padding: const EdgeInsets.all(12),
               decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(12)),
               child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                     Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                           Text(approvalActionLabel(item.approval.action), style: const TextStyle(color: AppTheme.textMain, fontWeight: FontWeight.w500)),
                           Text(approvalStatusLabel(item.approval.status), style: GoogleFonts.jetBrainsMono(color: AppTheme.textSubtle, fontSize: 10)),
                        ]
                     ),
                     const SizedBox(height: 4),
                     Text(item.approval.reason, style: const TextStyle(color: AppTheme.textMuted, fontSize: 13)),
                  ]
               )
            ))
         ]
      )
    );
  }
}

class _ThreadActivityCard extends StatelessWidget {
  const _ThreadActivityCard({required this.item});

  final ThreadActivityItem item;

  @override
  Widget build(BuildContext context) {
    Color borderColor;
    Color iconColor;
    PhosphorIcon icon;
    
    switch (item.type) {
      case ThreadActivityItemType.userPrompt:
        borderColor = AppTheme.emerald.withOpacity(0.3);
        iconColor = AppTheme.emerald;
        icon = PhosphorIcon(PhosphorIcons.user(), color: iconColor, size: 16);
        break;
      case ThreadActivityItemType.assistantOutput:
        borderColor = Colors.white.withOpacity(0.1);
        iconColor = AppTheme.textMain;
        icon = PhosphorIcon(PhosphorIcons.robot(), color: iconColor, size: 16);
        break;
      case ThreadActivityItemType.terminalOutput:
        borderColor = Colors.white.withOpacity(0.05);
        iconColor = AppTheme.textSubtle;
        icon = PhosphorIcon(PhosphorIcons.terminalWindow(), color: iconColor, size: 16);
        break;
      case ThreadActivityItemType.approvalRequest:
        borderColor = AppTheme.amber.withOpacity(0.3);
        iconColor = AppTheme.amber;
        icon = PhosphorIcon(PhosphorIcons.shieldWarning(), color: iconColor, size: 16);
        break;
      case ThreadActivityItemType.securityEvent:
        borderColor = AppTheme.rose.withOpacity(0.3);
        iconColor = AppTheme.rose;
        icon = PhosphorIcon(PhosphorIcons.warning(), color: iconColor, size: 16);
        break;
      default:
        borderColor = Colors.white.withOpacity(0.1);
        iconColor = AppTheme.textSubtle;
        icon = PhosphorIcon(PhosphorIcons.lightning(), color: iconColor, size: 16);
        break;
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surfaceZinc800.withOpacity(0.3),
        border: Border(left: BorderSide(color: borderColor, width: 3)),
        borderRadius: const BorderRadius.only(topRight: Radius.circular(12), bottomRight: Radius.circular(12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              icon,
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  item.title,
                  style: GoogleFonts.jetBrainsMono(color: iconColor, fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ),
              Text(
                item.occurredAt,
                style: GoogleFonts.jetBrainsMono(color: AppTheme.textSubtle, fontSize: 10),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SelectableText(
             item.body, 
             style: item.type == ThreadActivityItemType.terminalOutput 
                ? GoogleFonts.jetBrainsMono(color: AppTheme.textMuted, fontSize: 12)
                : const TextStyle(color: AppTheme.textMain, fontSize: 14)
          ),
        ],
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
            Text('No timeline entries yet.', style: TextStyle(color: AppTheme.textMuted)),
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
      decoration: BoxDecoration(color: AppTheme.rose.withOpacity(0.1), borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.rose.withOpacity(0.3))),
      child: Text(message, style: const TextStyle(color: AppTheme.rose, fontSize: 13)),
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
      decoration: BoxDecoration(color: AppTheme.emerald.withOpacity(0.1), borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.emerald.withOpacity(0.3))),
      child: Text(message, style: const TextStyle(color: AppTheme.emerald, fontSize: 13)),
    );
  }
}

class _MutatingActionsBlockedNotice extends StatelessWidget {
  const _MutatingActionsBlockedNotice({required this.message, required this.onRetryReconnect});
  final String message;
  final Future<void> Function()? onRetryReconnect;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: AppTheme.surfaceZinc800, borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.white12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(message, style: const TextStyle(color: AppTheme.textMuted, fontSize: 13)),
          if (onRetryReconnect != null) ...[
            const SizedBox(height: 8),
            OutlinedButton(onPressed: onRetryReconnect, style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.white12)), child: const Text('Retry reconnect', style: TextStyle(color: AppTheme.textMain))),
          ],
        ],
      ),
    );
  }
}
