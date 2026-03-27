import 'package:vibe_bridge/features/threads/domain/parsed_command_output.dart';
import 'package:codex_ui/codex_ui.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:syntax_highlight/syntax_highlight.dart';

class ThreadDiffViewer extends StatelessWidget {
  const ThreadDiffViewer({
    super.key,
    required this.document,
    this.fileFilter,
    this.controller,
  });

  final ParsedDiffDocument document;
  final String? fileFilter;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    final filteredFiles = document.files
        .where((file) => fileFilter == null || file.path == fileFilter)
        .toList(growable: false);

    return FutureBuilder<ThreadCodeHighlighterSet>(
      future: ThreadCodeHighlighterSet.load(),
      builder: (context, snapshot) {
        final highlighterSet = snapshot.data;
        return ListView.separated(
          key: const Key('thread-git-diff-list'),
          controller: controller,
          padding: EdgeInsets.zero,
          itemCount: filteredFiles.length,
          itemBuilder: (context, index) => _ThreadDiffFileSection(
            file: filteredFiles[index],
            highlighterSet: highlighterSet,
          ),
          separatorBuilder: (context, index) => const SizedBox(height: 12),
        );
      },
    );
  }
}

class ThreadCodeHighlighterSet {
  ThreadCodeHighlighterSet._({required this.darkTheme});

  static final Future<void> _init = Highlighter.initialize(
    CodeLanguageResolver.supportedLanguages.toList(growable: false),
  );
  static Future<HighlighterTheme>? _darkThemeFuture;
  static final Map<String, Highlighter> _highlighters = <String, Highlighter>{};

  static Future<ThreadCodeHighlighterSet> load() async {
    await _init;
    final darkTheme = await (_darkThemeFuture ??=
        HighlighterTheme.loadDarkTheme());
    return ThreadCodeHighlighterSet._(darkTheme: darkTheme);
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

class CodeLanguageResolver {
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
    if (normalized.endsWith('.dart')) return 'dart';
    if (normalized.endsWith('.ts') || normalized.endsWith('.tsx')) {
      return 'typescript';
    }
    if (normalized.endsWith('.js') ||
        normalized.endsWith('.jsx') ||
        normalized.endsWith('.mjs') ||
        normalized.endsWith('.cjs')) {
      return 'javascript';
    }
    if (normalized.endsWith('.json')) return 'json';
    if (normalized.endsWith('.yaml') || normalized.endsWith('.yml')) {
      return 'yaml';
    }
    if (normalized.endsWith('.kt') || normalized.endsWith('.kts')) {
      return 'kotlin';
    }
    if (normalized.endsWith('.swift')) return 'swift';
    if (normalized.endsWith('.java')) return 'java';
    if (normalized.endsWith('.rs')) return 'rust';
    if (normalized.endsWith('.py')) return 'python';
    if (normalized.endsWith('.go')) return 'go';
    if (normalized.endsWith('.sql')) return 'sql';
    if (normalized.endsWith('.css')) return 'css';
    if (normalized.endsWith('.html') || normalized.endsWith('.htm')) {
      return 'html';
    }
    return null;
  }

  static String? displayName(String? path) {
    if (path == null || path.trim().isEmpty) {
      return null;
    }
    final normalized = path.trim().replaceAll('\\', '/');
    final segments = normalized.split('/');
    return segments.isEmpty ? normalized : segments.last;
  }
}

class _ThreadDiffFileSection extends StatelessWidget {
  const _ThreadDiffFileSection({
    required this.file,
    required this.highlighterSet,
  });

  final ParsedDiffFile file;
  final ThreadCodeHighlighterSet? highlighterSet;

