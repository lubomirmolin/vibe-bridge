part of 'thread_detail_page.dart';

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
    final totalQuestions = pendingUserInput.questions.length;
    final completedCopy = totalQuestions == 1
        ? 'Selection saved. Add optional context below, or press submit.'
        : 'All $totalQuestions questions are answered. Add optional context below, or press submit.';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E24),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
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
                  color: const Color(0xFFA855F7).withValues(alpha: 0.2),
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: PhosphorIcon(
                    PhosphorIcons.lightbulb(PhosphorIconsStyle.fill),
                    color: const Color(0xFFA855F7),
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
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
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
                    child: Text(
                      completedCopy,
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
                    pendingUserInputTitle: pendingUserInput.title,
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
    required this.pendingUserInputTitle,
    required this.selectedOptionId,
    required this.onSelectOption,
  });

  final int index;
  final int totalQuestions;
  final UserInputQuestionDto question;
  final String pendingUserInputTitle;
  final String? selectedOptionId;
  final ValueChanged<String> onSelectOption;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (totalQuestions > 1) ...[
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
          const SizedBox(height: 12),
        ],
        if (question.prompt.isNotEmpty &&
            question.prompt != pendingUserInputTitle) ...[
          Text(
            question.prompt,
            style: const TextStyle(
              color: AppTheme.textMain,
              fontSize: 14,
              height: 1.35,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 12),
        ],
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: question.options
              .map(
                (option) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _PendingUserInputOptionChip(
                    option: option,
                    isSelected: selectedOptionId == option.optionId,
                    onTap: () => onSelectOption(option.optionId),
                  ),
                ),
              )
              .toList(growable: false),
        ),
      ],
    );
  }
}

class _PendingProviderApprovalCard extends StatelessWidget {
  const _PendingProviderApprovalCard({
    required this.pendingUserInput,
    required this.question,
    required this.selectedOptionId,
    required this.isSubmitting,
    required this.onSelectOption,
  });

  final PendingUserInputDto pendingUserInput;
  final UserInputQuestionDto question;
  final String? selectedOptionId;
  final bool isSubmitting;
  final void Function(String questionId, String optionId) onSelectOption;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('turn-composer-approval-card'),
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF171D22), Color(0xFF1D242A)],
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: const Color(0xFF6B7280).withValues(alpha: 0.3),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.16),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: const Color(0xFFF59E0B).withValues(alpha: 0.16),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: const Color(0xFFF59E0B).withValues(alpha: 0.34),
                  ),
                ),
                child: Center(
                  child: PhosphorIcon(
                    PhosphorIcons.shieldWarning(PhosphorIconsStyle.fill),
                    color: const Color(0xFFF59E0B),
                    size: 20,
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
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Choose the permission response directly here. The turn resumes immediately after you select one.',
                      style: TextStyle(
                        color: AppTheme.textMuted,
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (pendingUserInput.detail case final detail?)
            Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F1419).withValues(alpha: 0.74),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.06),
                  ),
                ),
                child: Text(
                  detail,
                  style: GoogleFonts.jetBrainsMono(
                    color: const Color(0xFFD6DEE7),
                    fontSize: 11,
                    height: 1.45,
                  ),
                ),
              ),
            ),
          const SizedBox(height: 14),
          Column(
            children: question.options
                .map(
                  (option) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _PendingProviderApprovalActionButton(
                      option: option,
                      isSelected: selectedOptionId == option.optionId,
                      isSubmitting: isSubmitting,
                      onTap: isSubmitting
                          ? null
                          : () => onSelectOption(
                              question.questionId,
                              option.optionId,
                            ),
                    ),
                  ),
                )
                .toList(growable: false),
          ),
        ],
      ),
    );
  }
}

class _PendingProviderApprovalActionButton extends StatelessWidget {
  const _PendingProviderApprovalActionButton({
    required this.option,
    required this.isSelected,
    required this.isSubmitting,
    required this.onTap,
  });

  final UserInputOptionDto option;
  final bool isSelected;
  final bool isSubmitting;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tone = _ProviderApprovalTone.fromOptionId(option.optionId);
    final backgroundColor = isSelected
        ? tone.surface.withValues(alpha: 0.94)
        : tone.surface.withValues(alpha: 0.42);
    final borderColor = isSelected
        ? tone.border.withValues(alpha: 0.96)
        : tone.border.withValues(alpha: 0.42);
    final labelColor = isSelected ? tone.foreground : AppTheme.textMain;

    return Material(
      color: Colors.transparent,
      child: TextButton(
        key: Key('turn-composer-approval-option-${option.optionId}'),
        onPressed: onTap,
        style: TextButton.styleFrom(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          backgroundColor: backgroundColor,
          foregroundColor: labelColor,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: BorderSide(color: borderColor),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              margin: const EdgeInsets.only(top: 1),
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: tone.foreground.withValues(
                  alpha: isSelected ? 0.18 : 0.1,
                ),
                shape: BoxShape.circle,
              ),
              child: Center(
                child: isSubmitting && isSelected
                    ? SizedBox.square(
                        dimension: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: tone.foreground,
                        ),
                      )
                    : PhosphorIcon(tone.icon, color: tone.foreground, size: 18),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          option.label,
                          style: TextStyle(
                            color: labelColor,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (option.isRecommended)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            'RECOMMENDED',
                            style: GoogleFonts.jetBrainsMono(
                              color: const Color(0xFFFCD34D),
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                    ],
                  ),
                  if (option.description.trim().isNotEmpty) ...[
                    const SizedBox(height: 5),
                    Text(
                      option.description,
                      style: TextStyle(
                        color: AppTheme.textMuted,
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProviderApprovalTone {
  const _ProviderApprovalTone({
    required this.surface,
    required this.border,
    required this.foreground,
    required this.icon,
  });

  final Color surface;
  final Color border;
  final Color foreground;
  final IconData icon;

  factory _ProviderApprovalTone.fromOptionId(String optionId) {
    switch (optionId) {
      case 'allow_once':
        return _ProviderApprovalTone(
          surface: const Color(0xFF0F2B2B),
          border: const Color(0xFF2DD4BF),
          foreground: const Color(0xFF5EEAD4),
          icon: PhosphorIcons.check(),
        );
      case 'allow_for_session':
        return _ProviderApprovalTone(
          surface: const Color(0xFF13263B),
          border: const Color(0xFF60A5FA),
          foreground: const Color(0xFF93C5FD),
          icon: PhosphorIcons.clockClockwise(),
        );
      case 'deny':
        return _ProviderApprovalTone(
          surface: const Color(0xFF33151B),
          border: const Color(0xFFFB7185),
          foreground: const Color(0xFFFDA4AF),
          icon: PhosphorIcons.x(),
        );
      default:
        return _ProviderApprovalTone(
          surface: const Color(0xFF20262D),
          border: const Color(0xFF94A3B8),
          foreground: const Color(0xFFE2E8F0),
          icon: PhosphorIcons.dot(),
        );
    }
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
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Ink(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          decoration: BoxDecoration(
            color: isSelected
                ? Colors.white.withValues(alpha: 0.12)
                : Colors.white.withValues(alpha: 0.03),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isSelected
                  ? Colors.white.withValues(alpha: 0.2)
                  : Colors.white.withValues(alpha: 0.08),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      option.label,
                      style: TextStyle(
                        color: isSelected
                            ? AppTheme.textMain
                            : const Color(0xFFD4D4D8),
                        fontSize: 14,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ),
                  if (option.isRecommended) ...[
                    const SizedBox(width: 8),
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
                    fontSize: 12,
                    height: 1.3,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
