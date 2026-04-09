part of 'thread_detail_page.dart';

const double _composerPrimaryButtonSize = 50;
const double _composerModePeekOffset = 62;
const double _composerPrimaryRailWidth = 74;

bool _isProviderApprovalPrompt(PendingUserInputDto? pendingUserInput) {
  return pendingUserInput != null &&
      pendingUserInput.questions.length == 1 &&
      pendingUserInput.questions.first.questionId == 'approval_decision';
}

ParsedCommandOutput? _latestComposerDiffOutput(List<ThreadActivityItem> items) {
  for (final item in items.reversed) {
    if (item.type != ThreadActivityItemType.fileChange) {
      continue;
    }
    final parsedOutput = item.parsedCommandOutput;
    if (parsedOutput == null || !parsedOutput.hasDiffBlock) {
      continue;
    }
    return parsedOutput;
  }
  return null;
}

class _PinnedTurnComposer extends StatelessWidget {
  const _PinnedTurnComposer({
    required this.composerController,
    required this.composerFocusNode,
    required this.isTurnActive,
    required this.controlsEnabled,
    required this.isComposerMutationInFlight,
    required this.isInterruptMutationInFlight,
    required this.isSpeechRecording,
    required this.isSpeechTranscribing,
    required this.speechDurationSeconds,
    this.speechAmplitudeStream,
    required this.speechMessage,
    required this.speechMessageIsError,
    required this.isComposerFocused,
    required this.attachedImages,
    required this.threadUsage,
    required this.composerMode,
    this.latestDiffAdditions,
    this.latestDiffDeletions,
    required this.selectedPlanOptionByQuestionId,
    required this.selectedProvider,
    required this.selectedModel,
    required this.selectedReasoning,
    required this.supportsPlanMode,
    required this.session,
    required this.accessModeErrorMessage,
    required this.onPickImages,
    required this.onToggleSpeechInput,
    required this.onRemoveImage,
    required this.onComposerModeChanged,
    required this.onSelectPlanOption,
    this.onOpenDiff,
    required this.onSubmitComposer,
    required this.onSubmitPendingUserInput,
    this.pendingUserInput,
  });

  final TextEditingController composerController;
  final FocusNode composerFocusNode;
  final bool isTurnActive;
  final bool controlsEnabled;
  final bool isComposerMutationInFlight;
  final bool isInterruptMutationInFlight;
  final bool isSpeechRecording;
  final bool isSpeechTranscribing;
  final int speechDurationSeconds;
  final Stream<SpeechCaptureAmplitude>? speechAmplitudeStream;
  final String? speechMessage;
  final bool speechMessageIsError;
  final bool isComposerFocused;
  final List<XFile> attachedImages;
  final ThreadUsageDto? threadUsage;
  final TurnMode composerMode;
  final int? latestDiffAdditions;
  final int? latestDiffDeletions;
  final PendingUserInputDto? pendingUserInput;
  final Map<String, String> selectedPlanOptionByQuestionId;
  final ProviderKind selectedProvider;
  final String selectedModel;
  final String selectedReasoning;
  final bool supportsPlanMode;
  final AppBridgeSession? session;
  final String? accessModeErrorMessage;
  final Future<void> Function() onPickImages;
  final Future<void> Function() onToggleSpeechInput;
  final ValueChanged<XFile> onRemoveImage;
  final ValueChanged<TurnMode> onComposerModeChanged;
  final void Function(String questionId, String optionId) onSelectPlanOption;
  final VoidCallback? onOpenDiff;
  final Future<bool> Function(String rawInput) onSubmitComposer;
  final Future<bool> Function(String rawInput)? onSubmitPendingUserInput;

