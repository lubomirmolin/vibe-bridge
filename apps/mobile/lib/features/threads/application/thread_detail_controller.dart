import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:math' as math;

import 'package:vibe_bridge/foundation/connectivity/live_connection_state.dart';
import 'package:vibe_bridge/foundation/connectivity/reconnect_scheduler.dart';
import 'package:vibe_bridge/features/threads/application/thread_active_turn.dart'
    as active_turn;
import 'package:vibe_bridge/features/threads/application/thread_pending_prompts.dart';
import 'package:vibe_bridge/features/threads/application/thread_list_controller.dart';
import 'package:vibe_bridge/features/threads/application/thread_timeline_merge.dart';
import 'package:vibe_bridge/features/threads/data/thread_detail_bridge_api.dart';
import 'package:vibe_bridge/features/threads/data/thread_live_stream.dart';
import 'package:vibe_bridge/features/threads/domain/thread_activity_item.dart';
import 'package:vibe_bridge/foundation/contracts/bridge_contracts.dart';
import 'package:vibe_bridge/foundation/logging/thread_diagnostics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

part 'thread_detail_controller_loading.dart';
part 'thread_detail_controller_live.dart';
part 'thread_detail_controller_mutations.dart';
part 'thread_detail_controller_tracking.dart';

final threadDetailControllerProvider = StateNotifierProvider.autoDispose
    .family<
      ThreadDetailController,
      ThreadDetailState,
      ThreadDetailControllerArgs
    >((ref, args) {
      final threadListController = ref.read(
        threadListControllerProvider(args.bridgeApiBaseUrl).notifier,
      );

      return ThreadDetailController(
        bridgeApiBaseUrl: args.bridgeApiBaseUrl,
        threadId: args.threadId,
        initialVisibleTimelineEntries: args.initialVisibleTimelineEntries,
        bridgeApi: ref.watch(threadDetailBridgeApiProvider),
        liveStream: ref.watch(threadLiveStreamProvider),
        threadListController: threadListController,
        diagnostics: ref.watch(threadDiagnosticsServiceProvider),
      );
    });

class ThreadDetailControllerArgs {
  const ThreadDetailControllerArgs({
    required this.bridgeApiBaseUrl,
    required this.threadId,
    this.initialVisibleTimelineEntries = 80,
  });

  final String bridgeApiBaseUrl;
  final String threadId;
  final int initialVisibleTimelineEntries;

  @override
  bool operator ==(Object other) {
    return other is ThreadDetailControllerArgs &&
        other.bridgeApiBaseUrl == bridgeApiBaseUrl &&
        other.threadId == threadId &&
        other.initialVisibleTimelineEntries == initialVisibleTimelineEntries;
  }

  @override
  int get hashCode =>
      Object.hash(bridgeApiBaseUrl, threadId, initialVisibleTimelineEntries);
}

// ---------------------------------------------------------------------------
// Sub-states
// ---------------------------------------------------------------------------

class ThreadGitState {
  const ThreadGitState({
    this.gitStatus,
    this.isGitStatusLoading = false,
    this.isGitMutationInFlight = false,
    this.gitErrorMessage,
    this.gitMutationMessage,
    this.gitControlsUnavailableReason,
  });

  final GitStatusResponseDto? gitStatus;
  final bool isGitStatusLoading;
  final bool isGitMutationInFlight;
  final String? gitErrorMessage;
  final String? gitMutationMessage;
  final String? gitControlsUnavailableReason;

  static const initial = ThreadGitState();

  ThreadGitState copyWith({
    GitStatusResponseDto? gitStatus,
    bool clearGitStatus = false,
    bool? isGitStatusLoading,
    bool? isGitMutationInFlight,
    String? gitErrorMessage,
    bool clearGitErrorMessage = false,
    String? gitMutationMessage,
    bool clearGitMutationMessage = false,
    String? gitControlsUnavailableReason,
    bool clearGitControlsUnavailableReason = false,
  }) {
    return ThreadGitState(
      gitStatus: clearGitStatus ? null : (gitStatus ?? this.gitStatus),
      isGitStatusLoading: isGitStatusLoading ?? this.isGitStatusLoading,
      isGitMutationInFlight:
          isGitMutationInFlight ?? this.isGitMutationInFlight,
      gitErrorMessage: clearGitErrorMessage
          ? null
          : (gitErrorMessage ?? this.gitErrorMessage),
      gitMutationMessage: clearGitMutationMessage
          ? null
          : (gitMutationMessage ?? this.gitMutationMessage),
      gitControlsUnavailableReason: clearGitControlsUnavailableReason
          ? null
          : (gitControlsUnavailableReason ?? this.gitControlsUnavailableReason),
    );
  }
}

