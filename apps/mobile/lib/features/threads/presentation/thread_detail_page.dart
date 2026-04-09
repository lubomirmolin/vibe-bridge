import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:vibe_bridge/features/approvals/application/approvals_queue_controller.dart';
import 'package:vibe_bridge/features/approvals/presentation/approval_presenter.dart';
import 'package:vibe_bridge/features/settings/application/desktop_integration_controller.dart';
import 'package:vibe_bridge/features/settings/application/device_settings_controller.dart';
import 'package:vibe_bridge/features/settings/application/runtime_access_mode.dart';
import 'package:vibe_bridge/features/threads/application/thread_detail_controller.dart';
import 'package:vibe_bridge/features/threads/data/thread_composer_draft_repository.dart';
import 'package:vibe_bridge/features/threads/data/thread_detail_bridge_api.dart';
import 'package:vibe_bridge/features/threads/domain/parsed_command_output.dart';
import 'package:vibe_bridge/features/threads/domain/thread_activity_item.dart';
import 'package:vibe_bridge/features/threads/domain/thread_timeline_block.dart';
import 'package:vibe_bridge/features/threads/presentation/thread_git_diff_page.dart';
import 'package:vibe_bridge/foundation/connectivity/live_connection_state.dart';
import 'package:vibe_bridge/foundation/contracts/bridge_contracts.dart';
import 'package:vibe_bridge/foundation/layout/adaptive_layout.dart';
import 'package:vibe_bridge/foundation/logging/thread_diagnostics.dart';
import 'package:vibe_bridge/foundation/media/speech_capture.dart';
import 'package:vibe_bridge/foundation/session/current_bridge_session.dart';
import 'package:codex_ui/codex_ui.dart';

import 'package:vibe_bridge/shared/widgets/badges.dart';
import 'package:vibe_bridge/shared/widgets/connection_status_banner.dart';
import 'package:vibe_bridge/shared/widgets/provider_icon.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
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
part 'thread_detail_page_message_markdown.dart';
part 'thread_detail_page_timeline.dart';

const double threadSessionContentMaxWidth = 1280;

class ThreadDraftCreatedTransition {
  const ThreadDraftCreatedTransition({
    required this.threadId,
    required this.initialComposerInput,
    required this.initialAttachedImages,
    required this.initialTurnMode,
    required this.initialSelectedModel,
    required this.initialSelectedReasoningEffort,
  });

  final String threadId;
  final String initialComposerInput;
  final List<XFile> initialAttachedImages;
  final TurnMode initialTurnMode;
  final String initialSelectedModel;
  final String? initialSelectedReasoningEffort;
}

class _SpeechUnavailableDialogContent {
  const _SpeechUnavailableDialogContent({
    required this.title,
    required this.message,
  });

  final String title;
  final String message;
}

class _TimelineViewportAnchor {
  const _TimelineViewportAnchor({required this.blockId, required this.top});

