import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:codex_mobile_companion/features/approvals/application/approvals_queue_controller.dart';
import 'package:codex_mobile_companion/features/approvals/presentation/approval_presenter.dart';
import 'package:codex_mobile_companion/features/pairing/application/pairing_controller.dart';
import 'package:codex_mobile_companion/features/pairing/domain/pairing_qr_payload.dart';
import 'package:codex_mobile_companion/features/settings/application/desktop_integration_controller.dart';
import 'package:codex_mobile_companion/features/settings/application/device_settings_controller.dart';
import 'package:codex_mobile_companion/features/settings/application/runtime_access_mode.dart';
import 'package:codex_mobile_companion/features/threads/application/thread_detail_controller.dart';
import 'package:codex_mobile_companion/features/threads/data/thread_detail_bridge_api.dart';
import 'package:codex_mobile_companion/features/threads/domain/parsed_command_output.dart';
import 'package:codex_mobile_companion/features/threads/domain/thread_activity_item.dart';
import 'package:codex_mobile_companion/features/threads/domain/thread_timeline_block.dart';
import 'package:codex_mobile_companion/foundation/connectivity/live_connection_state.dart';
import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:codex_mobile_companion/foundation/theme/app_theme.dart';
import 'package:codex_mobile_companion/foundation/theme/liquid_styles.dart';
import 'package:codex_mobile_companion/shared/widgets/badges.dart';
import 'package:codex_mobile_companion/shared/widgets/connection_status_banner.dart';
import 'package:codex_mobile_companion/shared/widgets/magnetic_button.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:syntax_highlight/syntax_highlight.dart';

import '../application/thread_list_controller.dart';

part 'thread_detail_page_body.dart';
part 'thread_detail_page_composer.dart';
part 'thread_detail_page_draft.dart';
part 'thread_detail_page_header.dart';
part 'thread_detail_page_message.dart';
part 'thread_detail_page_timeline.dart';

class ThreadDetailPage extends ConsumerStatefulWidget {
  const ThreadDetailPage({
    super.key,
    required this.bridgeApiBaseUrl,
    required this.threadId,
    this.initialVisibleTimelineEntries = 80,
    this.initialComposerInput,
    this.initialAttachedImages = const <XFile>[],
    this.initialSelectedModel,
    this.initialSelectedReasoningEffort,
  }) : draftWorkspacePath = null,
       draftWorkspaceLabel = null;

  const ThreadDetailPage.draft({
    super.key,
    required this.bridgeApiBaseUrl,
    required String this.draftWorkspacePath,
    required String this.draftWorkspaceLabel,
    this.initialVisibleTimelineEntries = 80,
  }) : threadId = null,
       initialComposerInput = null,
       initialAttachedImages = const <XFile>[],
       initialSelectedModel = null,
       initialSelectedReasoningEffort = null;

  final String? threadId;
  final String? draftWorkspacePath;
  final String? draftWorkspaceLabel;
  final String? initialComposerInput;
  final List<XFile> initialAttachedImages;
  final String? initialSelectedModel;
  final String? initialSelectedReasoningEffort;

  bool get isDraft => threadId == null;
  final String bridgeApiBaseUrl;
  final int initialVisibleTimelineEntries;

  @override
  ConsumerState<ThreadDetailPage> createState() => _ThreadDetailPageState();
}

class _ThreadDetailPageState extends ConsumerState<ThreadDetailPage> {
  static const double _historyPrefetchTriggerOffset = 160;

  late final TextEditingController _composerController;
  late final FocusNode _composerFocusNode;
  late final TextEditingController _gitBranchController;
  late final ScrollController _timelineScrollController;
  late final ValueNotifier<bool> _isHeaderCollapsed;
  late final ValueNotifier<bool> _showNewMessagePill;
  final ImagePicker _imagePicker = ImagePicker();