class ThreadTurnControlState {
  const ThreadTurnControlState({
    this.isComposerMutationInFlight = false,
    this.isInterruptMutationInFlight = false,
    this.turnControlErrorMessage,
  });

  final bool isComposerMutationInFlight;
  final bool isInterruptMutationInFlight;
  final String? turnControlErrorMessage;

  static const initial = ThreadTurnControlState();

  ThreadTurnControlState copyWith({
    bool? isComposerMutationInFlight,
    bool? isInterruptMutationInFlight,
    String? turnControlErrorMessage,
    bool clearTurnControlError = false,
  }) {
    return ThreadTurnControlState(
      isComposerMutationInFlight:
          isComposerMutationInFlight ?? this.isComposerMutationInFlight,
      isInterruptMutationInFlight:
          isInterruptMutationInFlight ?? this.isInterruptMutationInFlight,
      turnControlErrorMessage: clearTurnControlError
          ? null
          : (turnControlErrorMessage ?? this.turnControlErrorMessage),
    );
  }
}

class ThreadOpenOnMacState {
  const ThreadOpenOnMacState({
    this.isOpenOnMacInFlight = false,
    this.openOnMacMessage,
    this.openOnMacErrorMessage,
  });

  final bool isOpenOnMacInFlight;
  final String? openOnMacMessage;
  final String? openOnMacErrorMessage;

  static const initial = ThreadOpenOnMacState();

  ThreadOpenOnMacState copyWith({
    bool? isOpenOnMacInFlight,
    String? openOnMacMessage,
    bool clearOpenOnMacMessage = false,
    String? openOnMacErrorMessage,
    bool clearOpenOnMacErrorMessage = false,
  }) {
    return ThreadOpenOnMacState(
      isOpenOnMacInFlight: isOpenOnMacInFlight ?? this.isOpenOnMacInFlight,
      openOnMacMessage: clearOpenOnMacMessage
          ? null
          : (openOnMacMessage ?? this.openOnMacMessage),
      openOnMacErrorMessage: clearOpenOnMacErrorMessage
          ? null
          : (openOnMacErrorMessage ?? this.openOnMacErrorMessage),
    );
  }
}

// ---------------------------------------------------------------------------
// Main state
// ---------------------------------------------------------------------------

class ThreadDetailState {
  const ThreadDetailState({
    required this.threadId,
    this.liveConnectionState = LiveConnectionState.connected,
    this.thread,
    this.items = const <ThreadActivityItem>[],
    this.pendingLocalUserPrompts = const <ThreadActivityItem>[],
    this.workflowState,
    this.pendingUserInput,
    this.errorMessage,
    this.streamErrorMessage,
    this.staleMessage,
    this.isUnavailable = false,
    this.isLoading = true,
    this.isShowingCachedData = false,
    this.isConnectivityUnavailable = false,
    this.hasMoreBefore = false,
    this.nextBefore,
    this.isLoadingEarlierHistory = false,
    this.git = ThreadGitState.initial,
    this.turnControl = ThreadTurnControlState.initial,
    this.openOnMac = ThreadOpenOnMacState.initial,
  });

  final String threadId;
  final LiveConnectionState liveConnectionState;
  final ThreadDetailDto? thread;
  final List<ThreadActivityItem> items;
  final List<ThreadActivityItem> pendingLocalUserPrompts;
  final ThreadWorkflowStateDto? workflowState;
  final PendingUserInputDto? pendingUserInput;
  final String? errorMessage;
  final String? streamErrorMessage;
  final String? staleMessage;
  final bool isUnavailable;
  final bool isLoading;
  final bool isShowingCachedData;
  final bool isConnectivityUnavailable;
  final bool hasMoreBefore;
  final String? nextBefore;
  final bool isLoadingEarlierHistory;
  final ThreadGitState git;
  final ThreadTurnControlState turnControl;
  final ThreadOpenOnMacState openOnMac;

  // ---- Convenience accessors (preserve existing public API) ----

  bool get hasThread => thread != null;

  bool get hasError => errorMessage != null;

  bool get canRunMutatingActions => !isConnectivityUnavailable;

  bool get hasGitRepositoryContext =>
      git.gitStatus != null &&
      _isRepositoryContextResolvable(git.gitStatus!.repository);

  bool get canRunGitMutations =>
      canRunMutatingActions &&
      hasGitRepositoryContext &&
      !git.isGitStatusLoading &&
      !git.isGitMutationInFlight;

