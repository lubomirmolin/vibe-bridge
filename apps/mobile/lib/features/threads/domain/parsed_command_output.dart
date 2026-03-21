import 'package:flutter/foundation.dart';

@immutable
class ParsedCommandOutput {
  const ParsedCommandOutput({
    required this.command,
    required this.exitCode,
    required this.outputBody,
    required this.hasDiffBlock,
    required this.isStatusOnlyFileList,
    this.wallTimeSeconds,
    this.diffDocument,
    this.diffPath,
    this.diffAdditions = 0,
    this.diffDeletions = 0,
  });

  final String? command;
  final int? exitCode;
  final String outputBody;
  final double? wallTimeSeconds;

  final bool hasDiffBlock;
  final bool isStatusOnlyFileList;
  final ParsedDiffDocument? diffDocument;
  final String? diffPath;
  final int diffAdditions;
  final int diffDeletions;

  bool get isSuccess => exitCode == 0;
  String? get backgroundTerminalSummary {
    if (!outputBody.startsWith('Background terminal ')) {
      return null;
    }
    final newlineIndex = outputBody.indexOf('\n');
    return newlineIndex == -1
        ? outputBody
        : outputBody.substring(0, newlineIndex);
  }

  String get terminalDisplayTitle =>
      backgroundTerminalSummary ?? command ?? 'Unknown command';

  String get terminalDisplayBody {
    final summary = backgroundTerminalSummary;
    if (summary == null) {
      return outputBody;
    }
    final bodyLines = outputBody.split('\n');
    if (bodyLines.length <= 1) {
      return outputBody;
    }
    return bodyLines.skip(1).join('\n').trim();
  }

