part of 'thread_detail_controller.dart';

mixin _ThreadDetailControllerTrackingMixin on _ThreadDetailControllerContext {
  int _timelineRefreshLimit() {
    return math.max(_initialVisibleTimelineEntries, state.items.length * 2);
  }

  void _seedLatestBridgeSeq(int? latestBridgeSeq) {
    if (latestBridgeSeq == null) {
      return;
    }
    final current = _lastSeenLiveBridgeSeq;
    if (current == null || latestBridgeSeq > current) {
      _lastSeenLiveBridgeSeq = latestBridgeSeq;
    }
  }

  void _updateThreadStatus({
    required ThreadStatus status,
    required String updatedAt,
    required String lastTurnSummary,
    String? title,
  }) {
    final thread = state.thread;
    if (thread == null) {
      return;
    }

    state = state.copyWith(
      thread: thread.copyWith(
        title: title ?? thread.title,
        status: status,
        updatedAt: updatedAt,
        lastTurnSummary: lastTurnSummary,
        activeTurnId: status == ThreadStatus.running
            ? thread.activeTurnId
            : null,
      ),
    );
  }

  void _recordActiveTurnSignal() {
    _lastActiveTurnSignalAt = DateTime.now();
    _syncSilentTurnWatchdog();
  }

  void _startTrackingActiveTurn() {
    _activeTurnSawMeaningfulLiveActivity = false;
    _activeTurnNeedsSnapshotCatchUp = false;
    _activeTurnSawLiveUserPrompt = false;
    _activeTurnSawIncrementalDelta = false;
    _silentTurnWatchdogStrikeCount = 0;
    _recordActiveTurnSignal();
  }

  void _finishTrackingActiveTurn({bool clearPendingPromptState = true}) {
    _cancelSilentTurnWatchdog();
    if (clearPendingPromptState) {
      _clearPendingPromptConfirmationTracking();
    }
    _lastActiveTurnSignalAt = null;
    _activeTurnNeedsSnapshotCatchUp = false;
    _activeTurnSawLiveUserPrompt = false;
    _activeTurnSawIncrementalDelta = false;
    _silentTurnWatchdogStrikeCount = 0;
  }

  String _generateClientMessageId() {
    return 'client-message-'
        '${DateTime.now().microsecondsSinceEpoch}-'
        '${math.Random().nextInt(1 << 32)}';
  }

  String _generateClientTurnIntentId() {
    return 'turn-intent-'
        '${DateTime.now().microsecondsSinceEpoch}-'
        '${math.Random().nextInt(1 << 32)}';
  }

  String? _appendPendingLocalUserPrompt({
    required String clientMessageId,
    required String input,
    required List<String> images,
  }) {
    if (input.isEmpty && images.isEmpty) {
      return null;
    }

    final occurredAt = DateTime.now().toUtc().toIso8601String();
    final localEventId = 'local-user-${DateTime.now().microsecondsSinceEpoch}';
    final pendingItem = ThreadActivityItem.localUserPrompt(
      eventId: localEventId,
      occurredAt: occurredAt,
      body: input,
      clientMessageId: clientMessageId,
      messageImageUrls: images,
    );

    state = state.copyWith(
      pendingLocalUserPrompts: List<ThreadActivityItem>.unmodifiable(
        <ThreadActivityItem>[...state.pendingLocalUserPrompts, pendingItem],
      ),
    );
    _debugLog(
      'thread_detail_pending_prompt_appended '
      'threadId=${state.threadId} '
      'eventId=$localEventId '
      'clientMessageId=$clientMessageId '
      'pendingPromptCount=${state.pendingLocalUserPrompts.length} '
      'bodyChars=${input.length} '
      'imageCount=${images.length}',
    );
    return localEventId;
  }

  void _removePendingLocalUserPrompt(String? localEventId) {
    if (localEventId == null) {
      return;
    }

    state = state.copyWith(
      pendingLocalUserPrompts: List<ThreadActivityItem>.unmodifiable(
        state.pendingLocalUserPrompts
            .where((item) => item.eventId != localEventId)
            .toList(growable: false),
      ),
    );
  }

  List<ThreadActivityItem> _reconcilePendingLocalUserPrompts(
    List<ThreadActivityItem> canonicalItems,
  ) {
    final pendingItems = state.pendingLocalUserPrompts;
    if (pendingItems.isEmpty) {
      return pendingItems;
    }

    final result = reconcilePendingLocalUserPrompts(
      canonicalItems: canonicalItems,
      pendingItems: pendingItems,
    );
    if (result.canonicalPromptCount == 0) {
      _debugLog(
        'thread_detail_pending_prompt_reconcile_deferred '
        'threadId=${state.threadId} '
        'pendingPromptCount=${pendingItems.length} '
        'canonicalPromptCount=0',
      );
      return pendingItems;
    }

    for (final match in result.matches) {
      _debugLog(
        'thread_detail_pending_prompt_reconciled '
        'threadId=${state.threadId} '
        'pendingEventId=${match.pendingItem.eventId} '
        'canonicalEventId=${match.canonicalItem.eventId} '
        'clientMessageId=${match.pendingItem.clientMessageId ?? ''}',
      );
    }
    for (final pendingItem in result.unmatchedItems) {
      _debugLog(
        'thread_detail_pending_prompt_unmatched '
        'threadId=${state.threadId} '
        'pendingEventId=${pendingItem.eventId} '
        'clientMessageId=${pendingItem.clientMessageId ?? ''} '
        'pendingOccurredAt=${pendingItem.occurredAt} '
        'canonicalPromptCount=${result.canonicalPromptCount} '
        'lastCanonicalPromptAt=${result.lastCanonicalPromptAt ?? ''}',
      );
    }

    if (result.remainingItems.isEmpty) {
      _clearPendingPromptConfirmationTracking();
    }
    return result.remainingItems;
  }

  void _clearPendingPromptConfirmationTracking() {
    _pendingPromptSubmittedAt = null;
    _pendingPromptSettledAt = null;
  }

  void _markUnconfirmedPendingPromptsAsFailedIfThreadSettled({
    required String source,
  }) {
    final threadStatus = state.thread?.status;
    if (threadStatus == null || threadStatus == ThreadStatus.running) {
      _debugLog(
        'thread_detail_pending_prompt_failure_skipped '
        'threadId=${state.threadId} '
        'source=$source '
        'threadStatus=${threadStatus?.wireValue ?? 'null'} '
        'reason=thread_running_or_missing',
      );
      return;
    }
    if (_pendingPromptSubmittedAt == null) {
      _debugLog(
        'thread_detail_pending_prompt_failure_skipped '
        'threadId=${state.threadId} '
        'source=$source '
        'threadStatus=${threadStatus.wireValue} '
        'reason=no_pending_submission_timestamp',
      );
      return;
    }

    final pendingItems = state.pendingLocalUserPrompts;
    if (pendingItems.isEmpty) {
      _clearPendingPromptConfirmationTracking();
      _debugLog(
        'thread_detail_pending_prompt_failure_skipped '
        'threadId=${state.threadId} '
        'source=$source '
        'threadStatus=${threadStatus.wireValue} '
        'reason=no_pending_items',
      );
      return;
    }

    final graceDeadline = pendingPromptFailureGraceDeadline(
      submittedAt: _pendingPromptSubmittedAt,
      settledAt: _pendingPromptSettledAt,
      graceWindow: _threadPendingPromptSettlementGraceWindow,
    );
    if (graceDeadline != null) {
      final remaining = graceDeadline.difference(DateTime.now());
      if (remaining > Duration.zero) {
        _debugLog(
          'thread_detail_pending_prompt_failure_skipped '
          'threadId=${state.threadId} '
          'source=$source '
          'threadStatus=${threadStatus.wireValue} '
          'reason=within_settlement_grace_window '
          'remainingMs=${remaining.inMilliseconds}',
        );
        if (source != 'lifecycle_status_update') {
          _scheduleThreadSnapshotRefresh(
            delay: remaining > const Duration(milliseconds: 200)
                ? remaining
                : const Duration(milliseconds: 200),
          );
        }
        return;
      }
    }

    final updatedPendingItems = markPendingPromptsFailed(
      pendingItems,
      errorMessage:
          'Bridge did not confirm this message before the turn settled.',
    );
    final changed = updatedPendingItems.any(
      (item) =>
          item.localMessageState == ThreadActivityLocalMessageState.failed &&
          item.localErrorMessage ==
              'Bridge did not confirm this message before the turn settled.',
    );
    if (!changed) {
      return;
    }

    _debugLog(
      'thread_detail_pending_prompt_failed '
      'threadId=${state.threadId} '
      'source=$source '
      'count=${updatedPendingItems.length} '
      'threadStatus=${threadStatus.wireValue} '
      'pendingSubmittedAt=${_pendingPromptSubmittedAt?.toIso8601String() ?? ''} '
      'pendingEventIds=${updatedPendingItems.map((item) => item.eventId).join(',')}',
    );
    state = state.copyWith(pendingLocalUserPrompts: updatedPendingItems);
    _clearPendingPromptConfirmationTracking();
  }

  void _recordPendingPromptSettlement() {
    if (_pendingPromptSubmittedAt == null ||
        state.pendingLocalUserPrompts.isEmpty ||
        _pendingPromptSettledAt != null) {
      return;
    }

    _pendingPromptSettledAt = DateTime.now();
  }

  void _recordMeaningfulLiveActivity(ThreadActivityItem item) {
    if (_isMeaningfulTurnLiveActivity(item)) {
      _activeTurnSawMeaningfulLiveActivity = true;
      _silentTurnWatchdogStrikeCount = 0;
      _cancelSilentTurnWatchdog();
    }
  }

  bool _isMeaningfulTurnLiveActivity(ThreadActivityItem item) {
    return active_turn.isMeaningfulTurnLiveActivity(item);
  }

  void _recordLiveTurnShape({
    required BridgeEventEnvelope<Map<String, dynamic>> event,
    required ThreadActivityItem item,
  }) {
    if (item.type == ThreadActivityItemType.userPrompt) {
      _activeTurnSawLiveUserPrompt = true;
    }
    if (_eventUsesIncrementalDelta(event)) {
      _activeTurnSawIncrementalDelta = true;
    }
  }

  bool _eventUsesIncrementalDelta(
    BridgeEventEnvelope<Map<String, dynamic>> event,
  ) {
    return active_turn.eventUsesIncrementalDelta(event);
  }

  void _syncSilentTurnWatchdog() {
    if (!_shouldWatchForSilentTurn()) {
      _cancelSilentTurnWatchdog();
      return;
    }

    _silentTurnWatchdogTimer?.cancel();
    _silentTurnWatchdogTimer = Timer(
      _threadSilentTurnSnapshotWatchdogDelay,
      _handleSilentTurnWatchdogFired,
    );
  }

  bool _shouldWatchForSilentTurn() {
    if (_isDisposed) {
      return false;
    }

    final thread = state.thread;
    if (thread == null || thread.status != ThreadStatus.running) {
      return false;
    }

    return !_activeTurnSawMeaningfulLiveActivity;
  }

  void _cancelSilentTurnWatchdog() {
    _silentTurnWatchdogTimer?.cancel();
    _silentTurnWatchdogTimer = null;
  }

  void _handleSilentTurnWatchdogFired() {
    if (!_shouldWatchForSilentTurn()) {
      return;
    }

    _silentTurnWatchdogStrikeCount += 1;
    _activeTurnNeedsSnapshotCatchUp = true;
    _debugLog(
      'thread_detail_silent_turn_watchdog '
      'threadId=${state.threadId} '
      'pendingPrompt=${_pendingPromptSubmittedAt != null} '
      'strike=$_silentTurnWatchdogStrikeCount',
    );
    if (_silentTurnWatchdogStrikeCount >=
        _threadSilentTurnWatchdogReconnectThreshold) {
      _debugLog(
        'thread_detail_silent_turn_watchdog_reconnect '
        'threadId=${state.threadId} '
        'strike=$_silentTurnWatchdogStrikeCount',
      );
      _silentTurnWatchdogStrikeCount = 0;
      _handleLiveStreamDisconnected();
      return;
    }
    _scheduleThreadSnapshotRefresh(delay: const Duration(milliseconds: 100));
    _syncSilentTurnWatchdog();
  }

  void _logPromptResponseIfNeeded({
    required BridgeEventEnvelope<Map<String, dynamic>> event,
    required ThreadActivityItem nextItem,
  }) {
    final submittedAt = _pendingPromptSubmittedAt;
    if (submittedAt == null) {
      return;
    }
    if (event.kind != BridgeEventKind.messageDelta) {
      return;
    }
    if (nextItem.type != ThreadActivityItemType.assistantOutput) {
      return;
    }

    final visibleText = nextItem.body.trim();
    if (visibleText.isEmpty) {
      return;
    }

    final elapsedMs = DateTime.now().difference(submittedAt).inMilliseconds;
    _debugLog(
      'thread_detail_response_received '
      'threadId=${state.threadId} '
      'eventId=${event.eventId} '
      'elapsedMs=$elapsedMs '
      'chars=${visibleText.length}',
    );
    _clearPendingPromptConfirmationTracking();
  }

  String? _liveEventTitle(BridgeEventEnvelope<Map<String, dynamic>> event) {
    final rawTitle = event.payload['title'];
    if (rawTitle is! String) {
      return null;
    }
    final normalized = rawTitle.trim();
    return normalized.isEmpty ? null : normalized;
  }

  void _logLiveEvent({
    required BridgeEventEnvelope<Map<String, dynamic>> event,
    required Map<String, dynamic> mergedPayload,
    required ThreadActivityItem nextItem,
  }) {
    if (event.kind != BridgeEventKind.messageDelta) {
      return;
    }

    final delta = event.payload['delta'];
    final mergedTextValue = mergedPayload['text'];
    final deltaLength = delta is String ? delta.length : 0;
    final mergedTextLength = mergedTextValue is String
        ? mergedTextValue.length
        : 0;
    final renderedBodyLength = nextItem.body.length;
    _debugLog(
      'thread_detail_live_event '
      'threadId=${state.threadId} '
      'eventId=${event.eventId} '
      'kind=${event.kind.wireValue} '
      'deltaChars=$deltaLength '
      'mergedTextChars=$mergedTextLength '
      'renderedBodyChars=$renderedBodyLength '
      'replace=${event.payload['replace'] == true}',
    );
  }

  Map<String, dynamic> _mergeLivePayload(
    Map<String, dynamic>? currentPayload,
    BridgeEventEnvelope<Map<String, dynamic>> event,
  ) {
    final payload = Map<String, dynamic>.from(currentPayload ?? const {});
    payload.addAll(event.payload);

    switch (event.kind) {
      case BridgeEventKind.messageDelta:
        payload['replace'] = event.payload['replace'] == true;
        _mergeIncrementalField(payload, 'text');
        payload['type'] = payload['type'] ?? 'message';
        break;
      case BridgeEventKind.planDelta:
        payload['replace'] = event.payload['replace'] == true;
        _mergeIncrementalField(payload, 'text');
        payload['type'] = payload['type'] ?? 'plan';
        break;
      case BridgeEventKind.commandDelta:
        payload['replace'] = event.payload['replace'] == true;
        _mergeIncrementalField(payload, 'output');
        payload['output'] ??= payload['aggregatedOutput'];
        payload['aggregatedOutput'] = payload['output'];
        payload['type'] = payload['type'] ?? 'command';
        break;
      case BridgeEventKind.fileChange:
        payload['replace'] = event.payload['replace'] == true;
        _mergeIncrementalField(payload, 'resolved_unified_diff');
        payload['resolved_unified_diff'] ??= payload['output'];
        payload['type'] = payload['type'] ?? 'file_change';
        break;
      case BridgeEventKind.threadMetadataChanged:
      case BridgeEventKind.threadStatusChanged:
      case BridgeEventKind.userInputRequested:
      case BridgeEventKind.approvalRequested:
      case BridgeEventKind.securityAudit:
        break;
    }

    return payload;
  }

  void _mergeIncrementalField(
    Map<String, dynamic> payload,
    String canonicalField,
  ) {
    final replace = payload['replace'] == true;
    final delta = payload['delta'];
    final nextDelta = delta is String ? delta : '';
    final existingValue = payload[canonicalField];
    final existingText = existingValue is String ? existingValue : '';

    if (nextDelta.isEmpty) {
      if (existingText.isEmpty) {
        final fallback = payload['text'];
        if (fallback is String && fallback.isNotEmpty) {
          payload[canonicalField] = fallback;
        }
      }
      return;
    }

    payload[canonicalField] = replace ? nextDelta : '$existingText$nextDelta';
  }
}
