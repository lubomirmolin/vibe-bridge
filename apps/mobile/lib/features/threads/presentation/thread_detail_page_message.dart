part of 'thread_detail_page.dart';

class _ChatMessageCard extends StatelessWidget {
  const _ChatMessageCard({required this.item});

  final ThreadActivityItem item;

  @override
  Widget build(BuildContext context) {
    final isUser = item.type == ThreadActivityItemType.userPrompt;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: isUser
          ? BoxDecoration(
              color: AppTheme.surfaceZinc800.withOpacity(0.4),
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
              ],
            ),
            const SizedBox(height: 6),
          ],
          _ThreadMessageBody(
            body: item.body,
            imageUrls: item.messageImageUrls,
            textStyle: TextStyle(
              color: isUser
                  ? AppTheme.textMain
                  : AppTheme.textMain.withOpacity(0.9),
              fontSize: 14,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _ThreadMessageBody extends StatelessWidget {
  const _ThreadMessageBody({
    required this.body,
    required this.imageUrls,
    required this.textStyle,
  });

  final String body;
  final List<String> imageUrls;
  final TextStyle textStyle;

  @override
  Widget build(BuildContext context) {
    final segments = _MessageBodyParser.parse(body);
    if (segments.length == 1 && !segments.first.isCode && imageUrls.isEmpty) {
      return SelectableText(segments.first.content, style: textStyle);
    }

    final children = <Widget>[];
    if (body.isNotEmpty) {
      for (var index = 0; index < segments.length; index++) {
        final segment = segments[index];
        if (segment.isCode) {
          children.add(
            _ThreadCodeBlockViewer(
              code: segment.content,
              languageHint: segment.languageHint,
              filePathHint: segment.filePathHint,
            ),
          );
        } else if (segment.content.isNotEmpty) {
          children.add(SelectableText(segment.content, style: textStyle));
        }

        if (index < segments.length - 1) {
          children.add(const SizedBox(height: 10));
        }
      }
    }

    for (var index = 0; index < imageUrls.length; index++) {
      if (children.isNotEmpty) {
        children.add(const SizedBox(height: 10));
      }
      children.add(
        _ThreadMessageImage(imageUrl: imageUrls[index], index: index),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }
}

class _ThreadMessageImage extends StatelessWidget {
  const _ThreadMessageImage({required this.imageUrl, required this.index});

  final String imageUrl;
  final int index;

  @override
  Widget build(BuildContext context) {
    final imageWidget = _buildImage();
    if (imageWidget == null) {
      return const SizedBox.shrink();
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Container(
        key: Key('thread-message-image-$index'),
        constraints: const BoxConstraints(maxHeight: 320),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.25),
          border: Border.all(color: Colors.white.withOpacity(0.08)),
          borderRadius: BorderRadius.circular(12),
        ),
        child: imageWidget,
      ),
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
      return Image.memory(bytes, fit: BoxFit.contain, gaplessPlayback: true);
    }

    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return Image.network(
        trimmed,
        fit: BoxFit.contain,
        errorBuilder: (context, error, stackTrace) => const SizedBox.shrink(),
      );
    }

    return null;
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
    final gutterWidth = ((digits * 10) + 24).toDouble();
    final language =
        _CodeLanguageResolver.normalize(languageHint) ??
        _CodeLanguageResolver.fromFilePath(filePathHint);
    final fileName = _CodeLanguageResolver.displayName(filePathHint);
    final languageLabel = _CodeLanguageResolver.label(language);
    final showHeader = fileName != null || languageLabel != null;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.35),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showHeader)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.03),
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
                        color: AppTheme.surfaceZinc800.withOpacity(0.9),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.08),
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
          FutureBuilder<_ThreadCodeHighlighterSet>(
            future: _ThreadCodeHighlighterSet.load(),
            builder: (context, snapshot) {
              final highlighted = language == null
                  ? null
                  : snapshot.data?.highlight(language, code);
              final codeStyle = GoogleFonts.jetBrainsMono(
                color: AppTheme.textMuted,
                fontSize: 11.5,
                height: 1.4,
              );

              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
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
                    const SizedBox(width: 12),
                    Container(
                      width: 1,
                      height: 18.0 * lineCount,
                      color: Colors.white.withOpacity(0.08),
                    ),
                    const SizedBox(width: 12),
                    SelectableText.rich(
                      highlighted == null
                          ? TextSpan(text: code, style: codeStyle)
                          : TextSpan(style: codeStyle, children: [highlighted]),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  String _lineNumbers(int lineCount) {
    final buffer = StringBuffer();
    for (var line = 1; line <= lineCount; line++) {
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

  static Future<_ThreadCodeHighlighterSet> load() async {
    await _init;
    final darkTheme = await (_darkThemeFuture ??=
        HighlighterTheme.loadDarkTheme());
    return _ThreadCodeHighlighterSet._(darkTheme: darkTheme);
  }

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
      return <_MessageSegment>[_MessageSegment.text(body)];
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

class _MessageSegment {
  const _MessageSegment._({
    required this.content,
    required this.isCode,
    this.languageHint,
    this.filePathHint,
  });

  factory _MessageSegment.text(String content) {
    return _MessageSegment._(content: content, isCode: false);
  }

  factory _MessageSegment.code(
    String content,
    String? languageHint, {
    String? filePathHint,
  }) {
    return _MessageSegment._(
      content: content,
      isCode: true,
      languageHint: languageHint,
      filePathHint: filePathHint,
    );
  }

  final String content;
  final bool isCode;
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