  @override
  Widget build(BuildContext context) {
    final language = CodeLanguageResolver.fromFilePath(file.path);
    final fileName = CodeLanguageResolver.displayName(file.path) ?? file.path;
    final changeLabel = _labelForChangeType(file.changeType);
    final visibleLines = file.lines
        .where((line) => line.kind != ParsedDiffLineKind.hunk)
        .toList(growable: false);
    final gutterWidth = _gutterWidthForLines(visibleLines);

    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.05)),
          bottom: BorderSide(color: Colors.white.withValues(alpha: 0.05)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 12, 2, 10),
            child: Wrap(
              spacing: 10,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  fileName,
                  key: Key('thread-git-diff-file-$fileName'),
                  style: GoogleFonts.jetBrainsMono(
                    color: AppTheme.textMain,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  '+${file.additions}',
                  style: GoogleFonts.jetBrainsMono(
                    color: AppTheme.emerald,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  '-${file.deletions}',
                  style: GoogleFonts.jetBrainsMono(
                    color: AppTheme.rose,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  changeLabel,
                  style: GoogleFonts.jetBrainsMono(
                    color: AppTheme.textSubtle,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          LayoutBuilder(
            builder: (context, constraints) {
              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minWidth: constraints.maxWidth),
                    child: IntrinsicWidth(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (
                            var index = 0;
                            index < visibleLines.length;
                            index += 1
                          )
                            _ThreadDiffLineRow(
                              key: Key('thread-diff-line-$fileName-$index'),
                              line: visibleLines[index],
                              language: language,
                              highlighterSet: highlighterSet,
                              displayLineNumber: _displayLineNumber(
                                visibleLines[index],
                                file.changeType,
                              ),
                              gutterWidth: gutterWidth,
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  static String _labelForChangeType(ParsedDiffChangeType changeType) {
    switch (changeType) {
      case ParsedDiffChangeType.added:
        return 'Added';
      case ParsedDiffChangeType.deleted:
        return 'Deleted';
      case ParsedDiffChangeType.modified:
        return 'Modified';
    }
  }

  static int? _displayLineNumber(
    ParsedDiffLine line,
    ParsedDiffChangeType changeType,
  ) {
    if (changeType == ParsedDiffChangeType.deleted) {
      return line.oldLineNumber;
    }
    return line.newLineNumber;
  }

  static double _gutterWidthForLines(List<ParsedDiffLine> lines) {
    var digits = 1;
    for (final line in lines) {
      final length =
          (line.newLineNumber ?? line.oldLineNumber)?.toString().length ?? 0;
      if (length > digits) {
        digits = length;
      }
    }
    if (digits <= 1) return 22;
    if (digits == 2) return 30;
    return (digits * 8 + 12).toDouble();
  }
}

class _ThreadDiffLineRow extends StatelessWidget {
  const _ThreadDiffLineRow({
    super.key,
    required this.line,
    required this.language,
    required this.highlighterSet,
    required this.displayLineNumber,
    required this.gutterWidth,
  });

  final ParsedDiffLine line;
  final String? language;
  final ThreadCodeHighlighterSet? highlighterSet;
  final int? displayLineNumber;
  final double gutterWidth;

  @override
  Widget build(BuildContext context) {
    final backgroundColor = _backgroundColorForLine(line.kind);
    final accentColor = _accentColorForLine(line.kind);
    final textStyle = GoogleFonts.jetBrainsMono(
      color: _textColorForLine(line.kind),
      fontSize: 11.5,
      height: 1.4,
    );

    return SizedBox(
      width: double.infinity,
      child: DecoratedBox(
        decoration: BoxDecoration(color: backgroundColor),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 420),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(width: 3, height: 24, color: accentColor),
              _DiffLineNumberCell(
                number: displayLineNumber,
                width: gutterWidth,
              ),
              Container(
                width: 1,
                height: 24,
                color: Colors.white.withValues(alpha: 0.06),
              ),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 8),
                child: line.kind == ParsedDiffLineKind.hunk
                    ? Text(
                        line.text,
                        style: GoogleFonts.jetBrainsMono(
                          color: AppTheme.textSubtle,
                          fontSize: 10.5,
                          height: 1.4,
                        ),
                      )
                    : RichText(text: _highlightedLine(textStyle)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  TextSpan _highlightedLine(TextStyle textStyle) {
    final highlighted = language == null
        ? null
        : highlighterSet?.highlight(language!, line.text);
    return highlighted == null
        ? TextSpan(text: line.text, style: textStyle)
        : TextSpan(style: textStyle, children: [highlighted]);
  }

  Color _backgroundColorForLine(ParsedDiffLineKind kind) {
    switch (kind) {
      case ParsedDiffLineKind.addition:
        return AppTheme.emerald.withValues(alpha: 0.12);
      case ParsedDiffLineKind.deletion:
        return AppTheme.rose.withValues(alpha: 0.14);
      case ParsedDiffLineKind.hunk:
        return Colors.white.withValues(alpha: 0.04);
      case ParsedDiffLineKind.context:
        return Colors.transparent;
    }
  }

  Color _accentColorForLine(ParsedDiffLineKind kind) {
    switch (kind) {
      case ParsedDiffLineKind.addition:
        return AppTheme.emerald.withValues(alpha: 0.85);
      case ParsedDiffLineKind.deletion:
        return AppTheme.rose.withValues(alpha: 0.85);
      case ParsedDiffLineKind.hunk:
        return Colors.white.withValues(alpha: 0.18);
      case ParsedDiffLineKind.context:
        return Colors.transparent;
    }
  }

  Color _textColorForLine(ParsedDiffLineKind kind) {
    switch (kind) {
      case ParsedDiffLineKind.addition:
      case ParsedDiffLineKind.deletion:
      case ParsedDiffLineKind.context:
        return AppTheme.textMain;
      case ParsedDiffLineKind.hunk:
        return AppTheme.textSubtle;
    }
  }
}

class _DiffLineNumberCell extends StatelessWidget {
  const _DiffLineNumberCell({required this.number, required this.width});

  final int? number;
  final double width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Padding(
        padding: const EdgeInsets.only(top: 4, right: 6),
        child: Text(
          number?.toString() ?? '',
          textAlign: TextAlign.right,
          style: GoogleFonts.jetBrainsMono(
            color: AppTheme.textSubtle,
            fontSize: 10.5,
            height: 1.4,
          ),
        ),
      ),
    );
  }
}