  bool get isTurnActive => thread?.status == ThreadStatus.running;

  List<ThreadActivityItem> get conversationItems =>
      List<ThreadActivityItem>.unmodifiable(<ThreadActivityItem>[
        ...items.where(_isConversationTimelineItem),
        ...pendingLocalUserPrompts,
      ]);

  int get hiddenHistoryCount => 0;

  bool get canLoadEarlierHistory => hasMoreBefore && !isLoadingEarlierHistory;

  bool get isInitialTimelineLoading =>
      isLoading && hasThread && visibleItems.isEmpty;

  List<ThreadActivityItem> get visibleItems => conversationItems;

  // Delegation accessors for sub-state fields (backward compat)
  GitStatusResponseDto? get gitStatus => git.gitStatus;
  bool get isGitStatusLoading => git.isGitStatusLoading;
  bool get isGitMutationInFlight => git.isGitMutationInFlight;
  String? get gitErrorMessage => git.gitErrorMessage;
  String? get gitMutationMessage => git.gitMutationMessage;
  String? get gitControlsUnavailableReason => git.gitControlsUnavailableReason;
  bool get isComposerMutationInFlight => turnControl.isComposerMutationInFlight;
  bool get isInterruptMutationInFlight =>
      turnControl.isInterruptMutationInFlight;
  String? get turnControlErrorMessage => turnControl.turnControlErrorMessage;
  bool get isOpenOnMacInFlight => openOnMac.isOpenOnMacInFlight;
  String? get openOnMacMessage => openOnMac.openOnMacMessage;
  String? get openOnMacErrorMessage => openOnMac.openOnMacErrorMessage;

  // ---- copyWith ----

  ThreadDetailState copyWith({
    LiveConnectionState? liveConnectionState,
    ThreadDetailDto? thread,
    bool clearThread = false,
    List<ThreadActivityItem>? items,
    List<ThreadActivityItem>? pendingLocalUserPrompts,
    ThreadWorkflowStateDto? workflowState,
    bool clearWorkflowState = false,
    PendingUserInputDto? pendingUserInput,
    bool clearPendingUserInput = false,
    String? errorMessage,
    bool clearErrorMessage = false,
    String? streamErrorMessage,
    bool clearStreamErrorMessage = false,
    String? staleMessage,
    bool clearStaleMessage = false,
    bool? isUnavailable,
    bool? isLoading,
    bool? isShowingCachedData,
    bool? isConnectivityUnavailable,
    bool? hasMoreBefore,
    String? nextBefore,
    bool clearNextBefore = false,
    bool? isLoadingEarlierHistory,
    ThreadGitState? git,
    ThreadTurnControlState? turnControl,
    ThreadOpenOnMacState? openOnMac,
    // Legacy individual sub-state fields (thin wrappers for call-site compat)
    bool? isComposerMutationInFlight,
    bool? isInterruptMutationInFlight,
    String? turnControlErrorMessage,
    bool clearTurnControlError = false,
    GitStatusResponseDto? gitStatus,
    bool clearGitStatus = false,
    bool? isGitStatusLoading,
    bool? isGitMutationInFlight,
    String? gitErrorMessage,
    bool clearGitErrorMessage = false,
    String? gitMutationMessage,
    bool clearGitMutationMessage = false,
    String? gitControlsUnavailableReason,
    bool clearGitControlsUnavailableReason = false,
    bool? isOpenOnMacInFlight,
    String? openOnMacMessageValue,
    bool clearOpenOnMacMessage = false,
    String? openOnMacErrorMessageValue,
    bool clearOpenOnMacErrorMessage = false,
  }) {
    // Resolve git sub-state: explicit object wins, else apply individual fields
    final resolvedGit =
        git ??
        _applyGitFieldOverrides(
          gitStatus: gitStatus,
          clearGitStatus: clearGitStatus,
          isGitStatusLoading: isGitStatusLoading,
          isGitMutationInFlight: isGitMutationInFlight,
          gitErrorMessage: gitErrorMessage,
          clearGitErrorMessage: clearGitErrorMessage,
          gitMutationMessage: gitMutationMessage,
          clearGitMutationMessage: clearGitMutationMessage,
          gitControlsUnavailableReason: gitControlsUnavailableReason,
          clearGitControlsUnavailableReason: clearGitControlsUnavailableReason,
        );

    final resolvedTurnControl =
        turnControl ??
        _applyTurnControlFieldOverrides(
          isComposerMutationInFlight: isComposerMutationInFlight,
          isInterruptMutationInFlight: isInterruptMutationInFlight,
          turnControlErrorMessage: turnControlErrorMessage,
          clearTurnControlError: clearTurnControlError,
        );

    final resolvedOpenOnMac =
        openOnMac ??
        _applyOpenOnMacFieldOverrides(
          isOpenOnMacInFlight: isOpenOnMacInFlight,
          openOnMacMessage: openOnMacMessageValue,
          clearOpenOnMacMessage: clearOpenOnMacMessage,
          openOnMacErrorMessage: openOnMacErrorMessageValue,
          clearOpenOnMacErrorMessage: clearOpenOnMacErrorMessage,
        );

    return ThreadDetailState(
      threadId: threadId,
      liveConnectionState: liveConnectionState ?? this.liveConnectionState,
      thread: clearThread ? null : (thread ?? this.thread),
      items: items ?? this.items,
      pendingLocalUserPrompts:
          pendingLocalUserPrompts ?? this.pendingLocalUserPrompts,
      workflowState: clearWorkflowState
          ? null
          : (workflowState ?? this.workflowState),
      pendingUserInput: clearPendingUserInput
          ? null
          : (pendingUserInput ?? this.pendingUserInput),
      errorMessage: clearErrorMessage
          ? null
          : (errorMessage ?? this.errorMessage),
      streamErrorMessage: clearStreamErrorMessage
          ? null
          : (streamErrorMessage ?? this.streamErrorMessage),
      staleMessage: clearStaleMessage
          ? null
          : (staleMessage ?? this.staleMessage),
      isUnavailable: isUnavailable ?? this.isUnavailable,
      isLoading: isLoading ?? this.isLoading,
      isShowingCachedData: isShowingCachedData ?? this.isShowingCachedData,
      isConnectivityUnavailable:
          isConnectivityUnavailable ?? this.isConnectivityUnavailable,
      hasMoreBefore: hasMoreBefore ?? this.hasMoreBefore,
      nextBefore: clearNextBefore ? null : (nextBefore ?? this.nextBefore),
      isLoadingEarlierHistory:
          isLoadingEarlierHistory ?? this.isLoadingEarlierHistory,
      git: resolvedGit,
      turnControl: resolvedTurnControl,
      openOnMac: resolvedOpenOnMac,
    );
  }

