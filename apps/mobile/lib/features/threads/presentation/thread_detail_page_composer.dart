part of 'thread_detail_page.dart';

class _PinnedTurnComposer extends StatelessWidget {
  const _PinnedTurnComposer({
    required this.composerController,
    required this.composerFocusNode,
    required this.isTurnActive,
    required this.controlsEnabled,
    required this.isComposerMutationInFlight,
    required this.isInterruptMutationInFlight,
    required this.isComposerFocused,
    required this.attachedImages,
    required this.modelOptions,
    required this.reasoningOptions,
    required this.selectedModel,
    required this.selectedReasoning,
    required this.accessMode,
    required this.trustedBridge,
    required this.isAccessModeUpdating,
    required this.accessModeErrorMessage,
    required this.onPickImages,
    required this.onRemoveImage,
    required this.onModelChanged,
    required this.onReasoningChanged,
    required this.onAccessModeChanged,
    required this.onSubmitComposer,
    required this.onInterruptActiveTurn,
  });

  final TextEditingController composerController;
  final FocusNode composerFocusNode;
  final bool isTurnActive;
  final bool controlsEnabled;
  final bool isComposerMutationInFlight;
  final bool isInterruptMutationInFlight;
  final bool isComposerFocused;
  final List<XFile> attachedImages;
  final List<ModelOptionDto> modelOptions;
  final List<String> reasoningOptions;
  final String selectedModel;
  final String selectedReasoning;
  final AccessMode accessMode;
  final TrustedBridgeIdentity? trustedBridge;
  final bool isAccessModeUpdating;
  final String? accessModeErrorMessage;
  final Future<void> Function() onPickImages;
  final ValueChanged<XFile> onRemoveImage;
  final ValueChanged<String> onModelChanged;
  final ValueChanged<String> onReasoningChanged;
  final ValueChanged<AccessMode> onAccessModeChanged;
  final Future<bool> Function(String rawInput) onSubmitComposer;
  final Future<bool> Function() onInterruptActiveTurn;

  @override
  Widget build(BuildContext context) {
    final canEditPinnedControls =
        !isComposerMutationInFlight && !isInterruptMutationInFlight;
    final composerEnabled =
        controlsEnabled &&
        !isComposerMutationInFlight &&
        !isInterruptMutationInFlight;

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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
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
          Row(
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
                child: isComposerFocused
                    ? const SizedBox(
                        key: ValueKey('composer-leading-actions-hidden'),
                      )
                    : Padding(
                        key: const ValueKey('composer-leading-actions-visible'),
                        padding: const EdgeInsets.only(right: 8),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _ComposerUtilityButton(
                              key: const Key('turn-composer-attach-button'),
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
                              key: const Key('turn-composer-model-button'),
                              icon: PhosphorIcons.slidersHorizontal(),
                              tooltip: 'Composer settings',
                              onPressed: canEditPinnedControls
                                  ? () {
                                      composerFocusNode.unfocus();
                                      showModalBottomSheet<void>(
                                        context: context,
                                        backgroundColor: Colors.transparent,
                                        isScrollControlled: true,
                                        builder: (context) =>
                                            _ComposerModelSheet(
                                              modelOptions: modelOptions,
                                              reasoningOptions:
                                                  reasoningOptions,
                                              initialModel: selectedModel,
                                              initialReasoning:
                                                  selectedReasoning,
                                              selectedAccessMode: accessMode,
                                              trustedBridge: trustedBridge,
                                              isAccessModeUpdating:
                                                  isAccessModeUpdating,
                                              onModelChanged: onModelChanged,
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
                  child: TextField(
                    key: const Key('turn-composer-input'),
                    controller: composerController,
                    focusNode: composerFocusNode,
                    enabled: composerEnabled,
                    minLines: 1,
                    maxLines: 4,
                    keyboardType: TextInputType.multiline,
                    textInputAction: TextInputAction.newline,
                    onTapOutside: (_) => composerFocusNode.unfocus(),
                    style: const TextStyle(
                      color: AppTheme.textMain,
                      fontSize: 15,
                    ),
                    decoration: InputDecoration(
                      hintText: isTurnActive
                          ? 'Turn in progress. Interrupt to send a new prompt.'
                          : 'Message Codex...',
                      hintStyle: const TextStyle(color: AppTheme.textSubtle),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 16,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 56,
                height: 56,
                child: ListenableBuilder(
                  listenable: composerController,
                  builder: (context, _) {
                    final hasInput =
                        composerController.text.trim().isNotEmpty ||
                        attachedImages.isNotEmpty;
                    final showStopAction =
                        isTurnActive || isInterruptMutationInFlight;
                    final canRunPrimaryAction = showStopAction
                        ? (controlsEnabled &&
                              isTurnActive &&
                              !isInterruptMutationInFlight &&
                              !isComposerMutationInFlight)
                        : (controlsEnabled &&
                              !isComposerMutationInFlight &&
                              !isInterruptMutationInFlight);

                    return MagneticButton(
                      key: Key(
                        showStopAction
                            ? 'turn-interrupt-button'
                            : 'turn-composer-submit',
                      ),
                      isCircle: true,
                      variant: showStopAction
                          ? MagneticButtonVariant.secondary
                          : MagneticButtonVariant.primary,
                      onClick: canRunPrimaryAction
                          ? () async {
                              if (showStopAction) {
                                await onInterruptActiveTurn();
                                return;
                              }

                              if (!hasInput) return;

                              final success = await onSubmitComposer(
                                composerController.text,
                              );
                              if (success) {
                                composerController.clear();
                              }
                            }
                          : () {},
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 180),
                        switchInCurve: Curves.easeOutCubic,
                        switchOutCurve: Curves.easeInCubic,
                        child: isComposerMutationInFlight
                            ? const SizedBox.square(
                                key: ValueKey('composer-loading'),
                                dimension: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: AppTheme.background,
                                ),
                              )
                            : isInterruptMutationInFlight
                            ? const SizedBox.square(
                                key: ValueKey('interrupt-loading'),
                                dimension: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: AppTheme.textMain,
                                ),
                              )
                            : PhosphorIcon(
                                showStopAction
                                    ? PhosphorIcons.stop()
                                    : PhosphorIcons.arrowUp(),
                                key: ValueKey(showStopAction ? 'stop' : 'send'),
                                size: 24,
                              ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
          if (trustedBridge == null) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: const Text(
                'Pair with a Mac to change access mode from here.',
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
        ],
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
    required this.trustedBridge,
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
  final TrustedBridgeIdentity? trustedBridge;
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
                  subtitle: widget.trustedBridge == null
                      ? 'Pair with a Mac to change access mode.'
                      : null,
                  children: AccessMode.values
                      .map(
                        (mode) => _ComposerSheetOption(
                          key: Key('turn-composer-access-mode-option-$mode'),
                          label: _accessModeChipLabel(mode),
                          selected: _selectedAccessMode == mode,
                          leading:
                              widget.trustedBridge == null &&
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
                          onTap: widget.trustedBridge == null
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
            child: Image.file(
              File(image.path),
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => Container(
                color: AppTheme.surfaceZinc800,
                alignment: Alignment.center,
                child: PhosphorIcon(
                  PhosphorIcons.imageBroken(),
                  color: AppTheme.textSubtle,
                ),
              ),
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
