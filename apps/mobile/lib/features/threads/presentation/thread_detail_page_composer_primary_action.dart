part of 'thread_detail_page.dart';

class _ComposerPrimaryActionRail extends StatefulWidget {
  const _ComposerPrimaryActionRail({
    required this.composerController,
    required this.attachedImages,
    required this.composerMode,
    required this.supportsPlanMode,
    required this.hasPendingUserInput,
    required this.selectedPlanOptionByQuestionId,
    required this.controlsEnabled,
    required this.isTurnActive,
    required this.isComposerMutationInFlight,
    required this.isInterruptMutationInFlight,
    required this.isSpeechRecording,
    required this.isSpeechTranscribing,
    required this.onComposerModeChanged,
    required this.onSubmitCurrentInput,
  });

  final TextEditingController composerController;
  final List<XFile> attachedImages;
  final TurnMode composerMode;
  final bool supportsPlanMode;
  final bool hasPendingUserInput;
  final Map<String, String> selectedPlanOptionByQuestionId;
  final bool controlsEnabled;
  final bool isTurnActive;
  final bool isComposerMutationInFlight;
  final bool isInterruptMutationInFlight;
  final bool isSpeechRecording;
  final bool isSpeechTranscribing;
  final ValueChanged<TurnMode> onComposerModeChanged;
  final Future<void> Function() onSubmitCurrentInput;

  @override
  State<_ComposerPrimaryActionRail> createState() =>
      _ComposerPrimaryActionRailState();
}

