import 'package:vibe_bridge/features/threads/domain/thread_activity_item.dart';
import 'package:vibe_bridge/foundation/contracts/bridge_contracts.dart';

bool shouldReloadTimelineAfterLiveEvent({
  required BridgeEventEnvelope<Map<String, dynamic>> event,
  required ThreadDetailDto? currentThread,
  required bool activeTurnNeedsSnapshotCatchUp,
  required bool activeTurnSawMeaningfulLiveActivity,
  required bool activeTurnSawLiveUserPrompt,
  required bool activeTurnSawIncrementalDelta,
  required DateTime? lastActiveTurnSignalAt,
  required DateTime? pendingPromptSubmittedAt,
}) {
  if (event.kind != BridgeEventKind.threadStatusChanged) {
    return false;
  }

  final reason = (event.payload['reason'] as String?)?.trim();
  if (reason == 'thread_title_generated') {
    return false;
  }

  final rawStatus = event.payload['status'];
  if (rawStatus is! String || rawStatus.trim().isEmpty) {
    return true;
  }

  final thread = currentThread;
  if (thread == null) {
    return false;
  }

  final status = threadStatusFromWire(rawStatus.trim());
  if (status == ThreadStatus.running) {
    return false;
  }

  final hadTrackedActiveTurn =
      thread.status == ThreadStatus.running ||
      lastActiveTurnSignalAt != null ||
      pendingPromptSubmittedAt != null ||
      activeTurnNeedsSnapshotCatchUp ||
      activeTurnSawMeaningfulLiveActivity;
  if (!hadTrackedActiveTurn) {
    return false;
  }

  if (status == ThreadStatus.failed || status == ThreadStatus.interrupted) {
    return true;
  }

  if (status == ThreadStatus.completed &&
      activeTurnSawMeaningfulLiveActivity &&
      !activeTurnNeedsSnapshotCatchUp &&
      !activeTurnSawLiveUserPrompt &&
      !activeTurnSawIncrementalDelta) {
    return false;
  }

  return true;
}

bool shouldApplyRefreshedThreadDetail({
  required ThreadDetailDto? current,
  required ThreadDetailDto refreshed,
  required bool activeTurnNeedsSnapshotCatchUp,
  required bool activeTurnSawMeaningfulLiveActivity,
  required DateTime? lastActiveTurnSignalAt,
  required Duration activeTurnRefreshGuardWindow,
}) {
  if (current == null) {
    return true;
  }
  if (threadDetailEquals(current, refreshed)) {
    return false;
  }

  final refreshedIsTerminal =
      refreshed.status == ThreadStatus.completed ||
      refreshed.status == ThreadStatus.failed ||
      refreshed.status == ThreadStatus.interrupted;
  if (current.status == ThreadStatus.running &&
      refreshedIsTerminal &&
      activeTurnNeedsSnapshotCatchUp &&
      !activeTurnSawMeaningfulLiveActivity) {
    return true;
  }

  final currentUpdatedAt = DateTime.tryParse(current.updatedAt);
  final refreshedUpdatedAt = DateTime.tryParse(refreshed.updatedAt);
  if (shouldPreserveRunningThreadStatus(
    current: current,
    refreshed: refreshed,
    lastActiveTurnSignalAt: lastActiveTurnSignalAt,
    activeTurnNeedsSnapshotCatchUp: activeTurnNeedsSnapshotCatchUp,
    activeTurnSawMeaningfulLiveActivity: activeTurnSawMeaningfulLiveActivity,
    activeTurnRefreshGuardWindow: activeTurnRefreshGuardWindow,
  )) {
    return false;
  }
  if (currentUpdatedAt != null &&
      refreshedUpdatedAt != null &&
      refreshedUpdatedAt.isBefore(currentUpdatedAt)) {
    return isPlaceholderThreadTitle(current.title) &&
        !isPlaceholderThreadTitle(refreshed.title);
  }

  return true;
}

