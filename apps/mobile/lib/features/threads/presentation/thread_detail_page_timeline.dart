part of 'thread_detail_page.dart';

class _ThreadActivityCard extends StatelessWidget {
  const _ThreadActivityCard({required this.item, this.exploration});

  final ThreadActivityItem item;
  final ThreadTimelineExplorationSummary? exploration;

  @override
  Widget build(BuildContext context) {
    final parsedContent = item.parsedCommandOutput;
    Widget content;

    if (parsedContent != null) {
      if (parsedContent.isStatusOnlyFileList ||
          _isHiddenInternalToolCommand(parsedContent)) {
        return const SizedBox.shrink();
      }
      if (parsedContent.hasDiffBlock) {
        content = Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: _CollapsibleFileChangeCard(item: item, parsed: parsedContent),
        );
      } else {
        content = Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: _CollapsibleTerminalCard(item: item, parsed: parsedContent),
        );
      }
    } else if (item.type == ThreadActivityItemType.assistantOutput ||
        item.type == ThreadActivityItemType.userPrompt) {
      content = Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: _ChatMessageCard(item: item),
      );
    } else {
      Color borderColor;
      Color iconColor;
      PhosphorIcon icon;

      switch (item.type) {
        case ThreadActivityItemType.approvalRequest:
          borderColor = AppTheme.amber.withValues(alpha: 0.3);
          iconColor = AppTheme.amber;
          icon = PhosphorIcon(
            PhosphorIcons.shieldWarning(),
            color: iconColor,
            size: 16,
          );
          break;
        case ThreadActivityItemType.securityEvent:
          borderColor = AppTheme.rose.withValues(alpha: 0.3);
          iconColor = AppTheme.rose;
          icon = PhosphorIcon(
            PhosphorIcons.warning(),
            color: iconColor,
            size: 16,
          );
          break;
        case ThreadActivityItemType.fileChange:
          borderColor = Colors.white.withValues(alpha: 0.1);
          iconColor = AppTheme.textSubtle;
          icon = PhosphorIcon(
            PhosphorIcons.fileCode(),
            color: iconColor,
            size: 16,
          );
          break;
        case ThreadActivityItemType.planUpdate:
          borderColor = AppTheme.emerald.withValues(alpha: 0.3);
          iconColor = AppTheme.emerald;
          icon = PhosphorIcon(
            PhosphorIcons.listChecks(),
            color: iconColor,
            size: 16,
          );
          break;
        default:
          borderColor = Colors.white.withValues(alpha: 0.1);
          iconColor = AppTheme.textSubtle;
          icon = PhosphorIcon(
            PhosphorIcons.lightning(),
            color: iconColor,
            size: 16,
          );
          break;
      }

      content = Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        decoration: BoxDecoration(
          color: AppTheme.surfaceZinc800.withValues(alpha: 0.3),
          border: Border(left: BorderSide(color: borderColor, width: 3)),
          borderRadius: const BorderRadius.only(
            topRight: Radius.circular(12),
            bottomRight: Radius.circular(12),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                icon,
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    item.title,
                    style: GoogleFonts.jetBrainsMono(
                      color: iconColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Text(
                  item.occurredAt,
                  style: GoogleFonts.jetBrainsMono(
                    color: AppTheme.textSubtle,
                    fontSize: 10,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SelectableText(
              item.body,
              style: const TextStyle(color: AppTheme.textMain, fontSize: 14),
            ),
          ],
        ),
      );
    }

    final explorationSummary = exploration;
    if (explorationSummary == null) {
      return content;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        content,
        _ExploredFilesCard(exploration: explorationSummary),
      ],
    );
  }
}

bool _isHiddenInternalToolCommand(ParsedCommandOutput parsed) {
  final normalizedCommand = parsed.command?.trim().toLowerCase();
  if (normalizedCommand != null && normalizedCommand.isNotEmpty) {
    return false;
  }

  final normalizedBody = parsed.outputBody.trim().toLowerCase();
  return _hiddenInternalToolCommands.contains(normalizedBody);
}

const Set<String> _hiddenInternalToolCommands = <String>{
  'apply_patch',
  'browser_click',
  'browser_close',
  'browser_console_messages',
  'browser_drag',
  'browser_evaluate',
  'browser_file_upload',
  'browser_fill_form',
  'browser_handle_dialog',
  'browser_hover',
  'browser_install',
  'browser_navigate',
  'browser_navigate_back',
  'browser_network_requests',
  'browser_press_key',
  'browser_resize',
  'browser_run_code',
  'browser_select_option',
  'browser_snapshot',
  'browser_tabs',
  'browser_take_screenshot',
  'browser_type',
  'browser_wait_for',
  'close_agent',
  'exec_command',
  'list_mcp_resource_templates',
  'list_mcp_resources',
  'read_mcp_resource',
  'read_thread_terminal',
  'request_user_input',
  'resume_agent',
  'send_input',
  'spawn_agent',
  'update_plan',
  'wait_agent',
  'write_stdin',
};

