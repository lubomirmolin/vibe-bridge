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
import 'package:codex_mobile_companion/features/threads/domain/thread_timeline_block.dart';
import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:codex_mobile_companion/foundation/theme/app_theme.dart';
import 'package:codex_mobile_companion/shared/widgets/badges.dart';
import 'package:codex_mobile_companion/shared/widgets/magnetic_button.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:syntax_highlight/syntax_highlight.dart';

part 'thread_detail_page_body.dart';
part 'thread_detail_page_composer.dart';
part 'thread_detail_page_header.dart';
part 'thread_detail_page_message.dart';
part 'thread_detail_page_timeline.dart';

class ThreadDetailPage extends ConsumerStatefulWidget {
  const ThreadDetailPage({
    super.key,
    required this.bridgeApiBaseUrl,
    required this.threadId,
    this.initialVisibleTimelineEntries = 80,
  });

  final String bridgeApiBaseUrl;
  final String threadId;
  final int initialVisibleTimelineEntries;

  @override
  ConsumerState<ThreadDetailPage> createState() => _ThreadDetailPageState();
}

class _ThreadDetailPageState extends ConsumerState<ThreadDetailPage> {
  static const double _historyPrefetchTriggerOffset = 160;
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
  late final FocusNode _composerFocusNode;
  late final TextEditingController _gitBranchController;
  late final ScrollController _timelineScrollController;
  late final ValueNotifier<bool> _isHeaderCollapsed;
  late final ValueNotifier<bool> _showNewMessagePill;
  final ImagePicker _imagePicker = ImagePicker();

  List<XFile> _attachedImages = const <XFile>[];
  String _selectedModel = _modelOptions.first;
  String _selectedReasoning = _reasoningOptions[1];
  bool _didInitialScrollToBottom = false;
  bool _isComposerFocused = false;
  bool _canLoadEarlierHistory = false;
  bool _isAutoLoadingEarlierHistory = false;
  Future<void> Function()? _loadEarlierHistory;

  double _lastScrollOffset = 0;
  double _scrollOffsetOnDirectionChange = 0;
  bool _isScrollingDown = false;

  @override
  void initState() {
    super.initState();
    _composerController = TextEditingController();
    _composerFocusNode = FocusNode();
    _gitBranchController = TextEditingController();
    _timelineScrollController = ScrollController();
    _isHeaderCollapsed = ValueNotifier(false);
    _showNewMessagePill = ValueNotifier(false);
    _composerFocusNode.addListener(_handleComposerFocusChange);
    _timelineScrollController.addListener(_onScroll);
  }

  void _handleComposerFocusChange() {
    if (_isComposerFocused == _composerFocusNode.hasFocus) {
      return;
    }
    setState(() {
      _isComposerFocused = _composerFocusNode.hasFocus;
    });
  }