  @override
  Widget build(BuildContext context) {
    final hasPendingUserInput = pendingUserInput != null;
    final isProviderApprovalPrompt = _isProviderApprovalPrompt(
      pendingUserInput,
    );
    final canEditPinnedControls =
        !isComposerMutationInFlight &&
        !isInterruptMutationInFlight &&
        !isSpeechRecording &&
        !isSpeechTranscribing;
    final composerEnabled =
        controlsEnabled &&
        !isComposerMutationInFlight &&
        !isInterruptMutationInFlight &&
        !isSpeechRecording &&
        !isSpeechTranscribing;
    final shouldHideLeadingActions =
        hasPendingUserInput || isComposerFocused || isSpeechRecording;

    if (!composerEnabled && composerFocusNode.hasFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (composerFocusNode.hasFocus) {
          composerFocusNode.unfocus();
        }
      });
    }
    if (isProviderApprovalPrompt && composerFocusNode.hasFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (composerFocusNode.hasFocus) {
          composerFocusNode.unfocus();
        }
      });
    }

    Future<void> submitCurrentInput() async {
      final success = hasPendingUserInput
          ? await onSubmitPendingUserInput?.call(composerController.text) ??
                false
          : await onSubmitComposer(composerController.text);
      if (success) {
        composerController.clear();
      }
    }

    Widget buildStatusMessages() {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (session == null) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: const Text(
                'Pair with a host bridge to change access mode from here.',
                key: Key('turn-composer-access-mode-pairing-note'),
                style: TextStyle(color: AppTheme.textSubtle, fontSize: 12),
              ),
            ),
          ],
          if (accessModeErrorMessage != null) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                accessModeErrorMessage!,
                key: const Key('turn-composer-access-mode-error'),
                style: const TextStyle(color: AppTheme.rose, fontSize: 12),
              ),
            ),
          ],
          if (speechMessage != null) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                speechMessage!,
                key: const Key('turn-composer-speech-message'),
                style: TextStyle(
                  color: speechMessageIsError
                      ? AppTheme.rose
                      : AppTheme.textSubtle,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ],
      );
    }

    if (isProviderApprovalPrompt) {
      final approvalQuestion = pendingUserInput!.questions.first;
      return Padding(
        key: const Key('pinned-turn-composer'),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 14),
        child: Align(
          alignment: Alignment.bottomCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: _ThreadDetailPageState._sessionContentMaxWidth,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _PendingProviderApprovalCard(
                  pendingUserInput: pendingUserInput!,
                  question: approvalQuestion,
                  selectedOptionId:
                      selectedPlanOptionByQuestionId[approvalQuestion
                          .questionId],
                  isSubmitting:
                      isComposerMutationInFlight || isInterruptMutationInFlight,
                  onSelectOption: onSelectPlanOption,
                ),
                buildStatusMessages(),
              ],
            ),
          ),
        ),
      );
    }

    return Padding(
      key: const Key('pinned-turn-composer'),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 14),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: _ThreadDetailPageState._sessionContentMaxWidth,
          ),
          child: SizedBox(
            width: double.infinity,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (pendingUserInput != null) ...[
                  _PendingUserInputCard(
                    pendingUserInput: pendingUserInput!,
                    selectedOptionByQuestionId: selectedPlanOptionByQuestionId,
                    onSelectOption: onSelectPlanOption,
                  ),
                  const SizedBox(height: 10),
                ],
                if (attachedImages.isNotEmpty) ...[
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: attachedImages
                          .map(
                            (image) => _ComposerImagePreview(
                              image: image,
                              onRemove: () => onRemoveImage(image),
                            ),
                          )
                          .toList(growable: false),
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
                TextFieldTapRegion(
                  child: Stack(
                    clipBehavior: Clip.none,
                    alignment: Alignment.bottomRight,
                    children: [
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOutCubic,
                        decoration: BoxDecoration(
                          color: AppTheme.surfaceZinc800.withValues(
                            alpha: isComposerFocused ? 0.98 : 0.9,
                          ),
                          borderRadius: BorderRadius.circular(28),
                          border: Border.all(
                            color: hasPendingUserInput
                                ? const Color(0xFFA855F7).withValues(alpha: 0.5)
                                : Colors.white.withValues(
                                    alpha: isComposerFocused ? 0.14 : 0.07,
                                  ),
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(
                                alpha: isComposerFocused ? 0.18 : 0.12,
                              ),
                              blurRadius: isComposerFocused ? 18 : 12,
                              offset: const Offset(0, 8),
                            ),
                          ],
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            AnimatedSwitcher(
                              duration: const Duration(milliseconds: 220),
                              switchInCurve: Curves.easeOutCubic,
                              switchOutCurve: Curves.easeInCubic,
                              transitionBuilder: (child, animation) {
                                return FadeTransition(
                                  opacity: animation,
                                  child: SizeTransition(
                                    axis: Axis.horizontal,
                                    axisAlignment: -1,
                                    sizeFactor: animation,
                                    child: child,
                                  ),
                                );
                              },
                              child: shouldHideLeadingActions
                                  ? const SizedBox(
                                      key: ValueKey(
                                        'composer-leading-actions-hidden',
                                      ),
                                    )
                                  : Padding(
                                      key: const ValueKey(
                                        'composer-leading-actions-visible',
                                      ),
                                      padding: const EdgeInsets.only(
                                        left: 4,
                                        bottom: 4,
                                      ),
                                      child: IconButton(
                                        key: const Key(
                                          'turn-composer-attach-button',
                                        ),
                                        tooltip: 'Attach images',
                                        icon: PhosphorIcon(
                                          PhosphorIcons.plus(),
                                          size: 22,
                                          color: AppTheme.textMain,
                                        ),
                                        onPressed: canEditPinnedControls
                                            ? () async {
                                                await onPickImages();
                                              }
                                            : null,
                                      ),
                                    ),
                            ),
                            Expanded(
                              child: AnimatedSwitcher(
                                duration: const Duration(milliseconds: 180),
                                switchInCurve: Curves.easeOutCubic,
                                switchOutCurve: Curves.easeInCubic,
                                child: isSpeechRecording
                                    ? _RecordingStatusInline(
                                        key: const ValueKey(
                                          'recording-inline-status',
                                        ),
                                        durationSeconds: speechDurationSeconds,
                                        amplitudeStream: speechAmplitudeStream,
                                      )
                                    : TextField(
                                        key: const Key('turn-composer-input'),
                                        controller: composerController,
                                        focusNode: composerFocusNode,
                                        enabled: composerEnabled,
                                        minLines: 1,
                                        maxLines: 4,
                                        keyboardType: TextInputType.multiline,
                                        textCapitalization:
                                            TextCapitalization.sentences,
                                        textInputAction: TextInputAction.send,
                                        onSubmitted: composerEnabled
                                            ? (_) {
                                                unawaited(submitCurrentInput());
                                              }
                                            : null,
                                        onTapOutside: (_) =>
                                            composerFocusNode.unfocus(),
                                        style: const TextStyle(
                                          color: AppTheme.textMain,
                                          fontSize: 15,
                                        ),
                                        decoration: InputDecoration(
                                          hintText: isSpeechTranscribing
                                              ? 'Transcribing voice message…'
                                              : hasPendingUserInput
                                              ? 'Something else...'
                                              : composerMode == TurnMode.plan
                                              ? 'Ask ${selectedProvider == ProviderKind.codex ? 'Codex' : 'Claude'} to plan...'
                                              : 'Message ${selectedProvider == ProviderKind.codex ? 'Codex' : 'Claude'}...',
                                          hintStyle: const TextStyle(
                                            color: AppTheme.textSubtle,
                                          ),
                                          border: InputBorder.none,
                                          contentPadding:
                                              const EdgeInsets.symmetric(
                                                horizontal: 16,
                                                vertical: 16,
                                              ),
                                        ),
                                      ),
                              ),
                            ),
                            AnimatedSwitcher(
                              duration: const Duration(milliseconds: 220),
                              switchInCurve: Curves.easeOutCubic,
                              switchOutCurve: Curves.easeInCubic,
                              transitionBuilder: (child, animation) {
                                return FadeTransition(
                                  opacity: animation,
                                  child: SizeTransition(
                                    axis: Axis.horizontal,
                                    axisAlignment: -1,
                                    sizeFactor: animation,
                                    child: child,
                                  ),
                                );
                              },
                              child:
                                  isComposerFocused ||
                                      isSpeechRecording ||
                                      isSpeechTranscribing
                                  ? Padding(
                                      key: const ValueKey(
                                        'composer-speech-visible',
                                      ),
                                      padding: const EdgeInsets.only(bottom: 2),
                                      child: SizedBox(
                                        width: 52,
                                        height: 52,
                                        child: IconButton(
                                          key: const Key(
                                            'turn-composer-speech-toggle',
                                          ),
                                          tooltip: isSpeechRecording
                                              ? 'Stop recording'
                                              : 'Voice input',
                                          onPressed:
                                              (controlsEnabled &&
                                                  !isTurnActive &&
                                                  !isComposerMutationInFlight &&
                                                  !isInterruptMutationInFlight &&
                                                  !isSpeechTranscribing)
                                              ? () async {
                                                  await onToggleSpeechInput();
                                                }
                                              : null,
                                          icon: AnimatedSwitcher(
                                            duration: const Duration(
                                              milliseconds: 180,
                                            ),
                                            child: isSpeechTranscribing
                                                ? const SizedBox.square(
                                                    key: ValueKey(
                                                      'speech-loading',
                                                    ),
                                                    dimension: 20,
                                                    child:
                                                        CircularProgressIndicator(
                                                          strokeWidth: 2,
                                                          color:
                                                              AppTheme.textMain,
                                                        ),
                                                  )
                                                : PhosphorIcon(
                                                    key: ValueKey<bool>(
                                                      isSpeechRecording,
                                                    ),
                                                    isSpeechRecording
                                                        ? PhosphorIcons.x()
                                                        : PhosphorIcons.microphone(),
                                                    size: 22,
                                                    color: isSpeechRecording
                                                        ? AppTheme.emerald
                                                        : AppTheme.textMain,
                                                  ),
                                          ),
                                        ),
                                      ),
                                    )
                                  : const SizedBox(
                                      key: ValueKey('composer-speech-hidden'),
                                    ),
                            ),
                            SizedBox(
                              width:
                                  (hasPendingUserInput
                                      ? _composerPrimaryButtonSize
                                      : _composerPrimaryRailWidth) -
                                  16.0,
                            ),
                          ],
                        ),
                      ),
                      Positioned(
                        right: -16.0,
                        bottom: 0,
                        child: _ComposerPrimaryActionRail(
                          composerController: composerController,
                          attachedImages: attachedImages,
                          composerMode: composerMode,
                          supportsPlanMode: supportsPlanMode,
                          hasPendingUserInput: hasPendingUserInput,
                          selectedPlanOptionByQuestionId:
                              selectedPlanOptionByQuestionId,
                          controlsEnabled: controlsEnabled,
                          isTurnActive: isTurnActive,
                          isComposerMutationInFlight:
                              isComposerMutationInFlight,
                          isInterruptMutationInFlight:
                              isInterruptMutationInFlight,
                          isSpeechRecording: isSpeechRecording,
                          isSpeechTranscribing: isSpeechTranscribing,
                          onComposerModeChanged: onComposerModeChanged,
                          onSubmitCurrentInput: submitCurrentInput,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                _ComposerFooter(
                  selectedProvider: selectedProvider,
                  selectedModel: selectedModel,
                  threadUsage: threadUsage,
                  latestDiffAdditions: latestDiffAdditions,
                  latestDiffDeletions: latestDiffDeletions,
                  onOpenDiff: onOpenDiff,
                ),
                buildStatusMessages(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ComposerFooter extends StatelessWidget {
  const _ComposerFooter({
    required this.selectedProvider,
    required this.selectedModel,
    required this.threadUsage,
    this.latestDiffAdditions,
    this.latestDiffDeletions,
    this.onOpenDiff,
  });

  final ProviderKind selectedProvider;
  final String selectedModel;
  final ThreadUsageDto? threadUsage;
  final int? latestDiffAdditions;
  final int? latestDiffDeletions;
  final VoidCallback? onOpenDiff;

  @override
  Widget build(BuildContext context) {
    final metadata = Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 6,
      runSpacing: 4,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ProviderIcon(provider: selectedProvider, size: 14),
            const SizedBox(width: 6),
            Text(
              selectedModel,
              style: const TextStyle(
                color: AppTheme.textMuted,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        if (threadUsage != null && selectedProvider == ProviderKind.codex) ...[
          const Text(
            '•',
            style: TextStyle(color: AppTheme.textSubtle, fontSize: 11),
          ),
          _UsageMetrics(threadUsage: threadUsage!),
        ],
      ],
    );
    final additions = latestDiffAdditions;
    final deletions = latestDiffDeletions;
    final hasDiffSummary =
        additions != null &&
        deletions != null &&
        (additions > 0 || deletions > 0);

    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(left: 4, top: 2),
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (!hasDiffSummary) {
              return metadata;
            }

            final diffSummary = _ComposerDiffSummary(
              additions: additions,
              deletions: deletions,
              onTap: onOpenDiff,
            );
            final shouldStack = constraints.maxWidth < 460;
            if (shouldStack) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  metadata,
                  const SizedBox(height: 6),
                  Align(alignment: Alignment.centerRight, child: diffSummary),
                ],
              );
            }

            return Row(
              children: [
                Expanded(child: metadata),
                const SizedBox(width: 12),
                diffSummary,
              ],
            );
          },
        ),
      ),
    );
  }
}