  List<ModelOptionDto> _availableModelOptions = fallbackModelCatalog.models;
  List<String> _availableReasoningOptions = const <String>[];
  List<XFile> _attachedImages = const <XFile>[];
  String _selectedModel = fallbackModelCatalog.models.first.id;
  String _selectedReasoning = 'Medium';
  bool _didInitialScrollToBottom = false;
  bool _isComposerFocused = false;
  bool _canLoadEarlierHistory = false;
  bool _isAutoLoadingEarlierHistory = false;
  bool _hasUserScrolledTimeline = false;
  bool _didSubmitInitialComposerInput = false;
  bool _isDraftThreadCreationInFlight = false;
  Future<void> Function()? _loadEarlierHistory;
  String? _draftThreadErrorMessage;
  final Map<String, bool> _timelineExpansionState = <String, bool>{};

  double _lastScrollOffset = 0;
  double _scrollOffsetOnDirectionChange = 0;
  bool _isScrollingDown = false;

  @override
  void initState() {
    super.initState();
    if (widget.initialSelectedModel != null &&
        widget.initialSelectedModel!.trim().isNotEmpty) {
      _selectedModel = widget.initialSelectedModel!.trim();
    }
    if (widget.initialSelectedReasoningEffort != null &&
        widget.initialSelectedReasoningEffort!.trim().isNotEmpty) {
      _selectedReasoning = _formatReasoningLabel(
        widget.initialSelectedReasoningEffort!,
      );
    }
    _composerController = TextEditingController();
    _composerFocusNode = FocusNode();
    _gitBranchController = TextEditingController();
    _timelineScrollController = ScrollController();
    _isHeaderCollapsed = ValueNotifier(false);
    _showNewMessagePill = ValueNotifier(false);
    _composerFocusNode.addListener(_handleComposerFocusChange);
    _timelineScrollController.addListener(_onScroll);
    _setComposerSelectionsFromCatalog(_availableModelOptions);
    _attachedImages = List<XFile>.unmodifiable(widget.initialAttachedImages);
    unawaited(_loadComposerModelCatalog());
  }

  Future<void> _loadComposerModelCatalog() async {
    final bridgeApi = ref.read(threadDetailBridgeApiProvider);
    final catalog = await bridgeApi.fetchModelCatalog(
      bridgeApiBaseUrl: widget.bridgeApiBaseUrl,
    );
    if (!mounted || catalog.models.isEmpty) {
      return;
    }

    setState(() {
      _setComposerSelectionsFromCatalog(catalog.models);
    });
  }

  void _setComposerSelectionsFromCatalog(List<ModelOptionDto> modelOptions) {
    if (modelOptions.isEmpty) {
      return;
    }

    _availableModelOptions = List<ModelOptionDto>.unmodifiable(modelOptions);
    final defaultModelId = modelOptions
        .firstWhere(
          (model) => model.isDefault,
          orElse: () => modelOptions.first,
        )
        .id;
    final hasSelectedModel = modelOptions.any(
      (model) => model.id == _selectedModel,
    );
    if (!hasSelectedModel) {
      _selectedModel = defaultModelId;
    }

    _availableReasoningOptions = _reasoningOptionsForModel(_selectedModel);
    if (_availableReasoningOptions.isEmpty) {
      _availableReasoningOptions = const <String>['Low', 'Medium', 'High'];
    }

    if (!_availableReasoningOptions.contains(_selectedReasoning)) {
      final selectedModel = modelOptions.firstWhere(
        (model) => model.id == _selectedModel,
      );
      final defaultReasoning = selectedModel.defaultReasoningEffort;
      if (defaultReasoning != null) {
        _selectedReasoning = _formatReasoningLabel(defaultReasoning);
      } else {
        _selectedReasoning = _availableReasoningOptions.first;
      }
    }
  }

  List<String> _reasoningOptionsForModel(String modelId) {
    final model = _availableModelOptions.firstWhere(
      (candidate) => candidate.id == modelId,
      orElse: () => _availableModelOptions.first,
    );

    final options = model.supportedReasoningEfforts
        .map((effort) => _formatReasoningLabel(effort.reasoningEffort))
        .where((label) => label.isNotEmpty)
        .toSet()
        .toList(growable: false);
    return options;
  }

  String _formatReasoningLabel(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return '';
    }

