import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:codex_mobile_companion/features/approvals/application/approvals_queue_controller.dart';
import 'package:codex_mobile_companion/features/approvals/presentation/approval_presenter.dart';
import 'package:codex_mobile_companion/features/settings/application/desktop_integration_controller.dart';
import 'package:codex_mobile_companion/features/settings/application/device_settings_controller.dart';
import 'package:codex_mobile_companion/features/settings/application/runtime_access_mode.dart';
import 'package:codex_mobile_companion/features/threads/application/thread_detail_controller.dart';
import 'package:codex_mobile_companion/features/threads/data/thread_detail_bridge_api.dart';
import 'package:codex_mobile_companion/features/threads/domain/parsed_command_output.dart';
import 'package:codex_mobile_companion/features/threads/domain/thread_activity_item.dart';
import 'package:codex_mobile_companion/features/threads/domain/thread_timeline_block.dart';
import 'package:codex_mobile_companion/features/threads/presentation/thread_git_diff_page.dart';
import 'package:codex_mobile_companion/foundation/connectivity/live_connection_state.dart';
import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:codex_mobile_companion/foundation/layout/adaptive_layout.dart';
import 'package:codex_mobile_companion/foundation/session/current_bridge_session.dart';
import 'package:codex_ui/codex_ui.dart';

import 'package:codex_mobile_companion/shared/widgets/badges.dart';
import 'package:codex_mobile_companion/shared/widgets/connection_status_banner.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:record/record.dart';
import 'package:syntax_highlight/syntax_highlight.dart';

import '../application/thread_list_controller.dart';

part 'thread_detail_page_body.dart';
part 'thread_detail_page_composer.dart';
part 'thread_detail_page_draft.dart';
part 'thread_detail_page_header.dart';
part 'thread_detail_page_message.dart';
part 'thread_detail_page_timeline.dart';

const double threadSessionContentMaxWidth = 1280;

class ThreadDraftCreatedTransition {
  const ThreadDraftCreatedTransition({
    required this.threadId,
    required this.initialComposerInput,
    required this.initialAttachedImages,
    required this.initialSelectedModel,
    required this.initialSelectedReasoningEffort,
  });

  final String threadId;
  final String initialComposerInput;
  final List<XFile> initialAttachedImages;
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
    this.speechRecorder,
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
    this.speechRecorder,
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
  final AudioRecorder? speechRecorder;
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

class _ThreadDetailPageState extends ConsumerState<ThreadDetailPage> {
  static const double _historyPrefetchTriggerOffset = 160;
  static const double _sessionContentMaxWidth = threadSessionContentMaxWidth;

  late final TextEditingController _composerController;
  late final FocusNode _composerFocusNode;
  late final TextEditingController _gitBranchController;
  late final ScrollController _timelineScrollController;
  late final ValueNotifier<bool> _isHeaderCollapsed;
  late final ValueNotifier<bool> _showNewMessagePill;
  final ImagePicker _imagePicker = ImagePicker();
  late final AudioRecorder _audioRecorder;

  List<ModelOptionDto> _availableModelOptions = fallbackModelCatalog.models;
  List<String> _availableReasoningOptions = const <String>[];
  List<XFile> _attachedImages = const <XFile>[];
  String _selectedModel = fallbackModelCatalog.models.first.id;
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
  String? _speechRecordingPath;
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
  Future<void> Function()? _loadEarlierHistory;
  String? _draftThreadErrorMessage;
  final Map<String, bool> _timelineExpansionState = <String, bool>{};
  bool? _lastObservedWideLayout;
  bool _isWideLayoutExitScheduled = false;

  double _lastScrollOffset = 0;
  double _scrollOffsetOnDirectionChange = 0;
  bool _isScrollingDown = false;

  bool get _isDraftMode =>
      widget.threadId == null && _localDraftTransition == null;

  String? get _effectiveThreadId =>
      widget.threadId ?? _localDraftTransition?.threadId;