String? _workedForLabel(double? wallTimeSeconds) {
  if (wallTimeSeconds == null || wallTimeSeconds <= 0) {
    return null;
  }

  final roundedSeconds = wallTimeSeconds.round();
  if (roundedSeconds < 60) {
    return 'Worked for ${roundedSeconds}s';
  }

  final minutes = roundedSeconds ~/ 60;
  final seconds = roundedSeconds % 60;
  if (seconds == 0) {
    return 'Worked for ${minutes}m';
  }
  return 'Worked for ${minutes}m ${seconds}s';
}

class _CollapsibleTerminalCard extends StatefulWidget {
  const _CollapsibleTerminalCard({required this.item, required this.parsed});

  final ThreadActivityItem item;
  final ParsedCommandOutput parsed;

  @override
  State<_CollapsibleTerminalCard> createState() =>
      _CollapsibleTerminalCardState();
}

class _CollapsibleTerminalCardState extends State<_CollapsibleTerminalCard> {
  bool _isExpanded = false;

  @override
  Widget build(BuildContext context) {
    final commandStr = widget.parsed.terminalDisplayTitle;
    final outputBody = widget.parsed.terminalDisplayBody;
    final isSuccess = widget.parsed.isSuccess;
    final isBackgroundTerminal =
        widget.parsed.backgroundTerminalSummary != null;
    final workedForLabel = _workedForLabel(widget.parsed.wallTimeSeconds);
    final cardDecoration = isBackgroundTerminal
        ? BoxDecoration(
            color: AppTheme.surfaceZinc900.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(10),
          )
        : BoxDecoration(
            color: AppTheme.background,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          );

    return Container(
      decoration: cardDecoration,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _isExpanded = !_isExpanded),
            borderRadius: BorderRadius.circular(isBackgroundTerminal ? 10 : 12),
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                12,
                isBackgroundTerminal ? 14 : 12,
                12,
                isBackgroundTerminal ? 14 : 12,
              ),
              child: Row(
                children: [
                  PhosphorIcon(
                    PhosphorIcons.terminalWindow(),
                    color: isBackgroundTerminal
                        ? AppTheme.textMuted
                        : AppTheme.textSubtle,
                    size: isBackgroundTerminal ? 15 : 16,
                  ),
                  SizedBox(width: isBackgroundTerminal ? 12 : 8),
                  if (!isBackgroundTerminal) ...[
                    Text(
                      '\$',
                      style: GoogleFonts.jetBrainsMono(
                        color: AppTheme.textMuted,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  Expanded(
                    child: Text(
                      commandStr,
                      key: isBackgroundTerminal
                          ? const Key('thread-terminal-background-summary')
                          : null,
                      style: isBackgroundTerminal
                          ? const TextStyle(
                              color: AppTheme.textMain,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              height: 1.25,
                            )
                          : GoogleFonts.jetBrainsMono(
                              color: AppTheme.textMain,
                              fontSize: 13,
                            ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (widget.parsed.exitCode != null)
                    Icon(
                      isSuccess
                          ? Icons.check_circle_rounded
                          : Icons.cancel_rounded,
                      color: isSuccess ? AppTheme.emerald : AppTheme.rose,
                      size: 16,
                    ),
                  const SizedBox(width: 8),
                  PhosphorIcon(
                    _isExpanded
                        ? PhosphorIcons.caretUp()
                        : PhosphorIcons.caretDown(),
                    color: AppTheme.textSubtle,
                    size: 16,
                  ),
                ],
              ),
            ),
          ),
          if (_isExpanded && outputBody.isNotEmpty) ...[
            Divider(
              height: 1,
              color: isBackgroundTerminal
                  ? Colors.white.withValues(alpha: 0.05)
                  : Colors.white10,
            ),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isBackgroundTerminal
                    ? Colors.transparent
                    : Colors.black.withValues(alpha: 0.2),
                borderRadius: const BorderRadius.only(
                  bottomLeft: Radius.circular(12),
                  bottomRight: Radius.circular(12),
                ),
              ),
              child: SelectableText(
                outputBody,
                key: isBackgroundTerminal
                    ? const Key('thread-terminal-background-details')
                    : null,
                style: GoogleFonts.jetBrainsMono(
                  color: isBackgroundTerminal
                      ? AppTheme.textSubtle
                      : AppTheme.textMuted,
                  fontSize: isBackgroundTerminal ? 11.5 : 12,
                  height: 1.45,
                ),
              ),
            ),
          ],
          if (workedForLabel != null) ...[
            Divider(
              height: 1,
              color: isBackgroundTerminal
                  ? Colors.white.withValues(alpha: 0.05)
                  : Colors.white10,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Container(
                      height: 1,
                      color: Colors.white.withValues(alpha: 0.06),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: Text(
                      workedForLabel,
                      key: const Key('thread-worked-for-summary'),
                      style: const TextStyle(
                        color: AppTheme.textMuted,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Container(
                      height: 1,
                      color: Colors.white.withValues(alpha: 0.06),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ExploredFilesCard extends StatefulWidget {
  const _ExploredFilesCard({required this.exploration});

  final ThreadTimelineExplorationSummary exploration;

  @override
  State<_ExploredFilesCard> createState() => _ExploredFilesCardState();
}

class _ExploredFilesCardState extends State<_ExploredFilesCard> {
  bool _isExpanded = true;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _isExpanded = !_isExpanded),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Text(
                    widget.exploration.label,
                    key: const Key('thread-explored-files-summary'),
                    style: const TextStyle(
                      color: AppTheme.textSubtle,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(width: 8),
                  PhosphorIcon(
                    _isExpanded
                        ? PhosphorIcons.caretDown()
                        : PhosphorIcons.caretRight(),
                    color: AppTheme.textSubtle,
                    size: 14,
                  ),
                ],
              ),
            ),
          ),
          if (_isExpanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: widget.exploration.files
                    .map(
                      (file) => Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          file,
                          style: const TextStyle(
                            color: AppTheme.textMuted,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    )
                    .toList(growable: false),
              ),
            ),
        ],
      ),
    );
  }
}

class _CollapsibleFileChangeCard extends StatefulWidget {
  const _CollapsibleFileChangeCard({required this.item, required this.parsed});

  final ThreadActivityItem item;
  final ParsedCommandOutput parsed;

  @override
  State<_CollapsibleFileChangeCard> createState() =>
      _CollapsibleFileChangeCardState();
}

class _CollapsibleFileChangeCardState
    extends State<_CollapsibleFileChangeCard> {
  bool _isExpanded = false;

  @override
  Widget build(BuildContext context) {
    final diffDocument = widget.parsed.diffDocument;
    final fileCount = diffDocument?.files.length ?? 0;
    final fileName = widget.parsed.diffPath ?? 'unknown file';
    final adds = widget.parsed.diffAdditions;
    final dels = widget.parsed.diffDeletions;
    final primaryChangeType = fileCount == 1
        ? diffDocument?.files.first.changeType
        : null;
    final titlePrefix = _titleForSummary(
      fileCount: fileCount,
      changeType: primaryChangeType,
    );

    return Container(
      decoration: BoxDecoration(
        color: AppTheme.surfaceZinc800.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _isExpanded = !_isExpanded),
            key: Key('thread-file-change-toggle-$fileName'),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  PhosphorIcon(
                    PhosphorIcons.fileCode(),
                    color: AppTheme.textSubtle,
                    size: 16,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: RichText(
                      text: TextSpan(
                        style: const TextStyle(
                          fontSize: 13,
                          color: AppTheme.textMain,
                        ),
                        children: [
                          TextSpan(text: titlePrefix),
                          if (fileCount <= 1) ...[
                            const TextSpan(text: ' '),
                            TextSpan(
                              text: fileName,
                              style: GoogleFonts.jetBrainsMono(
                                color: AppTheme.textMain,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ] else
                            TextSpan(
                              text: ' ($fileCount)',
                              style: GoogleFonts.jetBrainsMono(
                                color: AppTheme.textMuted,
                              ),
                            ),
                          TextSpan(
                            text: '  +$adds',
                            style: GoogleFonts.jetBrainsMono(
                              color: AppTheme.emerald,
                            ),
                          ),
                          TextSpan(
                            text: ' -$dels',
                            style: GoogleFonts.jetBrainsMono(
                              color: AppTheme.rose,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  PhosphorIcon(
                    _isExpanded
                        ? PhosphorIcons.caretUp()
                        : PhosphorIcons.caretDown(),
                    color: AppTheme.textSubtle,
                    size: 16,
                  ),
                ],
              ),
            ),
          ),
          if (_isExpanded) ...[
            const Divider(height: 1, color: Colors.white10),
            Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.3),
                borderRadius: const BorderRadius.only(
                  bottomLeft: Radius.circular(12),
                  bottomRight: Radius.circular(12),
                ),
              ),
              child: diffDocument == null
                  ? _ThreadCodeBlockViewer(
                      code: widget.parsed.outputBody,
                      languageHint: _CodeLanguageResolver.fromFilePath(
                        widget.parsed.diffPath,
                      ),
                    )
                  : _ThreadDiffViewer(document: diffDocument),
            ),
          ],
        ],
      ),
    );
  }

  String _titleForSummary({
    required int fileCount,
    required ParsedDiffChangeType? changeType,
  }) {
    if (fileCount > 1) {
      return 'Edited files';
    }

    switch (changeType) {
      case ParsedDiffChangeType.added:
        return 'Created file';
      case ParsedDiffChangeType.deleted:
        return 'Deleted file';
      case ParsedDiffChangeType.modified:
      case null:
        return 'Edited file';
    }
  }
}

class _ThreadDiffViewer extends StatelessWidget {
  const _ThreadDiffViewer({required this.document});