    final normalized = trimmed.replaceAll('_', ' ').toLowerCase();
    return normalized
        .split(' ')
        .where((word) => word.isNotEmpty)
        .map(
          (word) => word.length == 1
              ? word.toUpperCase()
              : '${word[0].toUpperCase()}${word.substring(1)}',
        )
        .join(' ');
  }

  String? _selectedReasoningEffortWireValue() {
    final selectedModel = _availableModelOptions.firstWhere(
      (candidate) => candidate.id == _selectedModel,
      orElse: () => _availableModelOptions.first,
    );

    for (final option in selectedModel.supportedReasoningEfforts) {
      if (_formatReasoningLabel(option.reasoningEffort) == _selectedReasoning) {
        return option.reasoningEffort;
      }
    }

    final normalized = _selectedReasoning.trim().toLowerCase().replaceAll(
      ' ',
      '_',
    );
    return normalized.isEmpty ? null : normalized;
  }

  void _onComposerModelChanged(String modelId) {
    setState(() {
      _selectedModel = modelId;
      _availableReasoningOptions = _reasoningOptionsForModel(modelId);
      if (_availableReasoningOptions.isEmpty) {
        _availableReasoningOptions = const <String>['Low', 'Medium', 'High'];
      }

      if (!_availableReasoningOptions.contains(_selectedReasoning)) {
        final model = _availableModelOptions.firstWhere(
          (candidate) => candidate.id == modelId,
          orElse: () => _availableModelOptions.first,
        );
        final defaultReasoning = model.defaultReasoningEffort;
        _selectedReasoning = defaultReasoning == null
            ? _availableReasoningOptions.first
            : _formatReasoningLabel(defaultReasoning);
      }
    });
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
        !_hasUserScrolledTimeline ||
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
      _didSubmitInitialComposerInput = false;
      _timelineExpansionState.clear();
    }
    if (oldWidget.bridgeApiBaseUrl != widget.bridgeApiBaseUrl) {
      unawaited(_loadComposerModelCatalog());
    }
    if (oldWidget.initialComposerInput != widget.initialComposerInput) {
      _didSubmitInitialComposerInput = false;
    }
    if (!listEquals(
      oldWidget.initialAttachedImages,
      widget.initialAttachedImages,
    )) {
      _attachedImages = List<XFile>.unmodifiable(widget.initialAttachedImages);
      if (widget.initialAttachedImages.isNotEmpty) {
        _didSubmitInitialComposerInput = false;
      }
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

  bool _isTimelineCardExpanded(String id, {required bool defaultValue}) {
    return _timelineExpansionState[id] ?? defaultValue;
  }

  void _setTimelineCardExpanded(String id, bool isExpanded) {
    if (_timelineExpansionState[id] == isExpanded) {
      return;
    }

    setState(() {
      _timelineExpansionState[id] = isExpanded;
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

  void _markTimelineUserScroll() {
    if (_hasUserScrolledTimeline) {
      return;
    }

    _hasUserScrolledTimeline = true;
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

  Future<bool> _submitDraftComposerInput(String rawInput) async {
    final workspacePath = widget.draftWorkspacePath?.trim() ?? '';
    if (workspacePath.isEmpty) {
      setState(() {
        _draftThreadErrorMessage = 'No workspace is available for this draft.';
      });
      return false;
    }

    final input = rawInput.trim();
    if (input.isEmpty && _attachedImages.isEmpty) {
      setState(() {
        _draftThreadErrorMessage =
            'Enter a prompt or attach an image to start a turn.';
      });
      return false;
    }

    setState(() {
      _isDraftThreadCreationInFlight = true;
      _draftThreadErrorMessage = null;
    });

    try {
      final bridgeApi = ref.read(threadDetailBridgeApiProvider);
      final snapshot = await bridgeApi.createThread(
        bridgeApiBaseUrl: widget.bridgeApiBaseUrl,
        workspace: workspacePath,
        model: _selectedModel,
      );
      final thread = snapshot.thread;
      final listController = ref.read(
        threadListControllerProvider(widget.bridgeApiBaseUrl).notifier,
      );
      listController.syncThreadDetail(thread);
      _persistSelectedThreadId(listController, thread.threadId);
      if (!mounted) {
        return true;
      }

      unawaited(
        Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(
            builder: (context) => ThreadDetailPage(
              bridgeApiBaseUrl: widget.bridgeApiBaseUrl,
              threadId: thread.threadId,
              initialComposerInput: input,
              initialAttachedImages: _attachedImages,
              initialSelectedModel: _selectedModel,
              initialSelectedReasoningEffort:
                  _selectedReasoningEffortWireValue(),
            ),
          ),
        ),
      );
      return true;
    } on ThreadCreateBridgeException catch (error) {
      if (!mounted) {
        return false;
      }
      setState(() {
        _isDraftThreadCreationInFlight = false;
        _draftThreadErrorMessage = error.message;
      });
      return false;
    } catch (_) {
      if (!mounted) {
        return false;
      }
      setState(() {
        _isDraftThreadCreationInFlight = false;
        _draftThreadErrorMessage =
            'Couldn’t create the thread right now. Please try again.';
      });
      return false;
    }
  }

  Future<bool> _submitComposerInput(
    ThreadDetailController controller,
    String rawInput, {
    List<XFile>? attachedImages,
  }) async {
    final imageDataUrls = await _encodeAttachedImages(
      attachedImages ?? _attachedImages,
    );
    final success = await controller.submitComposerInput(
      rawInput,
      images: imageDataUrls,
      model: _selectedModel,
      reasoningEffort: _selectedReasoningEffortWireValue(),
    );
    if (!mounted || !success) {
      return success;
    }

    setState(() {
      _attachedImages = const <XFile>[];
      _draftThreadErrorMessage = null;
    });
    return true;
  }

  Future<List<String>> _encodeAttachedImages(List<XFile> images) async {
    final encoded = <String>[];
    for (final image in images) {
      final dataUrl = await _encodeImageAsDataUrl(image);
      if (dataUrl != null) {
        encoded.add(dataUrl);
      }
    }
    return List<String>.unmodifiable(encoded);
  }

  Future<String?> _encodeImageAsDataUrl(XFile image) async {
    final bytes = await image.readAsBytes();
    if (bytes.isEmpty) {
      return null;
    }

    final mimeType = _detectImageMimeType(bytes, image);
    return 'data:$mimeType;base64,${base64Encode(bytes)}';
  }

  String _detectImageMimeType(Uint8List bytes, XFile image) {
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return 'image/png';
    }
    if (bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return 'image/jpeg';
    }
    if (bytes.length >= 6) {
      final header = ascii.decode(bytes.sublist(0, 6), allowInvalid: true);
      if (header == 'GIF87a' || header == 'GIF89a') {
        return 'image/gif';
      }
    }
    if (bytes.length >= 12 &&
        ascii.decode(bytes.sublist(0, 4), allowInvalid: true) == 'RIFF' &&
        ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WEBP') {
      return 'image/webp';
    }

    final candidate = '${image.name} ${image.path}'.toLowerCase();
    if (candidate.contains('.png')) {
      return 'image/png';
    }
    if (candidate.contains('.gif')) {
      return 'image/gif';
    }
    if (candidate.contains('.webp')) {
      return 'image/webp';
    }
    if (candidate.contains('.heic')) {
      return 'image/heic';
    }
    if (candidate.contains('.heif')) {
      return 'image/heif';
    }

    return 'image/jpeg';
  }

  void _persistSelectedThreadId(
    ThreadListController listController,
    String threadId,
  ) {
    unawaited(() async {
      try {
        await listController.selectThread(threadId);
      } catch (_) {
        // Avoid trapping the draft screen on storage/plugin failures.
      }
    }());
  }

  @override
  Widget build(BuildContext context) {
    final runtimeAccessMode = ref.watch(
      runtimeAccessModeProvider(widget.bridgeApiBaseUrl),
    );
    final pairingState = ref.watch(pairingControllerProvider);
    final deviceSettingsState = ref.watch(
      deviceSettingsControllerProvider(widget.bridgeApiBaseUrl),
    );
    final deviceSettingsController = ref.read(
      deviceSettingsControllerProvider(widget.bridgeApiBaseUrl).notifier,
    );

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

    if (widget.isDraft) {
      final effectiveAccessMode =
          runtimeAccessMode ?? AccessMode.controlWithApprovals;
      final isReadOnlyMode = effectiveAccessMode == AccessMode.readOnly;
      final controlsEnabled = !isReadOnlyMode;

      return Scaffold(
        backgroundColor: AppTheme.background,
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: Stack(
                  children: [
                    _ThreadDraftBody(
                      workspacePath: widget.draftWorkspacePath!,
                      workspaceLabel: widget.draftWorkspaceLabel!,
                      isReadOnlyMode: isReadOnlyMode,
                      draftErrorMessage: _draftThreadErrorMessage,
                    ),
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: _DraftThreadDetailHeader(
                        workspacePath: widget.draftWorkspacePath!,
                        workspaceLabel: widget.draftWorkspaceLabel!,
                        onBack: () => Navigator.of(context).pop(),
                      ),
                    ),
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
                          child: _PinnedTurnComposer(
                            composerController: _composerController,
                            composerFocusNode: _composerFocusNode,
                            isTurnActive: false,
                            controlsEnabled: controlsEnabled,
                            isComposerMutationInFlight:
                                _isDraftThreadCreationInFlight,
                            isInterruptMutationInFlight: false,
                            isComposerFocused: _isComposerFocused,
                            attachedImages: _attachedImages,
                            modelOptions: _availableModelOptions,
                            reasoningOptions: _availableReasoningOptions,
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
                            onModelChanged: _onComposerModelChanged,
                            onReasoningChanged: (value) {
                              setState(() {
                                _selectedReasoning = value;
                              });
                            },
                            onAccessModeChanged: changeAccessMode,
                            onSubmitComposer: _submitDraftComposerInput,
                            onInterruptActiveTurn: () async => false,
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

    final args = ThreadDetailControllerArgs(
      bridgeApiBaseUrl: widget.bridgeApiBaseUrl,
      threadId: widget.threadId!,
      initialVisibleTimelineEntries: widget.initialVisibleTimelineEntries,
    );
    final state = ref.watch(threadDetailControllerProvider(args));
    final controller = ref.read(threadDetailControllerProvider(args).notifier);
    final approvalsState = ref.watch(
      approvalsQueueControllerProvider(widget.bridgeApiBaseUrl),
    );
    final desktopIntegrationState = ref.watch(
      desktopIntegrationControllerProvider,
    );

    final approvalsController = ref.read(
      approvalsQueueControllerProvider(widget.bridgeApiBaseUrl).notifier,
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

    if (!_didSubmitInitialComposerInput &&
        !state.isLoading &&
        state.hasThread &&
        !state.isTurnActive &&
        !state.isComposerMutationInFlight) {
      final initialComposerInput = widget.initialComposerInput?.trim();
      if ((initialComposerInput != null && initialComposerInput.isNotEmpty) ||
          _attachedImages.isNotEmpty) {
        _didSubmitInitialComposerInput = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) {
            return;
          }
          unawaited(
            _submitComposerInput(controller, initialComposerInput ?? ''),
          );
        });
      }
    }

    final threadApprovals = approvalsState.forThread(widget.threadId!);
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
                    onTimelineUserScroll: _markTimelineUserScroll,
                    scrollController: _timelineScrollController,
                    isTimelineCardExpanded: _isTimelineCardExpanded,
                    onTimelineCardExpansionChanged: _setTimelineCardExpanded,
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
                                modelOptions: _availableModelOptions,
                                reasoningOptions: _availableReasoningOptions,
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
                                onModelChanged: _onComposerModelChanged,
                                onReasoningChanged: (value) {
                                  setState(() {
                                    _selectedReasoning = value;
                                  });
                                },
                                onAccessModeChanged: changeAccessMode,
                                onSubmitComposer: (value) =>
                                    _submitComposerInput(controller, value),
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

ConnectionBannerState _threadDetailConnectionBannerState(
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

String _threadDetailConnectionBannerDetail(ThreadDetailState state) {
  switch (state.liveConnectionState) {
    case LiveConnectionState.connected:
      return 'Thread socket is live.';
    case LiveConnectionState.reconnecting:
      return state.streamErrorMessage ??
          state.staleMessage ??
          'Live updates dropped. Reconnecting now.';
    case LiveConnectionState.disconnected:
      return state.errorMessage ??
          state.streamErrorMessage ??
          state.staleMessage ??
          'Bridge is offline. Thread updates are unavailable.';
  }
}