class _ComposerPrimaryActionRailState extends State<_ComposerPrimaryActionRail>
    with SingleTickerProviderStateMixin {
  static const double _maxPositiveDrag = 24.0;
  static const double _switchModeDragThreshold = -20.0;
  static const double _switchModeVelocityThreshold = -180.0;

  late final AnimationController _snapController;
  late Animation<double> _snapAnimation;
  double _dragDx = 0.0;
  bool _hasTriggeredLockHaptic = false;

  bool get _canSwitchModes =>
      !widget.hasPendingUserInput && widget.supportsPlanMode;

  TurnMode get _secondaryMode =>
      widget.composerMode == TurnMode.act ? TurnMode.plan : TurnMode.act;

  @override
  void initState() {
    super.initState();
    _snapController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _snapAnimation = const AlwaysStoppedAnimation(0.0);
    _snapController.addListener(() {
      setState(() {
        _dragDx = _snapAnimation.value;
      });
    });
  }

  @override
  void dispose() {
    _snapController.dispose();
    super.dispose();
  }

  void _onDragUpdate(DragUpdateDetails details) {
    if (!_canSwitchModes) {
      return;
    }

    _snapController.stop();
    setState(() {
      _dragDx = (_dragDx + details.delta.dx).clamp(
        -_composerModePeekOffset,
        _maxPositiveDrag,
      );
      _updateLockHaptic();
    });
  }

  void _onDragEnd(DragEndDetails details) {
    if (!_canSwitchModes) {
      return;
    }

    final velocity = details.primaryVelocity ?? 0.0;
    if (_shouldSwitchMode(velocity)) {
      unawaited(_switchModeAfterSnap());
      return;
    }

    unawaited(_resetRailPosition());
  }

  bool _shouldSwitchMode(double velocity) {
    return _dragDx <= _switchModeDragThreshold ||
        velocity < _switchModeVelocityThreshold;
  }

  void _updateLockHaptic() {
    if (_dragDx > -_composerModePeekOffset) {
      _hasTriggeredLockHaptic = false;
      return;
    }
    if (_hasTriggeredLockHaptic) {
      return;
    }

    HapticFeedback.selectionClick();
    _hasTriggeredLockHaptic = true;
  }

  Future<void> _switchModeAfterSnap() async {
    await _animateDragTo(-_composerModePeekOffset);
    if (!mounted) {
      return;
    }

    widget.onComposerModeChanged(_secondaryMode);
    setState(() {
      _dragDx = 0.0;
      _hasTriggeredLockHaptic = false;
    });
  }

  Future<void> _resetRailPosition() async {
    await _animateDragTo(0.0);
    if (!mounted) {
      return;
    }

    setState(() {
      _hasTriggeredLockHaptic = false;
    });
  }

  Future<void> _animateDragTo(double endOffset) async {
    _snapAnimation = Tween<double>(begin: _dragDx, end: endOffset).animate(
      CurvedAnimation(parent: _snapController, curve: Curves.easeOutCubic),
    );
    await _snapController.forward(from: 0.0);
  }

  Future<void> _handleSubmit(_ComposerPrimaryActionState actionState) async {
    if (!actionState.canRunPrimaryAction) {
      return;
    }
    await widget.onSubmitCurrentInput();
  }

  void _handleRailTapUp(
    TapUpDetails details,
    _ComposerPrimaryActionState actionState,
  ) {
    if (details.localPosition.dx >= _composerPrimaryButtonSize) {
      widget.onComposerModeChanged(actionState.secondaryMode);
      return;
    }
    unawaited(_handleSubmit(actionState));
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: const Key('turn-composer-primary-rail'),
      width: widget.hasPendingUserInput
          ? _composerPrimaryButtonSize
          : _composerPrimaryRailWidth,
      height: _composerPrimaryButtonSize,
      child: ValueListenableBuilder<TextEditingValue>(
        valueListenable: widget.composerController,
        builder: (context, value, _) {
          final actionState = _ComposerPrimaryActionState.fromWidget(
            widget,
            hasFreeText: value.text.trim().isNotEmpty,
          );

          if (actionState.showSinglePlanButton) {
            return SizedBox(
              key: const Key('turn-composer-plan-submit'),
              child: _ComposerPrimaryButton(
                mode: TurnMode.plan,
                dragProgress: 1.0,
                isLoading: widget.isComposerMutationInFlight,
                canPress: actionState.canRunPrimaryAction,
                usePlanAccent: true,
                onPressed: () => _handleSubmit(actionState),
              ),
            );
          }

          if (actionState.showSingleActButton) {
            return SizedBox(
              key: const Key('turn-composer-submit'),
              child: _ComposerPrimaryButton(
                mode: TurnMode.act,
                dragProgress: 1.0,
                isLoading: widget.isComposerMutationInFlight,
                canPress: actionState.canRunPrimaryAction,
                onPressed: () => _handleSubmit(actionState),
              ),
            );
          }

          return AnimatedBuilder(
            animation: _snapController,
            builder: (context, _) {
              final layout = _ComposerPrimaryRailLayout.fromDrag(_dragDx);

              return GestureDetector(
                key: actionState.primaryActionKey,
                behavior: HitTestBehavior.translucent,
                onTapUp: (details) => _handleRailTapUp(details, actionState),
                onHorizontalDragUpdate: _onDragUpdate,
                onHorizontalDragEnd: _onDragEnd,
                child: SizedBox(
                  width: _composerPrimaryRailWidth,
                  height: _composerPrimaryButtonSize,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      _ComposerPrimaryButtonSlot(
                        opacity: layout.secondaryProgress,
                        offset: layout.secondaryOffset,
                        scale: layout.secondaryScale,
                        child: _ComposerPrimaryButton(
                          mode: actionState.secondaryMode,
                          dragProgress: layout.secondaryProgress,
                          isLoading: false,
                          canPress: false,
                          onPressed: () async {},
                        ),
                      ),
                      _ComposerPrimaryButtonSlot(
                        opacity: layout.activeProgress,
                        offset: layout.activeOffset,
                        scale: layout.activeScale,
                        child: _ComposerPrimaryButton(
                          mode: actionState.activeMode,
                          dragProgress: layout.activeProgress,
                          isLoading: widget.isComposerMutationInFlight,
                          canPress:
                              actionState.canRunPrimaryAction &&
                              layout.activeProgress > 0.5,
                          onPressed: () => _handleSubmit(actionState),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _ComposerPrimaryActionState {
  const _ComposerPrimaryActionState({
    required this.activeMode,
    required this.secondaryMode,
    required this.canRunPrimaryAction,
    required this.showSinglePlanButton,
    required this.showSingleActButton,
  });

  final TurnMode activeMode;
  final TurnMode secondaryMode;
  final bool canRunPrimaryAction;
  final bool showSinglePlanButton;
  final bool showSingleActButton;

  Key get primaryActionKey => Key(
    activeMode == TurnMode.act
        ? 'turn-composer-submit'
        : 'turn-composer-plan-submit',
  );

  factory _ComposerPrimaryActionState.fromWidget(
    _ComposerPrimaryActionRail widget, {
    required bool hasFreeText,
  }) {
    final hasInput = widget.hasPendingUserInput
        ? hasFreeText || widget.selectedPlanOptionByQuestionId.isNotEmpty
        : hasFreeText || widget.attachedImages.isNotEmpty;
    final canRunPrimaryAction =
        hasInput &&
        widget.controlsEnabled &&
        !widget.isComposerMutationInFlight &&
        !widget.isInterruptMutationInFlight &&
        !widget.isSpeechRecording &&
        !widget.isSpeechTranscribing;
    final activeMode = widget.hasPendingUserInput
        ? TurnMode.plan
        : widget.composerMode;

    return _ComposerPrimaryActionState(
      activeMode: activeMode,
      secondaryMode: activeMode == TurnMode.act ? TurnMode.plan : TurnMode.act,
      canRunPrimaryAction: canRunPrimaryAction,
      showSinglePlanButton: widget.hasPendingUserInput,
      showSingleActButton:
          !widget.hasPendingUserInput && !widget.supportsPlanMode,
    );
  }
}

class _ComposerPrimaryRailLayout {
  const _ComposerPrimaryRailLayout({
    required this.activeOffset,
    required this.secondaryOffset,
    required this.activeProgress,
    required this.secondaryProgress,
    required this.activeScale,
    required this.secondaryScale,
  });

  final double activeOffset;
  final double secondaryOffset;
  final double activeProgress;
  final double secondaryProgress;
  final double activeScale;
  final double secondaryScale;

  factory _ComposerPrimaryRailLayout.fromDrag(double dragDx) {
    final activeOffset = dragDx;
    final secondaryOffset = _composerModePeekOffset + dragDx;

    return _ComposerPrimaryRailLayout(
      activeOffset: activeOffset,
      secondaryOffset: secondaryOffset,
      activeProgress: _progressForOffset(activeOffset),
      secondaryProgress: _progressForOffset(secondaryOffset),
      activeScale: _scaleForOffset(activeOffset),
      secondaryScale: _scaleForOffset(secondaryOffset),
    );
  }

  static double _progressForOffset(double offset) {
    return math
        .max(0.0, 1.0 - (offset.abs() / _composerModePeekOffset))
        .toDouble();
  }

  static double _scaleForOffset(double offset) {
    return math.max(0.6, 1.0 - (offset.abs() / 150)).toDouble();
  }
}

class _ComposerPrimaryButtonSlot extends StatelessWidget {
  const _ComposerPrimaryButtonSlot({
    required this.opacity,
    required this.offset,
    required this.scale,
    required this.child,
  });

  final double opacity;
  final double offset;
  final double scale;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 0,
      child: Opacity(
        opacity: opacity,
        child: Transform(
          transform: Matrix4.identity()
            ..translateByDouble(offset, 0.0, 0.0, 1.0)
            ..scaleByDouble(scale, scale, 1.0, 1.0),
          alignment: Alignment.center,
          child: child,
        ),
      ),
    );
  }
}

class _ComposerPrimaryButton extends StatelessWidget {
  const _ComposerPrimaryButton({
    required this.mode,
    required this.dragProgress,
    required this.isLoading,
    required this.canPress,
    required this.onPressed,
    this.usePlanAccent = false,
  });

  final TurnMode mode;
  final double dragProgress;
  final bool isLoading;
  final bool canPress;
  final bool usePlanAccent;
  final Future<void> Function() onPressed;

  @override
  Widget build(BuildContext context) {
    final appearance = _ComposerPrimaryButtonAppearance.fromProgress(
      dragProgress,
      usePlanAccent: usePlanAccent,
    );

    return SizedBox(
      width: _composerPrimaryButtonSize,
      height: _composerPrimaryButtonSize,
      child: Container(
        decoration: BoxDecoration(
          color: appearance.backgroundColor,
          shape: BoxShape.circle,
          border: Border.all(color: appearance.borderColor),
          boxShadow: appearance.shadowColor == Colors.transparent
              ? null
              : [
                  BoxShadow(
                    color: appearance.shadowColor,
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
        ),
        child: MagneticButton(
          isCircle: true,
          variant: MagneticButtonVariant.primary,
          backgroundColorOverride: Colors.transparent,
          foregroundColorOverride: appearance.iconColor,
          onClick: canPress ? onPressed : () {},
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: isLoading
                ? SizedBox.square(
                    key: ValueKey('composer-loading-${mode.wireValue}'),
                    dimension: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: appearance.activeIconColor,
                    ),
                  )
                : PhosphorIcon(
                    _iconForMode(mode, usePlanAccent: usePlanAccent),
                    key: ValueKey('composer-primary-${mode.wireValue}'),
                    size: usePlanAccent ? 24 : 22,
                    color: appearance.iconColor,
                  ),
          ),
        ),
      ),
    );
  }

  IconData _iconForMode(TurnMode mode, {required bool usePlanAccent}) {
    if (mode == TurnMode.act) {
      return PhosphorIcons.arrowUp();
    }
    if (usePlanAccent) {
      return PhosphorIcons.lightbulb(PhosphorIconsStyle.fill);
    }
    return PhosphorIcons.listChecks();
  }
}

class _ComposerPrimaryButtonAppearance {
  const _ComposerPrimaryButtonAppearance({
    required this.backgroundColor,
    required this.iconColor,
    required this.borderColor,
    required this.shadowColor,
    required this.activeIconColor,
  });

  final Color backgroundColor;
  final Color iconColor;
  final Color borderColor;
  final Color shadowColor;
  final Color activeIconColor;

  factory _ComposerPrimaryButtonAppearance.fromProgress(
    double progress, {
    required bool usePlanAccent,
  }) {
    final activeBackgroundColor = usePlanAccent
        ? const Color(0xFFA855F7)
        : Colors.white;
    final inactiveBackgroundColor = AppTheme.surfaceZinc800.withValues(
      alpha: 0.9,
    );
    final activeIconColor = usePlanAccent ? Colors.white : AppTheme.background;
    final inactiveIconColor = AppTheme.textSubtle;
    final activeBorderColor = Colors.transparent;
    final inactiveBorderColor = Colors.white.withValues(alpha: 0.06);
    final activeShadowColor = usePlanAccent
        ? const Color(0xFFA855F7).withValues(alpha: 0.4)
        : Colors.transparent;

    return _ComposerPrimaryButtonAppearance(
      backgroundColor: Color.lerp(
        inactiveBackgroundColor,
        activeBackgroundColor,
        progress,
      )!,
      iconColor: Color.lerp(inactiveIconColor, activeIconColor, progress)!,
      borderColor: Color.lerp(
        inactiveBorderColor,
        activeBorderColor,
        progress,
      )!,
      shadowColor: Color.lerp(Colors.transparent, activeShadowColor, progress)!,
      activeIconColor: activeIconColor,
    );
  }
}
