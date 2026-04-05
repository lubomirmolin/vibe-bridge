part of 'thread_detail_controller.dart';

mixin _ThreadDetailControllerMutationsMixin on _ThreadDetailControllerContext {
  Future<bool> submitComposerInput(
    String rawInput, {
    TurnMode mode = TurnMode.act,
    List<String> images = const <String>[],
    String? model,
    String? reasoningEffort,
  }) async {
    final thread = state.thread;
    if (thread == null) {
      return false;
    }

    if (!state.canRunMutatingActions) {
      state = state.copyWith(
        turnControlErrorMessage:
            'Turn controls are unavailable while the bridge is offline.',
      );
      return false;
    }

    final input = rawInput.trim();
    final normalizedImages = images
        .map((image) => image.trim())
        .where((image) => image.isNotEmpty)
        .toList(growable: false);
    if (input.isEmpty && normalizedImages.isEmpty) {
      state = state.copyWith(
        turnControlErrorMessage: state.isTurnActive
            ? 'Active-turn steering is unavailable in this build. Interrupt the turn or wait for it to finish before sending a new prompt.'
            : 'Enter a prompt or attach an image to start a turn.',
      );
      return false;
    }

    if (state.isTurnActive && normalizedImages.isNotEmpty) {
      state = state.copyWith(
        turnControlErrorMessage:
            'Interrupt the active turn or wait for it to finish before attaching images.',
      );
      return false;
    }

    state = state.copyWith(
      isComposerMutationInFlight: true,
      clearTurnControlError: true,
    );
    final shouldSteer = await _shouldRouteComposerInputToActiveTurnSteer();
    final clientMessageId = shouldSteer ? null : _generateClientMessageId();
    final clientTurnIntentId = shouldSteer
        ? null
        : _generateClientTurnIntentId();
    _recordDiagnostic(
      'composer_submit_started',
      data: <String, Object?>{
        'chars': input.length,
        'images': normalizedImages.length,
        'localIsTurnActive': state.isTurnActive,
        'shouldSteer': shouldSteer,
        'mode': mode.wireValue,
        'model': model,
        'reasoningEffort': reasoningEffort,
        'clientMessageId': clientMessageId,
        'clientTurnIntentId': clientTurnIntentId,
      },
    );
    _debugLog(
      'thread_detail_submit_composer '
      'threadId=${state.threadId} '
      'chars=${input.length} '
      'images=${normalizedImages.length} '
      'localIsTurnActive=${state.isTurnActive} '
      'shouldSteer=$shouldSteer '
      'mode=${mode.wireValue} '
      'clientMessageId=${clientMessageId ?? ''}',
    );
    final localPendingPromptId = shouldSteer
        ? null
        : _appendPendingLocalUserPrompt(
            clientMessageId: clientMessageId!,
            input: input,
            images: normalizedImages,
          );

    try {
      final mutationResult = shouldSteer
          ? await _bridgeApi.steerTurn(
              bridgeApiBaseUrl: _bridgeApiBaseUrl,
              threadId: state.threadId,
              instruction: input,
            )
          : await _bridgeApi.startTurn(
              bridgeApiBaseUrl: _bridgeApiBaseUrl,
              threadId: state.threadId,
              prompt: input,
              clientMessageId: clientMessageId!,
              clientTurnIntentId: clientTurnIntentId!,
              mode: mode,
              images: normalizedImages,
              model: model,
              effort: reasoningEffort,
            );

      _pendingPromptSubmittedAt = DateTime.now();
      _recordDiagnostic(
        'composer_submit_result',
        data: <String, Object?>{
          'operation': mutationResult.operation,
          'outcome': mutationResult.outcome,
          'threadStatus': mutationResult.threadStatus.wireValue,
          'turnId': mutationResult.turnId,
          'clientMessageId': mutationResult.clientMessageId,
          'clientTurnIntentId': mutationResult.clientTurnIntentId,
        },
      );
      _debugLog(
        'thread_detail_submit_composer_result '
        'threadId=${state.threadId} '
        'operation=${mutationResult.operation} '
        'outcome=${mutationResult.outcome} '
        'threadStatus=${mutationResult.threadStatus.wireValue} '
        'turnId=${mutationResult.turnId ?? ''}',
      );
      _applyTurnMutationResult(mutationResult);
      state = state.copyWith(
        isComposerMutationInFlight: false,
        clearTurnControlError: true,
      );
      return true;
    } on ThreadTurnBridgeException catch (error) {
      _recordDiagnostic(
        'composer_submit_failed',
        data: <String, Object?>{
          'message': error.message,
          'statusCode': error.statusCode,
          'code': error.code,
          'rawBody': error.rawBody,
          'isConnectivityError': error.isConnectivityError,
        },
      );
      _removePendingLocalUserPrompt(localPendingPromptId);
      state = state.copyWith(
        isComposerMutationInFlight: false,
        turnControlErrorMessage: error.message,
      );
      return false;
    } catch (_) {
      _recordDiagnostic(
        'composer_submit_failed',
        data: <String, Object?>{'message': 'unknown_error'},
      );
      _removePendingLocalUserPrompt(localPendingPromptId);
      state = state.copyWith(
        isComposerMutationInFlight: false,
        turnControlErrorMessage:
            'Couldn’t update the turn right now. Please try again.',
      );
      return false;
    }
  }

  Future<bool> _shouldRouteComposerInputToActiveTurnSteer() async {
    if (!state.isTurnActive) {
      _recordDiagnostic(
        'composer_route_decision',
        data: <String, Object?>{
          'localIsTurnActive': false,
          'shouldSteer': false,
          'reason': 'local_state_idle',
        },
      );
      return false;
    }

    final requestedThreadId = state.threadId;
    _recordDiagnostic(
      'thread_detail_verify_before_submit_started',
      data: <String, Object?>{'localStatus': state.thread?.status.wireValue},
    );
    try {
      final detail = await _bridgeApi.fetchThreadDetail(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
        threadId: requestedThreadId,
      );
      if (_isDisposed || !_isRequestCurrent(requestedThreadId)) {
        return state.isTurnActive;
      }

      final scopedDetail = _ensureScopedThreadDetail(
        detail: detail,
        expectedThreadId: requestedThreadId,
        context: 'verifying active turn state before submitting composer input',
      );
      _debugLog(
        'thread_detail_verify_turn_state_before_submit '
        'threadId=$requestedThreadId '
        'localStatus=${state.thread?.status.wireValue} '
        'bridgeStatus=${scopedDetail.status.wireValue}',
      );
      _recordDiagnostic(
        'thread_detail_verify_before_submit_result',
        data: <String, Object?>{
          'localStatus': state.thread?.status.wireValue,
          'bridgeStatus': scopedDetail.status.wireValue,
          'shouldSteer': scopedDetail.status == ThreadStatus.running,
        },
      );
      if (scopedDetail.status == ThreadStatus.running) {
        return true;
      }

      _updateThreadStatus(
        status: scopedDetail.status,
        updatedAt: scopedDetail.updatedAt,
        lastTurnSummary: scopedDetail.lastTurnSummary,
        title: scopedDetail.title,
      );
      _threadListController.applyThreadStatusUpdate(
        threadId: scopedDetail.threadId,
        status: scopedDetail.status,
        updatedAt: scopedDetail.updatedAt,
        title: scopedDetail.title,
      );
      _finishTrackingActiveTurn();
      return false;
    } catch (error) {
      _recordDiagnostic(
        'thread_detail_verify_before_submit_failed',
        data: <String, Object?>{
          'error': error.toString(),
          'errorType': error.runtimeType.toString(),
          'fallbackShouldSteer': true,
        },
      );
      return true;
    }
  }

  Future<bool> respondToPendingUserInput({
    required String freeText,
    required List<UserInputAnswerDto> answers,
    String? model,
    String? reasoningEffort,
  }) async {
    final pending = state.pendingUserInput;
    if (pending == null) {
      final workflowState = state.workflowState;
      state = state.copyWith(
        turnControlErrorMessage: switch ((
          workflowState?.workflowKind,
          workflowState?.state,
        )) {
          ('provider_approval', 'expired') =>
            'This approval request expired when the bridge restarted. Re-run the action if you still want to approve it.',
          ('plan_questionnaire', 'expired') =>
            'This plan questionnaire expired when the bridge restarted. Re-run plan mode if you still want Codex to continue with the clarification flow.',
          _ => 'There is no pending input request for this thread.',
        },
      );
      return false;
    }

    if (!state.canRunMutatingActions) {
      state = state.copyWith(
        turnControlErrorMessage:
            'Turn controls are unavailable while the bridge is offline.',
      );
      return false;
    }

    final isProviderApprovalPrompt =
        pending.questions.length == 1 &&
        pending.questions.first.questionId == 'approval_decision';
    final isLivePlanQuestionnaire =
        pending.workflowKind == 'plan_questionnaire' &&
        pending.providerRequestId != null;
    if (state.isTurnActive &&
        !isProviderApprovalPrompt &&
        !isLivePlanQuestionnaire) {
      state = state.copyWith(
        turnControlErrorMessage:
            'Wait for the active turn to finish before submitting this response.',
      );
      return false;
    }

    state = state.copyWith(
      isComposerMutationInFlight: true,
      clearTurnControlError: true,
    );

    try {
      final mutationResult = await _bridgeApi.respondToUserInput(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
        threadId: state.threadId,
        requestId: pending.requestId,
        answers: answers,
        freeText: freeText,
        model: model,
        effort: reasoningEffort,
      );

      _pendingPromptSubmittedAt = DateTime.now();
      _applyTurnMutationResult(mutationResult);
      state = state.copyWith(
        isComposerMutationInFlight: false,
        clearTurnControlError: true,
        clearWorkflowState: true,
        clearPendingUserInput: true,
      );
      if (!isLivePlanQuestionnaire) {
        unawaited(_refreshThreadSnapshotAfterMutation());
      }
      return true;
    } on ThreadTurnBridgeException catch (error) {
      state = state.copyWith(
        isComposerMutationInFlight: false,
        turnControlErrorMessage: error.message,
      );
      return false;
    } catch (_) {
      state = state.copyWith(
        isComposerMutationInFlight: false,
        turnControlErrorMessage:
            'Couldn’t submit this response right now. Please try again.',
      );
      return false;
    }
  }

  Future<bool> openOnMac() async {
    state = state.copyWith(
      isOpenOnMacInFlight: false,
      openOnMacErrorMessageValue: 'Open-on-host is unavailable in this build.',
      clearOpenOnMacMessage: true,
    );
    return false;
  }

  Future<bool> submitCommitAction({
    String? model,
    String? reasoningEffort,
  }) async {
    final thread = state.thread;
    if (thread == null) {
      return false;
    }

    if (!state.canRunMutatingActions) {
      state = state.copyWith(
        turnControlErrorMessage:
            'Turn controls are unavailable while the bridge is offline.',
      );
      return false;
    }

    if (state.isTurnActive) {
      state = state.copyWith(
        turnControlErrorMessage:
            'Interrupt the active turn or wait for it to finish before starting Commit.',
      );
      return false;
    }

    state = state.copyWith(
      isComposerMutationInFlight: true,
      clearTurnControlError: true,
    );

    try {
      final mutationResult = await _bridgeApi.startCommitAction(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
        threadId: state.threadId,
        model: model,
        effort: reasoningEffort,
      );

      _pendingPromptSubmittedAt = DateTime.now();
      _applyTurnMutationResult(mutationResult);
      state = state.copyWith(
        isComposerMutationInFlight: false,
        clearTurnControlError: true,
      );
      return true;
    } on ThreadTurnBridgeException catch (error) {
      state = state.copyWith(
        isComposerMutationInFlight: false,
        turnControlErrorMessage: error.message,
      );
      return false;
    } catch (_) {
      state = state.copyWith(
        isComposerMutationInFlight: false,
        turnControlErrorMessage:
            'Couldn’t start Commit right now. Please try again.',
      );
      return false;
    }
  }

  Future<bool> interruptActiveTurn() async {
    if (!state.isTurnActive) {
      return false;
    }

    if (!state.canRunMutatingActions) {
      state = state.copyWith(
        turnControlErrorMessage:
            'Turn controls are unavailable while the bridge is offline.',
      );
      return false;
    }

    state = state.copyWith(
      isInterruptMutationInFlight: true,
      clearTurnControlError: true,
    );

    try {
      final mutationResult = await _bridgeApi.interruptTurn(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
        threadId: state.threadId,
        turnId: state.thread?.activeTurnId,
      );
      _applyTurnMutationResult(mutationResult);
      state = state.copyWith(
        isInterruptMutationInFlight: false,
        clearTurnControlError: true,
      );
      return true;
    } on ThreadTurnBridgeException catch (error) {
      state = state.copyWith(
        isInterruptMutationInFlight: false,
        turnControlErrorMessage: 'Interrupt failed: ${error.message}',
      );
      return false;
    } catch (_) {
      state = state.copyWith(
        isInterruptMutationInFlight: false,
        turnControlErrorMessage:
            'Interrupt failed. The turn is still active. Please try again.',
      );
      return false;
    }
  }

  Future<void> refreshGitStatus({bool showLoading = true}) async {
    final thread = state.thread;
    if (thread == null) {
      return;
    }
    final requestedThreadId = state.threadId;

    state = state.copyWith(
      isGitStatusLoading: showLoading,
      clearGitErrorMessage: true,
      clearGitMutationMessage: showLoading,
      clearGitControlsUnavailableReason: true,
    );

    try {
      final gitStatus = await _bridgeApi.fetchGitStatus(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
        threadId: requestedThreadId,
      );
      if (!_isRequestCurrent(requestedThreadId)) {
        return;
      }
      final unavailableReason =
          _isRepositoryContextResolvable(gitStatus.repository)
          ? null
          : 'Git controls are unavailable for this thread.';
      state = state.copyWith(
        gitStatus: gitStatus,
        isGitStatusLoading: false,
        clearGitErrorMessage: true,
        clearGitMutationMessage: true,
        clearGitControlsUnavailableReason: unavailableReason == null,
        gitControlsUnavailableReason: unavailableReason,
      );
    } on ThreadGitBridgeException catch (error) {
      if (_isDisposed || !_isRequestCurrent(requestedThreadId)) {
        return;
      }
      final isNonRepositoryContext = _isNonRepositoryGitStatusError(
        error.message,
      );
      state = state.copyWith(
        clearGitStatus: state.gitStatus == null,
        isGitStatusLoading: false,
        gitErrorMessage: showLoading && !isNonRepositoryContext
            ? error.message
            : null,
        clearGitErrorMessage: !showLoading || isNonRepositoryContext,
        clearGitMutationMessage: true,
        clearGitControlsUnavailableReason: false,
        gitControlsUnavailableReason: isNonRepositoryContext
            ? 'Git controls are unavailable for this thread.'
            : error.message,
      );
    } catch (_) {
      if (_isDisposed || !_isRequestCurrent(requestedThreadId)) {
        return;
      }
      state = state.copyWith(
        clearGitStatus: state.gitStatus == null,
        isGitStatusLoading: false,
        gitErrorMessage: showLoading
            ? 'Couldn’t load git status right now.'
            : null,
        clearGitErrorMessage: !showLoading,
        clearGitMutationMessage: true,
        clearGitControlsUnavailableReason: false,
        gitControlsUnavailableReason: 'Couldn’t load git status right now.',
      );
    }
  }

  Future<bool> switchBranch(String rawBranch) async {
    if (!state.canRunMutatingActions) {
      state = state.copyWith(
        gitErrorMessage:
            'Git controls are unavailable while the bridge is offline.',
        clearGitMutationMessage: true,
      );
      return false;
    }

    final branch = rawBranch.trim();
    if (branch.isEmpty) {
      state = state.copyWith(
        gitErrorMessage: 'Enter a branch name.',
        clearGitMutationMessage: true,
      );
      return false;
    }

    state = state.copyWith(
      isGitMutationInFlight: true,
      clearGitErrorMessage: true,
      clearGitMutationMessage: true,
    );

    try {
      final mutationResult = await _bridgeApi.switchBranch(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
        threadId: state.threadId,
        branch: branch,
      );
      _applyGitMutationResult(mutationResult);
      return true;
    } on ThreadGitApprovalRequiredException catch (error) {
      state = state.copyWith(
        isGitMutationInFlight: false,
        clearGitErrorMessage: true,
        gitMutationMessage: error.message,
      );
      return true;
    } on ThreadGitMutationBridgeException catch (error) {
      state = state.copyWith(
        isGitMutationInFlight: false,
        gitErrorMessage: error.message,
        clearGitMutationMessage: true,
      );
      return false;
    } catch (_) {
      state = state.copyWith(
        isGitMutationInFlight: false,
        gitErrorMessage: 'Couldn’t switch branches right now.',
        clearGitMutationMessage: true,
      );
      return false;
    }
  }

  Future<bool> pullRepository() async {
    if (!state.canRunMutatingActions) {
      state = state.copyWith(
        gitErrorMessage:
            'Git controls are unavailable while the bridge is offline.',
        clearGitMutationMessage: true,
      );
      return false;
    }

    state = state.copyWith(
      isGitMutationInFlight: true,
      clearGitErrorMessage: true,
      clearGitMutationMessage: true,
    );

    try {
      final mutationResult = await _bridgeApi.pullRepository(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
        threadId: state.threadId,
      );
      _applyGitMutationResult(mutationResult);
      return true;
    } on ThreadGitApprovalRequiredException catch (error) {
      state = state.copyWith(
        isGitMutationInFlight: false,
        clearGitErrorMessage: true,
        gitMutationMessage: error.message,
      );
      return true;
    } on ThreadGitMutationBridgeException catch (error) {
      state = state.copyWith(
        isGitMutationInFlight: false,
        gitErrorMessage: error.message,
        clearGitMutationMessage: true,
      );
      return false;
    } catch (_) {
      state = state.copyWith(
        isGitMutationInFlight: false,
        gitErrorMessage: 'Couldn’t pull the repository right now.',
        clearGitMutationMessage: true,
      );
      return false;
    }
  }

  Future<bool> pushRepository() async {
    if (!state.canRunMutatingActions) {
      state = state.copyWith(
        gitErrorMessage:
            'Git controls are unavailable while the bridge is offline.',
        clearGitMutationMessage: true,
      );
      return false;
    }

    state = state.copyWith(
      isGitMutationInFlight: true,
      clearGitErrorMessage: true,
      clearGitMutationMessage: true,
    );

    try {
      final mutationResult = await _bridgeApi.pushRepository(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
        threadId: state.threadId,
      );
      _applyGitMutationResult(mutationResult);
      return true;
    } on ThreadGitApprovalRequiredException catch (error) {
      state = state.copyWith(
        isGitMutationInFlight: false,
        clearGitErrorMessage: true,
        gitMutationMessage: error.message,
      );
      return true;
    } on ThreadGitMutationBridgeException catch (error) {
      state = state.copyWith(
        isGitMutationInFlight: false,
        gitErrorMessage: error.message,
        clearGitMutationMessage: true,
      );
      return false;
    } catch (_) {
      state = state.copyWith(
        isGitMutationInFlight: false,
        gitErrorMessage: 'Couldn’t push the repository right now.',
        clearGitMutationMessage: true,
      );
      return false;
    }
  }

  void _applyGitMutationResult(MutationResultResponseDto mutationResult) {
    final thread = state.thread;
    final nextUpdatedAt = DateTime.now().toUtc().toIso8601String();
    final nextGitStatus = GitStatusResponseDto(
      contractVersion: mutationResult.contractVersion,
      threadId: mutationResult.threadId,
      repository: mutationResult.repository,
      status: mutationResult.status,
    );

    ThreadDetailDto? nextThread = thread;
    if (thread != null) {
      nextThread = thread.copyWith(
        status: mutationResult.threadStatus,
        repository: mutationResult.repository.repository,
        branch: mutationResult.repository.branch,
        updatedAt: nextUpdatedAt,
        lastTurnSummary: mutationResult.message,
      );
      _threadListController.syncThreadDetail(nextThread);
    }

    state = state.copyWith(
      thread: nextThread,
      gitStatus: nextGitStatus,
      isGitStatusLoading: false,
      isGitMutationInFlight: false,
      clearGitErrorMessage: true,
      gitMutationMessage: mutationResult.message,
      clearGitControlsUnavailableReason: true,
    );
  }

  void _applyTurnMutationResult(TurnMutationResult mutationResult) {
    final thread = state.thread;
    if (thread == null) {
      return;
    }

    final updatedAt = DateTime.now().toUtc().toIso8601String();
    state = state.copyWith(
      thread: thread.copyWith(
        status: mutationResult.threadStatus,
        updatedAt: updatedAt,
        lastTurnSummary: mutationResult.message,
        activeTurnId: mutationResult.threadStatus == ThreadStatus.running
            ? (mutationResult.turnId ?? thread.activeTurnId)
            : null,
      ),
    );
    if (mutationResult.threadStatus != ThreadStatus.running) {
      _recordPendingPromptSettlement();
      _finishTrackingActiveTurn();
    }
    if (mutationResult.threadStatus == ThreadStatus.running) {
      _startTrackingActiveTurn();
    }
    _threadListController.applyThreadStatusUpdate(
      threadId: thread.threadId,
      status: mutationResult.threadStatus,
      updatedAt: updatedAt,
    );
    _recordTurnUiStateSnapshot(
      'turn_mutation_state_applied',
      data: <String, Object?>{
        'operation': mutationResult.operation,
        'outcome': mutationResult.outcome,
        'threadStatus': mutationResult.threadStatus.wireValue,
        'turnId': mutationResult.turnId,
      },
    );
  }

  Future<void> _refreshThreadSnapshotAfterMutation() async {
    final requestedThreadId = state.threadId;
    if (_isDisposed || requestedThreadId.trim().isEmpty) {
      return;
    }

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
        context: 'refreshing thread detail after mutation',
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
        context: 'refreshing thread timeline after mutation',
      );
      _seedLatestBridgeSeq(scopedPage.latestBridgeSeq);

      final items = replaceTimelineItems(scopedPage.entries);
      _replaceKnownEventIds(items);

      state = state.copyWith(
        thread: scopedDetail,
        items: items,
        pendingUserInput: scopedPage.pendingUserInput,
        hasMoreBefore: scopedPage.hasMoreBefore,
        nextBefore: scopedPage.nextBefore,
        clearErrorMessage: true,
        clearStreamErrorMessage: true,
        clearStaleMessage: true,
      );
      _markUnconfirmedPendingPromptsAsFailedIfThreadSettled(
        source: 'post_mutation_snapshot',
      );
      _threadListController.syncThreadDetail(scopedDetail);
    } catch (_) {
      // Avoid disrupting the active thread when the follow-up refresh fails.
      return;
    }
  }
}