  void _onScroll() {
    if (!_timelineScrollController.hasClients) return;

    final position = _timelineScrollController.position;
    final currentOffset = clampDouble(
      _timelineScrollController.offset,
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    final isCurrentlyScrollingDown = currentOffset > _lastScrollOffset;

    if (isCurrentlyScrollingDown != _isScrollingDown) {
      _isScrollingDown = isCurrentlyScrollingDown;
      _scrollOffsetOnDirectionChange = currentOffset;
    }

    final scrollDeltaSinceDirectionChange =
        currentOffset - _scrollOffsetOnDirectionChange;

    if (_isScrollingDown &&
        scrollDeltaSinceDirectionChange > 30 &&
        !_isHeaderCollapsed.value &&
        currentOffset > 100) {
      _isHeaderCollapsed.value = true;
    } else if (!_isScrollingDown &&
        scrollDeltaSinceDirectionChange < -30 &&
        _isHeaderCollapsed.value) {
      _isHeaderCollapsed.value = false;
    }

    _lastScrollOffset = currentOffset;

    final isNearBottom = position.maxScrollExtent - currentOffset < 120;
    if (isNearBottom && _showNewMessagePill.value) {
      _showNewMessagePill.value = false;
    }

    _maybeAutoLoadEarlierHistory();
  }

  void _maybeAutoLoadEarlierHistory() {
    if (!_timelineScrollController.hasClients ||
        !_canLoadEarlierHistory ||
        _isAutoLoadingEarlierHistory) {
      return;
    }

    final position = _timelineScrollController.position;
    if (position.pixels >
        position.minScrollExtent + _historyPrefetchTriggerOffset) {
      return;
    }

    final previousOffset = position.pixels;
    final previousMaxScrollExtent = position.maxScrollExtent;
    final loadEarlierHistory = _loadEarlierHistory;
    if (loadEarlierHistory == null) {
      return;
    }
    _isAutoLoadingEarlierHistory = true;
    loadEarlierHistory().whenComplete(() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _isAutoLoadingEarlierHistory = false;
        if (!mounted || !_timelineScrollController.hasClients) {
          return;
        }

        final nextPosition = _timelineScrollController.position;
        final insertedExtent =
            nextPosition.maxScrollExtent - previousMaxScrollExtent;
        if (insertedExtent <= 0) {
          return;
        }

        final compensatedOffset = clampDouble(
          previousOffset + insertedExtent,
          nextPosition.minScrollExtent,
          nextPosition.maxScrollExtent,
        );
        if ((nextPosition.pixels - compensatedOffset).abs() < 0.5) {
          return;
        }

        _timelineScrollController.jumpTo(compensatedOffset);
      });
    });
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
    _composerFocusNode
      ..removeListener(_handleComposerFocusChange)
      ..dispose();
    _gitBranchController.dispose();
    _timelineScrollController.removeListener(_onScroll);
    _timelineScrollController.dispose();
    _isHeaderCollapsed.dispose();
    _showNewMessagePill.dispose();
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

  void _scrollToTimelineBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_timelineScrollController.hasClients) return;
      final position = _timelineScrollController.position;
      _timelineScrollController.animateTo(
        position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
      );
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

    ref.listen(
      threadDetailControllerProvider(args).select(
        (s) => (
          s.items.length,
          s.items.isEmpty ? null : s.items.last.eventId,
          s.items.isEmpty ? null : s.items.last.body,
        ),
      ),
      (previous, next) {
        if (previous != null) {
          final lastVisibleItemChanged =
              next.$2 != previous.$2 || next.$3 != previous.$3;
          if (!lastVisibleItemChanged) {
            return;
          }

          final isNearBottom =
              !_timelineScrollController.hasClients ||
              (_timelineScrollController.position.maxScrollExtent -
                      _timelineScrollController.offset <
                  180);

          if (isNearBottom) {
            _scrollToTimelineBottom();
          } else {
            _showNewMessagePill.value = true;
          }
        }
      },
    );

    final threadApprovals = approvalsState.forThread(widget.threadId);
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
    _canLoadEarlierHistory = state.canLoadEarlierHistory;
    _loadEarlierHistory = controller.loadEarlierHistory;

    if (state.hasThread && !_didInitialScrollToBottom) {
      _scheduleInitialScrollToBottom();
    }

    Future<void> openGitBranchSheet() async {
      await _showGitBranchSheet(
        context,
        gitControls: gitControls,
        onSwitchBranch: (rawBranch) async {
          final accepted = await controller.switchBranch(rawBranch);
          await approvalsController.loadApprovals(showLoading: false);
          return accepted;
        },
      );
    }

    Future<void> openGitSyncSheet() async {
      await _showGitSyncSheet(
        context,
        gitControls: gitControls,
        onRefreshGitStatus: controller.refreshGitStatus,
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
      );
    }

    Future<void> changeAccessMode(AccessMode mode) async {
      final trustedBridge = pairingState.trustedBridge;
      if (trustedBridge == null) {
        return;
      }

      await deviceSettingsController.setAccessMode(
        accessMode: mode,
        trustedBridge: trustedBridge,
      );
    }

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Stack(
                children: [
                  _ThreadDetailBody(
                    state: state,
                    isReadOnlyMode: isReadOnlyMode,
                    controlsEnabled: controlsEnabled,
                    desktopIntegrationEnabled:
                        desktopIntegrationState.isEnabled,
                    onRetry: controller.loadThread,
                    onRetryReconnect: controller.retryReconnectCatchUp,
                    threadApprovals: threadApprovals,
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
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: _ThreadDetailHeader(
                      state: state,
                      hasPendingApprovals: threadApprovals.isNotEmpty,
                      gitControls: gitControls,
                      canOpenOnMac:
                          desktopIntegrationControlsEnabled &&
                          desktopIntegrationState.isEnabled &&
                          !state.isOpenOnMacInFlight,
                      onBackWhenLoaded: () => Navigator.of(context).maybePop(),
                      onBackWhenUnavailable: () => Navigator.of(context).pop(),
                      onOpenGitBranchSheet: openGitBranchSheet,
                      onOpenGitSyncSheet: openGitSyncSheet,
                      onOpenOnMac: controller.openOnMac,
                      isHeaderCollapsed: _isHeaderCollapsed,
                    ),
                  ),
                  if (state.thread != null)
                    Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      child: Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              AppTheme.background.withValues(alpha: 0.0),
                              AppTheme.background,
                              AppTheme.background,
                            ],
                            stops: const [0.0, 0.45, 1.0],
                          ),
                        ),
                        child: SafeArea(
                          top: false,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              ValueListenableBuilder<bool>(
                                valueListenable: _showNewMessagePill,
                                builder: (context, show, child) {
                                  return AnimatedSwitcher(
                                    duration: const Duration(milliseconds: 240),
                                    transitionBuilder: (child, animation) =>
                                        FadeTransition(
                                          opacity: animation,
                                          child: SlideTransition(
                                            position:
                                                Tween<Offset>(
                                                  begin: const Offset(0, 0.4),
                                                  end: Offset.zero,
                                                ).animate(
                                                  CurvedAnimation(
                                                    parent: animation,
                                                    curve: Curves.easeOutBack,
                                                  ),
                                                ),
                                            child: child,
                                          ),
                                        ),
                                    child: show
                                        ? Padding(
                                            padding: const EdgeInsets.only(
                                              top: 8,
                                            ),
                                            child: MagneticButton(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 18,
                                                    vertical: 10,
                                                  ),
                                              variant: MagneticButtonVariant
                                                  .secondary,
                                              onClick: () {
                                                _showNewMessagePill.value =
                                                    false;
                                                _jumpToTimelineBottom(
                                                  attempt: 0,
                                                );
                                              },
                                              child: Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  const Text(
                                                    'New messages',
                                                    style: TextStyle(
                                                      fontSize: 14,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                    ),
                                                  ),
                                                  const SizedBox(width: 8),
                                                  PhosphorIcon(
                                                    PhosphorIcons.arrowDown(),
                                                    size: 16,
                                                  ),
                                                ],
                                              ),
                                            ),
                                          )
                                        : const SizedBox.shrink(),
                                  );
                                },
                              ),
                              _PinnedTurnComposer(
                                composerController: _composerController,
                                composerFocusNode: _composerFocusNode,
                                isTurnActive: state.isTurnActive,
                                controlsEnabled: controlsEnabled,
                                isComposerMutationInFlight:
                                    state.isComposerMutationInFlight,
                                isInterruptMutationInFlight:
                                    state.isInterruptMutationInFlight,
                                isComposerFocused: _isComposerFocused,
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
                                onAccessModeChanged: changeAccessMode,
                                onSubmitComposer:
                                    controller.submitComposerInput,
                                onInterruptActiveTurn:
                                    controller.interruptActiveTurn,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