  ThreadGitState _applyGitFieldOverrides({
    GitStatusResponseDto? gitStatus,
    bool clearGitStatus = false,
    bool? isGitStatusLoading,
    bool? isGitMutationInFlight,
    String? gitErrorMessage,
    bool clearGitErrorMessage = false,
    String? gitMutationMessage,
    bool clearGitMutationMessage = false,
    String? gitControlsUnavailableReason,
    bool clearGitControlsUnavailableReason = false,
  }) {
    if (gitStatus == null &&
        !clearGitStatus &&
        isGitStatusLoading == null &&
        isGitMutationInFlight == null &&
        gitErrorMessage == null &&
        !clearGitErrorMessage &&
        gitMutationMessage == null &&
        !clearGitMutationMessage &&
        gitControlsUnavailableReason == null &&
        !clearGitControlsUnavailableReason) {
      return git;
    }
    return git.copyWith(
      gitStatus: gitStatus,
      clearGitStatus: clearGitStatus,
      isGitStatusLoading: isGitStatusLoading,
      isGitMutationInFlight: isGitMutationInFlight,
      gitErrorMessage: gitErrorMessage,
      clearGitErrorMessage: clearGitErrorMessage,
      gitMutationMessage: gitMutationMessage,
      clearGitMutationMessage: clearGitMutationMessage,
      gitControlsUnavailableReason: gitControlsUnavailableReason,
      clearGitControlsUnavailableReason: clearGitControlsUnavailableReason,
    );
  }

  ThreadTurnControlState _applyTurnControlFieldOverrides({
    bool? isComposerMutationInFlight,
    bool? isInterruptMutationInFlight,
    String? turnControlErrorMessage,
    bool clearTurnControlError = false,
  }) {
    if (isComposerMutationInFlight == null &&
        isInterruptMutationInFlight == null &&
        turnControlErrorMessage == null &&
        !clearTurnControlError) {
      return turnControl;
    }
    return turnControl.copyWith(
      isComposerMutationInFlight: isComposerMutationInFlight,
      isInterruptMutationInFlight: isInterruptMutationInFlight,
      turnControlErrorMessage: turnControlErrorMessage,
      clearTurnControlError: clearTurnControlError,
    );
  }