  final ParsedDiffDocument document;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_ThreadCodeHighlighterSet>(
      future: _ThreadCodeHighlighterSet.load(),
      builder: (context, snapshot) {
        final highlighterSet = snapshot.data;
        final fileWidgets = <Widget>[];

        for (var index = 0; index < document.files.length; index++) {
          if (index > 0) {
            fileWidgets.add(const SizedBox(height: 12));
          }
          fileWidgets.add(
            _ThreadDiffFileSection(
              file: document.files[index],
              highlighterSet: highlighterSet,
            ),
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: fileWidgets,
        );
      },
    );
  }
}

class _ThreadDiffFileSection extends StatelessWidget {
  const _ThreadDiffFileSection({
    required this.file,
    required this.highlighterSet,
  });

  final ParsedDiffFile file;
  final _ThreadCodeHighlighterSet? highlighterSet;

  @override
  Widget build(BuildContext context) {
    final language = _CodeLanguageResolver.fromFilePath(file.path);
    final fileName = _CodeLanguageResolver.displayName(file.path) ?? file.path;
    final changeLabel = _labelForChangeType(file.changeType);
    final visibleLines = file.lines
        .where((line) => line.kind != ParsedDiffLineKind.hunk)
        .toList(growable: false);
    final gutterWidth = _gutterWidthForLines(visibleLines);

    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
                Text(
                  fileName,
                  key: Key('thread-diff-file-$fileName'),
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
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.surfaceZinc800.withValues(alpha: 0.8),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.08),
                    ),
                  ),
                  child: Text(
                    changeLabel,
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
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: visibleLines
                    .map(
                      (line) => _ThreadDiffLineRow(
                        line: line,
                        language: language,
                        highlighterSet: highlighterSet,
                        displayLineNumber: _displayLineNumber(line),
                        gutterWidth: gutterWidth,
                      ),
                    )
                    .toList(growable: false),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _labelForChangeType(ParsedDiffChangeType changeType) {
    switch (changeType) {
      case ParsedDiffChangeType.added:
        return 'Added';
      case ParsedDiffChangeType.deleted:
        return 'Deleted';
      case ParsedDiffChangeType.modified:
        return 'Modified';
    }
  }

  int? _displayLineNumber(ParsedDiffLine line) {
    if (file.changeType == ParsedDiffChangeType.deleted) {
      return line.oldLineNumber;
    }
    return line.newLineNumber;
  }

  double _gutterWidthForLines(List<ParsedDiffLine> lines) {
    var digits = 1;
    for (final line in lines) {
      final length = _displayLineNumber(line)?.toString().length ?? 0;
      if (length > digits) {
        digits = length;
      }
    }
    if (digits <= 1) {
      return 22;
    }
    if (digits == 2) {
      return 30;
    }
    return (digits * 8 + 12).toDouble();
  }
}

class _ThreadDiffLineRow extends StatelessWidget {
  const _ThreadDiffLineRow({
    required this.line,
    required this.language,
    required this.highlighterSet,
    required this.displayLineNumber,
    required this.gutterWidth,
  });

  final ParsedDiffLine line;
  final String? language;
  final _ThreadCodeHighlighterSet? highlighterSet;
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

    return Container(
      constraints: const BoxConstraints(minWidth: 420),
      color: backgroundColor,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(width: 3, height: 24, color: accentColor),
          _DiffLineNumberCell(number: displayLineNumber, width: gutterWidth),
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
