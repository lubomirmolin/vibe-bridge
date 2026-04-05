part of 'thread_detail_controller.dart';

mixin _ThreadDetailControllerLoadingMixin on _ThreadDetailControllerContext {
  Future<void> loadThread() async {
    if (_isDisposed) {
      return;
    }

    _reconnectScheduler.cancel();
    state = _resetTransientState(
      state,
    ).copyWith(isLoading: true, isUnavailable: false);

    try {
      await _closeLiveSubscription();
      _knownEventIds.clear();
      _lastLiveFrameFingerprintByEventId.clear();
      final requestedThreadId = state.threadId;

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
        context: 'loading thread detail',
      );

      state = _resetTransientState(
        state,
      ).copyWith(thread: scopedDetail, isLoading: true, isUnavailable: false);
      _threadListController.syncThreadDetail(scopedDetail);

      final page = await _bridgeApi.fetchThreadTimelinePage(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
        threadId: requestedThreadId,
        limit: _initialVisibleTimelineEntries,
      );
      if (!_isRequestCurrent(requestedThreadId)) {
        return;
      }
      final scopedPage = _ensureScopedTimelinePage(
        page: page,
        expectedThreadId: requestedThreadId,
        context: 'loading thread timeline',
      );
      _seedLatestBridgeSeq(scopedPage.latestBridgeSeq);

      final items = _mergeTimelineEntries(
        currentItems: const <ThreadActivityItem>[],
        timeline: scopedPage.entries,
      );
      _trackKnownEventIds(items);

      if (_isDisposed) {
        return;
      }

      state = _resetTransientState(state).copyWith(
        thread: scopedDetail,
        items: items,
        workflowState: scopedPage.workflowState,
        pendingUserInput: scopedPage.pendingUserInput,
        liveConnectionState: LiveConnectionState.connected,
        isLoading: true,
        isUnavailable: false,
        hasMoreBefore: scopedPage.hasMoreBefore,
        nextBefore: scopedPage.nextBefore,
      );
      await refreshGitStatus(showLoading: false);
      await _startLiveSubscription();
      if (_isDisposed || !_isRequestCurrent(requestedThreadId)) {
        return;
      }
      state = state.copyWith(
        isLoading: false,
        liveConnectionState: LiveConnectionState.connected,
        clearStreamErrorMessage: true,
      );
    } on ThreadDetailBridgeException catch (error) {
      if (_isDisposed) {
        return;
      }

      state = state.copyWith(
        isLoading: false,
        errorMessage: error.message,
        isUnavailable: error.isUnavailable,
        isConnectivityUnavailable: error.isConnectivityError,
        liveConnectionState: error.isConnectivityError
            ? LiveConnectionState.disconnected
            : state.liveConnectionState,
      );
    } catch (_) {
      if (_isDisposed) {
        return;
      }

      state = state.copyWith(
        isLoading: false,
        errorMessage: 'Couldn’t load this thread right now.',
        liveConnectionState: LiveConnectionState.disconnected,
      );
    }
  }

  Future<void> loadEarlierHistory() async {
    if (!state.canLoadEarlierHistory) {
      return;
    }

    final requestedThreadId = state.threadId;
    final previousBlockSignatures = _visibleBlockSignatures(state.visibleItems);

    state = state.copyWith(
      isLoadingEarlierHistory: true,
      clearStreamErrorMessage: true,
    );

    try {
      var nextBefore = state.nextBefore;
      var hasMoreBefore = state.hasMoreBefore;
      var items = state.items;
      ThreadDetailDto? latestThread = state.thread;
      ThreadWorkflowStateDto? latestWorkflowState = state.workflowState;

      while (hasMoreBefore && nextBefore != null) {
        final page = await _bridgeApi.fetchThreadTimelinePage(
          bridgeApiBaseUrl: _bridgeApiBaseUrl,
          threadId: requestedThreadId,
          before: nextBefore,
          limit: _initialVisibleTimelineEntries,
        );
        if (!_isRequestCurrent(requestedThreadId)) {
          return;
        }
        final scopedPage = _ensureScopedTimelinePage(
          page: page,
          expectedThreadId: requestedThreadId,
          context: 'loading older history',
        );
        _seedLatestBridgeSeq(scopedPage.latestBridgeSeq);
        latestThread = _fresherThreadDetail(
          current: latestThread,
          candidate: scopedPage.thread,
        );
        latestWorkflowState = scopedPage.workflowState;
        items = _prependTimelineEntries(items, scopedPage.entries);
        hasMoreBefore = scopedPage.hasMoreBefore;
        nextBefore = scopedPage.nextBefore;

        if (_didRevealNewVisibleBlock(
          previousBlockSignatures: previousBlockSignatures,
          nextItems: items,
        )) {
          break;
        }
      }

      if (_isDisposed) {
        return;
      }

      state = state.copyWith(
        thread: latestThread,
        items: items,
        workflowState: latestWorkflowState,
        hasMoreBefore: hasMoreBefore,
        nextBefore: nextBefore,
        isLoadingEarlierHistory: false,
        clearErrorMessage: true,
        clearStreamErrorMessage: true,
        clearStaleMessage: true,
      );
      if (latestThread != null) {
        _threadListController.syncThreadDetail(latestThread);
      }
    } on ThreadDetailBridgeException catch (error) {
      if (_isDisposed || !_isRequestCurrent(requestedThreadId)) {
        return;
      }

      state = state.copyWith(
        isLoadingEarlierHistory: false,
        streamErrorMessage: error.message,
        isConnectivityUnavailable: error.isConnectivityError,
        liveConnectionState: error.isConnectivityError
            ? LiveConnectionState.disconnected
            : state.liveConnectionState,
      );
    } catch (_) {
      if (_isDisposed || !_isRequestCurrent(requestedThreadId)) {
        return;
      }

      state = state.copyWith(
        isLoadingEarlierHistory: false,
        streamErrorMessage: 'Couldn’t load older history right now.',
        liveConnectionState: LiveConnectionState.disconnected,
      );
    }
  }

  Future<void> retryReconnectCatchUp() async {
    _reconnectScheduler.cancel();
    await _runReconnectCatchUp();
  }

  Future<void> _startLiveSubscription({
    int? afterSeq,
    bool handleFailure = true,
  }) async {
    try {
      final subscription = await _liveStream.subscribe(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
        threadId: state.threadId,
        afterSeq: afterSeq,
      );
      if (_isDisposed) {
        await subscription.close();
        return;
      }
      _liveSubscription = subscription;

      _liveEventSubscription = subscription.events.listen(
        _handleLiveEvent,
        onError: (_) {
          _handleLiveStreamDisconnected();
        },
        onDone: () {
          _handleLiveStreamDisconnected();
        },
      );

      state = state.copyWith(
        liveConnectionState: LiveConnectionState.connected,
        clearStreamErrorMessage: true,
        clearStaleMessage: true,
        clearTurnControlError: true,
        isShowingCachedData: false,
        isConnectivityUnavailable: false,
      );
    } catch (_) {
      if (handleFailure) {
        _handleLiveStreamDisconnected();
        return;
      }
      rethrow;
    }
  }

  void _handleLiveStreamDisconnected() {
    if (_isDisposed) {
      return;
    }

    _cancelSilentTurnWatchdog();
    if (state.isTurnActive ||
        _lastActiveTurnSignalAt != null ||
        _pendingPromptSubmittedAt != null) {
      _activeTurnNeedsSnapshotCatchUp = true;
    }

    state = state.copyWith(
      liveConnectionState: LiveConnectionState.disconnected,
      streamErrorMessage:
          'Live updates disconnected. Reconnecting and catching up…',
      staleMessage:
          'Bridge is offline. Current thread content may be stale until reconnect.',
      isShowingCachedData: false,
      isConnectivityUnavailable: true,
      gitControlsUnavailableReason:
          'Git controls are unavailable while reconnecting to the private route.',
    );
    _reconnectScheduler.schedule();
  }

  Future<void> _runReconnectCatchUp() async {
    if (_isDisposed) {
      return;
    }

    try {
      final lastSeenBridgeSeq = _lastSeenLiveBridgeSeq;
      if (state.liveConnectionState == LiveConnectionState.disconnected) {
        state = state.copyWith(
          liveConnectionState: LiveConnectionState.reconnecting,
        );
      }
      await _closeLiveSubscription();
      final requestedThreadId = state.threadId;

      final canUseReplayOnly =
          lastSeenBridgeSeq != null && !_activeTurnNeedsSnapshotCatchUp;
      if (canUseReplayOnly) {
        try {
          await _startLiveSubscription(
            afterSeq: lastSeenBridgeSeq,
            handleFailure: false,
          );
          if (!_isRequestCurrent(requestedThreadId) || _isDisposed) {
            return;
          }
          state = state.copyWith(
            liveConnectionState: LiveConnectionState.connected,
            clearErrorMessage: true,
            clearStreamErrorMessage: true,
            clearStaleMessage: true,
            clearTurnControlError: true,
            isShowingCachedData: false,
            isConnectivityUnavailable: false,
          );
          return;
        } on ThreadLiveReplayGapException {
          _activeTurnNeedsSnapshotCatchUp = true;
        }
      }

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
        context: 'running reconnect catch-up detail refresh',
      );

      state = state.copyWith(
        thread: scopedDetail,
        clearErrorMessage: true,
        clearStreamErrorMessage: true,
        clearStaleMessage: true,
        clearTurnControlError: true,
        isShowingCachedData: false,
        isConnectivityUnavailable: false,
        git: ThreadGitState.initial,
      );
      _threadListController.syncThreadDetail(scopedDetail);

      final page = await _bridgeApi.fetchThreadTimelinePage(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
        threadId: requestedThreadId,
        limit: _initialVisibleTimelineEntries,
      );
      if (!_isRequestCurrent(requestedThreadId)) {
        return;
      }
      final scopedPage = _ensureScopedTimelinePage(
        page: page,
        expectedThreadId: requestedThreadId,
        context: 'running reconnect catch-up timeline refresh',
      );
      _seedLatestBridgeSeq(scopedPage.latestBridgeSeq);

      final mergedItems = _mergeTimeline(scopedPage.entries);

      if (_isDisposed) {
        return;
      }

      state = state.copyWith(
        thread: scopedDetail,
        items: mergedItems,
        pendingLocalUserPrompts: _reconcilePendingLocalUserPrompts(mergedItems),
        workflowState: scopedPage.workflowState,
        pendingUserInput: scopedPage.pendingUserInput,
        liveConnectionState: LiveConnectionState.connected,
        clearErrorMessage: true,
        clearStreamErrorMessage: true,
        clearStaleMessage: true,
        clearTurnControlError: true,
        isLoading: false,
        isUnavailable: false,
        isShowingCachedData: false,
        isConnectivityUnavailable: false,
        git: ThreadGitState.initial,
      );
      _markUnconfirmedPendingPromptsAsFailedIfThreadSettled(
        source: 'reconnect_catchup',
      );

      await refreshGitStatus(showLoading: false);
      await _startLiveSubscription(
        afterSeq: lastSeenBridgeSeq,
        handleFailure: false,
      );
    } on ThreadDetailBridgeException catch (error) {
      if (_isDisposed) {
        return;
      }

      state = state.copyWith(
        liveConnectionState: LiveConnectionState.disconnected,
        streamErrorMessage: error.message,
        staleMessage:
            'Bridge is offline. Current thread content may be stale until reconnect.',
        isShowingCachedData: false,
        isConnectivityUnavailable: true,
      );
      _reconnectScheduler.schedule();
    } on ThreadLiveReplayGapException {
      if (_isDisposed) {
        return;
      }
      _reconnectScheduler.schedule();
    } catch (_) {
      if (_isDisposed) {
        return;
      }

      _reconnectScheduler.schedule();
    }
  }

  List<ThreadActivityItem> _mergeTimeline(
    List<ThreadTimelineEntryDto> timeline,
  ) {
    final nextItems = replaceTimelineItems(timeline);
    _replaceKnownEventIds(nextItems);
    return nextItems;
  }

  List<ThreadActivityItem> _mergeTimelineEntries({
    required List<ThreadActivityItem> currentItems,
    required List<ThreadTimelineEntryDto> timeline,
  }) {
    return mergeTimelineEntries(currentItems: currentItems, timeline: timeline);
  }

  void _trackKnownEventIds(List<ThreadActivityItem> items) {
    _knownEventIds.addAll(items.map((item) => item.eventId));
  }

  void _replaceKnownEventIds(List<ThreadActivityItem> items) {
    _knownEventIds
      ..clear()
      ..addAll(items.map((item) => item.eventId));
  }

  List<ThreadActivityItem> _prependTimelineEntries(
    List<ThreadActivityItem> currentItems,
    List<ThreadTimelineEntryDto> timeline,
  ) {
    return prependTimelineEntries(
      currentItems: currentItems,
      timeline: timeline,
      knownEventIds: _knownEventIds,
    );
  }

  ThreadDetailDto? _fresherThreadDetail({
    required ThreadDetailDto? current,
    required ThreadDetailDto? candidate,
  }) {
    if (candidate == null) {
      return current;
    }
    if (current == null) {
      return candidate;
    }

    final currentUpdatedAt = DateTime.tryParse(current.updatedAt);
    final candidateUpdatedAt = DateTime.tryParse(candidate.updatedAt);
    if (currentUpdatedAt == null || candidateUpdatedAt == null) {
      return candidate;
    }

    return candidateUpdatedAt.isAfter(currentUpdatedAt) ? candidate : current;
  }

  bool _isRequestCurrent(String requestThreadId) {
    return !_isDisposed && state.threadId == requestThreadId;
  }

  ThreadDetailDto _ensureScopedThreadDetail({
    required ThreadDetailDto detail,
    required String expectedThreadId,
    required String context,
  }) {
    if (detail.threadId == expectedThreadId) {
      return detail;
    }

    throw ThreadDetailBridgeException(
      message:
          'Live thread data fell out of sync while $context. Retry the thread view and reconnect if needed.',
    );
  }

  ThreadTimelinePageDto _ensureScopedTimelinePage({
    required ThreadTimelinePageDto page,
    required String expectedThreadId,
    required String context,
  }) {
    _ensureScopedThreadDetail(
      detail: page.thread,
      expectedThreadId: expectedThreadId,
      context: context,
    );
    return page;
  }

  bool _didRevealNewVisibleBlock({
    required List<String> previousBlockSignatures,
    required List<ThreadActivityItem> nextItems,
  }) {
    final nextVisibleItems = nextItems
        .where(_isConversationTimelineItem)
        .toList(growable: false);
    final nextBlockSignatures = _visibleBlockSignatures(nextVisibleItems);
    return _hasNewLeadingVisibleBlock(
      previousBlockSignatures: previousBlockSignatures,
      nextBlockSignatures: nextBlockSignatures,
    );
  }

  List<String> _visibleBlockSignatures(List<ThreadActivityItem> items) {
    if (items.isEmpty) {
      return const <String>[];
    }

    final signatures = <String>[];
    var index = 0;

    while (index < items.length) {
      final item = items[index];

      if (_isExplorationTimelineItem(item)) {
        var scanIndex = index;
        while (scanIndex < items.length &&
            _isExplorationTimelineItem(items[scanIndex])) {
          scanIndex += 1;
        }

        signatures.add('exploration:${items[scanIndex - 1].eventId}');
        index = scanIndex;
        continue;
      }

      var scanIndex = index + 1;
      while (scanIndex < items.length &&
          _isExplorationTimelineItem(items[scanIndex])) {
        scanIndex += 1;
      }

      signatures.add('activity:${item.eventId}');
      index = scanIndex;
    }

    return List<String>.unmodifiable(signatures);
  }

  bool _hasNewLeadingVisibleBlock({
    required List<String> previousBlockSignatures,
    required List<String> nextBlockSignatures,
  }) {
    var previousIndex = previousBlockSignatures.length - 1;
    var nextIndex = nextBlockSignatures.length - 1;

    while (previousIndex >= 0 &&
        nextIndex >= 0 &&
        previousBlockSignatures[previousIndex] ==
            nextBlockSignatures[nextIndex]) {
      previousIndex -= 1;
      nextIndex -= 1;
    }

    return nextIndex >= 0;
  }
}