  static ParsedCommandOutput parse(String rawOutput) {
    String? command;
    int? exitCode;
    double? wallTimeSeconds;
    String body = rawOutput.trim();

    // Check for standard Antigravity bash output format
    // Format is typically:
    // Command: ...
    // Chunk ID: ...
    // Wall time: ...
    // Process exited with code X
    // Original token count: ...
    // Output:
    // <actual output>

    // Also check for Antigravity replace_file_content format:
    // The following changes were made by the multi_replace_file_content tool to: /path/to/target.dart
    // [diff_block_start]
    // ...
    // [diff_block_end]

    final commandMatch = RegExp(
      r'^Command:\s*(.+)$',
      multiLine: true,
    ).firstMatch(rawOutput);
    final exitCodeMatch = RegExp(
      r'^Process exited with code\s+(\d+)$',
      multiLine: true,
    ).firstMatch(rawOutput);
    final outputStartMatch = RegExp(
      r'^Output:\s*$',
      multiLine: true,
    ).firstMatch(rawOutput);
    final wallTimeMatch = RegExp(
      r'^Wall time:\s+([0-9]+(?:\.[0-9]+)?)\s+seconds$',
      multiLine: true,
    ).firstMatch(rawOutput);

    if (commandMatch != null) {
      command = commandMatch.group(1)?.trim();

      // Clean up the command if it's a zsh -lc wrapper
      if (command != null && command.isNotEmpty) {
        command = _unwrapZshCommand(command);
      }
    }

    // Fallback for bridge command outputs where the first line is a
    // markdown-style command, e.g. `/bin/zsh -lc 'dart format ...'`.
    if (command == null && body.isNotEmpty) {
      final lines = body.split('\n');
      final firstLine = lines.first.trim();
      final inlineMatch = RegExp(r'^`([^`]+)`?$').firstMatch(firstLine);
      final inlineCommand = inlineMatch?.group(1)?.trim();
      if (inlineCommand != null && inlineCommand.isNotEmpty) {
        command = _unwrapZshCommand(inlineCommand);
        body = lines.skip(1).join('\n').trim();
      }
    }

    if (exitCodeMatch != null) {
      exitCode = int.tryParse(exitCodeMatch.group(1) ?? '');
    }

    if (wallTimeMatch != null) {
      wallTimeSeconds = double.tryParse(wallTimeMatch.group(1) ?? '');
    }

    if (outputStartMatch != null) {
      body = rawOutput.substring(outputStartMatch.end).trim();
    }

    // Now look for diff blocks
    bool hasDiffBlock = false;
    bool isStatusOnlyFileList = false;
    ParsedDiffDocument? diffDocument;
    String? diffPath;
    int diffAdditions = 0;
    int diffDeletions = 0;

    final diffStart = body.indexOf('[diff_block_start]');
    final diffEnd = body.indexOf('[diff_block_end]');

    if (diffStart != -1 && diffEnd != -1 && diffEnd > diffStart) {
      final diffText = body
          .substring(diffStart + '[diff_block_start]'.length, diffEnd)
          .trim();

      // Find the file path from the preamble before the diff block
      final preamble = body.substring(0, diffStart);
      final pathMatch = RegExp(
        r'to:\s*([^\s]+)$',
        multiLine: true,
      ).firstMatch(preamble.trim());
      if (pathMatch != null) {
        diffPath = pathMatch.group(1);
        final parts = diffPath!.split('/');
        if (parts.isNotEmpty) diffPath = parts.last;
      }

      // Clean the body to just contain the clean diff for the UI to consume
      body = diffText;
      diffDocument = ParsedDiffDocument.parse(body);
      if (diffDocument != null) {
        hasDiffBlock = true;
        diffAdditions = diffDocument.totalAdditions;
        diffDeletions = diffDocument.totalDeletions;
        diffPath = diffPath ?? diffDocument.primaryPath;
      }
    }

    // Fall back to Codex apply_patch style diffs.
    if (!hasDiffBlock) {
      final patchStart = body.indexOf('*** Begin Patch');
      final patchEnd = body.indexOf('*** End Patch');
      if (patchStart != -1) {
        final patchBody = body
            .substring(
              patchStart,
              patchEnd == -1 ? body.length : patchEnd + '*** End Patch'.length,
            )
            .trim();
        final parsedPatch = ParsedDiffDocument.parse(patchBody);
        if (parsedPatch != null) {
          body = patchBody;
          diffDocument = parsedPatch;
          hasDiffBlock = true;
          diffAdditions = parsedPatch.totalAdditions;
          diffDeletions = parsedPatch.totalDeletions;
          diffPath = parsedPatch.primaryPath;
        }
      }
    }

    // Fall back to git-style diffs.
    if (!hasDiffBlock) {
      final parsedGitDiff = ParsedDiffDocument.parse(body);
      if (parsedGitDiff != null && parsedGitDiff.files.isNotEmpty) {
        diffDocument = parsedGitDiff;
        hasDiffBlock = true;
        diffPath = parsedGitDiff.primaryPath;
        diffAdditions = parsedGitDiff.totalAdditions;
        diffDeletions = parsedGitDiff.totalDeletions;
      }
    }

    // Fall back to git-status style changed file rows.
    if (!hasDiffBlock) {
      final statusMatches = RegExp(
        r'^(?:\s?[MADRCU?]{1,2})\s+(.+)$',
        multiLine: true,
      ).allMatches(body).toList(growable: false);
      if (statusMatches.isNotEmpty) {
        isStatusOnlyFileList = true;
        diffPath = statusMatches.first.group(1)?.trim();
        body = statusMatches
            .map((match) => match.group(0)!.trimRight())
            .join('\n');
      }
    }

    if (diffPath != null && diffPath.isNotEmpty) {
      final parts = diffPath.split('/');
      if (parts.isNotEmpty) {
        diffPath = parts.last;
      }
    }

    return ParsedCommandOutput(
      command: command,
      exitCode: exitCode,
      outputBody: body,
      hasDiffBlock: hasDiffBlock,
      isStatusOnlyFileList: isStatusOnlyFileList,
      wallTimeSeconds: wallTimeSeconds,
      diffDocument: diffDocument,
      diffPath: diffPath,
      diffAdditions: diffAdditions,
      diffDeletions: diffDeletions,
    );
  }
}

