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
import 'package:codex_mobile_companion/foundation/theme/app_theme.dart';
import 'package:codex_mobile_companion/shared/widgets/badges.dart';
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
            _ThreadDetailHeader(
              state: state,
              accessMode: effectiveAccessMode,
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
            ),
            Expanded(
              child: _ThreadDetailBody(
                state: state,
                isReadOnlyMode: isReadOnlyMode,
                controlsEnabled: controlsEnabled,
                desktopIntegrationEnabled: desktopIntegrationState.isEnabled,
                onRetry: controller.loadThread,
                onLoadEarlier: controller.loadEarlierHistory,
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
                  onAccessModeChanged: changeAccessMode,
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