bool shouldPreserveRunningThreadStatus({
  required ThreadDetailDto current,
  required ThreadDetailDto refreshed,
  required DateTime? lastActiveTurnSignalAt,
  required bool activeTurnNeedsSnapshotCatchUp,
  required bool activeTurnSawMeaningfulLiveActivity,
  required Duration activeTurnRefreshGuardWindow,
}) {
  if (current.status != ThreadStatus.running ||
      refreshed.status == ThreadStatus.running) {
    return false;
  }

  if (lastActiveTurnSignalAt == null) {
    return false;
  }

  final isTerminalRefresh =
      refreshed.status == ThreadStatus.completed ||
      refreshed.status == ThreadStatus.failed ||
      refreshed.status == ThreadStatus.interrupted;
  if (isTerminalRefresh &&
      activeTurnNeedsSnapshotCatchUp &&
      !activeTurnSawMeaningfulLiveActivity) {
    return false;
  }
  if (isTerminalRefresh) {
    final currentUpdatedAt = DateTime.tryParse(current.updatedAt);
    final refreshedUpdatedAt = DateTime.tryParse(refreshed.updatedAt);
    if (currentUpdatedAt != null &&
        refreshedUpdatedAt != null &&
        refreshedUpdatedAt.isAfter(currentUpdatedAt)) {
      return false;
    }
  }

  return DateTime.now().difference(lastActiveTurnSignalAt) <=
      activeTurnRefreshGuardWindow;
}

bool shouldIgnoreTransientLifecycleStatusUpdate({
  required ThreadStatus currentStatus,
  required ThreadStatus nextStatus,
  required DateTime? lastActiveTurnSignalAt,
  required bool hasActiveTurnEvidence,
  required Duration activeTurnRefreshGuardWindow,
}) {
  if (currentStatus != ThreadStatus.running ||
      nextStatus != ThreadStatus.idle) {
    return false;
  }

  if (lastActiveTurnSignalAt == null || !hasActiveTurnEvidence) {
    return false;
  }

  return DateTime.now().difference(lastActiveTurnSignalAt) <=
      activeTurnRefreshGuardWindow;
}

bool isMeaningfulTurnLiveActivity(ThreadActivityItem item) {
  if (item.body.trim().isEmpty) {
    return false;
  }

  return switch (item.type) {
    ThreadActivityItemType.assistantOutput => true,
    ThreadActivityItemType.terminalOutput => true,
    ThreadActivityItemType.fileChange => true,
    ThreadActivityItemType.planUpdate => true,
    _ => false,
  };
}

bool eventUsesIncrementalDelta(
  BridgeEventEnvelope<Map<String, dynamic>> event,
) {
  switch (event.kind) {
    case BridgeEventKind.messageDelta:
    case BridgeEventKind.planDelta:
    case BridgeEventKind.commandDelta:
    case BridgeEventKind.fileChange:
      break;
    case BridgeEventKind.threadMetadataChanged:
    case BridgeEventKind.threadStatusChanged:
    case BridgeEventKind.userInputRequested:
    case BridgeEventKind.approvalRequested:
    case BridgeEventKind.securityAudit:
      return false;
  }

  return event.payload['replace'] == true ||
      (event.payload['delta'] is String &&
          (event.payload['delta'] as String).isNotEmpty);
}

bool threadDetailEquals(ThreadDetailDto left, ThreadDetailDto right) {
  return left.contractVersion == right.contractVersion &&
      left.threadId == right.threadId &&
      left.title == right.title &&
      left.status == right.status &&
      left.workspace == right.workspace &&
      left.repository == right.repository &&
      left.branch == right.branch &&
      left.createdAt == right.createdAt &&
      left.updatedAt == right.updatedAt &&
      left.source == right.source &&
      left.accessMode == right.accessMode &&
      left.lastTurnSummary == right.lastTurnSummary;
}

bool isPlaceholderThreadTitle(String title) {
  final normalized = title.trim().toLowerCase();
  return normalized.isEmpty ||
      normalized == 'untitled thread' ||
      normalized == 'new thread' ||
      normalized == 'fresh session';
}