String _unwrapZshCommand(String value) {
  var command = value.trim();
  if (!command.startsWith('/bin/zsh -lc')) {
    return command;
  }

  final innerMatch = RegExp(
    r'''/bin/zsh\s+-lc\s+(["'])(.*?)\1''',
  ).firstMatch(command);
  if (innerMatch != null) {
    return innerMatch.group(2)?.trim() ?? command;
  }

  // fallback for unquoted invocation payloads
  final fallbackMatch = RegExp(
    r'''/bin/zsh\s+-lc\s+(.*)''',
  ).firstMatch(command);
  if (fallbackMatch == null) {
    return command;
  }

  command = fallbackMatch.group(1)?.trim() ?? command;
  if (command.length >= 2 &&
      ((command.startsWith("'") && command.endsWith("'")) ||
          (command.startsWith('"') && command.endsWith('"')))) {
    return command.substring(1, command.length - 1);
  }

  return command;
}

enum ParsedDiffChangeType { modified, added, deleted }

enum ParsedDiffLineKind { context, addition, deletion, hunk }

@immutable
class ParsedDiffDocument {
  const ParsedDiffDocument({required this.files});

  final List<ParsedDiffFile> files;

  int get totalAdditions =>
      files.fold<int>(0, (count, file) => count + file.additions);

  int get totalDeletions =>
      files.fold<int>(0, (count, file) => count + file.deletions);

  String? get primaryPath {
    if (files.isEmpty) {
      return null;
    }
    return files.first.path;
  }

  static ParsedDiffDocument? parse(String raw) {
    final normalized = raw.trim();
    if (normalized.isEmpty) {
      return null;
    }

    final applyPatchFiles = _parseApplyPatch(normalized);
    if (applyPatchFiles.isNotEmpty) {
      return ParsedDiffDocument(files: applyPatchFiles);
    }

    final gitDiffFiles = _parseGitDiff(normalized);
    if (gitDiffFiles.isNotEmpty) {
      return ParsedDiffDocument(files: gitDiffFiles);
    }

    return null;
  }

  static List<ParsedDiffFile> _parseApplyPatch(String raw) {
    final lines = raw.split('\n');
    final files = <ParsedDiffFile>[];
    _ParsedDiffFileBuilder? current;
    int oldLineNumber = 1;
    int newLineNumber = 1;

    void finishCurrent() {
      final built = current?.build();
      if (built != null) {
        files.add(built);
      }
      current = null;
      oldLineNumber = 1;
      newLineNumber = 1;
    }

    for (final line in lines) {
      if (line.startsWith('*** Update File: ')) {
        finishCurrent();
        current = _ParsedDiffFileBuilder(
          path: line.substring('*** Update File: '.length).trim(),
          changeType: ParsedDiffChangeType.modified,
        );
        oldLineNumber = 1;
        newLineNumber = 1;
        continue;
      }
      if (line.startsWith('*** Add File: ')) {
        finishCurrent();
        current = _ParsedDiffFileBuilder(
          path: line.substring('*** Add File: '.length).trim(),
          changeType: ParsedDiffChangeType.added,
        );
        oldLineNumber = 1;
        newLineNumber = 1;
        continue;
      }
      if (line.startsWith('*** Delete File: ')) {
        finishCurrent();
        current = _ParsedDiffFileBuilder(
          path: line.substring('*** Delete File: '.length).trim(),
          changeType: ParsedDiffChangeType.deleted,
        );
        oldLineNumber = 1;
        newLineNumber = 1;
        continue;
      }
      if (line.startsWith('*** Move to: ')) {
        current?.path = line.substring('*** Move to: '.length).trim();
        continue;
      }
      if (line == '*** Begin Patch' ||
          line == '*** End Patch' ||
          line == '*** End of File') {
        continue;
      }
      if (line.startsWith('@@')) {
        current?.addHunk(line);
        continue;
      }

      final kind = _kindForDiffLine(line);
      if (kind != null) {
        switch (kind) {
          case ParsedDiffLineKind.context:
            current?.addCodeLine(
              kind,
              _trimDiffPrefix(line),
              oldLineNumber: oldLineNumber,
              newLineNumber: newLineNumber,
            );
            oldLineNumber += 1;
            newLineNumber += 1;
            break;
          case ParsedDiffLineKind.deletion:
            current?.addCodeLine(
              kind,
              _trimDiffPrefix(line),
              oldLineNumber: oldLineNumber,
            );
            oldLineNumber += 1;
            break;
          case ParsedDiffLineKind.addition:
            current?.addCodeLine(
              kind,
              _trimDiffPrefix(line),
              newLineNumber: newLineNumber,
            );
            newLineNumber += 1;
            break;
          case ParsedDiffLineKind.hunk:
            current?.addHunk(line);
            break;
        }
      }
    }

    finishCurrent();
    return files;
  }

