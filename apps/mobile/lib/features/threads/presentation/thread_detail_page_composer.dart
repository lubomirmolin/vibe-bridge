part of 'thread_detail_page.dart';

class _PinnedTurnComposer extends StatelessWidget {
  const _PinnedTurnComposer({
    required this.composerController,
    required this.isTurnActive,
    required this.controlsEnabled,
    required this.isComposerMutationInFlight,
    required this.isInterruptMutationInFlight,
    required this.attachedImages,
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
  final bool isTurnActive;
  final bool controlsEnabled;
  final bool isComposerMutationInFlight;
  final bool isInterruptMutationInFlight;
  final List<XFile> attachedImages;
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
    final showStopAction = isTurnActive || isInterruptMutationInFlight;
    final canSubmitComposer =
        controlsEnabled &&
        !isTurnActive &&
        !isComposerMutationInFlight &&
        !isInterruptMutationInFlight;
    final canInterrupt =
        controlsEnabled &&
        isTurnActive &&
        !isInterruptMutationInFlight &&
        !isComposerMutationInFlight;
    final canRunPrimaryAction = showStopAction
        ? canInterrupt
        : canSubmitComposer;
    final canEditPinnedControls =
        !isComposerMutationInFlight && !isInterruptMutationInFlight;

    return Container(
      key: const Key('pinned-turn-composer'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      decoration: BoxDecoration(
        color: AppTheme.background.withOpacity(0.96),
        border: const Border(top: BorderSide(color: Colors.white10)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.45),
            blurRadius: 24,
            offset: const Offset(0, -8),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (attachedImages.isNotEmpty)
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
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              SizedBox(
                width: 56,
                height: 56,
                child: Container(
                  decoration: BoxDecoration(
                    color: AppTheme.surfaceZinc800.withOpacity(0.86),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white.withOpacity(0.06)),
                  ),
                  child: IconButton(
                    icon: PhosphorIcon(
                      PhosphorIcons.plus(),
                      size: 24,
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
              const SizedBox(width: 8),
              SizedBox(
                width: 56,
                height: 56,
                child: Container(
                  decoration: BoxDecoration(
                    color: AppTheme.surfaceZinc800.withOpacity(0.86),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white.withOpacity(0.06)),
                  ),
                  child: PopupMenuButton<dynamic>(
                    enabled: canEditPinnedControls,
                    tooltip: '',
                    icon: PhosphorIcon(
                      PhosphorIcons.cpu(),
                      size: 24,
                      color: AppTheme.textMain,
                    ),
                    onSelected: (value) {
                      if (value is String &&
                          _ThreadDetailPageState._modelOptions.contains(
                            value,
                          )) {
                        onModelChanged(value);
                      } else if (value is String &&
                          _ThreadDetailPageState._reasoningOptions.contains(
                            value,
                          )) {
                        onReasoningChanged(value);
                      } else if (value is AccessMode) {
                        onAccessModeChanged(value);
                      }
                    },
                    itemBuilder: (context) {
                      return [
                        const PopupMenuItem(
                          enabled: false,
                          child: Text(
                            'Model',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                        ..._ThreadDetailPageState._modelOptions.map(
                          (model) =>
                              PopupMenuItem(value: model, child: Text(model)),
                        ),
                        const PopupMenuDivider(),
                        const PopupMenuItem(
                          enabled: false,
                          child: Text(
                            'Reasoning',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                        ..._ThreadDetailPageState._reasoningOptions.map(
                          (reasoning) => PopupMenuItem(
                            value: reasoning,
                            child: Text(reasoning),
                          ),
                        ),
                        const PopupMenuDivider(),
                        const PopupMenuItem(
                          enabled: false,
                          child: Text(
                            'Access Mode',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                        ...AccessMode.values.map(
                          (mode) => PopupMenuItem(
                            value: mode,
                            child: Text(_accessModeChipLabel(mode)),
                          ),
                        ),
                      ];
                    },
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: AppTheme.surfaceZinc800.withOpacity(0.86),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: Colors.white.withOpacity(0.06)),
                  ),
                  child: TextField(
                    key: const Key('turn-composer-input'),
                    controller: composerController,
                    enabled: canSubmitComposer,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.newline,
                    style: const TextStyle(
                      color: AppTheme.textMain,
                      fontSize: 15,
                    ),
                    decoration: InputDecoration(
                      hintText: isTurnActive
                          ? 'Guide the agent...'
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
                child: ElevatedButton(
                  key: const Key('turn-composer-submit'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: showStopAction
                        ? (canRunPrimaryAction
                              ? AppTheme.rose
                              : AppTheme.rose.withOpacity(0.35))
                        : (canRunPrimaryAction ? Colors.white : Colors.white24),
                    foregroundColor: showStopAction
                        ? Colors.white
                        : Colors.black,
                    padding: EdgeInsets.zero,
                    elevation: 0,
                    shape: const CircleBorder(),
                  ),
                  onPressed: canRunPrimaryAction
                      ? () async {
                          if (showStopAction) {
                            await onInterruptActiveTurn();
                            return;
                          }

                          final success = await onSubmitComposer(
                            composerController.text,
                          );
                          if (success) {
                            composerController.clear();
                          }
                        }
                      : null,
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
                              color: Colors.black,
                            ),
                          )
                        : isInterruptMutationInFlight
                        ? const SizedBox.square(
                            key: ValueKey('interrupt-loading'),
                            dimension: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : PhosphorIcon(
                            showStopAction
                                ? PhosphorIcons.stop()
                                : PhosphorIcons.arrowUp(),
                            key: ValueKey(showStopAction ? 'stop' : 'send'),
                            size: 24,
                            color: showStopAction ? Colors.white : Colors.black,
                          ),
                  ),
                ),
              ),
            ],
          ),
          if (trustedBridge == null) ...[
            const SizedBox(height: 8),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Pair with a Mac to change access mode from here.',
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
                style: const TextStyle(color: AppTheme.rose, fontSize: 12),
              ),
            ),
          ],
        ],
      ),
    );
  }
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
                color: Colors.black.withOpacity(0.72),
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