  ThreadOpenOnMacState _applyOpenOnMacFieldOverrides({
    bool? isOpenOnMacInFlight,
    String? openOnMacMessage,
    bool clearOpenOnMacMessage = false,
    String? openOnMacErrorMessage,
    bool clearOpenOnMacErrorMessage = false,
  }) {
    if (isOpenOnMacInFlight == null &&
        openOnMacMessage == null &&
        !clearOpenOnMacMessage &&
        openOnMacErrorMessage == null &&
        !clearOpenOnMacErrorMessage) {
      return openOnMac;
    }
    return openOnMac.copyWith(
      isOpenOnMacInFlight: isOpenOnMacInFlight,
      openOnMacMessage: openOnMacMessage,
      clearOpenOnMacMessage: clearOpenOnMacMessage,
      openOnMacErrorMessage: openOnMacErrorMessage,
      clearOpenOnMacErrorMessage: clearOpenOnMacErrorMessage,
    );
  }
}

bool _isConversationTimelineItem(ThreadActivityItem item) {
  switch (item.type) {
    case ThreadActivityItemType.lifecycleUpdate:
    case ThreadActivityItemType.securityEvent:
      return false;
    default:
      return true;
  }
}

bool _isExplorationTimelineItem(ThreadActivityItem item) {
  return item.presentation?.groupKind ==
      ThreadActivityPresentationGroupKind.exploration;
}

// ---------------------------------------------------------------------------
// Controller
// ---------------------------------------------------------------------------

const Duration _threadActiveTurnRefreshGuardWindow = Duration(seconds: 5);
const Duration _threadSilentTurnSnapshotWatchdogDelay = Duration(seconds: 4);
const int _threadSilentTurnWatchdogReconnectThreshold = 3;
const Duration _threadPendingPromptSettlementGraceWindow = Duration(seconds: 8);