  static List<ParsedDiffFile> _parseGitDiff(String raw) {
    final lines = raw.split('\n');
    final files = <ParsedDiffFile>[];
    _ParsedDiffFileBuilder? current;
    int? oldLineNumber;
    int? newLineNumber;

    void finishCurrent() {
      final built = current?.build();
      if (built != null) {
        files.add(built);
      }
      current = null;
      oldLineNumber = null;
      newLineNumber = null;
    }

    for (final line in lines) {
      if (line.startsWith('diff --git ')) {
        finishCurrent();
        final match = RegExp(r'^diff --git a/(.+?) b/(.+)$').firstMatch(line);
        final path = match?.group(2) ?? match?.group(1);
        if (path != null) {
          current = _ParsedDiffFileBuilder(
            path: path.trim(),
            changeType: ParsedDiffChangeType.modified,
          );
        }
        continue;
      }

      if (current == null) {
        continue;
      }

      final currentFile = current;
      if (currentFile == null) {
        continue;
      }

      if (line.startsWith('new file mode ')) {
        currentFile.changeType = ParsedDiffChangeType.added;
        continue;
      }
      if (line.startsWith('deleted file mode ')) {
        currentFile.changeType = ParsedDiffChangeType.deleted;
        continue;
      }
      if (line == '--- /dev/null') {
        currentFile.changeType = ParsedDiffChangeType.added;
        continue;
      }
      if (line == '+++ /dev/null') {
        currentFile.changeType = ParsedDiffChangeType.deleted;
        continue;
      }
      if (line.startsWith('rename to ')) {
        currentFile.path = line.substring('rename to '.length).trim();
        continue;
      }
      if (line.startsWith('+++ ')) {
        final nextPath = _normalizeGitFilePath(line.substring(4));
        if (nextPath != null) {
          currentFile.path = nextPath;
        }
        continue;
      }
      if (line.startsWith('@@')) {
        final hunk = _GitHunkState.parse(line);
        oldLineNumber = hunk?.oldLine;
        newLineNumber = hunk?.newLine;
        currentFile.addHunk(line);
        continue;
      }
      if (line == r'\ No newline at end of file' ||
          line.startsWith('index ') ||
          line.startsWith('--- ')) {
        continue;
      }

      final kind = _kindForDiffLine(line);
      if (kind == null) {
        continue;
      }

      switch (kind) {
        case ParsedDiffLineKind.context:
          currentFile.addCodeLine(
            kind,
            _trimDiffPrefix(line),
            oldLineNumber: oldLineNumber,
            newLineNumber: newLineNumber,
          );
          oldLineNumber = _incrementLineNumber(oldLineNumber);
          newLineNumber = _incrementLineNumber(newLineNumber);
          break;
        case ParsedDiffLineKind.deletion:
          currentFile.addCodeLine(
            kind,
            _trimDiffPrefix(line),
            oldLineNumber: oldLineNumber,
          );
          oldLineNumber = _incrementLineNumber(oldLineNumber);
          break;
        case ParsedDiffLineKind.addition:
          currentFile.addCodeLine(
            kind,
            _trimDiffPrefix(line),
            newLineNumber: newLineNumber,
          );
          newLineNumber = _incrementLineNumber(newLineNumber);
          break;
        case ParsedDiffLineKind.hunk:
          currentFile.addHunk(line);
          break;
      }
    }

    finishCurrent();
    return files;
  }

