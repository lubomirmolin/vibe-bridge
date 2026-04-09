part of 'thread_detail_page.dart';

class _ComposerModelSheet extends StatefulWidget {
  const _ComposerModelSheet({
    required this.modelOptions,
    required this.reasoningOptions,
    required this.initialProvider,
    required this.canChangeProvider,
    required this.initialModel,
    required this.initialReasoning,
    required this.selectedAccessMode,
    required this.session,
    required this.isAccessModeUpdating,
    required this.onProviderChanged,
    required this.onModelChanged,
    required this.onReasoningChanged,
    required this.onAccessModeChanged,
  });

  final List<ModelOptionDto> modelOptions;
  final List<String> reasoningOptions;
  final ProviderKind initialProvider;
  final bool canChangeProvider;
  final String initialModel;
  final String initialReasoning;
  final AccessMode selectedAccessMode;
  final AppBridgeSession? session;
  final bool isAccessModeUpdating;
  final Future<void> Function(ProviderKind provider) onProviderChanged;
  final ValueChanged<String> onModelChanged;
  final ValueChanged<String> onReasoningChanged;
  final ValueChanged<AccessMode> onAccessModeChanged;

  @override
  State<_ComposerModelSheet> createState() => _ComposerModelSheetState();
}

class _ComposerModelSheetState extends State<_ComposerModelSheet> {
  late ProviderKind _selectedProvider;
  late List<ModelOptionDto> _modelOptions;
  late List<String> _reasoningOptions;
  late String _selectedModel;
  late String _selectedReasoning;
  late AccessMode _selectedAccessMode;
  bool _isProviderUpdating = false;

  @override
  void initState() {
    super.initState();
    _selectedProvider = widget.initialProvider;
    _modelOptions = widget.modelOptions;
    _reasoningOptions = widget.reasoningOptions;
    _selectedModel = widget.initialModel;
    _selectedReasoning = widget.initialReasoning;
    _selectedAccessMode = widget.selectedAccessMode;
  }

  bool get _supportsPlanMode => _selectedProvider == ProviderKind.codex;

  String _providerLabel(ProviderKind provider) {
    switch (provider) {
      case ProviderKind.codex:
        return 'Codex';
      case ProviderKind.claudeCode:
        return 'Claude Code';
    }
  }

