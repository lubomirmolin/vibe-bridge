part of 'thread_detail_controller.dart';

mixin _ThreadDetailControllerLiveMixin on _ThreadDetailControllerContext {
  void _handleLiveEvent(BridgeEventEnvelope<Map<String, dynamic>> event) {
    if (event.threadId != state.threadId) {
      return;
    }
    if (_isDuplicateLiveFrame(event)) {
      return;
    }
    if (event.bridgeSeq != null) {
      _lastSeenLiveBridgeSeq = event.bridgeSeq;
    }

    final shouldReloadTimeline = _shouldReloadTimelineAfterLiveEvent(event);

    if (event.kind == BridgeEventKind.userInputRequested) {
      final resolvedState = (event.payload['state'] as String?)?.trim();
      state = state.copyWith(
        pendingUserInput: resolvedState == 'resolved'
            ? null
            : PendingUserInputDto.fromJson(event.payload),
        clearStreamErrorMessage: true,
      );
      _scheduleThreadDetailRefresh(delay: const Duration(milliseconds: 200));
      return;
    }

    if (event.kind == BridgeEventKind.threadMetadataChanged) {
      final rawWorkflowState = event.payload['workflow_state'];
      final nextWorkflowState = rawWorkflowState is Map<String, dynamic>
          ? ThreadWorkflowStateDto.fromJson(rawWorkflowState)
          : null;
      state = state.copyWith(
        workflowState: nextWorkflowState,
        clearWorkflowState: rawWorkflowState == null,
        clearStreamErrorMessage: true,
      );
      return;
    }

    if (event.kind == BridgeEventKind.threadStatusChanged) {
      _applyLifecycleStatusUpdate(event);
    } else {
      _recordActiveTurnSignal();
    }

    final exactEventIndex = state.items.indexWhere(
      (item) => item.eventId == event.eventId,
    );
    final mergedPayload = _mergeLivePayload(
      exactEventIndex >= 0 ? state.items[exactEventIndex].payload : null,
      event,
    );
    final mergedEvent = BridgeEventEnvelope<Map<String, dynamic>>(
      contractVersion: event.contractVersion,
      eventId: event.eventId,
      threadId: event.threadId,
      kind: event.kind,
      occurredAt: event.occurredAt,
      payload: mergedPayload,
      annotations: event.annotations,
    );
    final nextItem = ThreadActivityItem.fromLiveEvent(mergedEvent);
    _logLiveEvent(
      event: event,
      mergedPayload: mergedPayload,
      nextItem: nextItem,
    );
    _recordLiveTurnShape(event: event, item: nextItem);
    _recordMeaningfulLiveActivity(nextItem);
    _logPromptResponseIfNeeded(event: event, nextItem: nextItem);
    final nextItems = List<ThreadActivityItem>.from(state.items);
    final mergeIndex = findTimelineMergeIndex(
      items: nextItems,
      candidate: nextItem,
    );
    if (mergeIndex >= 0) {
      nextItems[mergeIndex] = preferTimelineMergedItem(
        current: nextItems[mergeIndex],
        candidate: nextItem,
      );
    } else {
      nextItems.add(nextItem);
    }
    _knownEventIds.add(event.eventId);

    final thread = state.thread;
    if (thread != null && event.kind != BridgeEventKind.threadStatusChanged) {
      final nextSummary = nextItem.body.trim().isEmpty
          ? thread.lastTurnSummary
          : nextItem.body;
      _updateThreadStatus(
        status: thread.status,
        updatedAt: event.occurredAt,
        lastTurnSummary: nextSummary,
      );
      _threadListController.applyThreadStatusUpdate(
        threadId: event.threadId,
        status: thread.status,
        updatedAt: event.occurredAt,
      );
    }

    state = state.copyWith(
      items: nextItems,
      pendingLocalUserPrompts: _reconcilePendingLocalUserPrompts(nextItems),
      clearStreamErrorMessage: true,
    );
    if (shouldReloadTimeline) {
      _scheduleThreadSnapshotRefresh(delay: const Duration(milliseconds: 200));
    } else {
      _scheduleThreadDetailRefresh(delay: const Duration(milliseconds: 700));
    }
  }

  bool _isDuplicateLiveFrame(BridgeEventEnvelope<Map<String, dynamic>> event) {
    final fingerprint = jsonEncode(<String, Object?>{
      'kind': event.kind.wireValue,
      'occurredAt': event.occurredAt,
      'payload': event.payload,
    });
    final previous = _lastLiveFrameFingerprintByEventId[event.eventId];
    if (previous == fingerprint) {
      _debugLog(
        'thread_detail_duplicate_live_frame '
        'threadId=${state.threadId} '
        'eventId=${event.eventId} '
        'kind=${event.kind.wireValue}',
      );
      return true;
    }
    _lastLiveFrameFingerprintByEventId[event.eventId] = fingerprint;
    return false;
  }

  void _scheduleThreadDetailRefresh({required Duration delay}) {
    if (_isDisposed || state.thread == null) {
      return;
    }

    if (_snapshotRefreshTimer?.isActive ?? false) {
      return;
    }
    _detailRefreshTimer?.cancel();
    _detailRefreshTimer = Timer(delay, () {
      unawaited(_refreshThreadDetailFromBridge());
    });
  }

  void _scheduleThreadSnapshotRefresh({required Duration delay}) {
    if (_isDisposed || state.thread == null) {
      return;
    }

    _snapshotRefreshTimer?.cancel();
    _detailRefreshTimer?.cancel();
    _snapshotRefreshTimer = Timer(delay, () {
      unawaited(_refreshThreadSnapshotFromBridge());
    });
  }

  bool _shouldReloadTimelineAfterLiveEvent(
    BridgeEventEnvelope<Map<String, dynamic>> event,
  ) {
    try {
      return active_turn.shouldReloadTimelineAfterLiveEvent(
        event: event,
        currentThread: state.thread,
        activeTurnNeedsSnapshotCatchUp: _activeTurnNeedsSnapshotCatchUp,
        activeTurnSawMeaningfulLiveActivity:
            _activeTurnSawMeaningfulLiveActivity,
        activeTurnSawLiveUserPrompt: _activeTurnSawLiveUserPrompt,
        activeTurnSawIncrementalDelta: _activeTurnSawIncrementalDelta,
        lastActiveTurnSignalAt: _lastActiveTurnSignalAt,
        pendingPromptSubmittedAt: _pendingPromptSubmittedAt,
      );
    } on FormatException {
      return true;
    }
  }

  Future<void> _refreshThreadDetailFromBridge() async {
    if (_isDisposed) {
      return;
    }
    if (_isDetailRefreshInFlight) {
      _shouldRefreshDetailAfterCurrentRequest = true;
      return;
    }

    final requestedThreadId = state.threadId;
    _isDetailRefreshInFlight = true;

    try {
      final detail = await _bridgeApi.fetchThreadDetail(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
        threadId: requestedThreadId,
      );
      if (!_isRequestCurrent(requestedThreadId)) {
        return;
      }

      final scopedDetail = _ensureScopedThreadDetail(
        detail: detail,
        expectedThreadId: requestedThreadId,
        context: 'refreshing live thread detail',
      );

      if (!_shouldApplyRefreshedThreadDetail(
        current: state.thread,
        refreshed: scopedDetail,
      )) {
        _syncSilentTurnWatchdog();
        return;
      }

      state = state.copyWith(thread: scopedDetail);
      _threadListController.syncThreadDetail(scopedDetail);
      if (scopedDetail.status != ThreadStatus.running) {
        _finishTrackingActiveTurn();
      } else {
        _syncSilentTurnWatchdog();
      }
    } on ThreadDetailBridgeException {
      // Keep the current live state when a background metadata refresh fails.
    } catch (_) {
      // Ignore best-effort metadata refresh failures.
    } finally {
      _isDetailRefreshInFlight = false;
      if (_shouldRefreshDetailAfterCurrentRequest && !_isDisposed) {
        _shouldRefreshDetailAfterCurrentRequest = false;
        unawaited(_refreshThreadDetailFromBridge());
      }
    }
  }

  Future<void> _refreshThreadSnapshotFromBridge() async {
    if (_isDisposed) {
      return;
    }
    if (_isSnapshotRefreshInFlight) {
      _shouldRefreshSnapshotAfterCurrentRequest = true;
      return;
    }

    final requestedThreadId = state.threadId;
    _isSnapshotRefreshInFlight = true;

    try {
      final detail = await _bridgeApi.fetchThreadDetail(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
        threadId: requestedThreadId,
      );
      if (_isDisposed || !_isRequestCurrent(requestedThreadId)) {
        return;
      }
      final scopedDetail = _ensureScopedThreadDetail(
        detail: detail,
        expectedThreadId: requestedThreadId,
        context: 'refreshing live thread snapshot detail',
      );

      final page = await _bridgeApi.fetchThreadTimelinePage(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
        threadId: requestedThreadId,
        limit: _timelineRefreshLimit(),
      );
      if (_isDisposed || !_isRequestCurrent(requestedThreadId)) {
        return;
      }
      final scopedPage = _ensureScopedTimelinePage(
        page: page,
        expectedThreadId: requestedThreadId,
        context: 'refreshing live thread snapshot timeline',
      );
      _seedLatestBridgeSeq(scopedPage.latestBridgeSeq);
      _debugLog(
        'thread_detail_snapshot_refresh_result '
        'threadId=${state.threadId} '
        'status=${scopedDetail.status.wireValue} '
        'entryCount=${scopedPage.entries.length} '
        'hasPendingUserInput=${scopedPage.pendingUserInput != null}',
      );
      final nextThread =
          _shouldApplyRefreshedThreadDetail(
            current: state.thread,
            refreshed: scopedDetail,
          )
          ? scopedDetail
          : (state.thread ?? scopedDetail);

      final shouldPreserveLiveItems =
          _activeTurnSawMeaningfulLiveActivity &&
          scopedPage.entries.isEmpty &&
          state.items.isNotEmpty;
      final items = shouldPreserveLiveItems
          ? state.items
          : _mergeTimeline(scopedPage.entries);
      if (shouldPreserveLiveItems) {
        _debugLog(
          'thread_detail_snapshot_refresh_preserve_live_items '
          'threadId=${state.threadId}',
        );
      }

      state = state.copyWith(
        thread: nextThread,
        items: items,
        pendingLocalUserPrompts: _reconcilePendingLocalUserPrompts(items),
        workflowState: scopedPage.workflowState,
        pendingUserInput: scopedPage.pendingUserInput,
        hasMoreBefore: scopedPage.hasMoreBefore,
        nextBefore: scopedPage.nextBefore,
        clearErrorMessage: true,
        clearStreamErrorMessage: true,
        clearStaleMessage: true,
      );
      _markUnconfirmedPendingPromptsAsFailedIfThreadSettled(
        source: 'snapshot_refresh',
      );
      _threadListController.syncThreadDetail(nextThread);
      if (nextThread.status != ThreadStatus.running) {
        _finishTrackingActiveTurn();
      } else {
        _syncSilentTurnWatchdog();
      }
    } on ThreadDetailBridgeException {
      // Keep the current live state when a background snapshot refresh fails.
    } catch (_) {
      // Ignore best-effort snapshot refresh failures.
    } finally {
      _isSnapshotRefreshInFlight = false;
      if (_shouldRefreshSnapshotAfterCurrentRequest && !_isDisposed) {
        _shouldRefreshSnapshotAfterCurrentRequest = false;
        unawaited(_refreshThreadSnapshotFromBridge());
      }
    }
  }

  bool _shouldApplyRefreshedThreadDetail({
    required ThreadDetailDto? current,
    required ThreadDetailDto refreshed,
  }) {
    return active_turn.shouldApplyRefreshedThreadDetail(
      current: current,
      refreshed: refreshed,
      activeTurnNeedsSnapshotCatchUp: _activeTurnNeedsSnapshotCatchUp,
      activeTurnSawMeaningfulLiveActivity: _activeTurnSawMeaningfulLiveActivity,
      lastActiveTurnSignalAt: _lastActiveTurnSignalAt,
      activeTurnRefreshGuardWindow: _threadActiveTurnRefreshGuardWindow,
    );
  }

  void _applyLifecycleStatusUpdate(
    BridgeEventEnvelope<Map<String, dynamic>> event,
  ) {
    final rawStatus = event.payload['status'];
    if (rawStatus is! String || rawStatus.trim().isEmpty) {
      return;
    }

    ThreadStatus? status;
    try {
      status = threadStatusFromWire(rawStatus.trim());
    } on FormatException {
      return;
    }

    final thread = state.thread;
    if (thread == null) {
      return;
    }

    if (_shouldIgnoreTransientLifecycleStatusUpdate(
      currentStatus: thread.status,
      nextStatus: status,
    )) {
      _recordTurnUiStateSnapshot(
        'lifecycle_status_ignored',
        data: <String, Object?>{
          'incomingStatus': status.wireValue,
          'previousStatus': thread.status.wireValue,
          'reason': 'transient_settling_idle',
          'eventId': event.eventId,
        },
      );
      _debugLog(
        'thread_detail_lifecycle_status_ignored '
        'threadId=${state.threadId} '
        'previousStatus=${thread.status.wireValue} '
        'nextStatus=${status.wireValue} '
        'reason=transient_settling_idle',
      );
      return;
    }

    if (status == ThreadStatus.running) {
      if (thread.status != ThreadStatus.running) {
        _startTrackingActiveTurn();
      } else {
        _recordActiveTurnSignal();
      }
    }

    _updateThreadStatus(
      status: status,
      updatedAt: event.occurredAt,
      lastTurnSummary: thread.lastTurnSummary,
      title: _liveEventTitle(event) ?? thread.title,
    );
    _threadListController.applyThreadStatusUpdate(
      threadId: thread.threadId,
      status: status,
      updatedAt: event.occurredAt,
      title: _liveEventTitle(event),
    );
    _debugLog(
      'thread_detail_lifecycle_status_update '
      'threadId=${state.threadId} '
      'previousStatus=${thread.status.wireValue} '
      'nextStatus=${status.wireValue} '
      'reason=${(event.payload['reason'] as String?)?.trim() ?? ''} '
      'pendingPromptCount=${state.pendingLocalUserPrompts.length} '
      'pendingSubmitted=${_pendingPromptSubmittedAt != null}',
    );

    if (status != ThreadStatus.running) {
      _recordPendingPromptSettlement();
      _markUnconfirmedPendingPromptsAsFailedIfThreadSettled(
        source: 'lifecycle_status_update',
      );
      _finishTrackingActiveTurn(clearPendingPromptState: false);
    }
    _recordTurnUiStateSnapshot(
      'lifecycle_status_applied',
      data: <String, Object?>{
        'incomingStatus': status.wireValue,
        'previousStatus': thread.status.wireValue,
        'reason': (event.payload['reason'] as String?)?.trim(),
        'eventId': event.eventId,
      },
    );
  }

  bool _shouldIgnoreTransientLifecycleStatusUpdate({
    required ThreadStatus currentStatus,
    required ThreadStatus nextStatus,
  }) {
    final hasActiveTurnEvidence =
        _pendingPromptSubmittedAt != null ||
        _activeTurnSawLiveUserPrompt ||
        _activeTurnSawIncrementalDelta ||
        _activeTurnSawMeaningfulLiveActivity ||
        _activeTurnNeedsSnapshotCatchUp;
    return active_turn.shouldIgnoreTransientLifecycleStatusUpdate(
      currentStatus: currentStatus,
      nextStatus: nextStatus,
      lastActiveTurnSignalAt: _lastActiveTurnSignalAt,
      hasActiveTurnEvidence: hasActiveTurnEvidence,
      activeTurnRefreshGuardWindow: _threadActiveTurnRefreshGuardWindow,
    );
  }
}