  static ParsedDiffLineKind? _kindForDiffLine(String line) {
    if (line.isEmpty) {
      return ParsedDiffLineKind.context;
    }
    if (line.startsWith('+') && !line.startsWith('+++')) {
      return ParsedDiffLineKind.addition;
    }
    if (line.startsWith('-') && !line.startsWith('---')) {
      return ParsedDiffLineKind.deletion;
    }
    if (line.startsWith(' ')) {
      return ParsedDiffLineKind.context;
    }
    return null;
  }

  static String _trimDiffPrefix(String line) {
    if (line.isEmpty) {
      return '';
    }
    final prefix = line[0];
    if (prefix == '+' || prefix == '-' || prefix == ' ') {
      return line.substring(1);
    }
    return line;
  }

  static String? _normalizeGitFilePath(String rawPath) {
    final trimmed = rawPath.trim();
    if (trimmed.isEmpty || trimmed == '/dev/null') {
      return null;
    }
    if (trimmed.startsWith('a/') || trimmed.startsWith('b/')) {
      return trimmed.substring(2);
    }
    return trimmed;
  }

  static int? _incrementLineNumber(int? value) {
    if (value == null) {
      return null;
    }
    return value + 1;
  }
}

@immutable
class ParsedDiffFile {
  const ParsedDiffFile({
    required this.path,
    required this.changeType,
    required this.lines,
    required this.additions,
    required this.deletions,
  });

  final String path;
  final ParsedDiffChangeType changeType;
  final List<ParsedDiffLine> lines;
  final int additions;
  final int deletions;
}

@immutable
class ParsedDiffLine {
  const ParsedDiffLine({
    required this.kind,
    required this.text,
    this.oldLineNumber,
    this.newLineNumber,
  });

  final ParsedDiffLineKind kind;
  final String text;
  final int? oldLineNumber;
  final int? newLineNumber;
}

class _ParsedDiffFileBuilder {
  _ParsedDiffFileBuilder({required this.path, required this.changeType});

  String path;
  ParsedDiffChangeType changeType;
  final List<ParsedDiffLine> _lines = <ParsedDiffLine>[];
  int _additions = 0;
  int _deletions = 0;

  void addHunk(String header) {
    _lines.add(ParsedDiffLine(kind: ParsedDiffLineKind.hunk, text: header));
  }

  void addCodeLine(
    ParsedDiffLineKind kind,
    String text, {
    int? oldLineNumber,
    int? newLineNumber,
  }) {
    if (kind == ParsedDiffLineKind.addition) {
      _additions += 1;
    } else if (kind == ParsedDiffLineKind.deletion) {
      _deletions += 1;
    }

    _lines.add(
      ParsedDiffLine(
        kind: kind,
        text: text,
        oldLineNumber: oldLineNumber,
        newLineNumber: newLineNumber,
      ),
    );
  }

  ParsedDiffFile? build() {
    final normalizedPath = path.trim();
    if (normalizedPath.isEmpty || _lines.isEmpty) {
      return null;
    }

    return ParsedDiffFile(
      path: normalizedPath,
      changeType: changeType,
      lines: List<ParsedDiffLine>.unmodifiable(_lines),
      additions: _additions,
      deletions: _deletions,
    );
  }
}

class _GitHunkState {
  const _GitHunkState({required this.oldLine, required this.newLine});

  final int? oldLine;
  final int? newLine;

  static _GitHunkState? parse(String header) {
    final match = RegExp(
      r'^@@\s+-(\d+)(?:,\d+)?\s+\+(\d+)(?:,\d+)?\s+@@',
    ).firstMatch(header);
    if (match == null) {
      return const _GitHunkState(oldLine: null, newLine: null);
    }
    return _GitHunkState(
      oldLine: int.tryParse(match.group(1) ?? ''),
      newLine: int.tryParse(match.group(2) ?? ''),
    );
  }
}
