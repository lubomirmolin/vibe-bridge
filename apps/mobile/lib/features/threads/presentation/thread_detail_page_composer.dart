part of 'thread_detail_page.dart';

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
    required this.composerMode,
    required this.selectedPlanOptionByQuestionId,
    required this.modelOptions,
    required this.reasoningOptions,
    required this.selectedModel,
    required this.selectedReasoning,
    required this.accessMode,
    required this.session,
    required this.isAccessModeUpdating,
    required this.accessModeErrorMessage,
    required this.onPickImages,
    required this.onToggleSpeechInput,
    required this.onRemoveImage,
    required this.onComposerModeChanged,
    required this.onSelectPlanOption,
    required this.onModelChanged,
    required this.onReasoningChanged,
    required this.onAccessModeChanged,
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
  final TurnMode composerMode;
  final PendingUserInputDto? pendingUserInput;
  final Map<String, String> selectedPlanOptionByQuestionId;
  final List<ModelOptionDto> modelOptions;
  final List<String> reasoningOptions;
  final String selectedModel;
  final String selectedReasoning;
  final AccessMode accessMode;
  final AppBridgeSession? session;
  final bool isAccessModeUpdating;
  final String? accessModeErrorMessage;
  final Future<void> Function() onPickImages;
  final Future<void> Function() onToggleSpeechInput;
  final ValueChanged<XFile> onRemoveImage;
  final ValueChanged<TurnMode> onComposerModeChanged;
  final void Function(String questionId, String optionId) onSelectPlanOption;
  final ValueChanged<String> onModelChanged;
  final ValueChanged<String> onReasoningChanged;
  final ValueChanged<AccessMode> onAccessModeChanged;
  final Future<bool> Function(String rawInput) onSubmitComposer;
  final Future<bool> Function(String rawInput)? onSubmitPendingUserInput;

  @override
  Widget build(BuildContext context) {
    final hasPendingUserInput = pendingUserInput != null;
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
                                padding: const EdgeInsets.only(right: 8),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    _ComposerUtilityButton(
                                      key: const Key(
                                        'turn-composer-attach-button',
                                      ),
                                      icon: PhosphorIcons.plus(),
                                      tooltip: 'Attach images',
                                      onPressed: canEditPinnedControls
                                          ? () async {
                                              await onPickImages();
                                            }
                                          : null,
                                    ),
                                    const SizedBox(width: 8),
                                    _ComposerUtilityButton(
                                      key: const Key(
                                        'turn-composer-model-button',
                                      ),
                                      icon: PhosphorIcons.slidersHorizontal(),
                                      tooltip: 'Composer settings',
                                      onPressed: canEditPinnedControls
                                          ? () {
                                              composerFocusNode.unfocus();
                                              showModalBottomSheet<void>(
                                                context: context,
                                                backgroundColor:
                                                    Colors.transparent,
                                                isScrollControlled: true,
                                                builder: (context) =>
                                                    _ComposerModelSheet(
                                                      modelOptions:
                                                          modelOptions,
                                                      reasoningOptions:
                                                          reasoningOptions,
                                                      initialModel:
                                                          selectedModel,
                                                      initialReasoning:
                                                          selectedReasoning,
                                                      selectedAccessMode:
                                                          accessMode,
                                                      session: session,
                                                      isAccessModeUpdating:
                                                          isAccessModeUpdating,
                                                      onModelChanged:
                                                          onModelChanged,
                                                      onReasoningChanged:
                                                          onReasoningChanged,
                                                      onAccessModeChanged:
                                                          onAccessModeChanged,
                                                    ),
                                              );
                                            }
                                          : null,
                                    ),
                                  ],
                                ),
                              ),
                      ),
                      Expanded(
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 220),
                          curve: Curves.easeOutCubic,
                          decoration: BoxDecoration(
                            color: AppTheme.surfaceZinc800.withValues(
                              alpha: isComposerFocused ? 0.98 : 0.9,
                            ),
                            borderRadius: BorderRadius.circular(26),
                            border: Border.all(
                              color: Colors.white.withValues(
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
                                    textInputAction: TextInputAction.newline,
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
                                          ? 'Ask Codex to plan...'
                                          : 'Message Codex...',
                                      hintStyle: const TextStyle(
                                        color: AppTheme.textSubtle,
                                      ),
                                      border: InputBorder.none,
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                            horizontal: 18,
                                            vertical: 16,
                                          ),
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
                                key: const ValueKey('composer-speech-visible'),
                                padding: const EdgeInsets.only(left: 10),
                                child: SizedBox(
                                  width: 56,
                                  height: 56,
                                  child: MagneticButton(
                                    key: const Key(
                                      'turn-composer-speech-toggle',
                                    ),
                                    isCircle: true,
                                    variant: MagneticButtonVariant.secondary,
                                    onClick:
                                        (controlsEnabled &&
                                            !isTurnActive &&
                                            !isComposerMutationInFlight &&
                                            !isInterruptMutationInFlight &&
                                            !isSpeechTranscribing)
                                        ? () async {
                                            await onToggleSpeechInput();
                                          }
                                        : () {},
                                    child: AnimatedSwitcher(
                                      duration: const Duration(
                                        milliseconds: 180,
                                      ),
                                      child: isSpeechTranscribing
                                          ? const SizedBox.square(
                                              key: ValueKey('speech-loading'),
                                              dimension: 20,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                                color: AppTheme.textMain,
                                              ),
                                            )
                                          : PhosphorIcon(
                                              key: ValueKey<bool>(
                                                isSpeechRecording,
                                              ),
                                              isSpeechRecording
                                                  ? PhosphorIcons.x()
                                                  : PhosphorIcons.microphone(),
                                              size: 24,
                                              color: isSpeechRecording
                                                  ? AppTheme.emerald
                                                  : null,
                                            ),
                                    ),
                                  ),
                                ),
                              )
                            : const SizedBox(
                                key: ValueKey('composer-speech-hidden'),
                              ),
                      ),
                      const SizedBox(width: 10),
                      _ComposerPrimaryActionRail(
                        composerController: composerController,
                        attachedImages: attachedImages,
                        composerMode: composerMode,
                        hasPendingUserInput: hasPendingUserInput,
                        selectedPlanOptionByQuestionId:
                            selectedPlanOptionByQuestionId,
                        controlsEnabled: controlsEnabled,
                        isTurnActive: isTurnActive,
                        isComposerMutationInFlight: isComposerMutationInFlight,
                        isInterruptMutationInFlight:
                            isInterruptMutationInFlight,
                        isSpeechRecording: isSpeechRecording,
                        isSpeechTranscribing: isSpeechTranscribing,
                        onComposerModeChanged: onComposerModeChanged,
                        onSubmitComposer: onSubmitComposer,
                        onSubmitPendingUserInput: onSubmitPendingUserInput,
                      ),
                    ],
                  ),
                ),
                if (session == null) ...[
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: const Text(
                      'Pair with a host bridge to change access mode from here.',
                      key: Key('turn-composer-access-mode-pairing-note'),
                      style: TextStyle(
                        color: AppTheme.textSubtle,
                        fontSize: 12,
                      ),
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
                      style: const TextStyle(
                        color: AppTheme.rose,
                        fontSize: 12,
                      ),
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
            ),
          ),
        ),
      ),
    );
  }
}