mixin _ThreadDetailControllerContext on StateNotifier<ThreadDetailState> {
  String get _bridgeApiBaseUrl;
  int get _initialVisibleTimelineEntries;
  ThreadDetailBridgeApi get _bridgeApi;
  ThreadLiveStream get _liveStream;
  ThreadListController get _threadListController;
  ThreadDiagnosticsService? get _diagnostics;
  void Function(String message) get _debugLog;
  Set<String> get _knownEventIds;
  Map<String, String> get _lastLiveFrameFingerprintByEventId;
  ReconnectScheduler get _reconnectScheduler;
  ThreadLiveSubscription? get _liveSubscription;
  set _liveSubscription(ThreadLiveSubscription? value);
  StreamSubscription<BridgeEventEnvelope<Map<String, dynamic>>>?
  get _liveEventSubscription;
  set _liveEventSubscription(
    StreamSubscription<BridgeEventEnvelope<Map<String, dynamic>>>? value,
  );
  Timer? get _detailRefreshTimer;
  set _detailRefreshTimer(Timer? value);
  Timer? get _snapshotRefreshTimer;
  set _snapshotRefreshTimer(Timer? value);
  Timer? get _silentTurnWatchdogTimer;
  set _silentTurnWatchdogTimer(Timer? value);
  bool get _isDetailRefreshInFlight;
  set _isDetailRefreshInFlight(bool value);
  bool get _isSnapshotRefreshInFlight;
  set _isSnapshotRefreshInFlight(bool value);
  bool get _shouldRefreshDetailAfterCurrentRequest;
  set _shouldRefreshDetailAfterCurrentRequest(bool value);
  bool get _shouldRefreshSnapshotAfterCurrentRequest;
  set _shouldRefreshSnapshotAfterCurrentRequest(bool value);
  bool get _isDisposed;
  set _isDisposed(bool value);
  DateTime? get _pendingPromptSubmittedAt;
  set _pendingPromptSubmittedAt(DateTime? value);
  DateTime? get _pendingPromptSettledAt;
  set _pendingPromptSettledAt(DateTime? value);
  DateTime? get _lastActiveTurnSignalAt;
  set _lastActiveTurnSignalAt(DateTime? value);
  bool get _activeTurnSawMeaningfulLiveActivity;
  set _activeTurnSawMeaningfulLiveActivity(bool value);
  bool get _activeTurnNeedsSnapshotCatchUp;
  set _activeTurnNeedsSnapshotCatchUp(bool value);
  bool get _activeTurnSawLiveUserPrompt;
  set _activeTurnSawLiveUserPrompt(bool value);
  bool get _activeTurnSawIncrementalDelta;
  set _activeTurnSawIncrementalDelta(bool value);
  int? get _lastSeenLiveBridgeSeq;
  set _lastSeenLiveBridgeSeq(int? value);
  int get _silentTurnWatchdogStrikeCount;
  set _silentTurnWatchdogStrikeCount(int value);

  ThreadDetailState _resetTransientState(ThreadDetailState base);
  Future<void> _closeLiveSubscription();
  void _recordDiagnostic(
    String kind, {
    Map<String, Object?> data = const <String, Object?>{},
  });
  void _recordTurnUiStateSnapshot(
    String kind, {
    Map<String, Object?> data = const <String, Object?>{},
  });

  Future<void> loadThread();
  Future<void> loadEarlierHistory();
  Future<void> retryReconnectCatchUp();
  Future<void> _startLiveSubscription({
    int? afterSeq,
    bool handleFailure = true,
  });
  void _handleLiveStreamDisconnected();
  Future<void> _runReconnectCatchUp();
  List<ThreadActivityItem> _mergeTimeline(
    List<ThreadTimelineEntryDto> timeline,
  );
  List<ThreadActivityItem> _mergeTimelineEntries({
    required List<ThreadActivityItem> currentItems,
    required List<ThreadTimelineEntryDto> timeline,
  });
  void _trackKnownEventIds(List<ThreadActivityItem> items);
  void _replaceKnownEventIds(List<ThreadActivityItem> items);
  List<ThreadActivityItem> _prependTimelineEntries(
    List<ThreadActivityItem> currentItems,
    List<ThreadTimelineEntryDto> timeline,
  );
  ThreadDetailDto? _fresherThreadDetail({
    required ThreadDetailDto? current,
    required ThreadDetailDto? candidate,
  });
  bool _isRequestCurrent(String requestThreadId);
  ThreadDetailDto _ensureScopedThreadDetail({
    required ThreadDetailDto detail,
    required String expectedThreadId,
    required String context,
  });
  ThreadTimelinePageDto _ensureScopedTimelinePage({
    required ThreadTimelinePageDto page,
    required String expectedThreadId,
    required String context,
  });
  bool _didRevealNewVisibleBlock({
    required List<String> previousBlockSignatures,
    required List<ThreadActivityItem> nextItems,
  });
  List<String> _visibleBlockSignatures(List<ThreadActivityItem> items);
  bool _hasNewLeadingVisibleBlock({
    required List<String> previousBlockSignatures,
    required List<String> nextBlockSignatures,
  });

  void _handleLiveEvent(BridgeEventEnvelope<Map<String, dynamic>> event);
  bool _isDuplicateLiveFrame(BridgeEventEnvelope<Map<String, dynamic>> event);
  void _scheduleThreadDetailRefresh({required Duration delay});
  void _scheduleThreadSnapshotRefresh({required Duration delay});
  bool _shouldReloadTimelineAfterLiveEvent(
    BridgeEventEnvelope<Map<String, dynamic>> event,
  );
  Future<void> _refreshThreadDetailFromBridge();
  Future<void> _refreshThreadSnapshotFromBridge();
  bool _shouldApplyRefreshedThreadDetail({
    required ThreadDetailDto? current,
    required ThreadDetailDto refreshed,
  });
  void _applyLifecycleStatusUpdate(
    BridgeEventEnvelope<Map<String, dynamic>> event,
  );
  bool _shouldIgnoreTransientLifecycleStatusUpdate({
    required ThreadStatus currentStatus,
    required ThreadStatus nextStatus,
  });

  Future<bool> submitComposerInput(
    String rawInput, {
    TurnMode mode = TurnMode.act,
    List<String> images = const <String>[],
    String? model,
    String? reasoningEffort,
  });
  Future<bool> _shouldRouteComposerInputToActiveTurnSteer();
  Future<bool> respondToPendingUserInput({
    required String freeText,
    required List<UserInputAnswerDto> answers,
    String? model,
    String? reasoningEffort,
  });
  Future<bool> openOnMac();
  Future<bool> submitCommitAction({String? model, String? reasoningEffort});
  Future<bool> interruptActiveTurn();
  Future<void> refreshGitStatus({bool showLoading = true});
  Future<bool> switchBranch(String rawBranch);
  Future<bool> pullRepository();
  Future<bool> pushRepository();
  void _applyGitMutationResult(MutationResultResponseDto mutationResult);
  void _applyTurnMutationResult(TurnMutationResult mutationResult);
  Future<void> _refreshThreadSnapshotAfterMutation();

  int _timelineRefreshLimit();
  void _seedLatestBridgeSeq(int? latestBridgeSeq);
  void _updateThreadStatus({
    required ThreadStatus status,
    required String updatedAt,
    required String lastTurnSummary,
    String? title,
  });
  void _recordActiveTurnSignal();
  void _startTrackingActiveTurn();
  void _finishTrackingActiveTurn({bool clearPendingPromptState = true});
  String _generateClientMessageId();
  String _generateClientTurnIntentId();
  String? _appendPendingLocalUserPrompt({
    required String clientMessageId,
    required String input,
    required List<String> images,
  });
  void _removePendingLocalUserPrompt(String? localEventId);
  List<ThreadActivityItem> _reconcilePendingLocalUserPrompts(
    List<ThreadActivityItem> canonicalItems,
  );
  void _clearPendingPromptConfirmationTracking();
  void _markUnconfirmedPendingPromptsAsFailedIfThreadSettled({
    required String source,
  });
  void _recordPendingPromptSettlement();
  void _recordMeaningfulLiveActivity(ThreadActivityItem item);
  bool _isMeaningfulTurnLiveActivity(ThreadActivityItem item);
  void _recordLiveTurnShape({
    required BridgeEventEnvelope<Map<String, dynamic>> event,
    required ThreadActivityItem item,
  });
  bool _eventUsesIncrementalDelta(
    BridgeEventEnvelope<Map<String, dynamic>> event,
  );
  void _syncSilentTurnWatchdog();
  bool _shouldWatchForSilentTurn();
  void _cancelSilentTurnWatchdog();
  void _handleSilentTurnWatchdogFired();
  void _logPromptResponseIfNeeded({
    required BridgeEventEnvelope<Map<String, dynamic>> event,
    required ThreadActivityItem nextItem,
  });
  String? _liveEventTitle(BridgeEventEnvelope<Map<String, dynamic>> event);
  void _logLiveEvent({
    required BridgeEventEnvelope<Map<String, dynamic>> event,
    required Map<String, dynamic> mergedPayload,
    required ThreadActivityItem nextItem,
  });
  Map<String, dynamic> _mergeLivePayload(
    Map<String, dynamic>? currentPayload,
    BridgeEventEnvelope<Map<String, dynamic>> event,
  );
  void _mergeIncrementalField(
    Map<String, dynamic> payload,
    String canonicalField,
  );
}