class _ComposerDiffSummary extends StatelessWidget {
  const _ComposerDiffSummary({
    required this.additions,
    required this.deletions,
    this.onTap,
  });

  final int additions;
  final int deletions;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      child: Row(
        key: const Key('thread-composer-diff-summary'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '+$additions',
            key: const Key('thread-composer-diff-additions'),
            style: GoogleFonts.jetBrainsMono(
              color: AppTheme.emerald,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '-$deletions',
            key: const Key('thread-composer-diff-deletions'),
            style: GoogleFonts.jetBrainsMono(
              color: AppTheme.rose,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );

    final decorated = DecoratedBox(
      decoration: BoxDecoration(
        color: AppTheme.surfaceZinc900.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: content,
    );

    if (onTap == null) {
      return decorated;
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: const Key('thread-composer-diff-summary-button'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: decorated,
      ),
    );
  }
}

class _UsageMetrics extends StatelessWidget {
  const _UsageMetrics({required this.threadUsage});

  final ThreadUsageDto threadUsage;

  @override
  Widget build(BuildContext context) {
    final windows = <_UsageWindowPresentation>[
      _UsageWindowPresentation(
        key: const Key('thread-usage-primary-window'),
        resetLabel: _formatUsageResetLabel(
          threadUsage.primaryWindow.resetAfterSeconds,
        ),
        usedPercent: threadUsage.primaryWindow.usedPercent,
      ),
      if (threadUsage.secondaryWindow != null)
        _UsageWindowPresentation(
          key: const Key('thread-usage-secondary-window'),
          resetLabel: _formatUsageResetLabel(
            threadUsage.secondaryWindow!.resetAfterSeconds,
          ),
          usedPercent: threadUsage.secondaryWindow!.usedPercent,
        ),
    ];
    if (windows.isEmpty) {
      return const SizedBox.shrink();
    }

    return Wrap(
      spacing: 12,
      runSpacing: 4,
      children: windows
          .map((window) {
            return _SimpleUsageBar(
              key: window.key,
              resetLabel: window.resetLabel,
              usedPercent: window.usedPercent,
            );
          })
          .toList(growable: false),
    );
  }
}

class _UsageWindowPresentation {
  const _UsageWindowPresentation({
    required this.key,
    required this.resetLabel,
    required this.usedPercent,
  });

  final Key key;
  final String resetLabel;
  final int usedPercent;
}

class _SimpleUsageBar extends StatelessWidget {
  const _SimpleUsageBar({
    super.key,
    required this.resetLabel,
    required this.usedPercent,
  });

  final String resetLabel;
  final int usedPercent;

  @override
  Widget build(BuildContext context) {
    final remainingPercent = 100 - usedPercent.clamp(0, 100);
    final normalizedProgress = remainingPercent.toDouble() / 100;

    Color barColor = const Color(0xFF10B981); // Emerald 500
    if (remainingPercent < 20) {
      barColor = const Color(0xFFEF4444); // Red 500
    } else if (remainingPercent < 50) {
      barColor = const Color(0xFFF59E0B); // Amber 500
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          resetLabel,
          style: GoogleFonts.ibmPlexMono(
            color: AppTheme.textMuted,
            fontSize: 10,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.2,
          ),
        ),
        const SizedBox(width: 4),
        SizedBox(
          width: 32,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(1.5),
            child: LinearProgressIndicator(
              minHeight: 3,
              value: normalizedProgress,
              backgroundColor: Colors.white.withValues(alpha: 0.08),
              valueColor: AlwaysStoppedAnimation<Color>(barColor),
            ),
          ),
        ),
      ],
    );
  }
}

String _formatUsageResetLabel(int seconds) {
  const secondsPerMinute = 60;
  const secondsPerHour = 60 * secondsPerMinute;
  const secondsPerDay = 24 * secondsPerHour;
  final normalizedSeconds = seconds < 0 ? 0 : seconds;
  if (normalizedSeconds >= secondsPerDay) {
    return '${(normalizedSeconds / secondsPerDay).ceil()}d';
  }
  if (normalizedSeconds >= secondsPerHour) {
    return '${(normalizedSeconds / secondsPerHour).ceil()}h';
  }
  if (normalizedSeconds >= secondsPerMinute) {
    return '${(normalizedSeconds / secondsPerMinute).ceil()}m';
  }
  return '${normalizedSeconds}s';
}
