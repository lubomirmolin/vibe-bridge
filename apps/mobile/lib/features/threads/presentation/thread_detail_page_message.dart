part of 'thread_detail_page.dart';

class _ChatMessageCard extends StatelessWidget {
  const _ChatMessageCard({required this.item});

  final ThreadActivityItem item;

  @override
  Widget build(BuildContext context) {
    final isUser = item.type == ThreadActivityItemType.userPrompt;
    final isSending =
        item.localMessageState == ThreadActivityLocalMessageState.sending;
    final isFailed =
        item.localMessageState == ThreadActivityLocalMessageState.failed;

    return _SwipeToRevealMessageTimestamp(
      eventId: item.eventId,
      occurredAt: item.occurredAt,
      child: Container(
        width: double.infinity,
        padding: isUser ? const EdgeInsets.fromLTRB(16, 12, 16, 14) : null,
        decoration: isUser
            ? BoxDecoration(
                color: AppTheme.surfaceZinc800.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(16),
              )
            : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (isUser) ...[
              Row(
                children: [
                  PhosphorIcon(
                    PhosphorIcons.user(),
                    color: AppTheme.emerald,
                    size: 14,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'User',
                    style: GoogleFonts.jetBrainsMono(
                      color: AppTheme.emerald,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (isSending || isFailed) ...[
                    const SizedBox(width: 10),
                    if (isSending)
                      SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          key: const Key('thread-message-sending-spinner'),
                          strokeWidth: 1.75,
                          color: AppTheme.emerald,
                        ),
                      )
                    else
                      PhosphorIcon(
                        PhosphorIcons.warningCircle(),
                        color: AppTheme.rose,
                        size: 13,
                      ),
                    const SizedBox(width: 6),
                    Text(
                      isSending ? 'Sending' : 'Send failed',
                      key: Key('thread-message-local-state-${item.eventId}'),
                      style: GoogleFonts.jetBrainsMono(
                        color: isSending ? AppTheme.emerald : AppTheme.rose,
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 6),
            ],
            _ThreadMessageBody(
              body: item.body,
              hideAppDirectives: !isUser,
              imageUrls: item.messageImageUrls,
              textStyle: TextStyle(
                color: isUser
                    ? AppTheme.textMain
                    : AppTheme.textMain.withValues(alpha: 0.9),
                fontSize: 14,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SwipeToRevealMessageTimestamp extends StatefulWidget {
  const _SwipeToRevealMessageTimestamp({
    required this.eventId,
    required this.occurredAt,
    required this.child,
  });

  final String eventId;
  final String occurredAt;
  final Widget child;

  @override
  State<_SwipeToRevealMessageTimestamp> createState() =>
      _SwipeToRevealMessageTimestampState();
}

class _SwipeToRevealMessageTimestampState
    extends State<_SwipeToRevealMessageTimestamp> {
  static const double _maxRevealOffset = 80;
  static const double _visibleThreshold = 8;
  static const Duration _snapBackDuration = Duration(milliseconds: 180);

  double _rawDragOffset = 0;
  double _dragOffset = 0;
  bool _isDragging = false;

  bool get _isTimestampVisible => _dragOffset.abs() >= _visibleThreshold;

  void _handleDragUpdate(double deltaX) {
    setState(() {
      _isDragging = true;
      _rawDragOffset += deltaX;
      _dragOffset = _applyResistance(_rawDragOffset);
    });
  }

  void _resetDrag() {
    if (_rawDragOffset == 0 && _dragOffset == 0 && !_isDragging) {
      return;
    }

    setState(() {
      _rawDragOffset = 0;
      _dragOffset = 0;
      _isDragging = false;
    });
  }

  double _applyResistance(double rawOffset) {
    final distance = rawOffset.abs();
    if (distance == 0) {
      return 0;
    }

    final resistedDistance = _maxRevealOffset * (distance / (distance + 96));
    return rawOffset.isNegative ? -resistedDistance : resistedDistance;
  }

  @override
  Widget build(BuildContext context) {
    final timestamp = _MessageTimestampLabel.parse(widget.occurredAt);
    final revealAlignment = _dragOffset.isNegative
        ? Alignment.centerRight
        : Alignment.centerLeft;
    final revealCrossAxisAlignment = _dragOffset.isNegative
        ? CrossAxisAlignment.end
        : CrossAxisAlignment.start;
    final revealOpacity = clampDouble(_dragOffset.abs() / 28, 0, 1);

    return GestureDetector(
      key: Key('thread-message-card-${widget.eventId}'),
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: (_) {
        if (_isDragging) {
          return;
        }
        setState(() {
          _isDragging = true;
        });
      },
      onHorizontalDragUpdate: (details) => _handleDragUpdate(details.delta.dx),
      onHorizontalDragEnd: (_) => _resetDrag(),
      onHorizontalDragCancel: _resetDrag,
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          if (_isTimestampVisible)
            Positioned.fill(
              child: IgnorePointer(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Align(
                    alignment: revealAlignment,
                    child: AnimatedOpacity(
                      duration: _isDragging ? Duration.zero : _snapBackDuration,
                      curve: Curves.easeOutCubic,
                      opacity: revealOpacity,
                      child: _MessageTimestampReveal(
                        key: Key('thread-message-timestamp-${widget.eventId}'),
                        timestamp: timestamp,
                        crossAxisAlignment: revealCrossAxisAlignment,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          AnimatedContainer(
            duration: _isDragging ? Duration.zero : _snapBackDuration,
            curve: Curves.easeOutCubic,
            transform: Matrix4.translationValues(_dragOffset, 0, 0),
            child: widget.child,
          ),
        ],
      ),
    );
  }
}

class _MessageTimestampReveal extends StatelessWidget {
  const _MessageTimestampReveal({
    super.key,
    required this.timestamp,
    required this.crossAxisAlignment,
  });

  final _MessageTimestampLabel timestamp;
  final CrossAxisAlignment crossAxisAlignment;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: crossAxisAlignment,
      children: [
        Text(
          timestamp.dateLabel,
          style: GoogleFonts.jetBrainsMono(
            color: AppTheme.textSubtle,
            fontSize: 10,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          timestamp.timeLabel,
          style: GoogleFonts.jetBrainsMono(
            color: AppTheme.textMuted,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _MessageTimestampLabel {
  const _MessageTimestampLabel({
    required this.dateLabel,
    required this.timeLabel,
  });

  final String dateLabel;
  final String timeLabel;

  static _MessageTimestampLabel parse(String rawTimestamp) {
    final parsed = DateTime.tryParse(rawTimestamp);
    if (parsed == null) {
      return _MessageTimestampLabel(
        dateLabel: rawTimestamp.trim().isEmpty ? 'Unknown date' : rawTimestamp,
        timeLabel: '',
      );
    }

    final date = [
      parsed.year.toString().padLeft(4, '0'),
      parsed.month.toString().padLeft(2, '0'),
      parsed.day.toString().padLeft(2, '0'),
    ].join('-');
    final time =
        '${parsed.hour.toString().padLeft(2, '0')}:${parsed.minute.toString().padLeft(2, '0')}';

    return _MessageTimestampLabel(dateLabel: date, timeLabel: time);
  }
}

class _ThreadMessageBody extends StatelessWidget {
  const _ThreadMessageBody({
    required this.body,
    required this.hideAppDirectives,
    required this.imageUrls,
    required this.textStyle,
  });

  final String body;
  final bool hideAppDirectives;
  final List<String> imageUrls;
  final TextStyle textStyle;

  @override
  Widget build(BuildContext context) {
    final parsedBody = hideAppDirectives
        ? _parseAssistantDirectiveBody(body)
        : _ParsedAssistantDirectiveBody(displayBody: body, pills: const []);
    final displayBody = parsedBody.displayBody;
    final segments = _MessageBodyParser.parse(displayBody);
    final children = <Widget>[];
    var textBlockIndex = 0;

    void addChild(Widget child) {
      if (children.isNotEmpty) {
        children.add(const SizedBox(height: 10));
      }
      children.add(child);
    }

    if (displayBody.isNotEmpty) {
      for (final segment in segments) {
        switch (segment.kind) {
          case _MessageSegmentKind.code:
            addChild(
              _ThreadCodeBlockViewer(
                code: segment.content,
                languageHint: segment.languageHint,
                filePathHint: segment.filePathHint,
              ),
            );
            break;
          case _MessageSegmentKind.text:
            if (segment.content.isEmpty) {
              break;
            }

            final textBlocks = _MessageTextBlockParser.parse(segment.content);
            for (final block in textBlocks) {
              addChild(
                _ThreadTextBlock(
                  block: block,
                  textStyle: textStyle,
                  blockIndex: textBlockIndex,
                ),
              );
              textBlockIndex += 1;
            }
            break;
        }
      }
    }

    for (var index = 0; index < imageUrls.length; index++) {
      addChild(_ThreadMessageImage(imageUrl: imageUrls[index], index: index));
    }

    if (parsedBody.pills.isNotEmpty) {
      addChild(_AssistantDirectivePillRow(pills: parsedBody.pills));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }
}

class _ParsedAssistantDirectiveBody {
  const _ParsedAssistantDirectiveBody({
    required this.displayBody,
    required this.pills,
  });

  final String displayBody;
  final List<_AssistantDirectivePillData> pills;
}

class _AssistantDirectivePillData {
  const _AssistantDirectivePillData({
    required this.label,
    required this.icon,
    required this.textColor,
    required this.backgroundColor,
    required this.borderColor,
  });

  final String label;
  final IconData icon;
  final Color textColor;
  final Color backgroundColor;
  final Color borderColor;
}

_ParsedAssistantDirectiveBody _parseAssistantDirectiveBody(String body) {
  if (body.trim().isEmpty) {
    return const _ParsedAssistantDirectiveBody(displayBody: '', pills: []);
  }

  final directivePattern = RegExp(
    r'^\s*::([a-z0-9-]+)\{.*\}\s*$',
    caseSensitive: false,
  );
  final keptLines = <String>[];
  final pills = <_AssistantDirectivePillData>[];
  var previousWasBlank = false;

  for (final line in body.split('\n')) {
    final match = directivePattern.firstMatch(line);
    if (match != null) {
      final pill = _directivePillForName(match.group(1) ?? '');
      if (pill != null) {
        pills.add(pill);
      }
      continue;
    }

    final isBlank = line.trim().isEmpty;
    if (isBlank && (keptLines.isEmpty || previousWasBlank)) {
      continue;
    }

    keptLines.add(line);
    previousWasBlank = isBlank;
  }

  while (keptLines.isNotEmpty && keptLines.last.trim().isEmpty) {
    keptLines.removeLast();
  }

  return _ParsedAssistantDirectiveBody(
    displayBody: keptLines.join('\n'),
    pills: pills,
  );
}

_AssistantDirectivePillData? _directivePillForName(String rawName) {
  final name = rawName.trim().toLowerCase();
  switch (name) {
    case 'git-stage':
      return _AssistantDirectivePillData(
        label: 'Staged',
        icon: PhosphorIcons.checkCircle(),
        textColor: const Color(0xFF34D399),
        backgroundColor: AppTheme.emerald.withValues(alpha: 0.14),
        borderColor: AppTheme.emerald.withValues(alpha: 0.28),
      );
    case 'git-commit':
      return _AssistantDirectivePillData(
        label: 'Committed',
        icon: PhosphorIcons.gitCommit(),
        textColor: const Color(0xFF7DD3FC),
        backgroundColor: const Color(0xFF0EA5E9).withValues(alpha: 0.12),
        borderColor: const Color(0xFF38BDF8).withValues(alpha: 0.28),
      );
    case 'git-create-branch':
      return _AssistantDirectivePillData(
        label: 'Branch created',
        icon: PhosphorIcons.gitBranch(),
        textColor: const Color(0xFFFBBF24),
        backgroundColor: AppTheme.amber.withValues(alpha: 0.12),
        borderColor: AppTheme.amber.withValues(alpha: 0.28),
      );
    case 'git-push':
      return _AssistantDirectivePillData(
        label: 'Pushed',
        icon: PhosphorIcons.uploadSimple(),
        textColor: const Color(0xFFA78BFA),
        backgroundColor: const Color(0xFF8B5CF6).withValues(alpha: 0.12),
        borderColor: const Color(0xFFA78BFA).withValues(alpha: 0.28),
      );
    case 'git-create-pr':
      return _AssistantDirectivePillData(
        label: 'PR created',
        icon: PhosphorIcons.gitPullRequest(),
        textColor: const Color(0xFFF9A8D4),
        backgroundColor: const Color(0xFFEC4899).withValues(alpha: 0.12),
        borderColor: const Color(0xFFF472B6).withValues(alpha: 0.28),
      );
  }

  return null;
}

class _AssistantDirectivePillRow extends StatelessWidget {
  const _AssistantDirectivePillRow({required this.pills});

  final List<_AssistantDirectivePillData> pills;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (var index = 0; index < pills.length; index++)
          _AssistantDirectivePill(
            key: Key('thread-message-directive-pill-$index'),
            pill: pills[index],
          ),
      ],
    );
  }
}

class _AssistantDirectivePill extends StatelessWidget {
  const _AssistantDirectivePill({super.key, required this.pill});

  final _AssistantDirectivePillData pill;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: pill.backgroundColor,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: pill.borderColor),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          PhosphorIcon(pill.icon, color: pill.textColor, size: 13),
          const SizedBox(width: 6),
          Text(
            pill.label,
            style: GoogleFonts.jetBrainsMono(
              color: pill.textColor,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _ThreadInlineText extends StatelessWidget {
  const _ThreadInlineText({
    super.key,
    required this.text,
    required this.textStyle,
  });

  final String text;
  final TextStyle textStyle;

  @override
  Widget build(BuildContext context) {
    final spans = _InlineQuoteParser.parse(text, textStyle);
    final onlySpan = spans.length == 1 ? spans.first : null;
    if (onlySpan is TextSpan && onlySpan.style == textStyle) {
      return SelectableText(text, key: key, style: textStyle);
    }

    return SelectableText.rich(
      key: key,
      TextSpan(style: textStyle, children: spans),
    );
  }
}

class _ThreadMessageImage extends StatelessWidget {
  const _ThreadMessageImage({required this.imageUrl, required this.index});

  final String imageUrl;
  final int index;

  static const double _maxHeight = 320;
  static const double _heightRatio = 0.75;

  @override
  Widget build(BuildContext context) {
    final imageWidget = _buildImage();
    if (imageWidget == null) {
      return const SizedBox.shrink();
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final boundedWidth = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : _maxHeight / _heightRatio;
        final reservedHeight = math.min(
          boundedWidth * _heightRatio,
          _maxHeight,
        );

        return ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Container(
            key: Key('thread-message-image-$index'),
            width: double.infinity,
            height: reservedHeight,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.25),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
              borderRadius: BorderRadius.circular(12),
            ),
            child: imageWidget,
          ),
        );
      },
    );
  }

  Widget? _buildImage() {
    final trimmed = imageUrl.trim();
    if (trimmed.isEmpty) {
      return null;
    }

    final uri = Uri.tryParse(trimmed);
    if (uri != null && uri.scheme == 'data') {
      final bytes = uri.data?.contentAsBytes();
      if (bytes == null || bytes.isEmpty) {
        return null;
      }
      return _buildFramedImage(
        Image.memory(bytes, fit: BoxFit.contain, gaplessPlayback: true),
      );
    }

    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return _buildFramedImage(
        Image.network(
          trimmed,
          fit: BoxFit.contain,
          errorBuilder: (context, error, stackTrace) => _ImageFailureState(),
          loadingBuilder: (context, child, loadingProgress) {
            if (loadingProgress == null) {
              return child;
            }
            return Stack(
              fit: StackFit.expand,
              children: [child, const _ImageLoadingState()],
            );
          },
        ),
      );
    }

    return null;
  }

  Widget _buildFramedImage(Widget child) {
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.12),
      child: Center(child: child),
    );
  }
}

class _ImageLoadingState extends StatelessWidget {
  const _ImageLoadingState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          PhosphorIcon(
            PhosphorIcons.imageSquare(),
            color: AppTheme.textSubtle,
            size: 20,
          ),
          const SizedBox(height: 8),
          Text(
            'Loading image…',
            style: GoogleFonts.jetBrainsMono(
              color: AppTheme.textSubtle,
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _ImageFailureState extends StatelessWidget {
  const _ImageFailureState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          PhosphorIcon(
            PhosphorIcons.imageBroken(),
            color: AppTheme.textMuted,
            size: 20,
          ),
          const SizedBox(height: 8),
          Text(
            'Image unavailable',
            style: GoogleFonts.jetBrainsMono(
              color: AppTheme.textMuted,
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _ThreadCodeBlockViewer extends StatelessWidget {
  const _ThreadCodeBlockViewer({
    required this.code,
    this.languageHint,
    this.filePathHint,
  });

  final String code;
  final String? languageHint;
  final String? filePathHint;

  @override
  Widget build(BuildContext context) {
    final lineCount = '\n'.allMatches(code).length + 1;
    final digits = lineCount.toString().length;
    final gutterWidth = _gutterWidthForDigits(digits);
    final language =
        _CodeLanguageResolver.normalize(languageHint) ??
        _CodeLanguageResolver.fromFilePath(filePathHint);
    final fileName = _CodeLanguageResolver.displayName(filePathHint);
    final languageLabel = _CodeLanguageResolver.label(language);
    final shouldShowHeader = fileName != null || languageLabel != null;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (shouldShowHeader)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.03),
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(10),
                  topRight: Radius.circular(10),
                ),
              ),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (fileName != null)
                    Text(
                      fileName,
                      key: Key('thread-code-file-$fileName'),
                      style: GoogleFonts.jetBrainsMono(
                        color: AppTheme.textMain,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  if (languageLabel != null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: AppTheme.surfaceZinc800.withValues(alpha: 0.9),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.08),
                        ),
                      ),
                      child: Text(
                        languageLabel,
                        key: Key('thread-code-language-$language'),
                        style: GoogleFonts.jetBrainsMono(
                          color: AppTheme.textSubtle,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          _buildCodeContent(
            language: language,
            lineCount: lineCount,
            gutterWidth: gutterWidth,
          ),
        ],
      ),
    );
  }

  Widget _buildCodeContent({
    required String? language,
    required int lineCount,
    required double gutterWidth,
  }) {
    // Use the cached instance synchronously when available to avoid
    // FutureBuilder-driven layout reflows.
    final cached = _ThreadCodeHighlighterSet.cachedInstance;
    if (cached != null) {
      return _codeContentBody(
        highlighterSet: cached,
        language: language,
        lineCount: lineCount,
        gutterWidth: gutterWidth,
      );
    }

    return FutureBuilder<_ThreadCodeHighlighterSet>(
      future: _ThreadCodeHighlighterSet.load(),
      builder: (context, snapshot) {
        return _codeContentBody(
          highlighterSet: snapshot.data,
          language: language,
          lineCount: lineCount,
          gutterWidth: gutterWidth,
        );
      },
    );
  }

  Widget _codeContentBody({
    required _ThreadCodeHighlighterSet? highlighterSet,
    required String? language,
    required int lineCount,
    required double gutterWidth,
  }) {
    final highlighted = language == null
        ? null
        : highlighterSet?.highlight(language, code);
    final codeStyle = GoogleFonts.jetBrainsMono(
      color: AppTheme.textMuted,
      fontSize: 11.5,
      height: 1.4,
    );

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: gutterWidth,
            child: Text(
              _lineNumbers(lineCount),
              textAlign: TextAlign.right,
              style: GoogleFonts.jetBrainsMono(
                color: AppTheme.textSubtle,
                fontSize: 10.5,
                height: 1.4,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Container(
            width: 1,
            height: 18.0 * lineCount,
            color: Colors.white.withValues(alpha: 0.08),
          ),
          const SizedBox(width: 8),
          SelectableText.rich(
            highlighted == null
                ? TextSpan(text: code, style: codeStyle)
                : TextSpan(style: codeStyle, children: [highlighted]),
          ),
        ],
      ),
    );
  }

  double _gutterWidthForDigits(int digits) {
    if (digits <= 1) {
      return 20;
    }
    if (digits == 2) {
      return 28;
    }
    return (digits * 8 + 12).toDouble();
  }

  String _lineNumbers(int lineCount) {
    const startLineNumber = 1;
    final buffer = StringBuffer();
    for (
      var line = startLineNumber;
      line < startLineNumber + lineCount;
      line++
    ) {
      buffer.writeln(line);
    }
    return buffer.toString().trimRight();
  }
}

class _ThreadCodeHighlighterSet {
  _ThreadCodeHighlighterSet._({required this.darkTheme});

  static final Future<void> _init = Highlighter.initialize(
    _CodeLanguageResolver.supportedLanguages.toList(growable: false),
  );
  static Future<HighlighterTheme>? _darkThemeFuture;
  static final Map<String, Highlighter> _highlighters = <String, Highlighter>{};

  /// Eagerly-resolved singleton. Available synchronously once the first
  /// [load] completes; `null` while still loading.
  static _ThreadCodeHighlighterSet? _cached;

  /// Shared future so multiple callers coalesce on the same load.
  static Future<_ThreadCodeHighlighterSet>? _loadFuture;

  /// Kick off the highlighter load early so it is ready before any code
  /// blocks need it. Call this once at app/page startup.
  static void warmUp() {
    _loadFuture ??= _doLoad();
  }

  static Future<_ThreadCodeHighlighterSet> load() {
    return _loadFuture ??= _doLoad();
  }

  static Future<_ThreadCodeHighlighterSet> _doLoad() async {
    if (_cached != null) {
      return _cached!;
    }
    await _init;
    final darkTheme = await (_darkThemeFuture ??=
        HighlighterTheme.loadDarkTheme());
    final instance = _ThreadCodeHighlighterSet._(darkTheme: darkTheme);
    _cached = instance;
    return instance;
  }

  /// Returns the cached instance synchronously, or `null` if not yet
  /// loaded. This avoids FutureBuilder rebuilds for code blocks rendered
  /// after the first load finishes.
  static _ThreadCodeHighlighterSet? get cachedInstance => _cached;

  final HighlighterTheme darkTheme;

  TextSpan highlight(String language, String code) {
    final highlighter = _highlighters.putIfAbsent(
      language,
      () => Highlighter(language: language, theme: darkTheme),
    );
    return highlighter.highlight(code);
  }
}

class _MessageBodyParser {
  static final RegExp _codeFencePattern = RegExp(
    r'```([^\n`]*)\n([\s\S]*?)```',
    multiLine: true,
  );

  static List<_MessageSegment> parse(String body) {
    final matches = _codeFencePattern.allMatches(body).toList(growable: false);
    if (matches.isEmpty) {
      return body.isEmpty
          ? const <_MessageSegment>[]
          : <_MessageSegment>[_MessageSegment.text(body)];
    }

    final segments = <_MessageSegment>[];
    var start = 0;

    for (final match in matches) {
      final leadingText = body.substring(start, match.start);
      if (match.start > start) {
        segments.add(_MessageSegment.text(leadingText));
      }

      final rawLanguage = match.group(1)?.trim();
      final code = (match.group(2) ?? '').trimRight();
      final filePathHint = _CodeLanguageResolver.filePathForCodeBlock(
        rawFenceInfo: rawLanguage,
        leadingText: leadingText,
      );
      final languageHint = _CodeLanguageResolver.resolveLanguage(
        rawFenceInfo: rawLanguage,
        filePathHint: filePathHint,
      );
      segments.add(
        _MessageSegment.code(code, languageHint, filePathHint: filePathHint),
      );
      start = match.end;
    }

    if (start < body.length) {
      segments.add(_MessageSegment.text(body.substring(start)));
    }

    return segments;
  }
}

class _InlineQuoteParser {
  static List<InlineSpan> parse(String text, TextStyle textStyle) {
    if (text.isEmpty) {
      return const <InlineSpan>[];
    }

    final lines = text.split('\n');
    final spans = <InlineSpan>[];
    for (var lineIndex = 0; lineIndex < lines.length; lineIndex++) {
      if (lineIndex > 0) {
        spans.add(TextSpan(text: '\n', style: textStyle));
      }

      final line = lines[lineIndex];
      final titleSpan = _tryParseMarkdownTitle(line, textStyle);
      if (titleSpan != null) {
        spans.add(titleSpan);
        continue;
      }

      spans.addAll(_parseInlineContent(line, textStyle));
    }

    return spans;
  }

  static List<InlineSpan> _parseInlineContent(
    String text,
    TextStyle textStyle,
  ) {
    if (text.isEmpty) {
      return const <InlineSpan>[];
    }

    final spans = <InlineSpan>[];
    final buffer = StringBuffer();
    var index = 0;

    void flushText() {
      if (buffer.isEmpty) {
        return;
      }
      spans.add(TextSpan(text: buffer.toString(), style: textStyle));
      buffer.clear();
    }

    while (index < text.length) {
      final char = text[index];
      final link = _tryParseMarkdownLink(text, index);
      if (link != null) {
        flushText();
        spans.add(_buildLinkSpan(link.label, textStyle));
        index = link.end;
        continue;
      }

      if (char != '`' || _isPartOfBacktickRun(text, index)) {
        buffer.write(char);
        index += 1;
        continue;
      }

      final closingIndex = _findClosingBacktick(text, index + 1);
      if (closingIndex == null) {
        buffer.write(char);
        index += 1;
        continue;
      }

      flushText();
      final quotedText = text.substring(index + 1, closingIndex);
      spans.add(
        TextSpan(text: quotedText, style: _buildInlineCodeStyle(textStyle)),
      );
      index = closingIndex + 1;
    }

    flushText();
    return spans;
  }

  static TextSpan? _tryParseMarkdownTitle(String text, TextStyle textStyle) {
    final match = RegExp(r'^\s*\*\*\s*(.+?)\s*\*\*\s*$').firstMatch(text);
    final title = match?.group(1)?.trim();
    if (title == null || title.isEmpty) {
      return null;
    }

    return TextSpan(text: title, style: _buildTitleStyle(textStyle));
  }

  static TextSpan _buildLinkSpan(String label, TextStyle textStyle) {
    final isFileLike = _looksLikeFileReference(label);
    final baseStyle = textStyle.copyWith(
      color: AppTheme.emerald,
      fontWeight: FontWeight.w600,
    );
    final style = isFileLike
        ? GoogleFonts.jetBrainsMono(
            textStyle: baseStyle,
            fontSize: textStyle.fontSize,
            height: textStyle.height,
          )
        : baseStyle;
    return TextSpan(text: label, style: style);
  }

  static TextStyle _buildInlineCodeStyle(TextStyle textStyle) {
    final baseStyle = textStyle.copyWith(
      color: AppTheme.emerald,
      fontWeight: FontWeight.w600,
      backgroundColor: AppTheme.emerald.withValues(alpha: 0.12),
    );
    return GoogleFonts.jetBrainsMono(
      textStyle: baseStyle,
      fontSize: textStyle.fontSize,
      height: textStyle.height,
    );
  }

  static TextStyle _buildTitleStyle(TextStyle textStyle) {
    final titleFontSize = (textStyle.fontSize ?? 14) + 2;
    return GoogleFonts.jetBrainsMono(
      textStyle: textStyle.copyWith(
        color: AppTheme.textMain,
        fontSize: titleFontSize,
        height: 1.35,
        fontWeight: FontWeight.w700,
      ),
    );
  }

  static bool _isPartOfBacktickRun(String text, int index) {
    final previousIsBacktick = index > 0 && text[index - 1] == '`';
    final nextIsBacktick = index + 1 < text.length && text[index + 1] == '`';
    return previousIsBacktick || nextIsBacktick;
  }

  static int? _findClosingBacktick(String text, int start) {
    for (var index = start; index < text.length; index++) {
      if (text[index] != '`') {
        continue;
      }
      if (_isPartOfBacktickRun(text, index)) {
        continue;
      }
      return index;
    }
    return null;
  }

  static _MarkdownLinkMatch? _tryParseMarkdownLink(String text, int start) {
    if (text[start] != '[') {
      return null;
    }

    final labelEnd = text.indexOf(']', start + 1);
    if (labelEnd == -1 || labelEnd + 1 >= text.length) {
      return null;
    }
    if (text[labelEnd + 1] != '(') {
      return null;
    }

    final targetEnd = _findMarkdownLinkTargetEnd(text, labelEnd + 1);
    if (targetEnd == null) {
      return null;
    }

    final label = text.substring(start + 1, labelEnd).trim();
    if (label.isEmpty) {
      return null;
    }

    return _MarkdownLinkMatch(label: label, end: targetEnd + 1);
  }

  static int? _findMarkdownLinkTargetEnd(String text, int openParenIndex) {
    var depth = 0;

    for (var index = openParenIndex; index < text.length; index++) {
      final char = text[index];
      if (char == '(') {
        depth += 1;
        continue;
      }
      if (char != ')') {
        continue;
      }

      depth -= 1;
      if (depth == 0) {
        return index;
      }
      if (depth < 0) {
        return null;
      }
    }

    return null;
  }

  static bool _looksLikeFileReference(String label) {
    return label.contains('/') ||
        RegExp(
          r'\.[a-z0-9]{1,8}(?::\d+)?$',
          caseSensitive: false,
        ).hasMatch(label);
  }
}

class _MarkdownLinkMatch {
  const _MarkdownLinkMatch({required this.label, required this.end});

  final String label;
  final int end;
}

enum _MessageSegmentKind { text, code }

class _MessageSegment {
  const _MessageSegment._({
    required this.content,
    required this.kind,
    this.languageHint,
    this.filePathHint,
  });

  factory _MessageSegment.text(String content) {
    return _MessageSegment._(content: content, kind: _MessageSegmentKind.text);
  }

  factory _MessageSegment.code(
    String content,
    String? languageHint, {
    String? filePathHint,
  }) {
    return _MessageSegment._(
      content: content,
      kind: _MessageSegmentKind.code,
      languageHint: languageHint,
      filePathHint: filePathHint,
    );
  }

  final String content;
  final _MessageSegmentKind kind;
  final String? languageHint;
  final String? filePathHint;
}

class _CodeLanguageResolver {
  static const Set<String> supportedLanguages = <String>{
    'css',
    'dart',
    'go',
    'html',
    'java',
    'javascript',
    'json',
    'kotlin',
    'python',
    'rust',
    'sql',
    'swift',
    'typescript',
    'yaml',
  };

  static String? fromFilePath(String? path) {
    if (path == null || path.trim().isEmpty) {
      return null;
    }
    final normalized = path.toLowerCase().trim();
    if (normalized.endsWith('.dart')) {
      return 'dart';
    }
    if (normalized.endsWith('.ts') || normalized.endsWith('.tsx')) {
      return 'typescript';
    }
    if (normalized.endsWith('.js') ||
        normalized.endsWith('.jsx') ||
        normalized.endsWith('.mjs') ||
        normalized.endsWith('.cjs')) {
      return 'javascript';
    }
    if (normalized.endsWith('.json')) {
      return 'json';
    }
    if (normalized.endsWith('.yaml') || normalized.endsWith('.yml')) {
      return 'yaml';
    }
    if (normalized.endsWith('.kt') || normalized.endsWith('.kts')) {
      return 'kotlin';
    }
    if (normalized.endsWith('.swift')) {
      return 'swift';
    }
    if (normalized.endsWith('.java')) {
      return 'java';
    }
    if (normalized.endsWith('.rs')) {
      return 'rust';
    }
    if (normalized.endsWith('.py')) {
      return 'python';
    }
    if (normalized.endsWith('.go')) {
      return 'go';
    }
    if (normalized.endsWith('.sql')) {
      return 'sql';
    }
    if (normalized.endsWith('.css')) {
      return 'css';
    }
    if (normalized.endsWith('.html') || normalized.endsWith('.htm')) {
      return 'html';
    }
    return null;
  }

  static String? resolveLanguage({
    required String? rawFenceInfo,
    required String? filePathHint,
  }) {
    return normalize(rawFenceInfo) ??
        fromFilePath(rawFenceInfo) ??
        fromFilePath(filePathHint);
  }

  static String? filePathForCodeBlock({
    required String? rawFenceInfo,
    required String leadingText,
  }) {
    return _extractFilePath(rawFenceInfo) ?? _lastFilePathInText(leadingText);
  }

  static String? displayName(String? path) {
    if (path == null || path.trim().isEmpty) {
      return null;
    }
    final normalized = path.trim().replaceAll('\\', '/');
    final segments = normalized.split('/');
    return segments.isEmpty ? normalized : segments.last;
  }

  static String? label(String? language) {
    switch (language) {
      case 'css':
        return 'CSS';
      case 'dart':
        return 'Dart';
      case 'go':
        return 'Go';
      case 'html':
        return 'HTML';
      case 'java':
        return 'Java';
      case 'javascript':
        return 'JavaScript';
      case 'json':
        return 'JSON';
      case 'kotlin':
        return 'Kotlin';
      case 'python':
        return 'Python';
      case 'rust':
        return 'Rust';
      case 'sql':
        return 'SQL';
      case 'swift':
        return 'Swift';
      case 'typescript':
        return 'TypeScript';
      case 'yaml':
        return 'YAML';
      default:
        return null;
    }
  }

  static String? _extractFilePath(String? rawFenceInfo) {
    if (rawFenceInfo == null || rawFenceInfo.trim().isEmpty) {
      return null;
    }

    final trimmed = rawFenceInfo.trim();
    final directCandidates = <String>[
      trimmed,
      ...trimmed.split(RegExp(r'\s+')),
    ];
    for (final candidate in directCandidates) {
      final normalized = _normalizeFilePathCandidate(candidate);
      if (normalized != null && fromFilePath(normalized) != null) {
        return normalized;
      }
    }

    final namedValuePattern = RegExp(
      r'''(?:file|filename|path|title)\s*=\s*["']?([^"'\s}]+)["']?''',
      caseSensitive: false,
    );
    final match = namedValuePattern.firstMatch(trimmed);
    final normalized = _normalizeFilePathCandidate(match?.group(1));
    if (normalized == null || fromFilePath(normalized) == null) {
      return null;
    }
    return normalized;
  }

  static String? _lastFilePathInText(String text) {
    if (text.trim().isEmpty) {
      return null;
    }

    final recentText = text.length > 400
        ? text.substring(text.length - 400)
        : text;
    final pattern = RegExp(
      r'([~./A-Za-z0-9_-]+(?:/[~./A-Za-z0-9_-]+)*\.[A-Za-z0-9]+)',
    );

    String? lastSupportedPath;
    for (final match in pattern.allMatches(recentText)) {
      final normalized = _normalizeFilePathCandidate(match.group(1));
      if (normalized != null && fromFilePath(normalized) != null) {
        lastSupportedPath = normalized;
      }
    }
    return lastSupportedPath;
  }

  static String? _normalizeFilePathCandidate(String? value) {
    if (value == null) {
      return null;
    }
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return null;
    }

    final withoutQuotes = trimmed.replaceAll(
      RegExp(r'''^[`"']+|[`"']+$'''),
      '',
    );
    final withoutTrailingPunctuation = withoutQuotes.replaceAll(
      RegExp(r'[\s)\],:;]+$'),
      '',
    );
    if (withoutTrailingPunctuation.isEmpty ||
        !withoutTrailingPunctuation.contains('.')) {
      return null;
    }

    return withoutTrailingPunctuation;
  }

  static String? normalize(String? raw) {
    if (raw == null) {
      return null;
    }
    final value = raw.trim().toLowerCase();
    if (value.isEmpty) {
      return null;
    }
    if (supportedLanguages.contains(value)) {
      return value;
    }

    switch (value) {
      case 'ts':
      case 'tsx':
        return 'typescript';
      case 'js':
      case 'jsx':
      case 'node':
        return 'javascript';
      case 'py':
        return 'python';
      case 'yml':
        return 'yaml';
      case 'md':
      case 'markdown':
      case 'diff':
      case 'patch':
      case 'txt':
      case 'text':
      case 'bash':
      case 'zsh':
      case 'shell':
      case 'sh':
        return null;
      default:
        return null;
    }
  }
}

String _runningTurnPhaseLabel(List<ThreadActivityItem> items) {
  for (final item in items.reversed) {
    final presentation = item.presentation;
    if (presentation != null) {
      switch (presentation.entryKind) {
        case ThreadActivityPresentationEntryKind.read:
          return 'Reading files';
        case ThreadActivityPresentationEntryKind.search:
          return 'Searching';
        case ThreadActivityPresentationEntryKind.generic:
          break;
      }
    }

    switch (item.type) {
      case ThreadActivityItemType.fileChange:
        return 'Editing files';
      case ThreadActivityItemType.planUpdate:
        return 'Planning';
      case ThreadActivityItemType.terminalOutput:
        return 'Running commands';
      case ThreadActivityItemType.assistantOutput:
        return item.body.trim().isEmpty ? 'Thinking' : 'Writing';
      case ThreadActivityItemType.approvalRequest:
        return 'Waiting for approval';
      case ThreadActivityItemType.securityEvent:
        return 'Running checks';
      case ThreadActivityItemType.userPrompt:
      case ThreadActivityItemType.lifecycleUpdate:
      case ThreadActivityItemType.generic:
        break;
    }
  }

  return 'Thinking';
}

class _ChatLoadingMessageCard extends StatefulWidget {
  const _ChatLoadingMessageCard({
    required this.phaseLabel,
    required this.controlsEnabled,
    required this.isInterruptMutationInFlight,
    required this.onInterruptActiveTurn,
  });

  final String phaseLabel;
  final bool controlsEnabled;
  final bool isInterruptMutationInFlight;
  final Future<bool> Function() onInterruptActiveTurn;

  @override
  State<_ChatLoadingMessageCard> createState() =>
      _ChatLoadingMessageCardState();
}

class _ChatLoadingMessageCardState extends State<_ChatLoadingMessageCard>
    with SingleTickerProviderStateMixin {
  late final Timer _timer;
  final List<String> _frames = const <String>[
    '⠋',
    '⠙',
    '⠹',
    '⠸',
    '⠼',
    '⠴',
    '⠦',
    '⠧',
    '⠇',
    '⠏',
  ];
  final String _chars = r'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@#$*&%';
  final math.Random _random = math.Random();
  String _currentText = '';
  int _frameIndex = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 60), (_) {
      _generateRandomText();
    });
    _generateRandomText();
  }

  void _generateRandomText() {
    final length = 12 + _random.nextInt(10);
    final buffer = StringBuffer('${_frames[_frameIndex]} ');
    for (int i = 0; i < length; i++) {
      buffer.write(_chars[_random.nextInt(_chars.length)]);
    }
    setState(() {
      _currentText = buffer.toString();
      _frameIndex = (_frameIndex + 1) % _frames.length;
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('thread-running-indicator-card'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: AppTheme.surfaceZinc800.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Row(
        children: [
          PhosphorIcon(
            PhosphorIcons.sparkle(),
            color: AppTheme.textSubtle,
            size: 16,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.phaseLabel,
                  key: const Key('thread-running-phase-label'),
                  style: GoogleFonts.jetBrainsMono(
                    color: AppTheme.textMain,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _currentText,
                  key: const Key('thread-running-scramble'),
                  style: GoogleFonts.jetBrainsMono(
                    color: AppTheme.textMuted,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          TextButton.icon(
            key: const Key('turn-interrupt-button'),
            onPressed:
                widget.controlsEnabled && !widget.isInterruptMutationInFlight
                ? () async {
                    await widget.onInterruptActiveTurn();
                  }
                : null,
            style: TextButton.styleFrom(
              foregroundColor: AppTheme.rose,
              backgroundColor: AppTheme.rose.withValues(alpha: 0.08),
              disabledForegroundColor: AppTheme.textSubtle,
              disabledBackgroundColor: AppTheme.surfaceZinc800.withValues(
                alpha: 0.35,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              minimumSize: const Size(0, 40),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: AppTheme.rose.withValues(alpha: 0.16)),
              ),
            ),
            icon: widget.isInterruptMutationInFlight
                ? const SizedBox.square(
                    dimension: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : PhosphorIcon(PhosphorIcons.stop(), size: 16),
            label: Text(
              widget.isInterruptMutationInFlight ? 'Cancelling' : 'Cancel',
              style: GoogleFonts.jetBrainsMono(
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