class _PendingUserInputCard extends StatelessWidget {
  const _PendingUserInputCard({
    required this.pendingUserInput,
    required this.selectedOptionByQuestionId,
    required this.onSelectOption,
  });

  final PendingUserInputDto pendingUserInput;
  final Map<String, String> selectedOptionByQuestionId;
  final void Function(String questionId, String optionId) onSelectOption;

  @override
  Widget build(BuildContext context) {
    UserInputQuestionDto? currentQuestion;
    var currentQuestionIndex = -1;
    final answeredQuestions =
        <
          ({
            int index,
            UserInputQuestionDto question,
            UserInputOptionDto option,
          })
        >[];

    for (var index = 0; index < pendingUserInput.questions.length; index += 1) {
      final question = pendingUserInput.questions[index];
      final selectedOptionId = selectedOptionByQuestionId[question.questionId];
      if (selectedOptionId == null) {
        currentQuestion ??= question;
        currentQuestionIndex = currentQuestionIndex == -1
            ? index
            : currentQuestionIndex;
        continue;
      }

      final selectedOption = question.options.firstWhere(
        (option) => option.optionId == selectedOptionId,
        orElse: () => question.options.first,
      );
      answeredQuestions.add((
        index: index,
        question: question,
        option: selectedOption,
      ));
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      decoration: BoxDecoration(
        color: const Color(0xFF10211A),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppTheme.emerald.withValues(alpha: 0.28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: AppTheme.emerald.withValues(alpha: 0.14),
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: PhosphorIcon(
                    PhosphorIcons.listChecks(),
                    color: AppTheme.emerald,
                    size: 18,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      pendingUserInput.title,
                      style: const TextStyle(
                        color: AppTheme.textMain,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (pendingUserInput.detail case final detail?)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          detail,
                          style: const TextStyle(
                            color: AppTheme.textMuted,
                            fontSize: 12,
                            height: 1.3,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (answeredQuestions.isNotEmpty) ...[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: answeredQuestions
                  .map(
                    (entry) => Container(
                      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.05),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.08),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '${entry.index + 1}',
                            style: GoogleFonts.jetBrainsMono(
                              color: AppTheme.emerald,
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              entry.option.label,
                              style: const TextStyle(
                                color: AppTheme.textMain,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                  .toList(growable: false),
            ),
            const SizedBox(height: 12),
          ],
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            child: currentQuestion == null
                ? Container(
                    key: const ValueKey('pending-user-input-complete'),
                    padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.03),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.06),
                      ),
                    ),
                    child: const Text(
                      'All three answers are selected. Add "Something else" below if needed, or press plan to continue.',
                      style: TextStyle(
                        color: AppTheme.textMuted,
                        fontSize: 13,
                        height: 1.35,
                      ),
                    ),
                  )
                : _PendingUserInputQuestionCard(
                    key: ValueKey(currentQuestion.questionId),
                    index: currentQuestionIndex + 1,
                    totalQuestions: pendingUserInput.questions.length,
                    question: currentQuestion,
                    selectedOptionId:
                        selectedOptionByQuestionId[currentQuestion.questionId],
                    onSelectOption: (optionId) =>
                        onSelectOption(currentQuestion!.questionId, optionId),
                  ),
          ),
        ],
      ),
    );
  }
}