  Future<void> _handleProviderChanged(ProviderKind provider) async {
    setState(() {
      _selectedProvider = provider;
      _isProviderUpdating = true;
    });

    try {
      await widget.onProviderChanged(provider);
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isProviderUpdating = false;
      });
      return;
    }

    if (!mounted) {
      return;
    }

    final modelOptions = fallbackModelCatalogForProvider(provider).models;
    final defaultModel = _defaultModelOption(modelOptions);
    setState(() {
      _modelOptions = modelOptions;
      _selectedModel = defaultModel.id;
      _reasoningOptions = _reasoningOptionsForModel(defaultModel);
      _selectedReasoning = _defaultReasoningForModel(
        defaultModel,
        fallback: 'Medium',
      );
      _isProviderUpdating = false;
    });
  }

  void _handleModelChanged(ModelOptionDto model) {
    final reasoningOptions = _reasoningOptionsForModel(model);
    setState(() {
      _selectedModel = model.id;
      _reasoningOptions = reasoningOptions;
      _selectedReasoning = _defaultReasoningForModel(
        model,
        fallback: reasoningOptions.isEmpty
            ? _selectedReasoning
            : reasoningOptions.first,
      );
    });
    widget.onModelChanged(model.id);
  }

  List<String> _reasoningOptionsForModel(ModelOptionDto model) {
    return model.supportedReasoningEfforts
        .map((option) => _formatComposerReasoningLabel(option.reasoningEffort))
        .toList(growable: false);
  }

  String _defaultReasoningForModel(
    ModelOptionDto model, {
    required String fallback,
  }) {
    final defaultReasoning = model.defaultReasoningEffort;
    if (defaultReasoning == null) {
      return fallback;
    }
    return _formatComposerReasoningLabel(defaultReasoning);
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
                Text(
                  widget.canChangeProvider
                      ? (_supportsPlanMode
                            ? 'Pick the provider, model, and intelligence level for the next turn.'
                            : 'Pick the provider and model for the next Claude turn. Plan mode stays on Codex-only threads.')
                      : (_supportsPlanMode
                            ? 'This thread stays on Codex. You can still adjust the model and intelligence level.'
                            : 'This thread stays on Claude Code. You can still adjust the model. Plan mode stays on Codex-only threads.'),
                  style: const TextStyle(
                    color: AppTheme.textMuted,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 18),
                _ComposerSheetSection(
                  title: 'Provider',
                  subtitle: widget.canChangeProvider
                      ? null
                      : 'Provider is fixed once the thread is created.',
                  children: widget.canChangeProvider
                      ? ProviderKind.values
                            .map(
                              (provider) => _ComposerSheetOption(
                                key: Key(
                                  'turn-composer-provider-option-${provider.wireValue}',
                                ),
                                label: _providerLabel(provider),
                                leadingWidget: ProviderIcon(
                                  provider: provider,
                                  size: 17,
                                ),
                                selected: _selectedProvider == provider,
                                trailing:
                                    _isProviderUpdating &&
                                        _selectedProvider == provider
                                    ? const SizedBox.square(
                                        dimension: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: AppTheme.textMain,
                                        ),
                                      )
                                    : null,
                                onTap:
                                    _isProviderUpdating ||
                                        _selectedProvider == provider
                                    ? () {}
                                    : () => _handleProviderChanged(provider),
                              ),
                            )
                            .toList(growable: false)
                      : <Widget>[
                          _ComposerSheetOption(
                            key: Key(
                              'turn-composer-provider-option-${_selectedProvider.wireValue}',
                            ),
                            label: _providerLabel(_selectedProvider),
                            selected: true,
                            leadingWidget: ProviderIcon(
                              provider: _selectedProvider,
                              size: 17,
                            ),
                            leading: PhosphorIcons.lock(),
                            leadingColor: AppTheme.textSubtle,
                            onTap: () {},
                          ),
                        ],
                ),
                const SizedBox(height: 18),
                _ComposerSheetSection(
                  title: 'Models',
                  children: _modelOptions
                      .map(
                        (model) => _ComposerSheetOption(
                          key: Key('turn-composer-model-option-${model.id}'),
                          label: model.displayName,
                          selected: _selectedModel == model.id,
                          onTap: () => _handleModelChanged(model),
                        ),
                      )
                      .toList(growable: false),
                ),
                const SizedBox(height: 18),
                _ComposerSheetSection(
                  title: 'Intelligence',
                  subtitle: _supportsPlanMode
                      ? null
                      : 'Claude uses its own effort scale and plan mode stays disabled.',
                  children: _reasoningOptions
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

ModelOptionDto _defaultModelOption(List<ModelOptionDto> modelOptions) {
  return modelOptions.firstWhere(
    (model) => model.isDefault,
    orElse: () => modelOptions.first,
  );
}

String _formatComposerReasoningLabel(String value) {
  return value
      .split('_')
      .map(
        (word) => word.isEmpty
            ? word
            : '${word[0].toUpperCase()}${word.substring(1)}',
      )
      .join(' ');
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
    this.leadingWidget,
    this.leadingColor,
    this.trailing,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? leading;
  final Widget? leadingWidget;
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
                if (leadingWidget != null) ...[
                  SizedBox.square(
                    dimension: 18,
                    child: Center(child: leadingWidget!),
                  ),
                  const SizedBox(width: 10),
                ] else if (leading != null) ...[
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
      if (!mounted) {
        return;
      }

      setState(() {
        for (var index = _bars.length - 1; index > 0; index -= 1) {
          _bars[index] = _bars[index - 1];
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