  String? get _effectiveInitialComposerInput =>
      _localDraftTransition?.initialComposerInput ??
      widget.initialComposerInput;

  List<XFile> get _effectiveInitialAttachedImages =>
      _localDraftTransition?.initialAttachedImages ??
      widget.initialAttachedImages;

  bool get _hasPendingInitialComposerSubmission {
    final initialComposerInput = _effectiveInitialComposerInput?.trim();
    return (initialComposerInput != null && initialComposerInput.isNotEmpty) ||
        _effectiveInitialAttachedImages.isNotEmpty;
  }

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
    _audioRecorder = widget.speechRecorder ?? AudioRecorder();
    _composerFocusNode.addListener(_handleComposerFocusChange);
    _timelineScrollController.addListener(_onScroll);
    _setComposerSelectionsFromCatalog(_availableModelOptions);
    _attachedImages = List<XFile>.unmodifiable(_effectiveInitialAttachedImages);
    unawaited(_loadComposerModelCatalog());
    unawaited(_loadSpeechStatus());
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
      _localDraftTransition = null;
      _didInitialScrollToBottom = false;
      _didSubmitInitialComposerInput = false;
      _timelineExpansionState.clear();
    }
    if (oldWidget.bridgeApiBaseUrl != widget.bridgeApiBaseUrl) {
      unawaited(_loadComposerModelCatalog());
      unawaited(_loadSpeechStatus());
    }
    if (oldWidget.initialComposerInput != widget.initialComposerInput) {
      _didSubmitInitialComposerInput = false;
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
  void dispose() {
    if (_isSpeechRecording) {
      unawaited(_audioRecorder.stop());
    }
    _speechRecordingTimer?.cancel();
    _audioRecorder.dispose();
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

    final hasPermission = await _audioRecorder.hasPermission();
    if (!hasPermission) {
      _setSpeechMessage(
        'Microphone permission is required to record a voice message.',
        isError: true,
      );
      return;
    }

    final recordingDirectory = await Directory.systemTemp.createTemp(
      'codex-mobile-companion-speech-',
    );
    final recordingPath = '${recordingDirectory.path}/voice-message.wav';

    try {
      await _audioRecorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: recordingPath,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _isSpeechRecording = true;
        _speechDurationSeconds = 0;
        _speechRecordingPath = recordingPath;
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
    final previousRecordingPath = _speechRecordingPath;
    _SpeechUnavailableDialogContent? pendingSpeechDialog;
    setState(() {
      _isSpeechRecording = false;
      _isSpeechTranscribing = true;
      _speechMessage = 'Transcribing voice message…';
      _speechMessageIsError = false;
    });

    try {
      final resolvedPath = await _audioRecorder.stop() ?? previousRecordingPath;
      if (resolvedPath == null || resolvedPath.trim().isEmpty) {
        throw const ThreadSpeechBridgeException(
          message: 'No audio was captured for transcription.',
          code: 'speech_invalid_audio',
        );
      }

      final audioBytes = await File(resolvedPath).readAsBytes();
      final bridgeApi = ref.read(threadDetailBridgeApiProvider);
      final result = await bridgeApi.transcribeAudio(
        bridgeApiBaseUrl: widget.bridgeApiBaseUrl,
        audioBytes: audioBytes,
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
    } on FileSystemException {
      _setSpeechMessage(
        'Couldn’t read the recording for transcription.',
        isError: true,
      );
    } finally {
      await _cleanupSpeechRecording(
        previousRecordingPath ?? _speechRecordingPath,
      );
      if (mounted) {
        setState(() {
          _isSpeechTranscribing = false;
          _speechRecordingPath = null;
        });
      }
    }

    final speechDialog = pendingSpeechDialog;
    if (speechDialog != null) {
      await _showSpeechUnavailableDialog(speechDialog);
    }
  }

  Future<void> _cleanupSpeechRecording(String? recordingPath) async {
    if (recordingPath == null || recordingPath.trim().isEmpty) {
      return;
    }

    final directory = File(recordingPath).parent;
    if (await directory.exists()) {
      await directory.delete(recursive: true);
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

      final transition = ThreadDraftCreatedTransition(
        threadId: thread.threadId,
        initialComposerInput: input,
        initialAttachedImages: _attachedImages,
        initialSelectedModel: _selectedModel,
        initialSelectedReasoningEffort: _selectedReasoningEffortWireValue(),
      );
      if (widget.onDraftThreadCreated != null) {
        widget.onDraftThreadCreated!(transition);
        return true;
      }

      setState(() {
        _localDraftTransition = transition;
        _isDraftThreadCreationInFlight = false;
        _draftThreadErrorMessage = null;
        _didInitialScrollToBottom = false;
        _didSubmitInitialComposerInput = false;
        _timelineExpansionState.clear();
        _attachedImages = List<XFile>.unmodifiable(
          transition.initialAttachedImages,
        );
      });
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
                              ? _audioRecorder.onAmplitudeChanged(
                                  const Duration(milliseconds: 50),
                                )
                              : null,
                          speechMessage: _speechMessage,
                          speechMessageIsError: _speechMessageIsError,
                          isComposerFocused: _isComposerFocused,
                          attachedImages: _attachedImages,
                          modelOptions: _availableModelOptions,
                          reasoningOptions: _availableReasoningOptions,
                          selectedModel: _selectedModel,
                          selectedReasoning: _selectedReasoning,
                          accessMode: effectiveAccessMode,
                          session: currentSession,
                          isAccessModeUpdating:
                              deviceSettingsState.isAccessModeUpdating,
                          accessModeErrorMessage:
                              deviceSettingsState.accessModeErrorMessage,
                          onPickImages: _pickImages,
                          onToggleSpeechInput: _toggleSpeechInput,
                          onRemoveImage: _removeAttachedImage,
                          onModelChanged: _onComposerModelChanged,
                          onReasoningChanged: (value) {
                            setState(() {
                              _selectedReasoning = value;
                            });
                          },
                          onAccessModeChanged: changeAccessMode,
                          onSubmitComposer: _submitDraftComposerInput,
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
        !state.isComposerMutationInFlight &&
        _hasPendingInitialComposerSubmission) {
      final initialComposerInput = _effectiveInitialComposerInput?.trim();
      if (initialComposerInput != null ||
          _effectiveInitialAttachedImages.isNotEmpty) {
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

    final threadApprovals = approvalsState.forThread(_effectiveThreadId!);
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
                                          child: MagneticButton(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 18,
                                              vertical: 10,
                                            ),
                                            variant:
                                                MagneticButtonVariant.secondary,
                                            onClick: () {
                                              _showNewMessagePill.value = false;
                                              _jumpToTimelineBottom(attempt: 0);
                                            },
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                const Text(
                                                  'New messages',
                                                  style: TextStyle(
                                                    fontSize: 14,
                                                    fontWeight: FontWeight.w600,
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
                              isSpeechRecording: _isSpeechRecording,
                              isSpeechTranscribing: _isSpeechTranscribing,
                              speechDurationSeconds: _speechDurationSeconds,
                              speechAmplitudeStream: _isSpeechRecording
                                  ? _audioRecorder.onAmplitudeChanged(
                                      const Duration(milliseconds: 50),
                                    )
                                  : null,
                              speechMessage: _speechMessage,
                              speechMessageIsError: _speechMessageIsError,
                              isComposerFocused: _isComposerFocused,
                              attachedImages: _attachedImages,
                              modelOptions: _availableModelOptions,
                              reasoningOptions: _availableReasoningOptions,
                              selectedModel: _selectedModel,
                              selectedReasoning: _selectedReasoning,
                              accessMode: effectiveAccessMode,
                              session: currentSession,
                              isAccessModeUpdating:
                                  deviceSettingsState.isAccessModeUpdating,
                              accessModeErrorMessage:
                                  deviceSettingsState.accessModeErrorMessage,
                              onPickImages: _pickImages,
                              onToggleSpeechInput: _toggleSpeechInput,
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