class _PendingUserInputQuestionCard extends StatelessWidget {
  const _PendingUserInputQuestionCard({
    super.key,
    required this.index,
    required this.totalQuestions,
    required this.question,
    required this.selectedOptionId,
    required this.onSelectOption,
  });

  final int index;
  final int totalQuestions;
  final UserInputQuestionDto question;
  final String? selectedOptionId;
  final ValueChanged<String> onSelectOption;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '$index',
                style: GoogleFonts.jetBrainsMono(
                  color: AppTheme.emerald,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'Question $index of $totalQuestions',
                style: const TextStyle(
                  color: AppTheme.textSubtle,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            question.prompt,
            style: const TextStyle(
              color: AppTheme.textMain,
              fontSize: 14,
              height: 1.35,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: question.options
                .map(
                  (option) => _PendingUserInputOptionChip(
                    option: option,
                    isSelected: selectedOptionId == option.optionId,
                    onTap: () => onSelectOption(option.optionId),
                  ),
                )
                .toList(growable: false),
          ),
        ],
      ),
    );
  }
}

class _PendingUserInputOptionChip extends StatelessWidget {
  const _PendingUserInputOptionChip({
    required this.option,
    required this.isSelected,
    required this.onTap,
  });

  final UserInputOptionDto option;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Ink(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          decoration: BoxDecoration(
            color: isSelected
                ? AppTheme.emerald.withValues(alpha: 0.18)
                : Colors.white.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: isSelected
                  ? AppTheme.emerald.withValues(alpha: 0.75)
                  : Colors.white.withValues(alpha: 0.08),
            ),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 96, maxWidth: 220),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        option.label,
                        style: TextStyle(
                          color: isSelected
                              ? AppTheme.textMain
                              : AppTheme.textMuted,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (option.isRecommended) ...[
                      const SizedBox(width: 6),
                      Text(
                        'REC',
                        style: GoogleFonts.jetBrainsMono(
                          color: AppTheme.emerald,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ],
                ),
                if (option.description.trim().isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    option.description,
                    style: const TextStyle(
                      color: AppTheme.textSubtle,
                      fontSize: 11,
                      height: 1.3,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ComposerPrimaryActionRail extends StatelessWidget {
  const _ComposerPrimaryActionRail({
    required this.composerController,
    required this.attachedImages,
    required this.composerMode,
    required this.hasPendingUserInput,
    required this.selectedPlanOptionByQuestionId,
    required this.controlsEnabled,
    required this.isTurnActive,
    required this.isComposerMutationInFlight,
    required this.isInterruptMutationInFlight,
    required this.isSpeechRecording,
    required this.isSpeechTranscribing,
    required this.onComposerModeChanged,
    required this.onSubmitComposer,
    required this.onSubmitPendingUserInput,
  });

  final TextEditingController composerController;
  final List<XFile> attachedImages;
  final TurnMode composerMode;
  final bool hasPendingUserInput;
  final Map<String, String> selectedPlanOptionByQuestionId;
  final bool controlsEnabled;
  final bool isTurnActive;
  final bool isComposerMutationInFlight;
  final bool isInterruptMutationInFlight;
  final bool isSpeechRecording;
  final bool isSpeechTranscribing;
  final ValueChanged<TurnMode> onComposerModeChanged;
  final Future<bool> Function(String rawInput) onSubmitComposer;
  final Future<bool> Function(String rawInput)? onSubmitPendingUserInput;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: const Key('turn-composer-primary-rail'),
      width: hasPendingUserInput ? 56 : 66,
      height: 56,
      child: ListenableBuilder(
        listenable: composerController,
        builder: (context, _) {
          final hasFreeText = composerController.text.trim().isNotEmpty;
          final hasInput = hasPendingUserInput
              ? hasFreeText || selectedPlanOptionByQuestionId.isNotEmpty
              : hasFreeText || attachedImages.isNotEmpty;
          final canRunPrimaryAction =
              hasInput &&
              controlsEnabled &&
              !isTurnActive &&
              !isComposerMutationInFlight &&
              !isInterruptMutationInFlight &&
              !isSpeechRecording &&
              !isSpeechTranscribing;
          final effectiveMode = hasPendingUserInput
              ? TurnMode.plan
              : composerMode;

          Future<void> handleSubmit() async {
            if (!canRunPrimaryAction) {
              return;
            }
            final success = hasPendingUserInput
                ? await onSubmitPendingUserInput?.call(
                        composerController.text,
                      ) ??
                      false
                : await onSubmitComposer(composerController.text);
            if (success) {
              composerController.clear();
            }
          }

          Widget buildPrimaryButton({
            required TurnMode mode,
            required bool isActive,
          }) {
            if (!isActive) {
              return Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: AppTheme.surfaceZinc800.withValues(alpha: 0.9),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.06),
                  ),
                ),
                child: Center(
                  child: PhosphorIcon(
                    mode == TurnMode.plan
                        ? PhosphorIcons.listChecks()
                        : PhosphorIcons.arrowUp(),
                    size: 20,
                    color: AppTheme.textSubtle,
                  ),
                ),
              );
            }
            return SizedBox(
              width: 56,
              height: 56,
              child: MagneticButton(
                key: Key(
                  mode == TurnMode.act
                      ? 'turn-composer-submit'
                      : 'turn-composer-plan-submit',
                ),
                isCircle: true,
                variant: MagneticButtonVariant.primary,
                onClick: isActive && canRunPrimaryAction
                    ? () async {
                        await handleSubmit();
                      }
                    : () {},
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  child: isComposerMutationInFlight && isActive
                      ? SizedBox.square(
                          key: ValueKey('composer-loading-${mode.wireValue}'),
                          dimension: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: isActive
                                ? AppTheme.background
                                : AppTheme.textMain,
                          ),
                        )
                      : PhosphorIcon(
                          mode == TurnMode.plan
                              ? PhosphorIcons.listChecks()
                              : PhosphorIcons.arrowUp(),
                          key: ValueKey('composer-primary-${mode.wireValue}'),
                          size: 22,
                        ),
                ),
              ),
            );
          }

          if (hasPendingUserInput) {
            return buildPrimaryButton(mode: TurnMode.plan, isActive: true);
          }

          final activeMode = effectiveMode;
          final secondaryMode = activeMode == TurnMode.act
              ? TurnMode.plan
              : TurnMode.act;

          return GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTapUp: (details) {
              if (details.localPosition.dx >= 56) {
                onComposerModeChanged(secondaryMode);
              }
            },
            onHorizontalDragEnd: (details) {
              final velocity = details.primaryVelocity ?? 0;
              if (velocity <= -180) {
                onComposerModeChanged(TurnMode.plan);
              } else if (velocity >= 180) {
                onComposerModeChanged(TurnMode.act);
              }
            },
            child: Stack(
              children: [
                Positioned(
                  left: 10,
                  child: Opacity(
                    opacity: 0.95,
                    child: buildPrimaryButton(
                      mode: secondaryMode,
                      isActive: false,
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  child: buildPrimaryButton(mode: activeMode, isActive: true),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _ComposerUtilityButton extends StatelessWidget {
  const _ComposerUtilityButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 52,
      height: 52,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppTheme.surfaceZinc800.withValues(alpha: 0.86),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
        ),
        child: IconButton(
          tooltip: tooltip,
          onPressed: onPressed,
          icon: PhosphorIcon(icon, size: 22, color: AppTheme.textMain),
        ),
      ),
    );
  }
}

class _ComposerModelSheet extends StatefulWidget {
  const _ComposerModelSheet({
    required this.modelOptions,
    required this.reasoningOptions,
    required this.initialModel,
    required this.initialReasoning,
    required this.selectedAccessMode,
    required this.session,
    required this.isAccessModeUpdating,
    required this.onModelChanged,
    required this.onReasoningChanged,
    required this.onAccessModeChanged,
  });

  final List<ModelOptionDto> modelOptions;
  final List<String> reasoningOptions;
  final String initialModel;
  final String initialReasoning;
  final AccessMode selectedAccessMode;
  final AppBridgeSession? session;
  final bool isAccessModeUpdating;
  final ValueChanged<String> onModelChanged;
  final ValueChanged<String> onReasoningChanged;
  final ValueChanged<AccessMode> onAccessModeChanged;

  @override
  State<_ComposerModelSheet> createState() => _ComposerModelSheetState();
}

class _ComposerModelSheetState extends State<_ComposerModelSheet> {
  late String _selectedModel;
  late String _selectedReasoning;
  late AccessMode _selectedAccessMode;

  @override
  void initState() {
    super.initState();
    _selectedModel = widget.initialModel;
    _selectedReasoning = widget.initialReasoning;
    _selectedAccessMode = widget.selectedAccessMode;
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.82,
        ),
        child: DecoratedBox(
          decoration: const BoxDecoration(
            color: AppTheme.surfaceZinc900,
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Settings for the chat',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              fontWeight: FontWeight.w600,
                              letterSpacing: -0.3,
                            ),
                      ),
                    ),
                    IconButton(
                      key: const Key('turn-composer-model-sheet-close'),
                      onPressed: () => Navigator.of(context).pop(),
                      icon: PhosphorIcon(
                        PhosphorIcons.x(),
                        size: 20,
                        color: AppTheme.textMuted,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                const Text(
                  'Pick the model and intelligence level for the next turn.',
                  style: TextStyle(color: AppTheme.textMuted, fontSize: 13),
                ),
                const SizedBox(height: 18),
                _ComposerSheetSection(
                  title: 'Models',
                  children: widget.modelOptions
                      .map(
                        (model) => _ComposerSheetOption(
                          key: Key('turn-composer-model-option-${model.id}'),
                          label: model.displayName,
                          selected: _selectedModel == model.id,
                          onTap: () {
                            setState(() {
                              _selectedModel = model.id;
                            });
                            widget.onModelChanged(model.id);
                          },
                        ),
                      )
                      .toList(growable: false),
                ),
                const SizedBox(height: 18),
                _ComposerSheetSection(
                  title: 'Intelligence',
                  children: widget.reasoningOptions
                      .map(
                        (reasoning) => _ComposerSheetOption(
                          key: Key('turn-composer-reasoning-option-$reasoning'),
                          label: reasoning,
                          selected: _selectedReasoning == reasoning,
                          onTap: () {
                            setState(() {
                              _selectedReasoning = reasoning;
                            });
                            widget.onReasoningChanged(reasoning);
                          },
                        ),
                      )
                      .toList(growable: false),
                ),
                const SizedBox(height: 18),
                _ComposerSheetSection(
                  title: 'Approval',
                  subtitle: widget.session == null
                      ? 'Connect to a bridge session to change access mode.'
                      : widget.session!.isLocalLoopback
                      ? 'This control changes the access mode for the bridge running on the current machine.'
                      : null,
                  children: AccessMode.values
                      .map(
                        (mode) => _ComposerSheetOption(
                          key: Key('turn-composer-access-mode-option-$mode'),
                          label: _accessModeChipLabel(mode),
                          selected: _selectedAccessMode == mode,
                          leading:
                              widget.session?.canMutateAccessMode != true &&
                                  _selectedAccessMode != mode
                              ? PhosphorIcons.lock()
                              : _composerAccessModeVisual(mode).icon,
                          leadingColor: _composerAccessModeVisual(mode).color,
                          trailing:
                              widget.isAccessModeUpdating &&
                                  _selectedAccessMode == mode
                              ? const SizedBox.square(
                                  dimension: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: AppTheme.textMain,
                                  ),
                                )
                              : null,
                          onTap: widget.session?.canMutateAccessMode != true
                              ? () {}
                              : () {
                                  setState(() {
                                    _selectedAccessMode = mode;
                                  });
                                  widget.onAccessModeChanged(mode);
                                },
                        ),
                      )
                      .toList(growable: false),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ComposerSheetSection extends StatelessWidget {
  const _ComposerSheetSection({
    required this.title,
    required this.children,
    this.subtitle,
  });

  final String title;
  final List<Widget> children;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: GoogleFonts.jetBrainsMono(
                color: AppTheme.textMuted,
                fontSize: 11,
                letterSpacing: 0.7,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 10),
            if (subtitle != null) ...[
              Text(
                subtitle!,
                style: const TextStyle(
                  color: AppTheme.textSubtle,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 10),
            ],
            ...children,
          ],
        ),
      ),
    );
  }
}

class _ComposerSheetOption extends StatelessWidget {
  const _ComposerSheetOption({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.leading,
    this.leadingColor,
    this.trailing,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? leading;
  final Color? leadingColor;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Ink(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            decoration: BoxDecoration(
              color: selected
                  ? Colors.white.withValues(alpha: 0.06)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Row(
              children: [
                if (leading != null) ...[
                  PhosphorIcon(
                    leading!,
                    size: 18,
                    color: leadingColor ?? AppTheme.textMuted,
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      color: selected ? AppTheme.textMain : AppTheme.textMuted,
                      fontSize: 15,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ),
                if (trailing != null)
                  trailing!
                else if (selected)
                  PhosphorIcon(
                    PhosphorIcons.check(),
                    size: 18,
                    color: AppTheme.textMain,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

_ComposerAccessModeVisual _composerAccessModeVisual(AccessMode accessMode) {
  switch (accessMode) {
    case AccessMode.readOnly:
      return _ComposerAccessModeVisual(
        icon: PhosphorIcons.lock(),
        color: AppTheme.textSubtle,
      );
    case AccessMode.controlWithApprovals:
      return _ComposerAccessModeVisual(
        icon: PhosphorIcons.shieldCheck(),
        color: AppTheme.amber,
      );
    case AccessMode.fullControl:
      return _ComposerAccessModeVisual(
        icon: PhosphorIcons.lightning(),
        color: AppTheme.emerald,
      );
  }
}

class _ComposerAccessModeVisual {
  const _ComposerAccessModeVisual({required this.icon, required this.color});

  final IconData icon;
  final Color color;
}

class _ComposerImagePreview extends StatelessWidget {
  const _ComposerImagePreview({required this.image, required this.onRemove});

  final XFile image;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: SizedBox(
            width: 74,
            height: 74,
            child: FutureBuilder<Uint8List>(
              future: image.readAsBytes(),
              builder: (context, snapshot) {
                final bytes = snapshot.data;
                if (bytes != null) {
                  return Image.memory(
                    bytes,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => _brokenComposerImagePreview(),
                  );
                }
                if (snapshot.hasError) {
                  return _brokenComposerImagePreview();
                }
                return Container(
                  color: AppTheme.surfaceZinc800,
                  alignment: Alignment.center,
                  child: const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                );
              },
            ),
          ),
        ),
        Positioned(
          top: 4,
          right: 4,
          child: GestureDetector(
            onTap: onRemove,
            child: Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.72),
                shape: BoxShape.circle,
              ),
              child: PhosphorIcon(
                PhosphorIcons.x(),
                size: 14,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

Widget _brokenComposerImagePreview() {
  return Container(
    color: AppTheme.surfaceZinc800,
    alignment: Alignment.center,
    child: PhosphorIcon(
      PhosphorIcons.imageBroken(),
      color: AppTheme.textSubtle,
    ),
  );
}

String _accessModeChipLabel(AccessMode value) {
  switch (value) {
    case AccessMode.readOnly:
      return 'Read-only';
    case AccessMode.controlWithApprovals:
      return 'Approvals';
    case AccessMode.fullControl:
      return 'Full access';
  }
}

class _RecordingStatusInline extends StatelessWidget {
  const _RecordingStatusInline({
    super.key,
    required this.durationSeconds,
    required this.amplitudeStream,
  });

  final int durationSeconds;
  final Stream<SpeechCaptureAmplitude>? amplitudeStream;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      child: Row(
        children: [
          Text(
            _formatRecordingDuration(durationSeconds),
            style: const TextStyle(
              color: AppTheme.textMain,
              fontSize: 15,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: _RecordingWaveform(amplitudeStream: amplitudeStream)),
        ],
      ),
    );
  }
}

String _formatRecordingDuration(int seconds) {
  final minutes = seconds ~/ 60;
  final remainingSeconds = seconds % 60;
  return '${minutes.toString().padLeft(2, '0')}:${remainingSeconds.toString().padLeft(2, '0')}';
}

class _RecordingWaveform extends StatefulWidget {
  const _RecordingWaveform({required this.amplitudeStream});

  final Stream<SpeechCaptureAmplitude>? amplitudeStream;

  @override
  State<_RecordingWaveform> createState() => _RecordingWaveformState();
}

class _RecordingWaveformState extends State<_RecordingWaveform> {
  static const int _barCount = 30;

  final List<double> _bars = List<double>.filled(_barCount, 0.18);
  StreamSubscription<SpeechCaptureAmplitude>? _amplitudeSubscription;
  int _tick = 0;

  @override
  void initState() {
    super.initState();
    _subscribeToAmplitude();
  }

  @override
  void didUpdateWidget(covariant _RecordingWaveform oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.amplitudeStream != widget.amplitudeStream) {
      _amplitudeSubscription?.cancel();
      _subscribeToAmplitude();
    }
  }

  void _subscribeToAmplitude() {
    _amplitudeSubscription = widget.amplitudeStream?.listen((amp) {
      if (!mounted) return;
      setState(() {
        for (int i = _bars.length - 1; i > 0; i--) {
          _bars[i] = _bars[i - 1];
        }
        final normalized = (amp.current + 45).clamp(0.0, 45.0) / 45.0;
        final pulse = 0.14 + ((math.sin(_tick * 0.65) + 1) * 0.04);
        _bars[0] = (0.16 + (normalized * 0.84)).clamp(pulse, 1.0);
        _tick += 1;
      });
    });
  }

  @override
  void dispose() {
    _amplitudeSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 30,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: List<Widget>.generate(_bars.length, (index) {
          final value = _bars[_bars.length - index - 1];
          final barHeight = 5 + (value * 21);
          final colorAlpha = 0.5 + (value * 0.5);

          return Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1.25),
              child: Align(
                alignment: Alignment.bottomCenter,
                child: TweenAnimationBuilder<double>(
                  tween: Tween<double>(begin: 5, end: barHeight),
                  duration: const Duration(milliseconds: 120),
                  curve: Curves.easeOutCubic,
                  builder: (context, height, child) {
                    return DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: colorAlpha),
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: SizedBox(width: 3, height: height),
                    );
                  },
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}