  final String blockId;
  final double top;
}

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
    this.pickImagesOverride,
    this.speechCaptureOverride,
    this.showBackButton = true,
    this.embedInScaffold = true,
    this.onBack,
    this.onDraftThreadCreated,
    this.onOpenDiff,
    this.onToggleSidebar,
    this.isSidebarVisible,
    this.onToggleDiff,
    this.isDiffVisible,
  }) : draftWorkspacePath = null,
       draftWorkspaceLabel = null;

  const ThreadDetailPage.draft({
    super.key,
    required this.bridgeApiBaseUrl,
    required String this.draftWorkspacePath,
    required String this.draftWorkspaceLabel,
    this.initialVisibleTimelineEntries = 80,
    this.pickImagesOverride,
    this.speechCaptureOverride,
    this.showBackButton = true,
    this.embedInScaffold = true,
    this.onBack,
    this.onDraftThreadCreated,
    this.onOpenDiff,
    this.onToggleSidebar,
    this.isSidebarVisible,
    this.onToggleDiff,
    this.isDiffVisible,
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
  final Future<List<XFile>> Function()? pickImagesOverride;
  final SpeechCapture? speechCaptureOverride;
  final bool showBackButton;
  final bool embedInScaffold;
  final VoidCallback? onBack;
  final ValueChanged<ThreadDraftCreatedTransition>? onDraftThreadCreated;
  final VoidCallback? onOpenDiff;
  final VoidCallback? onToggleSidebar;
  final bool? isSidebarVisible;
  final VoidCallback? onToggleDiff;
  final bool? isDiffVisible;

  bool get isDraft => threadId == null;
  final String bridgeApiBaseUrl;
  final int initialVisibleTimelineEntries;

  @override
  ConsumerState<ThreadDetailPage> createState() => _ThreadDetailPageState();
}

class _ThreadDetailPageState extends ConsumerState<ThreadDetailPage>
    with WidgetsBindingObserver {
  static const double _historyPrefetchTriggerOffset = 160;
  static const double _sessionContentMaxWidth = threadSessionContentMaxWidth;

  late final TextEditingController _composerController;
  late final FocusNode _composerFocusNode;
  late final TextEditingController _gitBranchController;
  late final ScrollController _timelineScrollController;
  final GlobalKey _timelineScrollViewKey = GlobalKey(
    debugLabel: 'thread-detail-scroll-view',
  );
  late final ValueNotifier<bool> _isHeaderCollapsed;
  late final ValueNotifier<bool> _showNewMessagePill;
  late final ValueNotifier<String?> _newMessagePreview;
  final ImagePicker _imagePicker = ImagePicker();
  SpeechCapture? _speechCapture;

  ProviderKind _selectedProvider = ProviderKind.codex;
  List<ModelOptionDto> _availableModelOptions = fallbackModelCatalogForProvider(
    ProviderKind.codex,
  ).models;
  List<String> _availableReasoningOptions = const <String>[];
  List<XFile> _attachedImages = const <XFile>[];
  TurnMode _composerMode = TurnMode.act;
  String? _lastPendingUserInputRequestId;
  final Map<String, String> _selectedPlanOptionByQuestionId =
      <String, String>{};
  String _selectedModel = fallbackModelCatalogForProvider(
    ProviderKind.codex,
  ).models.first.id;
  String _selectedReasoning = 'Medium';
  SpeechModelStatusDto _speechModelStatus = const SpeechModelStatusDto(
    contractVersion: contractVersion,
    provider: 'fluid_audio',
    modelId: 'parakeet-tdt-0.6b-v3-coreml',
    state: SpeechModelState.unsupported,
    lastError: 'Speech transcription is unavailable in this build.',
  );
  String? _speechMessage;
  bool _speechMessageIsError = false;
  bool _isSpeechRecording = false;
  bool _isSpeechTranscribing = false;
  Timer? _speechRecordingTimer;
  int _speechDurationSeconds = 0;
  ThreadDraftCreatedTransition? _localDraftTransition;
  bool _didInitialScrollToBottom = false;
  bool _isComposerFocused = false;
  bool _canLoadEarlierHistory = false;
  bool _isAutoLoadingEarlierHistory = false;
  bool _hasUserScrolledTimeline = false;
  bool _didSubmitInitialComposerInput = false;
  bool _isDraftThreadCreationInFlight = false;
  bool _isResumeReconnectInFlight = false;
  bool _didRestoreComposerDraft = false;
  String? _lastPersistedComposerDraftValue;
  Future<void> _composerDraftPersistence = Future<void>.value();
  int _timelineBottomFollowRunId = 0;
  Future<void> Function()? _loadEarlierHistory;
  String? _draftThreadErrorMessage;
  ThreadUsageDto? _threadUsage;
  final Map<String, bool> _timelineExpansionState = <String, bool>{};
  final Map<String, GlobalKey> _timelineBlockMeasurementKeys =
      <String, GlobalKey>{};
  List<String> _timelineBlockOrder = const <String>[];
  bool? _lastObservedWideLayout;
  bool _isWideLayoutExitScheduled = false;
  int _modelCatalogLoadEpoch = 0;
  int _threadUsageLoadEpoch = 0;

  double _lastScrollOffset = 0;
  double _scrollOffsetOnDirectionChange = 0;
  bool _isScrollingDown = false;
  bool _isTimelineAutoFollowEnabled = true;
  String? _lastInitialSubmitGateLogKey;

  bool get _isDraftMode =>
      widget.threadId == null && _localDraftTransition == null;

  bool get _canChangeComposerProvider => _effectiveThreadId == null;

  String? get _effectiveThreadId =>
      _localDraftTransition?.threadId ?? widget.threadId;

  String? get _composerDraftStorageId {
    final effectiveThreadId = _effectiveThreadId?.trim();
    if (effectiveThreadId != null && effectiveThreadId.isNotEmpty) {
      return 'thread:$effectiveThreadId';
    }

    final workspacePath = widget.draftWorkspacePath?.trim();
    if (workspacePath != null && workspacePath.isNotEmpty) {
      return 'workspace:$workspacePath';
    }

    return null;
  }

  String? get _effectiveInitialComposerInput =>
      _localDraftTransition?.initialComposerInput ??
      widget.initialComposerInput;

  List<XFile> get _effectiveInitialAttachedImages =>
      _localDraftTransition?.initialAttachedImages ??
      widget.initialAttachedImages;

  TurnMode get _effectiveInitialTurnMode =>
      _localDraftTransition?.initialTurnMode ?? _composerMode;

  bool get _supportsPlanMode => _selectedProvider == ProviderKind.codex;

  bool get _hasPendingInitialComposerSubmission {
    final initialComposerInput = _effectiveInitialComposerInput?.trim();
    return (initialComposerInput != null && initialComposerInput.isNotEmpty) ||
        _effectiveInitialAttachedImages.isNotEmpty;
  }

  void _logDraftFlow(String event, [Map<String, Object?> data = const {}]) {
    final payload = <String, Object?>{
      'widgetThreadId': widget.threadId,
      'effectiveThreadId': _effectiveThreadId,
      'draftWorkspacePath': widget.draftWorkspacePath,
      'isDraftMode': _isDraftMode,
      ...data,
    };
    debugPrint(
      'thread_detail_draft_flow '
      'event=$event '
      'payload=${jsonEncode(payload)}',
    );
    unawaited(
      ref
          .read(threadDiagnosticsServiceProvider)
          .record(
            kind: 'thread_detail_draft_flow',
            threadId: (_effectiveThreadId ?? widget.threadId)?.trim(),
            data: <String, Object?>{'event': event, ...payload},
          ),
    );
  }

  SpeechCapture get _resolvedSpeechCapture {
    final speechCapture = _speechCapture;
    if (speechCapture != null) {
      return speechCapture;
    }

    final createdCapture =
        (widget.speechCaptureOverride ?? ref.read(speechCaptureProvider))
            as SpeechCapture;
    _speechCapture = createdCapture;
    return createdCapture;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Pre-warm the syntax highlighter so code blocks render without a
    // FutureBuilder-driven layout reflow.
    _ThreadCodeHighlighterSet.warmUp();
    final initialThreadId = widget.threadId?.trim();
    _selectedProvider = initialThreadId == null || initialThreadId.isEmpty
        ? ProviderKind.codex
        : providerKindFromThreadId(initialThreadId);
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
    _newMessagePreview = ValueNotifier(null);
    _composerController.addListener(_handleComposerChanged);
    _composerFocusNode.addListener(_handleComposerFocusChange);
    _timelineScrollController.addListener(_onScroll);
    _availableModelOptions = List<ModelOptionDto>.unmodifiable(
      fallbackModelCatalogForProvider(_selectedProvider).models,
    );
    _setComposerSelectionsFromCatalog(_availableModelOptions);
    _attachedImages = List<XFile>.unmodifiable(_effectiveInitialAttachedImages);
    unawaited(_restorePersistedComposerDraft());
    unawaited(_loadComposerModelCatalog());
    unawaited(_loadSpeechStatus());
    unawaited(_loadThreadUsage());
  }

  Future<void> _restorePersistedComposerDraft() async {
    if (_didRestoreComposerDraft) {
      return;
    }

    _didRestoreComposerDraft = true;
    if (_hasPendingInitialComposerSubmission) {
      return;
    }

    final draftId = _composerDraftStorageId;
    if (draftId == null) {
      return;
    }

    final draftRepository = ref.read(threadComposerDraftRepositoryProvider);
    final persistedDraft = await draftRepository.readDraft(draftId);
    if (!mounted || persistedDraft == null || persistedDraft.isEmpty) {
      return;
    }
    if (_composerController.text.trim().isNotEmpty) {
      return;
    }

    _composerController.value = TextEditingValue(
      text: persistedDraft,
      selection: TextSelection.collapsed(offset: persistedDraft.length),
    );
  }

  Future<void> _loadComposerModelCatalog() async {
    final provider = _selectedProvider;
    final requestEpoch = ++_modelCatalogLoadEpoch;
    final bridgeApi = ref.read(threadDetailBridgeApiProvider);
    final catalog = await bridgeApi.fetchModelCatalog(
      bridgeApiBaseUrl: widget.bridgeApiBaseUrl,
      provider: provider,
    );
    if (!mounted ||
        requestEpoch != _modelCatalogLoadEpoch ||
        catalog.models.isEmpty) {
      return;
    }

    setState(() {
      _setComposerSelectionsFromCatalog(catalog.models);
    });
  }

  Future<void> _onComposerProviderChanged(ProviderKind provider) async {
    if (!_canChangeComposerProvider || _selectedProvider == provider) {
      return;
    }

    setState(() {
      _selectedProvider = provider;
      _setComposerSelectionsFromCatalog(
        fallbackModelCatalogForProvider(provider).models,
      );
      if (provider != ProviderKind.codex) {
        _composerMode = TurnMode.act;
      }
    });
    await _loadComposerModelCatalog();
  }

  Future<void> _loadSpeechStatus() async {
    final bridgeApi = ref.read(threadDetailBridgeApiProvider);
    try {
      final status = await bridgeApi.fetchSpeechStatus(
        bridgeApiBaseUrl: widget.bridgeApiBaseUrl,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _speechModelStatus = status;
      });
    } on ThreadSpeechBridgeException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _speechModelStatus = SpeechModelStatusDto(
          contractVersion: contractVersion,
          provider: 'fluid_audio',
          modelId: 'parakeet-tdt-0.6b-v3-coreml',
          state: SpeechModelState.failed,
          lastError: error.message,
        );
      });
    }
  }

  Future<void> _loadThreadUsage() async {
    final threadId = _effectiveThreadId?.trim();
    if (threadId == null || threadId.isEmpty) {
      if (mounted && _threadUsage != null) {
        setState(() {
          _threadUsage = null;
        });
      }
      return;
    }
    if (providerKindFromThreadId(threadId) != ProviderKind.codex) {
      if (mounted && _threadUsage != null) {
        setState(() {
          _threadUsage = null;
        });
      }
      return;
    }

    final requestEpoch = ++_threadUsageLoadEpoch;
    final bridgeApi = ref.read(threadDetailBridgeApiProvider);
    try {
      final usage = await bridgeApi.fetchThreadUsage(
        bridgeApiBaseUrl: widget.bridgeApiBaseUrl,
        threadId: threadId,
      );
      if (!mounted || requestEpoch != _threadUsageLoadEpoch) {
        return;
      }
      setState(() {
        _threadUsage = usage;
      });
    } on ThreadUsageBridgeException {
      if (!mounted || requestEpoch != _threadUsageLoadEpoch) {
        return;
      }
      setState(() {
        _threadUsage = null;
      });
    }
  }

  Future<void> _openDiffView() async {
    if (_isDraftMode) {
      return;
    }
    if (widget.onOpenDiff != null) {
      widget.onOpenDiff!.call();
      return;
    }
    final threadId = _effectiveThreadId;
    if (threadId == null || !mounted) {
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => ThreadGitDiffPage(
          bridgeApiBaseUrl: widget.bridgeApiBaseUrl,
          threadId: threadId,
        ),
      ),
    );
  }

  void _toggleDiffView() {
    final onToggleDiff = widget.onToggleDiff;
    if (onToggleDiff != null) {
      onToggleDiff();
      return;
    }
    unawaited(_openDiffView());
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

  void _handleComposerChanged() {
    _composerDraftPersistence = _composerDraftPersistence.then(
      (_) => _persistComposerDraft(),
      onError: (_) => _persistComposerDraft(),
    );
  }

  Future<void> _persistComposerDraft() async {
    final draftId = _composerDraftStorageId;
    if (draftId == null) {
      return;
    }

    final currentValue = _composerController.text.trimRight();
    if (_lastPersistedComposerDraftValue == currentValue) {
      return;
    }
    _lastPersistedComposerDraftValue = currentValue;

    final draftRepository = ref.read(threadComposerDraftRepositoryProvider);
    if (currentValue.isEmpty) {
      await draftRepository.deleteDraft(draftId);
      return;
    }

    await draftRepository.saveDraft(draftId, currentValue);
  }

  Future<void> _clearComposerDraft({String? draftId}) async {
    final resolvedDraftId = draftId ?? _composerDraftStorageId;
    if (resolvedDraftId == null) {
      return;
    }

    _lastPersistedComposerDraftValue = '';
    await ref
        .read(threadComposerDraftRepositoryProvider)
        .deleteDraft(resolvedDraftId);
  }

  void _onScroll() {
    if (!_timelineScrollController.hasClients) return;

    final position = _timelineScrollController.position;
    final currentOffset = clampDouble(
      _timelineScrollController.offset,
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    final scrollDelta = currentOffset - _lastScrollOffset;
    // In a reversed list, increasing offset means the user is scrolling
    // toward *older* content (visually upward).
    final isScrollingTowardOlder = currentOffset > _lastScrollOffset;

    if (isScrollingTowardOlder != _isScrollingDown) {
      _isScrollingDown = isScrollingTowardOlder;
      _scrollOffsetOnDirectionChange = currentOffset;
    }

    final scrollDeltaSinceDirectionChange =
        currentOffset - _scrollOffsetOnDirectionChange;

    // Collapse the header when the user scrolls toward older content (up).
    if (isScrollingTowardOlder &&
        scrollDeltaSinceDirectionChange > 30 &&
        !_isHeaderCollapsed.value &&
        currentOffset > 100) {
      _isHeaderCollapsed.value = true;
    } else if (!isScrollingTowardOlder &&
        scrollDeltaSinceDirectionChange < -30 &&
        _isHeaderCollapsed.value) {
      _isHeaderCollapsed.value = false;
    }

    _lastScrollOffset = currentOffset;

    final isNearBottom = _isTimelineNearBottom(currentOffset: currentOffset);
    if (isNearBottom) {
      _isTimelineAutoFollowEnabled = true;
    } else if (scrollDelta > 24) {
      // In a reversed list, scrolling *away* from the bottom means offset
      // is increasing, so we disable auto-follow when delta > 0.
      _isTimelineAutoFollowEnabled = false;
    }
    if (isNearBottom && _showNewMessagePill.value) {
      _showNewMessagePill.value = false;
      _newMessagePreview.value = null;
    }

    _maybeAutoLoadEarlierHistory();
  }

  bool _isTimelineNearBottom({double? currentOffset, double tolerance = 120}) {
    if (!_timelineScrollController.hasClients) {
      return true;
    }

    final position = _timelineScrollController.position;
    final effectiveOffset =
        currentOffset ??
        clampDouble(
          _timelineScrollController.offset,
          position.minScrollExtent,
          position.maxScrollExtent,
        );
    // In a reversed list, offset 0 is the visual bottom (newest content).
    // "Near bottom" means the offset is close to minScrollExtent.
    final distanceFromBottom = effectiveOffset - position.minScrollExtent;
    final effectiveTolerance = math.min(
      tolerance,
      position.maxScrollExtent * 0.25,
    );
    return distanceFromBottom < effectiveTolerance;
  }

  void _maybeAutoLoadEarlierHistory() {
    if (!_timelineScrollController.hasClients ||
        !_hasUserScrolledTimeline ||
        !_canLoadEarlierHistory ||
        _isAutoLoadingEarlierHistory) {
      return;
    }

    final position = _timelineScrollController.position;
    // In a reversed list, older content is at maxScrollExtent. Trigger
    // earlier history load when the user scrolls close to maxScrollExtent.
    if (position.pixels <
        position.maxScrollExtent - _historyPrefetchTriggerOffset) {
      return;
    }

    final previousOffset = position.pixels;
    final previousMaxScrollExtent = position.maxScrollExtent;
    final anchor = _captureLeadingVisibleTimelineAnchor();
    final loadEarlierHistory = _loadEarlierHistory;
    if (loadEarlierHistory == null) {
      return;
    }
    _isAutoLoadingEarlierHistory = true;
    loadEarlierHistory().whenComplete(() {
      _stabilizeEarlierHistoryOffset(
        anchor: anchor,
        previousOffset: previousOffset,
        previousMaxScrollExtent: previousMaxScrollExtent,
      );
    });
  }

  void _stabilizeEarlierHistoryOffset({
    _TimelineViewportAnchor? anchor,
    required double previousOffset,
    required double previousMaxScrollExtent,
    int remainingFrames = 12,
    int stableFrameCount = 0,
    double? previousObservedMaxScrollExtent,
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_timelineScrollController.hasClients) {
        _isAutoLoadingEarlierHistory = false;
        return;
      }

      final position = _timelineScrollController.position;
      // In a reversed list, prepending older items extends maxScrollExtent
      // while the current scroll offset (anchored to the newest/bottom end)
      // naturally stays stable. We still use the visual anchor when
      // available to correct any layout-driven drift.
      final anchorDelta = _timelineAnchorDelta(anchor);
      if (anchorDelta != null && anchorDelta.abs() >= 0.5) {
        final compensatedOffset = clampDouble(
          position.pixels + anchorDelta,
          position.minScrollExtent,
          position.maxScrollExtent,
        );
        if ((position.pixels - compensatedOffset).abs() >= 0.5) {
          _timelineScrollController.jumpTo(compensatedOffset);
        }
      } else {
        final insertedExtent =
            position.maxScrollExtent - previousMaxScrollExtent;
        if (insertedExtent > 0) {
          final compensatedOffset = clampDouble(
            previousOffset + insertedExtent,
            position.minScrollExtent,
            position.maxScrollExtent,
          );
          if ((position.pixels - compensatedOffset).abs() >= 0.5) {
            _timelineScrollController.jumpTo(compensatedOffset);
          }
        }
      }

      final hasStableExtent =
          previousObservedMaxScrollExtent != null &&
          (position.maxScrollExtent - previousObservedMaxScrollExtent).abs() <
              0.5;
      final nextStableFrameCount = hasStableExtent ? stableFrameCount + 1 : 0;
      if (remainingFrames <= 0 || nextStableFrameCount >= 2) {
        _isAutoLoadingEarlierHistory = false;
        return;
      }

      _stabilizeEarlierHistoryOffset(
        anchor: anchor,
        previousOffset: previousOffset,
        previousMaxScrollExtent: previousMaxScrollExtent,
        remainingFrames: remainingFrames - 1,
        stableFrameCount: nextStableFrameCount,
        previousObservedMaxScrollExtent: position.maxScrollExtent,
      );
    });
  }

  @override
  void didUpdateWidget(covariant ThreadDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.threadId != widget.threadId) {
      _logDraftFlow('did_update_widget_thread_changed', <String, Object?>{
        'oldThreadId': oldWidget.threadId,
        'newThreadId': widget.threadId,
      });
      _localDraftTransition = null;
      final nextThreadId = widget.threadId?.trim();
      _selectedProvider = nextThreadId == null || nextThreadId.isEmpty
          ? ProviderKind.codex
          : providerKindFromThreadId(nextThreadId);
      _setComposerSelectionsFromCatalog(
        fallbackModelCatalogForProvider(_selectedProvider).models,
      );
      _didInitialScrollToBottom = false;
      _didSubmitInitialComposerInput = false;
      _lastInitialSubmitGateLogKey = null;
      _didRestoreComposerDraft = false;
      _lastPersistedComposerDraftValue = null;
      _isTimelineAutoFollowEnabled = true;
      _timelineBottomFollowRunId += 1;
      _timelineExpansionState.clear();
      _threadUsage = null;
      unawaited(_restorePersistedComposerDraft());
      unawaited(_loadComposerModelCatalog());
      unawaited(_loadThreadUsage());
    }
    if (oldWidget.bridgeApiBaseUrl != widget.bridgeApiBaseUrl) {
      unawaited(_loadComposerModelCatalog());
      unawaited(_loadSpeechStatus());
      unawaited(_loadThreadUsage());
    }
    if (oldWidget.initialComposerInput != widget.initialComposerInput) {
      _didSubmitInitialComposerInput = false;
      _lastInitialSubmitGateLogKey = null;
    }
    if (!listEquals(
      oldWidget.initialAttachedImages,
      widget.initialAttachedImages,
    )) {
      _attachedImages = List<XFile>.unmodifiable(
        _effectiveInitialAttachedImages,
      );
      if (widget.initialAttachedImages.isNotEmpty) {
        _didSubmitInitialComposerInput = false;
        _lastInitialSubmitGateLogKey = null;
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final isWideLayout = AdaptiveLayoutInfo.fromMediaQuery(
      MediaQuery.of(context),
    ).isWideLayout;
    final previousWideLayout = _lastObservedWideLayout;
    _lastObservedWideLayout = isWideLayout;

    if (previousWideLayout == false && isWideLayout) {
      _maybeExitStandaloneDetailForWideLayout();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state != AppLifecycleState.resumed) {
      return;
    }
    unawaited(_refreshThreadConnectionOnResume());
  }

  Future<void> _refreshThreadConnectionOnResume() async {
    if (!mounted || _isDraftMode || _isResumeReconnectInFlight) {
      return;
    }

    final threadId = _effectiveThreadId;
    if (threadId == null || threadId.trim().isEmpty) {
      return;
    }

    _isResumeReconnectInFlight = true;
    final args = ThreadDetailControllerArgs(
      bridgeApiBaseUrl: widget.bridgeApiBaseUrl,
      threadId: threadId,
      initialVisibleTimelineEntries: widget.initialVisibleTimelineEntries,
    );

    try {
      await ref
          .read(threadDetailControllerProvider(args).notifier)
          .retryReconnectCatchUp();
      await _loadThreadUsage();
    } finally {
      _isResumeReconnectInFlight = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_isSpeechRecording) {
      unawaited(_resolvedSpeechCapture.stop());
    }
    _speechRecordingTimer?.cancel();
    final speechCapture = _speechCapture;
    if (speechCapture != null) {
      unawaited(speechCapture.dispose());
    }
    _composerController
      ..removeListener(_handleComposerChanged)
      ..dispose();
    _composerFocusNode
      ..removeListener(_handleComposerFocusChange)
      ..dispose();
    _gitBranchController.dispose();
    _timelineScrollController.removeListener(_onScroll);
    _timelineScrollController.dispose();
    _isHeaderCollapsed.dispose();
    _showNewMessagePill.dispose();
    _newMessagePreview.dispose();
    super.dispose();
  }

  void _scheduleInitialScrollToBottom() {
    if (_didInitialScrollToBottom) {
      return;
    }
    _didInitialScrollToBottom = true;
    // In a reversed list the initial scroll position is already at offset 0
    // (the visual bottom / newest content), so no jump is needed. We just
    // mark the flag to prevent future re-entry.
  }

  /// Scrolls to the visual bottom of the timeline (newest content).
  /// In a reversed list this means jumping to minScrollExtent (offset 0).
  void _followTimelineBottomUntilSettled({
    int remainingFrames = 12,
    int stableFrameCount = 0,
    double? previousMinScrollExtent,
    int? runId,
  }) {
    final activeRunId = runId ?? ++_timelineBottomFollowRunId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || activeRunId != _timelineBottomFollowRunId) {
        return;
      }

      if (!_timelineScrollController.hasClients) {
        if (remainingFrames > 0) {
          _followTimelineBottomUntilSettled(
            remainingFrames: remainingFrames - 1,
            runId: activeRunId,
          );
        }
        return;
      }

      if (!_isTimelineAutoFollowEnabled) {
        return;
      }

      final position = _timelineScrollController.position;
      final minScrollExtent = position.minScrollExtent;
      _isTimelineAutoFollowEnabled = true;
      if ((position.pixels - minScrollExtent).abs() > 0.5) {
        _timelineScrollController.jumpTo(minScrollExtent);
      }

      final hasStableExtent =
          previousMinScrollExtent != null &&
          (minScrollExtent - previousMinScrollExtent).abs() < 0.5;
      final nextStableFrameCount = hasStableExtent ? stableFrameCount + 1 : 0;
      if (remainingFrames <= 0 || nextStableFrameCount >= 2) {
        return;
      }

      _followTimelineBottomUntilSettled(
        remainingFrames: remainingFrames - 1,
        stableFrameCount: nextStableFrameCount,
        previousMinScrollExtent: minScrollExtent,
        runId: activeRunId,
      );
    });
  }

  bool _isTimelineCardExpanded(String id, {required bool defaultValue}) {
    return _timelineExpansionState[id] ?? defaultValue;
  }

  GlobalKey _timelineBlockMeasurementKey(String id) {
    return _timelineBlockMeasurementKeys.putIfAbsent(
      id,
      () => GlobalKey(debugLabel: 'timeline-block:$id'),
    );
  }

  _TimelineViewportAnchor? _captureLeadingVisibleTimelineAnchor() {
    final viewportRenderBox = _timelineViewportRenderBox();
    if (viewportRenderBox == null) {
      return null;
    }
    final viewportHeight = viewportRenderBox.size.height;
    for (final blockId in _timelineBlockOrder) {
      final renderBox = _timelineBlockRenderBox(blockId);
      if (renderBox == null) {
        continue;
      }

      final top = renderBox
          .localToGlobal(Offset.zero, ancestor: viewportRenderBox)
          .dy;
      final bottom = top + renderBox.size.height;
      if (bottom <= 0 || top >= viewportHeight) {
        continue;
      }

      return _TimelineViewportAnchor(blockId: blockId, top: top);
    }

    return null;
  }

  double? _timelineAnchorDelta(_TimelineViewportAnchor? anchor) {
    if (anchor == null) {
      return null;
    }

    final viewportRenderBox = _timelineViewportRenderBox();
    if (viewportRenderBox == null) {
      return null;
    }

    final renderBox = _timelineBlockRenderBox(anchor.blockId);
    if (renderBox == null) {
      return null;
    }

    final currentTop = renderBox
        .localToGlobal(Offset.zero, ancestor: viewportRenderBox)
        .dy;
    return currentTop - anchor.top;
  }

  RenderBox? _timelineViewportRenderBox() {
    final context = _timelineScrollViewKey.currentContext;
    if (context == null) {
      return null;
    }

    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.attached) {
      return null;
    }

    return renderObject;
  }

  RenderBox? _timelineBlockRenderBox(String id) {
    final context = _timelineBlockMeasurementKeys[id]?.currentContext;
    if (context == null) {
      return null;
    }

    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.attached) {
      return null;
    }

    return renderObject;
  }

  String _timelineBlockId(ThreadTimelineBlock block) {
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
      _isTimelineAutoFollowEnabled = true;
      // In a reversed list, the visual bottom (newest content) is at
      // minScrollExtent (offset 0).
      _timelineScrollController.animateTo(
        position.minScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
      );
    });
  }

  void _maybeExitStandaloneDetailForWideLayout() {
    if (_isWideLayoutExitScheduled ||
        !widget.embedInScaffold ||
        _isDraftMode ||
        (widget.onBack == null && !Navigator.of(context).canPop())) {
      return;
    }

    _isWideLayoutExitScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }

      final isWideLayout = AdaptiveLayoutInfo.fromMediaQuery(
        MediaQuery.of(context),
      ).isWideLayout;
      if (!isWideLayout) {
        _isWideLayoutExitScheduled = false;
        return;
      }

      final onBack = widget.onBack;
      if (onBack != null) {
        onBack();
        if (mounted) {
          _isWideLayoutExitScheduled = false;
        }
        return;
      }

      final navigator = Navigator.of(context);
      if (!navigator.canPop()) {
        _isWideLayoutExitScheduled = false;
        return;
      }
      navigator.pop();
    });
  }

  Future<void> _pickImages() async {
    final images =
        await widget.pickImagesOverride?.call() ??
        await _imagePicker.pickMultiImage(imageQuality: 90, maxWidth: 2048);
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

  Future<void> _toggleSpeechInput() async {
    if (_isSpeechTranscribing) {
      return;
    }

    if (_isSpeechRecording) {
      await _stopSpeechRecordingAndTranscribe();
      return;
    }

    await _loadSpeechStatus();
    if (_speechModelStatus.state != SpeechModelState.ready) {
      await _showSpeechUnavailableDialogForStatus(_speechModelStatus);
      return;
    }

    try {
      final hasPermission = await _resolvedSpeechCapture.hasPermission();
      if (!hasPermission) {
        _setSpeechMessage(
          'Microphone permission is required to record a voice message.',
          isError: true,
        );
        return;
      }

      await _resolvedSpeechCapture.start();
      if (!mounted) {
        return;
      }
      setState(() {
        _isSpeechRecording = true;
        _speechDurationSeconds = 0;
        _speechMessage = 'Recording voice message… tap the mic again to stop.';
        _speechMessageIsError = false;
        _speechRecordingTimer?.cancel();
        _speechRecordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
          if (mounted) {
            setState(() {
              _speechDurationSeconds++;
            });
          }
        });
      });
    } on SpeechCaptureException catch (error) {
      _setSpeechMessage(_speechCaptureErrorMessageFor(error), isError: true);
    } catch (_) {
      _setSpeechMessage(
        'Couldn’t start recording right now. Please try again.',
        isError: true,
      );
    }
  }

  Future<void> _stopSpeechRecordingAndTranscribe() async {
    _speechRecordingTimer?.cancel();
    _speechRecordingTimer = null;
    _SpeechUnavailableDialogContent? pendingSpeechDialog;
    setState(() {
      _isSpeechRecording = false;
      _isSpeechTranscribing = true;
      _speechMessage = 'Transcribing voice message…';
      _speechMessageIsError = false;
    });

    try {
      final captureResult = await _resolvedSpeechCapture.stop();
      final bridgeApi = ref.read(threadDetailBridgeApiProvider);
      final result = await bridgeApi.transcribeAudio(
        bridgeApiBaseUrl: widget.bridgeApiBaseUrl,
        audioBytes: captureResult.bytes,
        fileName: captureResult.fileName,
      );
      if (!mounted) {
        return;
      }
      _insertSpeechTranscript(result.text);
      _setSpeechMessage(
        'Transcript inserted into the composer.',
        isError: false,
      );
      await _loadSpeechStatus();
    } on ThreadSpeechBridgeException catch (error) {
      if (_shouldShowSpeechUnavailableDialogForError(error)) {
        await _loadSpeechStatus();
        pendingSpeechDialog =
            _speechUnavailableDialogContentForStatus(_speechModelStatus) ??
            _speechUnavailableDialogContentForError(error);
        if (pendingSpeechDialog == null) {
          _setSpeechMessage(_speechErrorMessageFor(error), isError: true);
        }
      } else {
        _setSpeechMessage(_speechErrorMessageFor(error), isError: true);
      }
    } on SpeechCaptureException catch (error) {
      _setSpeechMessage(_speechCaptureErrorMessageFor(error), isError: true);
    } finally {
      if (mounted) {
        setState(() {
          _isSpeechTranscribing = false;
        });
      }
    }

    final speechDialog = pendingSpeechDialog;
    if (speechDialog != null) {
      await _showSpeechUnavailableDialog(speechDialog);
    }
  }

  void _insertSpeechTranscript(String transcript) {
    final trimmedTranscript = transcript.trim();
    if (trimmedTranscript.isEmpty) {
      return;
    }

    final currentText = _composerController.text;
    final nextText = currentText.trim().isEmpty
        ? trimmedTranscript
        : '$currentText ${trimmedTranscript.trimLeft()}';
    _composerController.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: nextText.length),
    );
  }

  void _setSpeechMessage(String message, {required bool isError}) {
    if (!mounted) {
      return;
    }

    setState(() {
      _speechMessage = message;
      _speechMessageIsError = isError;
    });
  }

  Future<void> _showSpeechUnavailableDialogForStatus(
    SpeechModelStatusDto status,
  ) async {
    final content = _speechUnavailableDialogContentForStatus(status);
    if (content == null) {
      return;
    }

    await _showSpeechUnavailableDialog(content);
  }

  Future<void> _showSpeechUnavailableDialog(
    _SpeechUnavailableDialogContent content,
  ) async {
    if (!mounted) {
      return;
    }

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          key: const Key('speech-unavailable-dialog'),
          title: Text(content.title),
          content: Text(content.message),
          actions: [
            TextButton(
              key: const Key('speech-unavailable-dialog-dismiss'),
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Dismiss'),
            ),
          ],
        );
      },
    );
  }

  _SpeechUnavailableDialogContent? _speechUnavailableDialogContentForStatus(
    SpeechModelStatusDto status,
  ) {
    switch (status.state) {
      case SpeechModelState.ready:
        return null;
      case SpeechModelState.notInstalled:
        return const _SpeechUnavailableDialogContent(
          title: 'Install Parakeet',
          message:
              'Parakeet is not installed on this host yet. Install it from the desktop host shell before using voice input.',
        );
      case SpeechModelState.unsupported:
        return _SpeechUnavailableDialogContent(
          title: 'Speech unavailable',
          message:
              status.lastError ??
              'Speech transcription is unavailable on this host or in this build.',
        );
      case SpeechModelState.installing:
        return const _SpeechUnavailableDialogContent(
          title: 'Parakeet is installing',
          message:
              'Parakeet is still being installed on this host. Wait for the download to finish, then try again.',
        );
      case SpeechModelState.busy:
        return const _SpeechUnavailableDialogContent(
          title: 'Speech busy',
          message:
              'Another speech task is already running on this host. Wait for it to finish, then try again.',
        );
      case SpeechModelState.failed:
        return _SpeechUnavailableDialogContent(
          title: 'Speech unavailable',
          message:
              status.lastError ??
              'Speech transcription is unavailable right now.',
        );
    }
  }

  _SpeechUnavailableDialogContent? _speechUnavailableDialogContentForError(
    ThreadSpeechBridgeException error,
  ) {
    switch (error.code) {
      case 'speech_not_installed':
        return const _SpeechUnavailableDialogContent(
          title: 'Install Parakeet',
          message:
              'Parakeet is not installed on this host yet. Install it from the desktop host shell before using voice input.',
        );
      case 'speech_unsupported':
        return _SpeechUnavailableDialogContent(
          title: 'Speech unavailable',
          message: error.message.isNotEmpty
              ? error.message
              : 'Speech transcription is unavailable on this host or in this build.',
        );
      case 'speech_busy':
        return const _SpeechUnavailableDialogContent(
          title: 'Speech busy',
          message:
              'Another speech task is already running on this host. Wait for it to finish, then try again.',
        );
      case 'speech_helper_unavailable':
      case 'speech_transcription_failed':
        return _SpeechUnavailableDialogContent(
          title: 'Speech unavailable',
          message: error.message.isNotEmpty
              ? error.message
              : 'Speech transcription is unavailable right now.',
        );
      default:
        return null;
    }
  }

  bool _shouldShowSpeechUnavailableDialogForError(
    ThreadSpeechBridgeException error,
  ) {
    switch (error.code) {
      case 'speech_not_installed':
      case 'speech_unsupported':
      case 'speech_busy':
      case 'speech_helper_unavailable':
      case 'speech_transcription_failed':
        return true;
      default:
        return false;
    }
  }

  String _speechErrorMessageFor(ThreadSpeechBridgeException error) {
    if (error.isConnectivityError) {
      return 'Cannot reach the host bridge. Check your private route.';
    }

    switch (error.code) {
      case 'speech_unsupported':
        return 'Speech transcription isn’t available on this host yet.';
      case 'speech_not_installed':
        return 'Parakeet is not installed on this host yet.';
      case 'speech_busy':
        return 'Another speech task is already running on this host.';
      case 'speech_helper_unavailable':
        return 'The host speech helper is unavailable right now.';
      case 'speech_invalid_audio':
        return 'That recording could not be processed as WAV audio.';
      default:
        return error.message;
    }
  }

  String _speechCaptureErrorMessageFor(SpeechCaptureException error) {
    switch (error.code) {
      case 'speech_capture_unsupported':
        return 'Voice capture is unavailable in this browser.';
      case 'speech_capture_read_failed':
        return 'Couldn’t read the recording for transcription.';
      default:
        return error.message;
    }
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

  void _handleTimelineUserScrollDirection(ScrollDirection direction) {
    if (direction == ScrollDirection.idle) {
      return;
    }

    _markTimelineUserScroll();
    if (!_isTimelineNearBottom(tolerance: 180)) {
      _isTimelineAutoFollowEnabled = false;
      return;
    }

    // In a reversed list, ScrollDirection.forward means the user is
    // dragging toward the visual bottom (newer content), which is the
    // direction where auto-follow should re-engage.
    if (direction == ScrollDirection.forward) {
      _isTimelineAutoFollowEnabled = true;
    }
  }

  Future<void> _showGitBranchSheet(
    BuildContext context, {
    required _ResolvedGitControls gitControls,
    required Future<bool> Function(String rawBranch) onSwitchBranch,
    required bool canStartCommit,
    required Future<bool> Function() onStartCommitAction,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.background,
      isScrollControlled: true,
      builder: (context) => _GitBranchSheet(
        gitControls: gitControls,
        gitBranchController: _gitBranchController,
        onSwitchBranch: onSwitchBranch,
        canStartCommit: canStartCommit,
        onStartCommitAction: onStartCommitAction,
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
    _logDraftFlow('draft_submit_started', <String, Object?>{
      'workspacePath': workspacePath,
      'rawChars': rawInput.length,
      'trimmedChars': rawInput.trim().length,
      'attachedImageCount': _attachedImages.length,
      'selectedProvider': _selectedProvider.wireValue,
      'selectedModel': _selectedModel,
      'composerMode': _composerMode.wireValue,
    });
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
        provider: _selectedProvider,
        model: _selectedModel,
      );
      final thread = snapshot.thread;
      _logDraftFlow('draft_thread_created', <String, Object?>{
        'createdThreadId': thread.threadId,
        'threadStatus': thread.status.wireValue,
        'inputChars': input.length,
        'attachedImageCount': _attachedImages.length,
      });
      final listController = ref.read(
        threadListControllerProvider(widget.bridgeApiBaseUrl).notifier,
      );
      listController.syncThreadDetail(thread);
      _persistSelectedThreadId(listController, thread.threadId);
      if (!mounted) {
        return true;
      }

      final transition = ThreadDraftCreatedTransition(
        threadId: thread.threadId,
        initialComposerInput: input,
        initialAttachedImages: _attachedImages,
        initialTurnMode: _supportsPlanMode ? _composerMode : TurnMode.act,
        initialSelectedModel: _selectedModel,
        initialSelectedReasoningEffort: _selectedReasoningEffortWireValue(),
      );
      if (widget.onDraftThreadCreated != null) {
        _logDraftFlow('draft_thread_created_callback', <String, Object?>{
          'createdThreadId': thread.threadId,
          'inputChars': input.length,
        });
        unawaited(
          ref
              .read(threadComposerDraftRepositoryProvider)
              .saveDraft('thread:${thread.threadId}', input),
        );
        unawaited(_clearComposerDraft(draftId: 'workspace:$workspacePath'));
        widget.onDraftThreadCreated!(transition);
        return true;
      }

      setState(() {
        _localDraftTransition = transition;
        _isDraftThreadCreationInFlight = false;
        _draftThreadErrorMessage = null;
        _didInitialScrollToBottom = false;
        _didSubmitInitialComposerInput = false;
        _lastInitialSubmitGateLogKey = null;
        _timelineExpansionState.clear();
        _attachedImages = List<XFile>.unmodifiable(
          transition.initialAttachedImages,
        );
      });
      _logDraftFlow('draft_transition_installed', <String, Object?>{
        'createdThreadId': transition.threadId,
        'inputChars': transition.initialComposerInput.length,
        'attachedImageCount': transition.initialAttachedImages.length,
        'initialTurnMode': transition.initialTurnMode.wireValue,
      });
      unawaited(_loadThreadUsage());
      unawaited(
        ref
            .read(threadComposerDraftRepositoryProvider)
            .saveDraft('thread:${thread.threadId}', input),
      );
      unawaited(_clearComposerDraft(draftId: 'workspace:$workspacePath'));
      return true;
    } on ThreadCreateBridgeException catch (error) {
      _logDraftFlow('draft_thread_create_failed', <String, Object?>{
        'message': error.message,
        'isConnectivityError': error.isConnectivityError,
      });
      if (!mounted) {
        return false;
      }
      setState(() {
        _isDraftThreadCreationInFlight = false;
        _draftThreadErrorMessage = error.message;
      });
      return false;
    } catch (error, stackTrace) {
      _logDraftFlow('draft_thread_create_failed_unknown', <String, Object?>{
        'error': error.toString(),
        'stackPreview': stackTrace.toString().split('\n').take(6).join('\n'),
      });
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
    TurnMode? mode,
    List<XFile>? attachedImages,
  }) async {
    _logDraftFlow('initial_submit_invoked', <String, Object?>{
      'threadId': controller.currentThread?.threadId ?? _effectiveThreadId,
      'rawChars': rawInput.length,
      'trimmedChars': rawInput.trim().length,
      'attachedImageCount': (attachedImages ?? _attachedImages).length,
      'mode': (mode ?? _composerMode).wireValue,
      'controllerHasThread': controller.currentThread != null,
      'controllerStatus': controller.currentThread?.status.wireValue,
      'canRunMutatingActions': controller.canRunMutatingActions,
      'isConnectivityUnavailable': controller.isConnectivityUnavailable,
      'liveConnectionState': controller.liveConnectionState.name,
      'turnControlErrorMessage': controller.turnControlErrorMessage,
    });
    final imageDataUrls = await _encodeAttachedImages(
      attachedImages ?? _attachedImages,
    );
    final success = await controller.submitComposerInput(
      rawInput,
      mode: mode ?? _composerMode,
      images: imageDataUrls,
      model: _selectedModel,
      reasoningEffort: _selectedReasoningEffortWireValue(),
    );
    _logDraftFlow('initial_submit_completed', <String, Object?>{
      'success': success,
      'threadId': controller.currentThread?.threadId ?? _effectiveThreadId,
      'controllerStatus': controller.currentThread?.status.wireValue,
      'canRunMutatingActions': controller.canRunMutatingActions,
      'isConnectivityUnavailable': controller.isConnectivityUnavailable,
      'liveConnectionState': controller.liveConnectionState.name,
      'turnControlErrorMessage': controller.turnControlErrorMessage,
    });
    if (!mounted || !success) {
      return success;
    }

    await _clearComposerDraft();
    setState(() {
      _attachedImages = const <XFile>[];
      _draftThreadErrorMessage = null;
    });
    unawaited(_loadThreadUsage());
    return true;
  }

  Future<bool> _submitPendingUserInput(
    ThreadDetailController controller,
    PendingUserInputDto pendingUserInput,
    String rawInput,
  ) async {
    final answers = _selectedPlanOptionByQuestionId.entries
        .map(
          (entry) =>
              UserInputAnswerDto(questionId: entry.key, optionId: entry.value),
        )
        .toList(growable: false);
    final success = await controller.respondToPendingUserInput(
      freeText: rawInput,
      answers: answers,
      model: _selectedModel,
      reasoningEffort: _selectedReasoningEffortWireValue(),
    );
    if (!mounted || !success) {
      return success;
    }

    await _clearComposerDraft();
    setState(() {
      _selectedPlanOptionByQuestionId.clear();
      _lastPendingUserInputRequestId = null;
    });
    unawaited(_loadThreadUsage());
    return true;
  }

  void _handlePendingUserInputSelection(
    ThreadDetailController controller,
    PendingUserInputDto pendingUserInput,
    String questionId,
    String optionId,
  ) {
    if (!mounted) {
      return;
    }

    setState(() {
      _selectedPlanOptionByQuestionId[questionId] = optionId;
    });

    if (_isProviderApprovalPrompt(pendingUserInput)) {
      unawaited(_submitPendingUserInput(controller, pendingUserInput, ''));
    }
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
    final currentSession = ref.watch(
      currentBridgeSessionProvider(widget.bridgeApiBaseUrl),
    );
    final deviceSettingsState = ref.watch(
      deviceSettingsControllerProvider(widget.bridgeApiBaseUrl),
    );
    final deviceSettingsController = ref.read(
      deviceSettingsControllerProvider(widget.bridgeApiBaseUrl).notifier,
    );

    Future<void> changeAccessMode(AccessMode mode) async {
      if (currentSession == null || !currentSession.canMutateAccessMode) {
        return;
      }

      await deviceSettingsController.setAccessMode(
        accessMode: mode,
        session: currentSession,
      );
    }

    if (_isDraftMode) {
      final effectiveAccessMode =
          runtimeAccessMode ?? AccessMode.controlWithApprovals;
      final isReadOnlyMode = effectiveAccessMode == AccessMode.readOnly;
      final controlsEnabled = !isReadOnlyMode;

      Future<void> openSettingsSheet() async {
        _composerFocusNode.unfocus();
        await showModalBottomSheet<void>(
          context: context,
          backgroundColor: Colors.transparent,
          isScrollControlled: true,
          builder: (context) => _ComposerModelSheet(
            modelOptions: _availableModelOptions,
            reasoningOptions: _availableReasoningOptions,
            initialProvider: _selectedProvider,
            canChangeProvider: _canChangeComposerProvider,
            initialModel: _selectedModel,
            initialReasoning: _selectedReasoning,
            selectedAccessMode: effectiveAccessMode,
            session: currentSession,
            isAccessModeUpdating: deviceSettingsState.isAccessModeUpdating,
            onProviderChanged: _onComposerProviderChanged,
            onModelChanged: _onComposerModelChanged,
            onReasoningChanged: (value) {
              setState(() {
                _selectedReasoning = value;
              });
            },
            onAccessModeChanged: changeAccessMode,
          ),
        );
      }

      return _wrapContent(
        Column(
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
                      onBack:
                          widget.onBack ?? () => Navigator.of(context).pop(),
                      showBackButton: widget.showBackButton,
                      onOpenSettings: openSettingsSheet,
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
                          isSpeechRecording: _isSpeechRecording,
                          isSpeechTranscribing: _isSpeechTranscribing,
                          speechDurationSeconds: _speechDurationSeconds,
                          speechAmplitudeStream: _isSpeechRecording
                              ? _resolvedSpeechCapture.amplitudeStream(
                                  const Duration(milliseconds: 50),
                                )
                              : null,
                          speechMessage: _speechMessage,
                          speechMessageIsError: _speechMessageIsError,
                          isComposerFocused: _isComposerFocused,
                          attachedImages: _attachedImages,
                          threadUsage: _threadUsage,
                          composerMode: _composerMode,
                          pendingUserInput: null,
                          selectedPlanOptionByQuestionId:
                              _selectedPlanOptionByQuestionId,
                          selectedProvider: _selectedProvider,
                          selectedModel: _selectedModel,
                          selectedReasoning: _selectedReasoning,
                          supportsPlanMode: _supportsPlanMode,
                          session: currentSession,
                          accessModeErrorMessage:
                              deviceSettingsState.accessModeErrorMessage,
                          onPickImages: _pickImages,
                          onToggleSpeechInput: _toggleSpeechInput,
                          onRemoveImage: _removeAttachedImage,
                          onComposerModeChanged: (mode) {
                            setState(() {
                              _composerMode = mode;
                            });
                          },
                          onSelectPlanOption: (questionId, optionId) {
                            setState(() {
                              _selectedPlanOptionByQuestionId[questionId] =
                                  optionId;
                            });
                          },
                          onSubmitComposer: _submitDraftComposerInput,
                          onSubmitPendingUserInput: null,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    final args = ThreadDetailControllerArgs(
      bridgeApiBaseUrl: widget.bridgeApiBaseUrl,
      threadId: _effectiveThreadId!,
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

          // In a reversed list the viewport starts at offset 0 (the visual
          // bottom). During the initial load the scroll controller may not
          // have clients yet, so _isTimelineNearBottom() can return false
          // even though the user is at the bottom. Treat the period before
          // the initial scroll flag is set as "near bottom" to avoid
          // flashing the new-message pill on every thread open.
          final isNearBottom =
              !_didInitialScrollToBottom || _isTimelineNearBottom();
          if (_isTimelineAutoFollowEnabled && isNearBottom) {
            _newMessagePreview.value = null;
            _scrollToTimelineBottom();
          } else {
            final preview = next.$3?.trim();
            _newMessagePreview.value = preview == null || preview.isEmpty
                ? null
                : preview;
            _showNewMessagePill.value = true;
          }
        }
      },
    );

    if (!_didSubmitInitialComposerInput &&
        _hasPendingInitialComposerSubmission) {
      final gateLogKey = jsonEncode(<String, Object?>{
        'effectiveThreadId': _effectiveThreadId,
        'isLoading': state.isLoading,
        'hasThread': state.hasThread,
        'isTurnActive': state.isTurnActive,
        'isComposerMutationInFlight': state.isComposerMutationInFlight,
        'didSubmitInitialComposerInput': _didSubmitInitialComposerInput,
        'hasPendingInitialComposerSubmission':
            _hasPendingInitialComposerSubmission,
        'initialInputChars': _effectiveInitialComposerInput?.trim().length ?? 0,
        'initialAttachedImageCount': _effectiveInitialAttachedImages.length,
      });
      if (_lastInitialSubmitGateLogKey != gateLogKey) {
        _lastInitialSubmitGateLogKey = gateLogKey;
        _logDraftFlow('initial_submit_gate', <String, Object?>{
          'effectiveThreadId': _effectiveThreadId,
          'isLoading': state.isLoading,
          'hasThread': state.hasThread,
          'isTurnActive': state.isTurnActive,
          'isComposerMutationInFlight': state.isComposerMutationInFlight,
          'canRunMutatingActions': state.canRunMutatingActions,
          'isConnectivityUnavailable': state.isConnectivityUnavailable,
          'liveConnectionState': state.liveConnectionState.name,
          'turnControlErrorMessage': state.turnControlErrorMessage,
          'initialInputChars':
              _effectiveInitialComposerInput?.trim().length ?? 0,
          'initialAttachedImageCount': _effectiveInitialAttachedImages.length,
        });
      }
    }

    if (!_didSubmitInitialComposerInput &&
        !state.isLoading &&
        state.hasThread &&
        !state.isTurnActive &&
        !state.isComposerMutationInFlight &&
        _hasPendingInitialComposerSubmission) {
      final initialComposerInput = _effectiveInitialComposerInput?.trim();
      if (initialComposerInput != null ||
          _effectiveInitialAttachedImages.isNotEmpty) {
        _didSubmitInitialComposerInput = true;
        _logDraftFlow('initial_submit_scheduled', <String, Object?>{
          'threadId': _effectiveThreadId,
          'inputChars': initialComposerInput?.length ?? 0,
          'attachedImageCount': _effectiveInitialAttachedImages.length,
          'mode': _effectiveInitialTurnMode.wireValue,
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) {
            return;
          }
          unawaited(
            _submitComposerInput(
              controller,
              initialComposerInput ?? '',
              mode: _effectiveInitialTurnMode,
            ),
          );
        });
      }
    }

    final threadApprovals = approvalsState.forThread(_effectiveThreadId!);
    final pendingUserInput = state.pendingUserInput;
    final pendingUserInputRequestId = pendingUserInput?.requestId;
    if (_lastPendingUserInputRequestId != pendingUserInputRequestId) {
      _lastPendingUserInputRequestId = pendingUserInputRequestId;
      _selectedPlanOptionByQuestionId.clear();
      if (pendingUserInputRequestId != null) {
        _composerController.clear();
      }
    }
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

    Future<void> openSettingsSheet() async {
      _composerFocusNode.unfocus();
      await showModalBottomSheet<void>(
        context: context,
        backgroundColor: Colors.transparent,
        isScrollControlled: true,
        builder: (context) => _ComposerModelSheet(
          modelOptions: _availableModelOptions,
          reasoningOptions: _availableReasoningOptions,
          initialProvider: _selectedProvider,
          canChangeProvider: _canChangeComposerProvider,
          initialModel: _selectedModel,
          initialReasoning: _selectedReasoning,
          selectedAccessMode: effectiveAccessMode,
          session: currentSession,
          isAccessModeUpdating: deviceSettingsState.isAccessModeUpdating,
          onProviderChanged: _onComposerProviderChanged,
          onModelChanged: _onComposerModelChanged,
          onReasoningChanged: (value) {
            setState(() {
              _selectedReasoning = value;
            });
          },
          onAccessModeChanged: changeAccessMode,
        ),
      );
    }

    _canLoadEarlierHistory = state.canLoadEarlierHistory;
    _loadEarlierHistory = controller.loadEarlierHistory;
    _timelineBlockOrder = buildThreadTimelineBlocks(
      state.visibleItems,
    ).map(_timelineBlockId).toList(growable: false);

    if (state.hasThread &&
        !state.isInitialTimelineLoading &&
        !_didInitialScrollToBottom) {
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
        canStartCommit:
            state.canRunMutatingActions &&
            !state.isComposerMutationInFlight &&
            !state.isTurnActive,
        onStartCommitAction: () {
          return controller.submitCommitAction(
            model: _selectedModel,
            reasoningEffort: _selectedReasoningEffortWireValue(),
          );
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

    return _wrapContent(
      Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                _ThreadDetailBody(
                  state: state,
                  isReadOnlyMode: isReadOnlyMode,
                  controlsEnabled: controlsEnabled,
                  onInterruptActiveTurn: controller.interruptActiveTurn,
                  desktopIntegrationEnabled: desktopIntegrationState.isEnabled,
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
                  onTimelineUserScroll: _handleTimelineUserScrollDirection,
                  scrollController: _timelineScrollController,
                  isTimelineCardExpanded: _isTimelineCardExpanded,
                  onTimelineCardExpansionChanged: _setTimelineCardExpanded,
                  timelineBlockMeasurementKey: _timelineBlockMeasurementKey,
                  timelineScrollViewKey: _timelineScrollViewKey,
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
                    onBackWhenLoaded:
                        widget.onBack ?? () => Navigator.of(context).maybePop(),
                    onBackWhenUnavailable:
                        widget.onBack ?? () => Navigator.of(context).pop(),
                    onOpenGitBranchSheet: openGitBranchSheet,
                    onOpenGitSyncSheet: openGitSyncSheet,
                    onOpenOnMac: controller.openOnMac,
                    onOpenDiff: _openDiffView,
                    onToggleSidebar: widget.onToggleSidebar,
                    onToggleDiff: _toggleDiffView,
                    onOpenSettings: openSettingsSheet,
                    isHeaderCollapsed: _isHeaderCollapsed,
                    showBackButton: widget.showBackButton,
                    isSidebarVisible: widget.isSidebarVisible ?? true,
                    isDiffVisible: widget.isDiffVisible ?? false,
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
                                          child: SizedBox(
                                            width: 40,
                                            height: 40,
                                            child: DecoratedBox(
                                              decoration: BoxDecoration(
                                                color: AppTheme.surfaceZinc800
                                                    .withValues(alpha: 0.94),
                                                shape: BoxShape.circle,
                                                border: Border.all(
                                                  color: Colors.white
                                                      .withValues(alpha: 0.08),
                                                ),
                                              ),
                                              child: IconButton(
                                                key: const Key(
                                                  'thread-detail-new-message-button',
                                                ),
                                                tooltip:
                                                    'Scroll to new messages',
                                                padding: EdgeInsets.zero,
                                                visualDensity:
                                                    VisualDensity.compact,
                                                iconSize: 18,
                                                onPressed: () {
                                                  _isTimelineAutoFollowEnabled =
                                                      true;
                                                  _showNewMessagePill.value =
                                                      false;
                                                  _newMessagePreview.value =
                                                      null;
                                                  _followTimelineBottomUntilSettled();
                                                },
                                                icon: PhosphorIcon(
                                                  PhosphorIcons.arrowDown(),
                                                  color: AppTheme.textMain,
                                                ),
                                              ),
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
                              isSpeechRecording: _isSpeechRecording,
                              isSpeechTranscribing: _isSpeechTranscribing,
                              speechDurationSeconds: _speechDurationSeconds,
                              speechAmplitudeStream: _isSpeechRecording
                                  ? _resolvedSpeechCapture.amplitudeStream(
                                      const Duration(milliseconds: 50),
                                    )
                                  : null,
                              speechMessage: _speechMessage,
                              speechMessageIsError: _speechMessageIsError,
                              isComposerFocused: _isComposerFocused,
                              attachedImages: _attachedImages,
                              threadUsage: _threadUsage,
                              composerMode: _composerMode,
                              pendingUserInput: pendingUserInput,
                              selectedPlanOptionByQuestionId:
                                  _selectedPlanOptionByQuestionId,
                              selectedProvider: _selectedProvider,
                              selectedModel: _selectedModel,
                              selectedReasoning: _selectedReasoning,
                              supportsPlanMode: _supportsPlanMode,
                              session: currentSession,
                              accessModeErrorMessage:
                                  deviceSettingsState.accessModeErrorMessage,
                              onPickImages: _pickImages,
                              onToggleSpeechInput: _toggleSpeechInput,
                              onRemoveImage: _removeAttachedImage,
                              onComposerModeChanged: (mode) {
                                setState(() {
                                  _composerMode = mode;
                                });
                              },
                              onSelectPlanOption: (questionId, optionId) {
                                final activePendingUserInput = pendingUserInput;
                                if (activePendingUserInput == null) {
                                  return;
                                }
                                _handlePendingUserInputSelection(
                                  controller,
                                  activePendingUserInput,
                                  questionId,
                                  optionId,
                                );
                              },
                              onSubmitComposer: (value) =>
                                  _submitComposerInput(controller, value),
                              onSubmitPendingUserInput: pendingUserInput == null
                                  ? null
                                  : (value) => _submitPendingUserInput(
                                      controller,
                                      pendingUserInput,
                                      value,
                                    ),
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
    );
  }

  Widget _wrapContent(Widget child) {
    final content = widget.embedInScaffold ? SafeArea(child: child) : child;
    if (!widget.embedInScaffold) {
      return ColoredBox(color: AppTheme.background, child: content);
    }

    return Scaffold(backgroundColor: AppTheme.background, body: content);
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