class ThreadDetailController extends StateNotifier<ThreadDetailState>
    with
        _ThreadDetailControllerContext,
        _ThreadDetailControllerLoadingMixin,
        _ThreadDetailControllerLiveMixin,
        _ThreadDetailControllerMutationsMixin,
        _ThreadDetailControllerTrackingMixin {
  ThreadDetailController({
    required String bridgeApiBaseUrl,
    required String threadId,
    required int initialVisibleTimelineEntries,
    required ThreadDetailBridgeApi bridgeApi,
    required ThreadLiveStream liveStream,
    required ThreadListController threadListController,
    ThreadDiagnosticsService? diagnostics,
    void Function(String message)? debugLog,
  }) : _bridgeApiBaseUrl = bridgeApiBaseUrl,
       _initialVisibleTimelineEntries = initialVisibleTimelineEntries,
       _bridgeApi = bridgeApi,
       _liveStream = liveStream,
       _threadListController = threadListController,
       _diagnostics = diagnostics,
       _debugLog = debugLog ?? _defaultDebugLog,
       super(ThreadDetailState(threadId: threadId)) {
    _reconnectScheduler = ReconnectScheduler(
      onReconnect: _runReconnectCatchUp,
      isDisposed: () => _isDisposed,
    );
    loadThread();
  }

  final String _bridgeApiBaseUrl;
  final int _initialVisibleTimelineEntries;
  final ThreadDetailBridgeApi _bridgeApi;
  final ThreadLiveStream _liveStream;
  final ThreadListController _threadListController;
  final ThreadDiagnosticsService? _diagnostics;
  final void Function(String message) _debugLog;
  final Set<String> _knownEventIds = <String>{};
  final Map<String, String> _lastLiveFrameFingerprintByEventId =
      <String, String>{};

  late final ReconnectScheduler _reconnectScheduler;
  ThreadLiveSubscription? _liveSubscription;

  void showTurnControlError(String message) {
    state = state.copyWith(turnControlErrorMessage: message);
  }

  ThreadDetailDto? get currentThread => state.thread;

  StreamSubscription<BridgeEventEnvelope<Map<String, dynamic>>>?
  _liveEventSubscription;
  Timer? _detailRefreshTimer;
  Timer? _snapshotRefreshTimer;
  Timer? _silentTurnWatchdogTimer;
  bool _isDetailRefreshInFlight = false;
  bool _isSnapshotRefreshInFlight = false;
  bool _shouldRefreshDetailAfterCurrentRequest = false;
  bool _shouldRefreshSnapshotAfterCurrentRequest = false;
  bool _isDisposed = false;
  DateTime? _pendingPromptSubmittedAt;
  DateTime? _pendingPromptSettledAt;
  DateTime? _lastActiveTurnSignalAt;
  bool _activeTurnSawMeaningfulLiveActivity = false;
  bool _activeTurnNeedsSnapshotCatchUp = false;
  bool _activeTurnSawLiveUserPrompt = false;
  bool _activeTurnSawIncrementalDelta = false;
  int? _lastSeenLiveBridgeSeq;
  int _silentTurnWatchdogStrikeCount = 0;

  /// Resets all transient sub-state to initial values. Used when
  /// (re-)loading the thread or catching up after a reconnect.
  ThreadDetailState _resetTransientState(ThreadDetailState base) {
    return base.copyWith(
      pendingLocalUserPrompts: const <ThreadActivityItem>[],
      clearPendingUserInput: true,
      clearErrorMessage: true,
      clearStreamErrorMessage: true,
      clearStaleMessage: true,
      isShowingCachedData: false,
      isConnectivityUnavailable: false,
      hasMoreBefore: false,
      clearNextBefore: true,
      isLoadingEarlierHistory: false,
      git: ThreadGitState.initial,
      turnControl: ThreadTurnControlState.initial,
      openOnMac: ThreadOpenOnMacState.initial,
    );
  }

  Future<void> _closeLiveSubscription() async {
    await _liveEventSubscription?.cancel();
    _liveEventSubscription = null;

    final subscription = _liveSubscription;
    _liveSubscription = null;
    if (subscription == null) {
      return;
    }

    try {
      await subscription.close();
    } catch (_) {
      // Ignore teardown failures from already-closed sockets/streams.
    }
  }

  static void _defaultDebugLog(String message) {
    developer.log(message, name: 'ThreadDetailController');
  }

  void _recordDiagnostic(
    String kind, {
    Map<String, Object?> data = const <String, Object?>{},
  }) {
    final diagnostics = _diagnostics;
    if (diagnostics == null) {
      return;
    }
    unawaited(
      diagnostics.record(kind: kind, threadId: state.threadId, data: data),
    );
  }

  void _recordTurnUiStateSnapshot(
    String kind, {
    Map<String, Object?> data = const <String, Object?>{},
  }) {
    final sendingCount = state.visibleItems
        .where(
          (item) =>
              item.localMessageState == ThreadActivityLocalMessageState.sending,
        )
        .length;
    final failedCount = state.visibleItems
        .where(
          (item) =>
              item.localMessageState == ThreadActivityLocalMessageState.failed,
        )
        .length;
    _recordDiagnostic(
      kind,
      data: <String, Object?>{
        ...data,
        'threadStatus': state.thread?.status.wireValue,
        'isTurnActive': state.isTurnActive,
        'isComposerMutationInFlight': state.isComposerMutationInFlight,
        'isInterruptMutationInFlight': state.isInterruptMutationInFlight,
        'pendingLocalPromptCount': state.pendingLocalUserPrompts.length,
        'visibleSendingCount': sendingCount,
        'visibleFailedCount': failedCount,
        'activeTurnSawMeaningfulLiveActivity':
            _activeTurnSawMeaningfulLiveActivity,
        'activeTurnNeedsSnapshotCatchUp': _activeTurnNeedsSnapshotCatchUp,
        'activeTurnSawLiveUserPrompt': _activeTurnSawLiveUserPrompt,
        'activeTurnSawIncrementalDelta': _activeTurnSawIncrementalDelta,
        'pendingPromptSubmittedAt': _pendingPromptSubmittedAt
            ?.toIso8601String(),
        'lastActiveTurnSignalAt': _lastActiveTurnSignalAt?.toIso8601String(),
      },
    );
  }

  @override
  void dispose() {
    _isDisposed = true;
    _reconnectScheduler.dispose();
    _detailRefreshTimer?.cancel();
    _snapshotRefreshTimer?.cancel();
    _silentTurnWatchdogTimer?.cancel();
    unawaited(_closeLiveSubscription());
    super.dispose();
  }
}

bool _isRepositoryContextResolvable(RepositoryContextDto context) {
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

bool _isNonRepositoryGitStatusError(String message) {
  return message.toLowerCase().contains('not a git repository');
}
