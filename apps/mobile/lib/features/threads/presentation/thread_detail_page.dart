import 'dart:io';

import 'package:codex_mobile_companion/features/approvals/application/approvals_queue_controller.dart';
import 'package:codex_mobile_companion/features/approvals/presentation/approval_presenter.dart';
import 'package:codex_mobile_companion/features/pairing/application/pairing_controller.dart';
import 'package:codex_mobile_companion/features/pairing/domain/pairing_qr_payload.dart';
import 'package:codex_mobile_companion/features/settings/application/desktop_integration_controller.dart';
import 'package:codex_mobile_companion/features/settings/application/device_settings_controller.dart';
import 'package:codex_mobile_companion/features/settings/application/runtime_access_mode.dart';
import 'package:codex_mobile_companion/features/threads/application/thread_detail_controller.dart';
import 'package:codex_mobile_companion/features/threads/domain/parsed_command_output.dart';
import 'package:codex_mobile_companion/features/threads/domain/thread_activity_item.dart';
import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:codex_mobile_companion/foundation/theme/app_theme.dart';
import 'package:codex_mobile_companion/shared/widgets/badges.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:syntax_highlight/syntax_highlight.dart';

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
  static const List<String> _modelOptions = <String>[
    'GPT-5',
    'GPT-5 Mini',
    'o4-mini',
  ];
  static const List<String> _reasoningOptions = <String>[
    'Low',
    'Medium',
    'High',
  ];

  late final TextEditingController _composerController;
  late final TextEditingController _gitBranchController;
  late final ScrollController _timelineScrollController;
  final ImagePicker _imagePicker = ImagePicker();
  List<XFile> _attachedImages = const <XFile>[];
  String _selectedModel = _modelOptions.first;
  String _selectedReasoning = _reasoningOptions[1];
  bool _didInitialScrollToBottom = false;

  @override
  void initState() {
    super.initState();
    _composerController = TextEditingController();
    _gitBranchController = TextEditingController();
    _timelineScrollController = ScrollController();
  }

  @override
  void didUpdateWidget(covariant ThreadDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.threadId != widget.threadId) {
      _didInitialScrollToBottom = false;
    }
  }

  @override
  void dispose() {
    _composerController.dispose();
    _gitBranchController.dispose();
    _timelineScrollController.dispose();
    super.dispose();
  }

  void _scheduleInitialScrollToBottom() {
    if (_didInitialScrollToBottom) {
      return;
    }
    _didInitialScrollToBottom = true;
    _jumpToTimelineBottom(attempt: 0);
  }

  void _jumpToTimelineBottom({required int attempt}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_timelineScrollController.hasClients) {
        if (attempt < 6) {
          _jumpToTimelineBottom(attempt: attempt + 1);
        }
        return;
      }

      final position = _timelineScrollController.position;
      _timelineScrollController.jumpTo(position.maxScrollExtent);

      if (attempt < 2) {
        _jumpToTimelineBottom(attempt: attempt + 1);
      }
    });
  }

  Future<void> _pickImages() async {
    final images = await _imagePicker.pickMultiImage(
      imageQuality: 90,
      maxWidth: 2048,
    );
    if (!mounted || images.isEmpty) {
      return;
    }

    setState(() {
      _attachedImages = List<XFile>.unmodifiable(<XFile>[
        ..._attachedImages,
        ...images,
      ]);
    });
  }

  void _removeAttachedImage(XFile image) {
    setState(() {
      _attachedImages = List<XFile>.unmodifiable(
        _attachedImages.where((candidate) => candidate.path != image.path),
      );
    });
  }

  Future<void> _showGitBranchSheet(
    BuildContext context, {
    required _ResolvedGitControls gitControls,
    required Future<bool> Function(String rawBranch) onSwitchBranch,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.background,
      isScrollControlled: true,
      builder: (context) => _GitBranchSheet(
        gitControls: gitControls,
        gitBranchController: _gitBranchController,
        onSwitchBranch: onSwitchBranch,
      ),
    );
  }

  Future<void> _showGitSyncSheet(
    BuildContext context, {
    required _ResolvedGitControls gitControls,
    required Future<void> Function({bool showLoading}) onRefreshGitStatus,
    required Future<bool> Function() onPullRepository,
    required Future<bool> Function() onPushRepository,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.background,
      builder: (context) => _GitSyncSheet(
        gitControls: gitControls,
        onRefreshGitStatus: onRefreshGitStatus,
        onPullRepository: onPullRepository,
        onPushRepository: onPushRepository,
      ),
    );
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
    final desktopIntegrationState = ref.watch(
      desktopIntegrationControllerProvider,
    );
    final pairingState = ref.watch(pairingControllerProvider);
    final deviceSettingsState = ref.watch(
      deviceSettingsControllerProvider(widget.bridgeApiBaseUrl),
    );

    final approvalsController = ref.read(
      approvalsQueueControllerProvider(widget.bridgeApiBaseUrl).notifier,
    );
    final deviceSettingsController = ref.read(
      deviceSettingsControllerProvider(widget.bridgeApiBaseUrl).notifier,
    );

    final effectiveAccessMode =
        runtimeAccessMode ??
        state.thread?.accessMode ??
        AccessMode.controlWithApprovals;
    final isReadOnlyMode = effectiveAccessMode == AccessMode.readOnly;
    final controlsEnabled = state.canRunMutatingActions && !isReadOnlyMode;
    final desktopIntegrationControlsEnabled = state.canRunMutatingActions;
    final gitControls = _ResolvedGitControls.resolve(
      thread: state.thread,
      gitStatus: state.gitStatus,
      controlsEnabled: controlsEnabled,
      isReadOnlyMode: isReadOnlyMode,
      isGitStatusLoading: state.isGitStatusLoading,
      isGitMutationInFlight: state.isGitMutationInFlight,
      gitControlsUnavailableReason: state.gitControlsUnavailableReason,
    );

    if (state.hasThread && !_didInitialScrollToBottom) {
      _scheduleInitialScrollToBottom();
    }

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SafeArea(
        child: Column(
          children: [
            // Sticky Header
            if (state.thread != null)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 16,
                ),
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: Colors.white10)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Row 1: CONNECTED & CODEX_BRIDGE
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: const BoxDecoration(
                                color: AppTheme.emerald,
                                shape: BoxShape.circle,
                                boxShadow: [
                                  BoxShadow(
                                    color: AppTheme.emerald,
                                    blurRadius: 10,
                                    spreadRadius: 2,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              !state.isConnectivityUnavailable
                                  ? 'CONNECTED'
                                  : 'DISCONNECTED',
                              style: GoogleFonts.jetBrainsMono(
                                color: !state.isConnectivityUnavailable
                                    ? AppTheme.textSubtle
                                    : AppTheme.rose,
                                fontSize: 10,
                                letterSpacing: 1.0,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                        Text(
                          'CODEX_BRIDGE',
                          style: GoogleFonts.jetBrainsMono(
                            color: AppTheme.textSubtle,
                            fontSize: 10,
                            letterSpacing: 1.0,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    // Row 2: < Title ACTIVE
                    Row(
                      children: [
                        IconButton(
                          onPressed: () => Navigator.of(context).maybePop(),
                          icon: PhosphorIcon(
                            PhosphorIcons.caretLeft(PhosphorIconsStyle.bold),
                            size: 24,
                            color: AppTheme.textMuted,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            state.thread!.title,
                            key: const Key('thread-detail-title'),
                            style: Theme.of(context).textTheme.titleLarge
                                ?.copyWith(
                                  fontWeight: FontWeight.w500,
                                  letterSpacing: -0.5,
                                ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        StatusBadge(
                          text: _threadStatusLabel(state.thread!.status),
                          variant: state.thread!.status == ThreadStatus.running
                              ? BadgeVariant.active
                              : BadgeVariant.defaultVariant,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    // Row 3: Repo • Approvals
                    Padding(
                      padding: const EdgeInsets.only(left: 36),
                      child: Row(
                        children: [
                          PhosphorIcon(
                            PhosphorIcons.folderSimple(),
                            size: 14,
                            color: AppTheme.textSubtle,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            state.thread!.repository,
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
                          Text(
                            state.thread!.threadId,
                            key: const Key('thread-detail-thread-id'),
                            style: GoogleFonts.jetBrainsMono(
                              color: AppTheme.textSubtle,
                              fontSize: 12,
                            ),
                          ),
                          if (approvalsState
                              .forThread(widget.threadId)
                              .isNotEmpty) ...[
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
                    const SizedBox(height: 16),
                    // Row 4: Controls
                    Padding(
                      padding: const EdgeInsets.only(left: 36),
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
                                    .withOpacity(0.5),
                                foregroundColor: AppTheme.textMain,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                  side: BorderSide(
                                    color: Colors.white.withOpacity(0.05),
                                  ),
                                ),
                              ),
                              onPressed: () async {
                                await _showGitBranchSheet(
                                  context,
                                  gitControls: gitControls,
                                  onSwitchBranch: (rawBranch) async {
                                    final accepted = await controller
                                        .switchBranch(rawBranch);
                                    await approvalsController.loadApprovals(
                                      showLoading: false,
                                    );
                                    return accepted;
                                  },
                                );
                              },
                              icon: PhosphorIcon(
                                PhosphorIcons.gitBranch(),
                                size: 16,
                                color: gitControls.hasDirtyWorkingTree
                                    ? AppTheme.amber
                                    : AppTheme.textSubtle,
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
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 10,
                                ),
                                backgroundColor: AppTheme.surfaceZinc800
                                    .withOpacity(0.5),
                                foregroundColor: AppTheme.textMain,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                  side: BorderSide(
                                    color: Colors.white.withOpacity(0.05),
                                  ),
                                ),
                              ),
                              onPressed: () async {
                                await _showGitSyncSheet(
                                  context,
                                  gitControls: gitControls,
                                  onRefreshGitStatus:
                                      controller.refreshGitStatus,
                                  onPullRepository: () async {
                                    final accepted = await controller
                                        .pullRepository();
                                    await approvalsController.loadApprovals(
                                      showLoading: false,
                                    );
                                    return accepted;
                                  },
                                  onPushRepository: () async {
                                    final accepted = await controller
                                        .pushRepository();
                                    await approvalsController.loadApprovals(
                                      showLoading: false,
                                    );
                                    return accepted;
                                  },
                                );
                              },
                              icon: PhosphorIcon(
                                PhosphorIcons.arrowsClockwise(),
                                size: 16,
                                color: AppTheme.textSubtle,
                              ),
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
                              backgroundColor: AppTheme.surfaceZinc800
                                  .withOpacity(0.5),
                              foregroundColor: AppTheme.textMain,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                                side: BorderSide(
                                  color: Colors.white.withOpacity(0.05),
                                ),
                              ),
                            ),
                            onPressed:
                                desktopIntegrationControlsEnabled &&
                                    desktopIntegrationState.isEnabled &&
                                    !state.isOpenOnMacInFlight
                                ? () async {
                                    await controller.openOnMac();
                                  }
                                : null,
                            child: state.isOpenOnMacInFlight
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
              )
            else
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 16,
                ),
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: Colors.white10)),
                ),
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
                        'Session Details',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w500,
                          letterSpacing: -0.5,
                        ),
                      ),
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
                desktopIntegrationEnabled: desktopIntegrationState.isEnabled,
                onRetry: controller.loadThread,
                onLoadEarlier: controller.loadEarlierHistory,
                onRetryReconnect: controller.retryReconnectCatchUp,
                composerController: _composerController,
                onSubmitComposer: controller.submitComposerInput,
                onInterruptActiveTurn: controller.interruptActiveTurn,
                threadApprovals: approvalsState.forThread(widget.threadId),
                approvalsErrorMessage: approvalsState.errorMessage,
                canResolveApprovals: approvalsState.canResolveApprovals,
                gitErrorMessage: state.gitErrorMessage,
                gitMutationMessage: state.gitMutationMessage,
                gitControlsUnavailableReason:
                    state.gitControlsUnavailableReason,
                openOnMacMessage: state.openOnMacMessage,
                openOnMacErrorMessage: state.openOnMacErrorMessage,
                hasPinnedComposer: state.thread != null,
                onRefreshApprovals: () {
                  approvalsController.loadApprovals(showLoading: false);
                },
                scrollController: _timelineScrollController,
              ),
            ),
            if (state.thread != null)
              SafeArea(
                top: false,
                child: _PinnedTurnComposer(
                  composerController: _composerController,
                  isTurnActive: state.isTurnActive,
                  controlsEnabled: controlsEnabled,
                  isComposerMutationInFlight: state.isComposerMutationInFlight,
                  isInterruptMutationInFlight:
                      state.isInterruptMutationInFlight,
                  attachedImages: _attachedImages,
                  selectedModel: _selectedModel,
                  selectedReasoning: _selectedReasoning,
                  accessMode: effectiveAccessMode,
                  trustedBridge: pairingState.trustedBridge,
                  isAccessModeUpdating:
                      deviceSettingsState.isAccessModeUpdating,
                  accessModeErrorMessage:
                      deviceSettingsState.accessModeErrorMessage,
                  onPickImages: _pickImages,
                  onRemoveImage: _removeAttachedImage,
                  onModelChanged: (value) {
                    setState(() {
                      _selectedModel = value;
                    });
                  },
                  onReasoningChanged: (value) {
                    setState(() {
                      _selectedReasoning = value;
                    });
                  },
                  onAccessModeChanged: (mode) async {
                    final trustedBridge = pairingState.trustedBridge;
                    if (trustedBridge == null) {
                      return;
                    }
                    await deviceSettingsController.setAccessMode(
                      accessMode: mode,
                      trustedBridge: trustedBridge,
                    );
                  },
                  onSubmitComposer: controller.submitComposerInput,
                  onInterruptActiveTurn: controller.interruptActiveTurn,
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
  required bool desktopIntegrationEnabled,
  required Future<void> Function() onRetry,
  required VoidCallback onLoadEarlier,
  required Future<void> Function() onRetryReconnect,
  required TextEditingController composerController,
  required Future<bool> Function(String rawInput) onSubmitComposer,
  required Future<bool> Function() onInterruptActiveTurn,
  required List<ApprovalItemState> threadApprovals,
  required String? approvalsErrorMessage,
  required bool canResolveApprovals,
  required String? gitErrorMessage,
  required String? gitMutationMessage,
  required String? gitControlsUnavailableReason,
  required String? openOnMacMessage,
  required String? openOnMacErrorMessage,
  required bool hasPinnedComposer,
  required VoidCallback onRefreshApprovals,
  required ScrollController scrollController,
}) {
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

  final isReadOnlyMode = accessMode == AccessMode.readOnly;
  final timelineBlocks = _buildTimelineBlocks(state.visibleItems);

  return RefreshIndicator(
    color: AppTheme.emerald,
    backgroundColor: AppTheme.surfaceZinc800,
    onRefresh: onRetry,
    child: ListView(
      controller: scrollController,
      key: const Key('thread-detail-scroll-view'),
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      children: [
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
        if (state.streamErrorMessage != null) ...[
          const SizedBox(height: 12),
          _InlineWarning(message: state.streamErrorMessage!),
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

        if (state.canLoadEarlierHistory) ...[
          OutlinedButton.icon(
            key: const Key('load-earlier-history'),
            onPressed: onLoadEarlier,
            icon: const Icon(Icons.history, color: AppTheme.textMuted),
            label: Text(
              'Load earlier history (${state.hiddenHistoryCount})',
              style: const TextStyle(color: AppTheme.textMuted),
            ),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: Colors.white12),
            ),
          ),
          const SizedBox(height: 16),
        ],

        if (state.visibleItems.isEmpty)
          const _EmptyTimelineState()
        else
          ...timelineBlocks
              .map(
                (block) => block.item != null
                    ? _ThreadActivityCard(
                        item: block.item!,
                        exploration: block.exploration,
                      )
                    : _ExploredFilesCard(exploration: block.exploration!),
              )
              .expand((widget) => [widget, const SizedBox(height: 12)]),
        if (hasPinnedComposer) const SizedBox(height: 220),
      ],
    ),
  );
}

List<_TimelineBlock> _buildTimelineBlocks(List<ThreadActivityItem> items) {
  final blocks = <_TimelineBlock>[];
  var index = 0;

  while (index < items.length) {
    final item = items[index];
    final exploration = _ExplorationSummaryBuilder();

    if (_isExplorationItem(item)) {
      var scanIndex = index;
      while (scanIndex < items.length && _isExplorationItem(items[scanIndex])) {
        exploration.add(items[scanIndex]);
        scanIndex += 1;
      }

      if (exploration.hasContent) {
        blocks.add(_TimelineBlock.explorationSummary(exploration.build()));
        index = scanIndex;
        continue;
      }
    }

    var scanIndex = index + 1;
    while (scanIndex < items.length && _isExplorationItem(items[scanIndex])) {
      exploration.add(items[scanIndex]);
      scanIndex += 1;
    }

    blocks.add(
      _TimelineBlock.activity(
        item,
        exploration: exploration.hasContent ? exploration.build() : null,
      ),
    );
    index = scanIndex;
  }

  return blocks;
}

bool _isExplorationItem(ThreadActivityItem item) {
  if (item.type != ThreadActivityItemType.terminalOutput) {
    return false;
  }

  final command = item.parsedCommandOutput?.command;
  if (command == null || command.trim().isEmpty) {
    return false;
  }

  final normalizedCommand = command.trim().toLowerCase();
  return normalizedCommand.startsWith('nl -ba ') ||
      normalizedCommand.startsWith('cat ') ||
      normalizedCommand.startsWith('sed -n ') ||
      normalizedCommand.startsWith('rg -n ') ||
      normalizedCommand.startsWith('rg --files ') ||
      normalizedCommand.startsWith('head ') ||
      normalizedCommand.startsWith('tail ');
}

String? _extractExploredFileLabel(ThreadActivityItem item) {
  final command = item.parsedCommandOutput?.command;
  if (command == null || command.trim().isEmpty) {
    return null;
  }

  final pattern = RegExp(
    r'([~./A-Za-z0-9_-]+(?:/[~./A-Za-z0-9_-]+)*\.[A-Za-z0-9]+)',
  );

  String? lastPath;
  for (final match in pattern.allMatches(command)) {
    lastPath = match.group(1);
  }

  final fileName = _CodeLanguageResolver.displayName(lastPath);
  if (fileName == null || fileName.isEmpty) {
    return null;
  }

  return 'Read $fileName';
}

bool _isSearchExplorationItem(ThreadActivityItem item) {
  final command = item.parsedCommandOutput?.command;
  if (command == null || command.trim().isEmpty) {
    return false;
  }

  final normalizedCommand = command.trim().toLowerCase();
  return normalizedCommand.startsWith('rg -n ') ||
      normalizedCommand.startsWith('rg --files ') ||
      normalizedCommand.startsWith('find ') ||
      normalizedCommand.startsWith('grep ') ||
      normalizedCommand.startsWith('search_query ');
}

class _TimelineBlock {
  const _TimelineBlock._({this.item, this.exploration});

  factory _TimelineBlock.activity(
    ThreadActivityItem item, {
    _ExplorationSummary? exploration,
  }) {
    return _TimelineBlock._(item: item, exploration: exploration);
  }

  factory _TimelineBlock.explorationSummary(_ExplorationSummary exploration) {
    return _TimelineBlock._(exploration: exploration);
  }

  final ThreadActivityItem? item;
  final _ExplorationSummary? exploration;
}

class _ExplorationSummaryBuilder {
  final List<String> _files = <String>[];
  final Set<String> _seenFiles = <String>{};
  int _searchCount = 0;

  bool get hasContent => _files.isNotEmpty || _searchCount > 0;

  void add(ThreadActivityItem item) {
    if (_isSearchExplorationItem(item)) {
      _searchCount += 1;
      return;
    }

    final file = _extractExploredFileLabel(item);
    if (file != null && _seenFiles.add(file)) {
      _files.add(file);
    }
  }

  _ExplorationSummary build() {
    return _ExplorationSummary(
      files: List<String>.unmodifiable(_files),
      searchCount: _searchCount,
    );
  }
}

class _ExplorationSummary {
  const _ExplorationSummary({required this.files, required this.searchCount});

  final List<String> files;
  final int searchCount;

  String get label {
    final parts = <String>[];
    if (files.isNotEmpty) {
      parts.add(
        'Explored ${files.length} ${files.length == 1 ? 'file' : 'files'}',
      );
    }
    if (searchCount > 0) {
      parts.add('$searchCount ${searchCount == 1 ? 'search' : 'searches'}');
    }
    if (parts.isEmpty) {
      return 'Explored activity';
    }
    if (parts.length == 1) {
      return parts.first;
    }
    return '${parts.first}, ${parts.sublist(1).join(', ')}';
  }
}

String? _workedForLabel(double? wallTimeSeconds) {
  if (wallTimeSeconds == null || wallTimeSeconds <= 0) {
    return null;
  }

  final roundedSeconds = wallTimeSeconds.round();
  if (roundedSeconds < 60) {
    return 'Worked for ${roundedSeconds}s';
  }

  final minutes = roundedSeconds ~/ 60;
  final seconds = roundedSeconds % 60;
  if (seconds == 0) {
    return 'Worked for ${minutes}m';
  }
  return 'Worked for ${minutes}m ${seconds}s';
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
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PinnedTurnComposer extends StatelessWidget {
  const _PinnedTurnComposer({
    required this.composerController,
    required this.isTurnActive,
    required this.controlsEnabled,
    required this.isComposerMutationInFlight,
    required this.isInterruptMutationInFlight,
    required this.attachedImages,
    required this.selectedModel,
    required this.selectedReasoning,
    required this.accessMode,
    required this.trustedBridge,
    required this.isAccessModeUpdating,
    required this.accessModeErrorMessage,
    required this.onPickImages,
    required this.onRemoveImage,
    required this.onModelChanged,
    required this.onReasoningChanged,
    required this.onAccessModeChanged,
    required this.onSubmitComposer,
    required this.onInterruptActiveTurn,
  });

  final TextEditingController composerController;
  final bool isTurnActive;
  final bool controlsEnabled;
  final bool isComposerMutationInFlight;
  final bool isInterruptMutationInFlight;
  final List<XFile> attachedImages;
  final String selectedModel;
  final String selectedReasoning;
  final AccessMode accessMode;
  final TrustedBridgeIdentity? trustedBridge;
  final bool isAccessModeUpdating;
  final String? accessModeErrorMessage;
  final Future<void> Function() onPickImages;
  final ValueChanged<XFile> onRemoveImage;
  final ValueChanged<String> onModelChanged;
  final ValueChanged<String> onReasoningChanged;
  final ValueChanged<AccessMode> onAccessModeChanged;
  final Future<bool> Function(String rawInput) onSubmitComposer;
  final Future<bool> Function() onInterruptActiveTurn;

  @override
  Widget build(BuildContext context) {
    final showStopAction = isTurnActive || isInterruptMutationInFlight;
    final canSubmitComposer =
        controlsEnabled &&
        !isTurnActive &&
        !isComposerMutationInFlight &&
        !isInterruptMutationInFlight;
    final canInterrupt =
        controlsEnabled &&
        isTurnActive &&
        !isInterruptMutationInFlight &&
        !isComposerMutationInFlight;
    final canRunPrimaryAction = showStopAction
        ? canInterrupt
        : canSubmitComposer;
    final canEditPinnedControls =
        !isComposerMutationInFlight && !isInterruptMutationInFlight;

    return Container(
      key: const Key('pinned-turn-composer'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      decoration: BoxDecoration(
        color: AppTheme.background.withOpacity(0.96),
        border: const Border(top: BorderSide(color: Colors.white10)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.45),
            blurRadius: 24,
            offset: const Offset(0, -8),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (attachedImages.isNotEmpty) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 10,
                runSpacing: 10,
                children: attachedImages
                    .map(
                      (image) => _ComposerImagePreview(
                        image: image,
                        onRemove: () => onRemoveImage(image),
                      ),
                    )
                    .toList(growable: false),
              ),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              SizedBox(
                width: 56,
                height: 56,
                child: Container(
                  decoration: BoxDecoration(
                    color: AppTheme.surfaceZinc800.withOpacity(0.86),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white.withOpacity(0.06)),
                  ),
                  child: IconButton(
                    icon: PhosphorIcon(
                      PhosphorIcons.plus(),
                      size: 24,
                      color: AppTheme.textMain,
                    ),
                    onPressed: canEditPinnedControls
                        ? () async {
                            await onPickImages();
                          }
                        : null,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 56,
                height: 56,
                child: Container(
                  decoration: BoxDecoration(
                    color: AppTheme.surfaceZinc800.withOpacity(0.86),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white.withOpacity(0.06)),
                  ),
                  child: PopupMenuButton<dynamic>(
                    enabled: canEditPinnedControls,
                    tooltip: '',
                    icon: PhosphorIcon(
                      PhosphorIcons.cpu(),
                      size: 24,
                      color: AppTheme.textMain,
                    ),
                    onSelected: (value) {
                      if (value is String &&
                          ['GPT-5', 'GPT-5 Mini', 'o4-mini'].contains(value)) {
                        onModelChanged(value);
                      } else if (value is String &&
                          ['Low', 'Medium', 'High'].contains(value)) {
                        onReasoningChanged(value);
                      } else if (value is AccessMode) {
                        onAccessModeChanged(value);
                      }
                    },
                    itemBuilder: (context) {
                      return [
                        const PopupMenuItem(
                          enabled: false,
                          child: Text(
                            'Model',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                        ...[
                          'GPT-5',
                          'GPT-5 Mini',
                          'o4-mini',
                        ].map((m) => PopupMenuItem(value: m, child: Text(m))),
                        const PopupMenuDivider(),
                        const PopupMenuItem(
                          enabled: false,
                          child: Text(
                            'Reasoning',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                        ...[
                          'Low',
                          'Medium',
                          'High',
                        ].map((r) => PopupMenuItem(value: r, child: Text(r))),
                        const PopupMenuDivider(),
                        const PopupMenuItem(
                          enabled: false,
                          child: Text(
                            'Access Mode',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                        ...AccessMode.values.map(
                          (a) => PopupMenuItem(
                            value: a,
                            child: Text(_accessModeChipLabel(a)),
                          ),
                        ),
                      ];
                    },
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: AppTheme.surfaceZinc800.withOpacity(0.86),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: Colors.white.withOpacity(0.06)),
                  ),
                  child: TextField(
                    key: const Key('turn-composer-input'),
                    controller: composerController,
                    enabled: canSubmitComposer,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.newline,
                    style: const TextStyle(
                      color: AppTheme.textMain,
                      fontSize: 15,
                    ),
                    decoration: InputDecoration(
                      hintText: isTurnActive
                          ? 'Guide the agent...'
                          : 'Message Codex...',
                      hintStyle: const TextStyle(color: AppTheme.textSubtle),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 16,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 56,
                height: 56,
                child: ElevatedButton(
                  key: const Key('turn-composer-submit'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: showStopAction
                        ? (canRunPrimaryAction
                              ? AppTheme.rose
                              : AppTheme.rose.withOpacity(0.35))
                        : (canRunPrimaryAction ? Colors.white : Colors.white24),
                    foregroundColor: showStopAction
                        ? Colors.white
                        : Colors.black,
                    padding: EdgeInsets.zero,
                    elevation: 0,
                    shape: const CircleBorder(),
                  ),
                  onPressed: canRunPrimaryAction
                      ? () async {
                          if (showStopAction) {
                            await onInterruptActiveTurn();
                            return;
                          }
                          final success = await onSubmitComposer(
                            composerController.text,
                          );
                          if (success) {
                            composerController.clear();
                          }
                        }
                      : null,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    child: isComposerMutationInFlight
                        ? const SizedBox.square(
                            key: ValueKey('composer-loading'),
                            dimension: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.black,
                            ),
                          )
                        : isInterruptMutationInFlight
                        ? const SizedBox.square(
                            key: ValueKey('interrupt-loading'),
                            dimension: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : PhosphorIcon(
                            showStopAction
                                ? PhosphorIcons.stop()
                                : PhosphorIcons.arrowUp(),
                            key: ValueKey(showStopAction ? 'stop' : 'send'),
                            size: 24,
                            color: showStopAction ? Colors.white : Colors.black,
                          ),
                  ),
                ),
              ),
            ],
          ),
          if (trustedBridge == null) ...[
            const SizedBox(height: 8),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Pair with a Mac to change access mode from here.',
                style: TextStyle(color: AppTheme.textSubtle, fontSize: 12),
              ),
            ),
          ],
          if (accessModeErrorMessage != null) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                accessModeErrorMessage!,
                style: const TextStyle(color: AppTheme.rose, fontSize: 12),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ComposerImagePreview extends StatelessWidget {
  const _ComposerImagePreview({required this.image, required this.onRemove});

  final XFile image;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: SizedBox(
            width: 74,
            height: 74,
            child: Image.file(
              File(image.path),
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => Container(
                color: AppTheme.surfaceZinc800,
                alignment: Alignment.center,
                child: PhosphorIcon(
                  PhosphorIcons.imageBroken(),
                  color: AppTheme.textSubtle,
                ),
              ),
            ),
          ),
        ),
        Positioned(
          top: 4,
          right: 4,
          child: GestureDetector(
            onTap: onRemove,
            child: Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.72),
                shape: BoxShape.circle,
              ),
              child: PhosphorIcon(
                PhosphorIcons.x(),
                size: 14,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

String _accessModeChipLabel(AccessMode value) {
  switch (value) {
    case AccessMode.readOnly:
      return 'Read-only';
    case AccessMode.controlWithApprovals:
      return 'Approvals';
    case AccessMode.fullControl:
      return 'Full access';
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
              style: TextStyle(
                color: AppTheme.textMain,
                fontWeight: FontWeight.w600,
                fontSize: 18,
              ),
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
                color: gitControls.hasDirtyWorkingTree
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
                    controller: gitBranchController,
                    enabled: gitControls.canRunGitMutations,
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
                  onPressed: gitControls.canRunGitMutations
                      ? () async {
                          final success = await onSwitchBranch(
                            gitBranchController.text,
                          );
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
    // Complex approval widgets adapted to match the dark theme
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppTheme.amber.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppTheme.amber.withOpacity(0.2)),
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

class _ThreadActivityCard extends StatelessWidget {
  const _ThreadActivityCard({required this.item, this.exploration});

  final ThreadActivityItem item;
  final _ExplorationSummary? exploration;

  @override
  Widget build(BuildContext context) {
    final parsedContent = item.parsedCommandOutput;

    if (parsedContent != null) {
      if (parsedContent.isStatusOnlyFileList ||
          _isHiddenInternalToolCommand(parsedContent)) {
        return const SizedBox.shrink();
      }
      if (parsedContent.hasDiffBlock) {
        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: _CollapsibleFileChangeCard(item: item, parsed: parsedContent),
        );
      } else {
        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: _CollapsibleTerminalCard(
            item: item,
            parsed: parsedContent,
            exploration: exploration,
          ),
        );
      }
    }

    if (item.type == ThreadActivityItemType.assistantOutput ||
        item.type == ThreadActivityItemType.userPrompt) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: _ChatMessageCard(item: item),
      );
    }

    Color borderColor;
    Color iconColor;
    PhosphorIcon icon;

    switch (item.type) {
      case ThreadActivityItemType.approvalRequest:
        borderColor = AppTheme.amber.withOpacity(0.3);
        iconColor = AppTheme.amber;
        icon = PhosphorIcon(
          PhosphorIcons.shieldWarning(),
          color: iconColor,
          size: 16,
        );
        break;
      case ThreadActivityItemType.securityEvent:
        borderColor = AppTheme.rose.withOpacity(0.3);
        iconColor = AppTheme.rose;
        icon = PhosphorIcon(
          PhosphorIcons.warning(),
          color: iconColor,
          size: 16,
        );
        break;
      case ThreadActivityItemType.fileChange:
        borderColor = Colors.white.withOpacity(0.1);
        iconColor = AppTheme.textSubtle;
        icon = PhosphorIcon(
          PhosphorIcons.fileCode(),
          color: iconColor,
          size: 16,
        );
        break;
      case ThreadActivityItemType.planUpdate:
        borderColor = AppTheme.emerald.withOpacity(0.3);
        iconColor = AppTheme.emerald;
        icon = PhosphorIcon(
          PhosphorIcons.listChecks(),
          color: iconColor,
          size: 16,
        );
        break;
      default:
        borderColor = Colors.white.withOpacity(0.1);
        iconColor = AppTheme.textSubtle;
        icon = PhosphorIcon(
          PhosphorIcons.lightning(),
          color: iconColor,
          size: 16,
        );
        break;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surfaceZinc800.withOpacity(0.3),
        border: Border(left: BorderSide(color: borderColor, width: 3)),
        borderRadius: const BorderRadius.only(
          topRight: Radius.circular(12),
          bottomRight: Radius.circular(12),
        ),
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
                  style: GoogleFonts.jetBrainsMono(
                    color: iconColor,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                item.occurredAt,
                style: GoogleFonts.jetBrainsMono(
                  color: AppTheme.textSubtle,
                  fontSize: 10,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SelectableText(
            item.body,
            style: const TextStyle(color: AppTheme.textMain, fontSize: 14),
          ),
        ],
      ),
    );
  }
}

bool _isHiddenInternalToolCommand(ParsedCommandOutput parsed) {
  final normalizedCommand = parsed.command?.trim().toLowerCase();
  if (normalizedCommand != null && normalizedCommand.isNotEmpty) {
    return false;
  }

  final normalizedBody = parsed.outputBody.trim().toLowerCase();
  return _hiddenInternalToolCommands.contains(normalizedBody);
}

const Set<String> _hiddenInternalToolCommands = <String>{
  'apply_patch',
  'browser_click',
  'browser_close',
  'browser_console_messages',
  'browser_drag',
  'browser_evaluate',
  'browser_file_upload',
  'browser_fill_form',
  'browser_handle_dialog',
  'browser_hover',
  'browser_install',
  'browser_navigate',
  'browser_navigate_back',
  'browser_network_requests',
  'browser_press_key',
  'browser_resize',
  'browser_run_code',
  'browser_select_option',
  'browser_snapshot',
  'browser_tabs',
  'browser_take_screenshot',
  'browser_type',
  'browser_wait_for',
  'close_agent',
  'exec_command',
  'list_mcp_resource_templates',
  'list_mcp_resources',
  'read_mcp_resource',
  'read_thread_terminal',
  'request_user_input',
  'resume_agent',
  'send_input',
  'spawn_agent',
  'update_plan',
  'wait_agent',
  'write_stdin',
};

class _ChatMessageCard extends StatelessWidget {
  const _ChatMessageCard({required this.item});
  final ThreadActivityItem item;

  @override
  Widget build(BuildContext context) {
    final isUser = item.type == ThreadActivityItemType.userPrompt;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: isUser
          ? BoxDecoration(
              color: AppTheme.surfaceZinc800.withOpacity(0.4),
              borderRadius: BorderRadius.circular(16),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isUser) ...[
            Row(
              children: [
                PhosphorIcon(
                  PhosphorIcons.user(),
                  color: AppTheme.emerald,
                  size: 14,
                ),
                const SizedBox(width: 8),
                Text(
                  'User',
                  style: GoogleFonts.jetBrainsMono(
                    color: AppTheme.emerald,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
          ],
          _ThreadMessageBody(
            body: item.body,
            imageUrls: item.messageImageUrls,
            textStyle: TextStyle(
              color: isUser
                  ? AppTheme.textMain
                  : AppTheme.textMain.withOpacity(0.9),
              fontSize: 14,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _CollapsibleTerminalCard extends StatefulWidget {
  const _CollapsibleTerminalCard({
    required this.item,
    required this.parsed,
    this.exploration,
  });
  final ThreadActivityItem item;
  final ParsedCommandOutput parsed;
  final _ExplorationSummary? exploration;

  @override
  State<_CollapsibleTerminalCard> createState() =>
      _CollapsibleTerminalCardState();
}

class _CollapsibleTerminalCardState extends State<_CollapsibleTerminalCard> {
  bool _isExpanded = false;
  bool _isExploredFilesExpanded = true;

  @override
  Widget build(BuildContext context) {
    final commandStr = widget.parsed.terminalDisplayTitle;
    final outputBody = widget.parsed.terminalDisplayBody;
    final isSuccess = widget.parsed.isSuccess;
    final isBackgroundTerminal =
        widget.parsed.backgroundTerminalSummary != null;
    final exploration = widget.exploration;
    final hasExploration = exploration != null;
    final workedForLabel = _workedForLabel(widget.parsed.wallTimeSeconds);
    final cardDecoration = isBackgroundTerminal
        ? BoxDecoration(
            color: AppTheme.surfaceZinc900.withOpacity(0.55),
            borderRadius: BorderRadius.circular(10),
          )
        : BoxDecoration(
            color: AppTheme.background,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white.withOpacity(0.08)),
          );

    return Container(
      decoration: cardDecoration,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header (always visible)
          InkWell(
            onTap: () => setState(() => _isExpanded = !_isExpanded),
            borderRadius: BorderRadius.circular(isBackgroundTerminal ? 10 : 12),
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                12,
                isBackgroundTerminal ? 14 : 12,
                12,
                isBackgroundTerminal ? 14 : 12,
              ),
              child: Row(
                children: [
                  PhosphorIcon(
                    PhosphorIcons.terminalWindow(),
                    color: isBackgroundTerminal
                        ? AppTheme.textMuted
                        : AppTheme.textSubtle,
                    size: isBackgroundTerminal ? 15 : 16,
                  ),
                  SizedBox(width: isBackgroundTerminal ? 12 : 8),
                  if (!isBackgroundTerminal) ...[
                    Text(
                      '\$',
                      style: GoogleFonts.jetBrainsMono(
                        color: AppTheme.textMuted,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  Expanded(
                    child: Text(
                      commandStr,
                      key: isBackgroundTerminal
                          ? const Key('thread-terminal-background-summary')
                          : null,
                      style: isBackgroundTerminal
                          ? const TextStyle(
                              color: AppTheme.textMain,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              height: 1.25,
                            )
                          : GoogleFonts.jetBrainsMono(
                              color: AppTheme.textMain,
                              fontSize: 13,
                            ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (widget.parsed.exitCode != null)
                    Icon(
                      isSuccess
                          ? Icons.check_circle_rounded
                          : Icons.cancel_rounded,
                      color: isSuccess ? AppTheme.emerald : AppTheme.rose,
                      size: 16,
                    ),
                  const SizedBox(width: 8),
                  PhosphorIcon(
                    _isExpanded
                        ? PhosphorIcons.caretUp()
                        : PhosphorIcons.caretDown(),
                    color: AppTheme.textSubtle,
                    size: 16,
                  ),
                ],
              ),
            ),
          ),

          // Collapsible Output
          if (_isExpanded && outputBody.isNotEmpty) ...[
            Divider(
              height: 1,
              color: isBackgroundTerminal
                  ? Colors.white.withOpacity(0.05)
                  : Colors.white10,
            ),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isBackgroundTerminal
                    ? Colors.transparent
                    : Colors.black.withOpacity(0.2),
                borderRadius: const BorderRadius.only(
                  bottomLeft: Radius.circular(12),
                  bottomRight: Radius.circular(12),
                ),
              ),
              child: SelectableText(
                outputBody,
                key: isBackgroundTerminal
                    ? const Key('thread-terminal-background-details')
                    : null,
                style: GoogleFonts.jetBrainsMono(
                  color: isBackgroundTerminal
                      ? AppTheme.textSubtle
                      : AppTheme.textMuted,
                  fontSize: isBackgroundTerminal ? 11.5 : 12,
                  height: 1.45,
                ),
              ),
            ),
          ],
          if (workedForLabel != null) ...[
            Divider(
              height: 1,
              color: isBackgroundTerminal
                  ? Colors.white.withOpacity(0.05)
                  : Colors.white10,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Container(
                      height: 1,
                      color: Colors.white.withOpacity(0.06),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: Text(
                      workedForLabel,
                      key: const Key('thread-worked-for-summary'),
                      style: TextStyle(
                        color: AppTheme.textMuted,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Container(
                      height: 1,
                      color: Colors.white.withOpacity(0.06),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (hasExploration) ...[
            Divider(
              height: 1,
              color: isBackgroundTerminal
                  ? Colors.white.withOpacity(0.05)
                  : Colors.white10,
            ),
            InkWell(
              onTap: () => setState(
                () => _isExploredFilesExpanded = !_isExploredFilesExpanded,
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                child: Row(
                  children: [
                    Text(
                      exploration.label,
                      key: const Key('thread-explored-files-summary'),
                      style: TextStyle(
                        color: isBackgroundTerminal
                            ? AppTheme.textMuted
                            : AppTheme.textSubtle,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(width: 8),
                    PhosphorIcon(
                      _isExploredFilesExpanded
                          ? PhosphorIcons.caretDown()
                          : PhosphorIcons.caretRight(),
                      color: AppTheme.textSubtle,
                      size: 14,
                    ),
                  ],
                ),
              ),
            ),
            if (_isExploredFilesExpanded)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: exploration.files
                      .map(
                        (file) => Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            file,
                            style: TextStyle(
                              color: isBackgroundTerminal
                                  ? AppTheme.textMuted
                                  : AppTheme.textMuted,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      )
                      .toList(growable: false),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _ExploredFilesCard extends StatefulWidget {
  const _ExploredFilesCard({required this.exploration});

  final _ExplorationSummary exploration;

  @override
  State<_ExploredFilesCard> createState() => _ExploredFilesCardState();
}

class _ExploredFilesCardState extends State<_ExploredFilesCard> {
  bool _isExpanded = true;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _isExpanded = !_isExpanded),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Text(
                    widget.exploration.label,
                    style: const TextStyle(
                      color: AppTheme.textSubtle,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(width: 8),
                  PhosphorIcon(
                    _isExpanded
                        ? PhosphorIcons.caretDown()
                        : PhosphorIcons.caretRight(),
                    color: AppTheme.textSubtle,
                    size: 14,
                  ),
                ],
              ),
            ),
          ),
          if (_isExpanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: widget.exploration.files
                    .map(
                      (file) => Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          file,
                          style: const TextStyle(
                            color: AppTheme.textMuted,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    )
                    .toList(growable: false),
              ),
            ),
        ],
      ),
    );
  }
}

class _CollapsibleFileChangeCard extends StatefulWidget {
  const _CollapsibleFileChangeCard({required this.item, required this.parsed});
  final ThreadActivityItem item;
  final ParsedCommandOutput parsed;

  @override
  State<_CollapsibleFileChangeCard> createState() =>
      _CollapsibleFileChangeCardState();
}

class _CollapsibleFileChangeCardState
    extends State<_CollapsibleFileChangeCard> {
  bool _isExpanded = false;

  @override
  Widget build(BuildContext context) {
    final diffDocument = widget.parsed.diffDocument;
    final fileCount = diffDocument?.files.length ?? 0;
    final fileName = widget.parsed.diffPath ?? 'unknown file';
    final adds = widget.parsed.diffAdditions;
    final dels = widget.parsed.diffDeletions;
    final primaryChangeType = fileCount == 1
        ? diffDocument?.files.first.changeType
        : null;
    final titlePrefix = _titleForSummary(
      fileCount: fileCount,
      changeType: primaryChangeType,
    );

    return Container(
      decoration: BoxDecoration(
        color: AppTheme.surfaceZinc800.withOpacity(0.4),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header (always visible)
          InkWell(
            onTap: () => setState(() => _isExpanded = !_isExpanded),
            key: Key('thread-file-change-toggle-$fileName'),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  PhosphorIcon(
                    PhosphorIcons.fileCode(),
                    color: AppTheme.textSubtle,
                    size: 16,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: RichText(
                      text: TextSpan(
                        style: const TextStyle(
                          fontSize: 13,
                          color: AppTheme.textMain,
                        ),
                        children: [
                          TextSpan(text: titlePrefix),
                          if (fileCount <= 1) ...[
                            const TextSpan(text: ' '),
                            TextSpan(
                              text: fileName,
                              style: GoogleFonts.jetBrainsMono(
                                color: AppTheme.textMain,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ] else
                            TextSpan(
                              text: ' ($fileCount)',
                              style: GoogleFonts.jetBrainsMono(
                                color: AppTheme.textMuted,
                              ),
                            ),
                          TextSpan(
                            text: '  +$adds',
                            style: GoogleFonts.jetBrainsMono(
                              color: AppTheme.emerald,
                            ),
                          ),
                          TextSpan(
                            text: ' -$dels',
                            style: GoogleFonts.jetBrainsMono(
                              color: AppTheme.rose,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  PhosphorIcon(
                    _isExpanded
                        ? PhosphorIcons.caretUp()
                        : PhosphorIcons.caretDown(),
                    color: AppTheme.textSubtle,
                    size: 16,
                  ),
                ],
              ),
            ),
          ),

          // Collapsible Diff Block
          if (_isExpanded) ...[
            const Divider(height: 1, color: Colors.white10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.3),
                borderRadius: const BorderRadius.only(
                  bottomLeft: Radius.circular(12),
                  bottomRight: Radius.circular(12),
                ),
              ),
              child: diffDocument == null
                  ? _ThreadCodeBlockViewer(
                      code: widget.parsed.outputBody,
                      languageHint: _CodeLanguageResolver.fromFilePath(
                        widget.parsed.diffPath,
                      ),
                    )
                  : _ThreadDiffViewer(document: diffDocument),
            ),
          ],
        ],
      ),
    );
  }

  String _titleForSummary({
    required int fileCount,
    required ParsedDiffChangeType? changeType,
  }) {
    if (fileCount > 1) {
      return 'Edited files';
    }

    switch (changeType) {
      case ParsedDiffChangeType.added:
        return 'Created file';
      case ParsedDiffChangeType.deleted:
        return 'Deleted file';
      case ParsedDiffChangeType.modified:
      case null:
        return 'Edited file';
    }
  }
}

class _ThreadDiffViewer extends StatelessWidget {
  const _ThreadDiffViewer({required this.document});

  final ParsedDiffDocument document;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_ThreadCodeHighlighterSet>(
      future: _ThreadCodeHighlighterSet.load(),
      builder: (context, snapshot) {
        final highlighterSet = snapshot.data;
        final fileWidgets = <Widget>[];

        for (var index = 0; index < document.files.length; index++) {
          if (index > 0) {
            fileWidgets.add(const SizedBox(height: 12));
          }
          fileWidgets.add(
            _ThreadDiffFileSection(
              file: document.files[index],
              highlighterSet: highlighterSet,
            ),
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: fileWidgets,
        );
      },
    );
  }
}

class _ThreadDiffFileSection extends StatelessWidget {
  const _ThreadDiffFileSection({
    required this.file,
    required this.highlighterSet,
  });

  final ParsedDiffFile file;
  final _ThreadCodeHighlighterSet? highlighterSet;

  @override
  Widget build(BuildContext context) {
    final language = _CodeLanguageResolver.fromFilePath(file.path);
    final fileName = _CodeLanguageResolver.displayName(file.path) ?? file.path;
    final changeLabel = _labelForChangeType(file.changeType);

    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.25),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withOpacity(0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.03),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(10),
                topRight: Radius.circular(10),
              ),
            ),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  fileName,
                  key: Key('thread-diff-file-$fileName'),
                  style: GoogleFonts.jetBrainsMono(
                    color: AppTheme.textMain,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  '+${file.additions}',
                  style: GoogleFonts.jetBrainsMono(
                    color: AppTheme.emerald,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  '-${file.deletions}',
                  style: GoogleFonts.jetBrainsMono(
                    color: AppTheme.rose,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.surfaceZinc800.withOpacity(0.8),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: Colors.white.withOpacity(0.08)),
                  ),
                  child: Text(
                    changeLabel,
                    style: GoogleFonts.jetBrainsMono(
                      color: AppTheme.textSubtle,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: file.lines
                    .where((line) => line.kind != ParsedDiffLineKind.hunk)
                    .map(
                      (line) => _ThreadDiffLineRow(
                        line: line,
                        language: language,
                        highlighterSet: highlighterSet,
                      ),
                    )
                    .toList(growable: false),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _labelForChangeType(ParsedDiffChangeType changeType) {
    switch (changeType) {
      case ParsedDiffChangeType.added:
        return 'Added';
      case ParsedDiffChangeType.deleted:
        return 'Deleted';
      case ParsedDiffChangeType.modified:
        return 'Modified';
    }
  }
}

class _ThreadDiffLineRow extends StatelessWidget {
  const _ThreadDiffLineRow({
    required this.line,
    required this.language,
    required this.highlighterSet,
  });

  final ParsedDiffLine line;
  final String? language;
  final _ThreadCodeHighlighterSet? highlighterSet;

  @override
  Widget build(BuildContext context) {
    final backgroundColor = _backgroundColorForLine(line.kind);
    final accentColor = _accentColorForLine(line.kind);
    final textStyle = GoogleFonts.jetBrainsMono(
      color: _textColorForLine(line.kind),
      fontSize: 11.5,
      height: 1.4,
    );

    return Container(
      constraints: const BoxConstraints(minWidth: 420),
      color: backgroundColor,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(width: 3, height: 24, color: accentColor),
          _DiffLineNumberCell(number: line.oldLineNumber),
          _DiffLineNumberCell(number: line.newLineNumber),
          Container(
            width: 1,
            height: 24,
            color: Colors.white.withOpacity(0.06),
          ),
          const SizedBox(width: 10),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 8),
            child: line.kind == ParsedDiffLineKind.hunk
                ? Text(
                    line.text,
                    style: GoogleFonts.jetBrainsMono(
                      color: AppTheme.textSubtle,
                      fontSize: 10.5,
                      height: 1.4,
                    ),
                  )
                : RichText(text: _highlightedLine(textStyle)),
          ),
        ],
      ),
    );
  }

  TextSpan _highlightedLine(TextStyle textStyle) {
    final highlighted = language == null
        ? null
        : highlighterSet?.highlight(language!, line.text);
    return highlighted == null
        ? TextSpan(text: line.text, style: textStyle)
        : TextSpan(style: textStyle, children: [highlighted]);
  }

  Color _backgroundColorForLine(ParsedDiffLineKind kind) {
    switch (kind) {
      case ParsedDiffLineKind.addition:
        return AppTheme.emerald.withOpacity(0.12);
      case ParsedDiffLineKind.deletion:
        return AppTheme.rose.withOpacity(0.14);
      case ParsedDiffLineKind.hunk:
        return Colors.white.withOpacity(0.04);
      case ParsedDiffLineKind.context:
        return Colors.transparent;
    }
  }

  Color _accentColorForLine(ParsedDiffLineKind kind) {
    switch (kind) {
      case ParsedDiffLineKind.addition:
        return AppTheme.emerald.withOpacity(0.85);
      case ParsedDiffLineKind.deletion:
        return AppTheme.rose.withOpacity(0.85);
      case ParsedDiffLineKind.hunk:
        return Colors.white.withOpacity(0.18);
      case ParsedDiffLineKind.context:
        return Colors.transparent;
    }
  }

  Color _textColorForLine(ParsedDiffLineKind kind) {
    switch (kind) {
      case ParsedDiffLineKind.addition:
      case ParsedDiffLineKind.deletion:
      case ParsedDiffLineKind.context:
        return AppTheme.textMain;
      case ParsedDiffLineKind.hunk:
        return AppTheme.textSubtle;
    }
  }
}

class _DiffLineNumberCell extends StatelessWidget {
  const _DiffLineNumberCell({required this.number});

  final int? number;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 46,
      child: Padding(
        padding: const EdgeInsets.only(top: 4, right: 8),
        child: Text(
          number?.toString() ?? '',
          textAlign: TextAlign.right,
          style: GoogleFonts.jetBrainsMono(
            color: AppTheme.textSubtle,
            fontSize: 10.5,
            height: 1.4,
          ),
        ),
      ),
    );
  }
}

class _ThreadMessageBody extends StatelessWidget {
  const _ThreadMessageBody({
    required this.body,
    required this.imageUrls,
    required this.textStyle,
  });

  final String body;
  final List<String> imageUrls;
  final TextStyle textStyle;

  @override
  Widget build(BuildContext context) {
    final segments = _MessageBodyParser.parse(body);
    if (segments.length == 1 && !segments.first.isCode && imageUrls.isEmpty) {
      return SelectableText(segments.first.content, style: textStyle);
    }

    final children = <Widget>[];
    if (body.isNotEmpty) {
      for (var i = 0; i < segments.length; i++) {
        final segment = segments[i];
        if (segment.isCode) {
          children.add(
            _ThreadCodeBlockViewer(
              code: segment.content,
              languageHint: segment.languageHint,
              filePathHint: segment.filePathHint,
            ),
          );
        } else if (segment.content.isNotEmpty) {
          children.add(SelectableText(segment.content, style: textStyle));
        }
        if (i < segments.length - 1) {
          children.add(const SizedBox(height: 10));
        }
      }
    }

    for (var i = 0; i < imageUrls.length; i++) {
      if (children.isNotEmpty) {
        children.add(const SizedBox(height: 10));
      }
      children.add(_ThreadMessageImage(imageUrl: imageUrls[i], index: i));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }
}

class _ThreadMessageImage extends StatelessWidget {
  const _ThreadMessageImage({required this.imageUrl, required this.index});

  final String imageUrl;
  final int index;

  @override
  Widget build(BuildContext context) {
    final imageWidget = _buildImage();
    if (imageWidget == null) {
      return const SizedBox.shrink();
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Container(
        key: Key('thread-message-image-$index'),
        constraints: const BoxConstraints(maxHeight: 320),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.25),
          border: Border.all(color: Colors.white.withOpacity(0.08)),
          borderRadius: BorderRadius.circular(12),
        ),
        child: imageWidget,
      ),
    );
  }

  Widget? _buildImage() {
    final trimmed = imageUrl.trim();
    if (trimmed.isEmpty) {
      return null;
    }

    final uri = Uri.tryParse(trimmed);
    if (uri != null && uri.scheme == 'data') {
      final bytes = uri.data?.contentAsBytes();
      if (bytes == null || bytes.isEmpty) {
        return null;
      }
      return Image.memory(bytes, fit: BoxFit.contain, gaplessPlayback: true);
    }

    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return Image.network(
        trimmed,
        fit: BoxFit.contain,
        errorBuilder: (context, error, stackTrace) => const SizedBox.shrink(),
      );
    }

    return null;
  }
}

class _ThreadCodeBlockViewer extends StatelessWidget {
  const _ThreadCodeBlockViewer({
    required this.code,
    this.languageHint,
    this.filePathHint,
  });

  final String code;
  final String? languageHint;
  final String? filePathHint;

  @override
  Widget build(BuildContext context) {
    final lineCount = '\n'.allMatches(code).length + 1;
    final digits = lineCount.toString().length;
    final gutterWidth = ((digits * 10) + 24).toDouble();
    final language =
        _CodeLanguageResolver.normalize(languageHint) ??
        _CodeLanguageResolver.fromFilePath(filePathHint);
    final fileName = _CodeLanguageResolver.displayName(filePathHint);
    final languageLabel = _CodeLanguageResolver.label(language);
    final showHeader = fileName != null || languageLabel != null;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.35),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showHeader)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.03),
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(10),
                  topRight: Radius.circular(10),
                ),
              ),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (fileName != null)
                    Text(
                      fileName,
                      key: Key('thread-code-file-$fileName'),
                      style: GoogleFonts.jetBrainsMono(
                        color: AppTheme.textMain,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  if (languageLabel != null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: AppTheme.surfaceZinc800.withOpacity(0.9),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.08),
                        ),
                      ),
                      child: Text(
                        languageLabel,
                        key: Key('thread-code-language-$language'),
                        style: GoogleFonts.jetBrainsMono(
                          color: AppTheme.textSubtle,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          FutureBuilder<_ThreadCodeHighlighterSet>(
            future: _ThreadCodeHighlighterSet.load(),
            builder: (context, snapshot) {
              final highlighted = language == null
                  ? null
                  : snapshot.data?.highlight(language, code);
              final codeStyle = GoogleFonts.jetBrainsMono(
                color: AppTheme.textMuted,
                fontSize: 11.5,
                height: 1.4,
              );

              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: gutterWidth,
                      child: Text(
                        _lineNumbers(lineCount),
                        textAlign: TextAlign.right,
                        style: GoogleFonts.jetBrainsMono(
                          color: AppTheme.textSubtle,
                          fontSize: 10.5,
                          height: 1.4,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Container(
                      width: 1,
                      height: 18.0 * lineCount,
                      color: Colors.white.withOpacity(0.08),
                    ),
                    const SizedBox(width: 12),
                    SelectableText.rich(
                      highlighted == null
                          ? TextSpan(text: code, style: codeStyle)
                          : TextSpan(style: codeStyle, children: [highlighted]),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  String _lineNumbers(int lineCount) {
    final buffer = StringBuffer();
    for (var line = 1; line <= lineCount; line++) {
      buffer.writeln(line);
    }
    return buffer.toString().trimRight();
  }
}

class _ThreadCodeHighlighterSet {
  _ThreadCodeHighlighterSet._({required this.darkTheme});

  static final Future<void> _init = Highlighter.initialize(
    _CodeLanguageResolver.supportedLanguages.toList(growable: false),
  );
  static Future<HighlighterTheme>? _darkThemeFuture;
  static final Map<String, Highlighter> _highlighters = <String, Highlighter>{};

  static Future<_ThreadCodeHighlighterSet> load() async {
    await _init;
    final darkTheme = await (_darkThemeFuture ??=
        HighlighterTheme.loadDarkTheme());
    return _ThreadCodeHighlighterSet._(darkTheme: darkTheme);
  }

  final HighlighterTheme darkTheme;

  TextSpan highlight(String language, String code) {
    final highlighter = _highlighters.putIfAbsent(
      language,
      () => Highlighter(language: language, theme: darkTheme),
    );
    return highlighter.highlight(code);
  }
}

class _MessageBodyParser {
  static final RegExp _codeFencePattern = RegExp(
    r'```([^\n`]*)\n([\s\S]*?)```',
    multiLine: true,
  );

  static List<_MessageSegment> parse(String body) {
    final matches = _codeFencePattern.allMatches(body).toList(growable: false);
    if (matches.isEmpty) {
      return <_MessageSegment>[_MessageSegment.text(body)];
    }

    final segments = <_MessageSegment>[];
    var start = 0;

    for (final match in matches) {
      final leadingText = body.substring(start, match.start);
      if (match.start > start) {
        segments.add(_MessageSegment.text(leadingText));
      }

      final rawLanguage = match.group(1)?.trim();
      final code = (match.group(2) ?? '').trimRight();
      final filePathHint = _CodeLanguageResolver.filePathForCodeBlock(
        rawFenceInfo: rawLanguage,
        leadingText: leadingText,
      );
      final languageHint = _CodeLanguageResolver.resolveLanguage(
        rawFenceInfo: rawLanguage,
        filePathHint: filePathHint,
      );
      segments.add(
        _MessageSegment.code(code, languageHint, filePathHint: filePathHint),
      );
      start = match.end;
    }

    if (start < body.length) {
      segments.add(_MessageSegment.text(body.substring(start)));
    }

    return segments;
  }
}

class _MessageSegment {
  const _MessageSegment._({
    required this.content,
    required this.isCode,
    this.languageHint,
    this.filePathHint,
  });

  factory _MessageSegment.text(String content) {
    return _MessageSegment._(content: content, isCode: false);
  }

  factory _MessageSegment.code(
    String content,
    String? languageHint, {
    String? filePathHint,
  }) {
    return _MessageSegment._(
      content: content,
      isCode: true,
      languageHint: languageHint,
      filePathHint: filePathHint,
    );
  }

  final String content;
  final bool isCode;
  final String? languageHint;
  final String? filePathHint;
}

class _CodeLanguageResolver {
  static const Set<String> supportedLanguages = <String>{
    'css',
    'dart',
    'go',
    'html',
    'java',
    'javascript',
    'json',
    'kotlin',
    'python',
    'rust',
    'sql',
    'swift',
    'typescript',
    'yaml',
  };

  static String? fromFilePath(String? path) {
    if (path == null || path.trim().isEmpty) {
      return null;
    }
    final normalized = path.toLowerCase().trim();
    if (normalized.endsWith('.dart')) {
      return 'dart';
    }
    if (normalized.endsWith('.ts') || normalized.endsWith('.tsx')) {
      return 'typescript';
    }
    if (normalized.endsWith('.js') ||
        normalized.endsWith('.jsx') ||
        normalized.endsWith('.mjs') ||
        normalized.endsWith('.cjs')) {
      return 'javascript';
    }
    if (normalized.endsWith('.json')) {
      return 'json';
    }
    if (normalized.endsWith('.yaml') || normalized.endsWith('.yml')) {
      return 'yaml';
    }
    if (normalized.endsWith('.kt') || normalized.endsWith('.kts')) {
      return 'kotlin';
    }
    if (normalized.endsWith('.swift')) {
      return 'swift';
    }
    if (normalized.endsWith('.java')) {
      return 'java';
    }
    if (normalized.endsWith('.rs')) {
      return 'rust';
    }
    if (normalized.endsWith('.py')) {
      return 'python';
    }
    if (normalized.endsWith('.go')) {
      return 'go';
    }
    if (normalized.endsWith('.sql')) {
      return 'sql';
    }
    if (normalized.endsWith('.css')) {
      return 'css';
    }
    if (normalized.endsWith('.html') || normalized.endsWith('.htm')) {
      return 'html';
    }
    return null;
  }

  static String? resolveLanguage({
    required String? rawFenceInfo,
    required String? filePathHint,
  }) {
    return normalize(rawFenceInfo) ??
        fromFilePath(rawFenceInfo) ??
        fromFilePath(filePathHint);
  }

  static String? filePathForCodeBlock({
    required String? rawFenceInfo,
    required String leadingText,
  }) {
    return _extractFilePath(rawFenceInfo) ?? _lastFilePathInText(leadingText);
  }

  static String? displayName(String? path) {
    if (path == null || path.trim().isEmpty) {
      return null;
    }
    final normalized = path.trim().replaceAll('\\', '/');
    final segments = normalized.split('/');
    return segments.isEmpty ? normalized : segments.last;
  }

  static String? label(String? language) {
    switch (language) {
      case 'css':
        return 'CSS';
      case 'dart':
        return 'Dart';
      case 'go':
        return 'Go';
      case 'html':
        return 'HTML';
      case 'java':
        return 'Java';
      case 'javascript':
        return 'JavaScript';
      case 'json':
        return 'JSON';
      case 'kotlin':
        return 'Kotlin';
      case 'python':
        return 'Python';
      case 'rust':
        return 'Rust';
      case 'sql':
        return 'SQL';
      case 'swift':
        return 'Swift';
      case 'typescript':
        return 'TypeScript';
      case 'yaml':
        return 'YAML';
      default:
        return null;
    }
  }

  static String? _extractFilePath(String? rawFenceInfo) {
    if (rawFenceInfo == null || rawFenceInfo.trim().isEmpty) {
      return null;
    }

    final trimmed = rawFenceInfo.trim();
    final directCandidates = <String>[
      trimmed,
      ...trimmed.split(RegExp(r'\s+')),
    ];
    for (final candidate in directCandidates) {
      final normalized = _normalizeFilePathCandidate(candidate);
      if (normalized != null && fromFilePath(normalized) != null) {
        return normalized;
      }
    }

    final namedValuePattern = RegExp(
      r'''(?:file|filename|path|title)\s*=\s*["']?([^"'\s}]+)["']?''',
      caseSensitive: false,
    );
    final match = namedValuePattern.firstMatch(trimmed);
    final normalized = _normalizeFilePathCandidate(match?.group(1));
    if (normalized == null || fromFilePath(normalized) == null) {
      return null;
    }
    return normalized;
  }

  static String? _lastFilePathInText(String text) {
    if (text.trim().isEmpty) {
      return null;
    }

    final recentText = text.length > 400
        ? text.substring(text.length - 400)
        : text;
    final pattern = RegExp(
      r'([~./A-Za-z0-9_-]+(?:/[~./A-Za-z0-9_-]+)*\.[A-Za-z0-9]+)',
    );

    String? lastSupportedPath;
    for (final match in pattern.allMatches(recentText)) {
      final normalized = _normalizeFilePathCandidate(match.group(1));
      if (normalized != null && fromFilePath(normalized) != null) {
        lastSupportedPath = normalized;
      }
    }
    return lastSupportedPath;
  }

  static String? _normalizeFilePathCandidate(String? value) {
    if (value == null) {
      return null;
    }
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return null;
    }

    final withoutQuotes = trimmed.replaceAll(
      RegExp(r'''^[`"']+|[`"']+$'''),
      '',
    );
    final withoutTrailingPunctuation = withoutQuotes.replaceAll(
      RegExp(r'[\s)\],:;]+$'),
      '',
    );
    if (withoutTrailingPunctuation.isEmpty ||
        !withoutTrailingPunctuation.contains('.')) {
      return null;
    }

    return withoutTrailingPunctuation;
  }

  static String? normalize(String? raw) {
    if (raw == null) {
      return null;
    }
    final value = raw.trim().toLowerCase();
    if (value.isEmpty) {
      return null;
    }
    if (supportedLanguages.contains(value)) {
      return value;
    }

    switch (value) {
      case 'ts':
      case 'tsx':
        return 'typescript';
      case 'js':
      case 'jsx':
      case 'node':
        return 'javascript';
      case 'py':
        return 'python';
      case 'yml':
        return 'yaml';
      case 'md':
      case 'markdown':
      case 'diff':
      case 'patch':
      case 'txt':
      case 'text':
      case 'bash':
      case 'zsh':
      case 'shell':
      case 'sh':
        return null;
      default:
        return null;
    }
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
        color: AppTheme.rose.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.rose.withOpacity(0.3)),
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
        color: AppTheme.emerald.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.emerald.withOpacity(0.3)),
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
