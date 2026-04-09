import 'package:flutter/foundation.dart';

const Set<String> hiddenToolInvocationNames = <String>{
  'close_agent',
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

@immutable
class ParsedCommandOutput {
  const ParsedCommandOutput({
    required this.command,
    required this.exitCode,
    required this.outputBody,
    required this.hasDiffBlock,
    required this.isStatusOnlyFileList,
    required this.commandPresentation,
    this.wallTimeSeconds,
    this.diffDocument,
    this.diffPath,
    this.diffAdditions = 0,
    this.diffDeletions = 0,
    this.readSnippet,
  });

  final String? command;
  final int? exitCode;
  final String outputBody;
  final double? wallTimeSeconds;
  final ParsedCommandPresentation? commandPresentation;

  final bool hasDiffBlock;
  final bool isStatusOnlyFileList;
  final ParsedDiffDocument? diffDocument;
  final String? diffPath;
  final int diffAdditions;
  final int diffDeletions;
  final ParsedReadSnippet? readSnippet;

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
      commandPresentation?.title ??
      backgroundTerminalSummary ??
      command ??
      'Unknown command';

  String? get terminalDisplaySubtitle => commandPresentation?.subtitle;

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

    final normalizedBody = body.trim();
    if (command == null &&
        _looksLikeToolInvocationName(normalizedBody) &&
        !hiddenToolInvocationNames.contains(normalizedBody)) {
      command = normalizedBody;
      body = '';
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
    ParsedReadSnippet? readSnippet;

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
      final nonEmptyLines = body
          .split('\n')
          .map((line) => line.trimRight())
          .where((line) => line.trim().isNotEmpty)
          .toList(growable: false);
      final isPureStatusList =
          statusMatches.isNotEmpty &&
          statusMatches.length == nonEmptyLines.length;
      if (isPureStatusList) {
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

    if (!hasDiffBlock) {
      readSnippet = ParsedReadSnippet.tryParse(
        command: command,
        outputBody: body,
      );
    }

    return ParsedCommandOutput(
      command: command,
      exitCode: exitCode,
      outputBody: body,
      commandPresentation: _buildCommandPresentation(
        command: command,
        outputBody: body,
        isStatusOnlyFileList: isStatusOnlyFileList,
      ),
      hasDiffBlock: hasDiffBlock,
      isStatusOnlyFileList: isStatusOnlyFileList,
      wallTimeSeconds: wallTimeSeconds,
      diffDocument: diffDocument,
      diffPath: diffPath,
      diffAdditions: diffAdditions,
      diffDeletions: diffDeletions,
      readSnippet: readSnippet,
    );
  }
}

@immutable
class ParsedCommandPresentation {
  const ParsedCommandPresentation({required this.title, this.subtitle});

  final String title;
  final String? subtitle;
}

ParsedCommandPresentation? _buildCommandPresentation({
  required String? command,
  required String outputBody,
  required bool isStatusOnlyFileList,
}) {
  final trimmedCommand = command?.trim();
  final trimmedOutput = outputBody.trim();
  if (trimmedCommand == null || trimmedCommand.isEmpty) {
    if (trimmedOutput.startsWith('Success. Updated the following files:')) {
      return const ParsedCommandPresentation(title: 'Updating files');
    }
    return null;
  }

  final segments = _splitShellSegments(trimmedCommand);
  if (segments.isEmpty) {
    return null;
  }

  final primarySegment = segments.last;
  final lowerCommand = trimmedCommand.toLowerCase();
  final lowerPrimary = primarySegment.toLowerCase();

  if (isStatusOnlyFileList || lowerPrimary.startsWith('git status')) {
    return ParsedCommandPresentation(
      title: 'Checking working tree',
      subtitle: trimmedCommand,
    );
  }

  if (lowerPrimary == 'apply_patch' ||
      lowerPrimary == 'replace_file_content' ||
      lowerPrimary == 'multi_replace_file_content') {
    return ParsedCommandPresentation(
      title: 'Updating files',
      subtitle: trimmedCommand,
    );
  }

  final searchQuery = _extractSearchQuery(trimmedCommand);
  if (searchQuery != null) {
    return ParsedCommandPresentation(
      title: 'Searching codebase for "$searchQuery"',
      subtitle: trimmedCommand,
    );
  }

  if (_looksLikeFileListingCommand(trimmedCommand)) {
    return ParsedCommandPresentation(
      title: 'Listing files',
      subtitle: trimmedCommand,
    );
  }

  if (lowerPrimary.startsWith('git diff --stat') ||
      lowerPrimary.startsWith('git diff --cached --stat')) {
    return ParsedCommandPresentation(
      title: 'Summarizing changes',
      subtitle: trimmedCommand,
    );
  }

  if (lowerPrimary.startsWith('git diff')) {
    return ParsedCommandPresentation(
      title: 'Reviewing changes',
      subtitle: trimmedCommand,
    );
  }

  if (lowerPrimary.startsWith('git log')) {
    return ParsedCommandPresentation(
      title: 'Reviewing commit history',
      subtitle: trimmedCommand,
    );
  }

  if (lowerPrimary.startsWith('git add') &&
      lowerCommand.contains('git commit')) {
    return ParsedCommandPresentation(
      title: 'Staging and committing changes',
      subtitle: trimmedCommand,
    );
  }

  if (lowerPrimary.startsWith('git add')) {
    return ParsedCommandPresentation(
      title: 'Staging changes',
      subtitle: trimmedCommand,
    );
  }

  if (lowerPrimary.startsWith('git commit')) {
    return ParsedCommandPresentation(
      title: 'Creating commit',
      subtitle: trimmedCommand,
    );
  }

  if (_looksLikeValidationCommand(primarySegment)) {
    return ParsedCommandPresentation(
      title: 'Validating project',
      subtitle: trimmedCommand,
    );
  }

  if (_looksLikeTestCommand(primarySegment)) {
    return ParsedCommandPresentation(
      title: 'Running tests',
      subtitle: trimmedCommand,
    );
  }

  if (_looksLikeFormatCommand(primarySegment)) {
    return ParsedCommandPresentation(
      title: 'Formatting code',
      subtitle: trimmedCommand,
    );
  }

  if (_looksLikeBuildCommand(primarySegment)) {
    return ParsedCommandPresentation(
      title: 'Building project',
      subtitle: trimmedCommand,
    );
  }

  if (lowerPrimary.startsWith('wc -l') ||
      lowerPrimary.contains(' xargs wc -l') ||
      lowerPrimary.contains('| xargs wc -l')) {
    return ParsedCommandPresentation(
      title: 'Counting lines',
      subtitle: trimmedCommand,
    );
  }

  if (lowerPrimary.startsWith('python3 - <<') ||
      lowerPrimary.startsWith('python - <<')) {
    return ParsedCommandPresentation(
      title: 'Running inline analysis script',
      subtitle: trimmedCommand,
    );
  }

  if (lowerPrimary.contains('infer_commit_style.py')) {
    return ParsedCommandPresentation(
      title: 'Inferring commit style',
      subtitle: trimmedCommand,
    );
  }

  if (_looksLikeFilesystemMutationCommand(trimmedCommand)) {
    return ParsedCommandPresentation(
      title: 'Reorganizing files',
      subtitle: trimmedCommand,
    );
  }

  if (outputBody.trim().isEmpty) {
    if (lowerPrimary.startsWith('git add')) {
      return ParsedCommandPresentation(
        title: 'Staging changes',
        subtitle: trimmedCommand,
      );
    }
    if (_looksLikeFilesystemMutationCommand(trimmedCommand)) {
      return ParsedCommandPresentation(
        title: 'Updating files',
        subtitle: trimmedCommand,
      );
    }
  }

  return null;
}

List<String> _splitShellSegments(String command) {
  return command
      .split(RegExp(r'\s*(?:&&|\|\||;)\s*'))
      .map((segment) => segment.trim())
      .where((segment) => segment.isNotEmpty)
      .toList(growable: false);
}

String? _extractSearchQuery(String command) {
  final rgWithFiles = RegExp(
    r'''(?:^|[;&]\s*)(?:pwd\s*&&\s*)?rg\s+--files(?:\s+[^\n|]+)?\s*\|\s*rg(?:\s+-[^\s]+)*\s+["']([^"']+)["']''',
    caseSensitive: false,
  ).firstMatch(command);
  if (rgWithFiles != null) {
    return rgWithFiles.group(1)?.trim();
  }

  final rgMatch = RegExp(
    r'''(?:^|[;&]\s*)(?:pwd\s*&&\s*)?rg(?:\s+-[^\s]+)*\s+["']([^"']+)["']''',
    caseSensitive: false,
  ).firstMatch(command);
  if (rgMatch != null) {
    return rgMatch.group(1)?.trim();
  }

  final rgUnquotedMatch = RegExp(
    r'''(?:^|[;&]\s*)(?:pwd\s*&&\s*)?rg(?:\s+-[^\s]+)*\s+([^\s"'|;][^\s|;]*)''',
    caseSensitive: false,
  ).firstMatch(command);
  if (rgUnquotedMatch != null) {
    return rgUnquotedMatch.group(1)?.trim();
  }

  final grepMatch = RegExp(
    r'''(?:^|[;&]\s*)grep(?:\s+-[^\s]+)*\s+["']([^"']+)["']''',
    caseSensitive: false,
  ).firstMatch(command);
  if (grepMatch != null) {
    return grepMatch.group(1)?.trim();
  }

  final grepUnquotedMatch = RegExp(
    r'''(?:^|[;&]\s*)grep(?:\s+-[^\s]+)*\s+([^\s"'|;][^\s|;]*)''',
    caseSensitive: false,
  ).firstMatch(command);
  return grepUnquotedMatch?.group(1)?.trim();
}

bool _looksLikeFileListingCommand(String command) {
  final trimmed = command.trim().toLowerCase();
  return trimmed.startsWith('rg --files') ||
      trimmed.startsWith('find ') ||
      trimmed.startsWith('ls ') ||
      trimmed.startsWith('ls -') ||
      trimmed.startsWith('pwd && find ') ||
      trimmed.startsWith('pwd && ls ');
}

bool _looksLikeValidationCommand(String command) {
  final lower = command.trim().toLowerCase();
  return lower.startsWith('flutter analyze') ||
      lower.startsWith('cargo check') ||
      lower.startsWith('cargo clippy') ||
      (lower.startsWith('xcodebuild ') && lower.contains(' build')) ||
      lower.startsWith('dart analyze');
}

bool _looksLikeTestCommand(String command) {
  final lower = command.trim().toLowerCase();
  return lower.startsWith('flutter test') ||
      lower.startsWith('cargo test') ||
      (lower.startsWith('xcodebuild ') && lower.contains(' test')) ||
      lower.startsWith('dart test');
}

bool _looksLikeFormatCommand(String command) {
  final lower = command.trim().toLowerCase();
  return lower.startsWith('dart format') ||
      lower.startsWith('cargo fmt') ||
      lower.startsWith('swiftformat');
}

bool _looksLikeBuildCommand(String command) {
  final lower = command.trim().toLowerCase();
  return lower.startsWith('flutter build') ||
      lower.startsWith('cargo build') ||
      (lower.startsWith('xcodebuild ') && lower.contains(' build'));
}

bool _looksLikeFilesystemMutationCommand(String command) {
  final lower = command.trim().toLowerCase();
  return lower.startsWith('rm ') ||
      lower.startsWith('mv ') ||
      lower.startsWith('cp ') ||
      lower.startsWith('mkdir ') ||
      lower.contains('&& rm ') ||
      lower.contains('&& mv ') ||
      lower.contains('&& cp ') ||
      lower.contains('&& mkdir ');
}

bool _looksLikeToolInvocationName(String value) {
  if (value.isEmpty || value.contains(RegExp(r'\s'))) {
    return false;
  }

  return value.contains('_') && RegExp(r'^[a-z0-9_]+$').hasMatch(value);
}

@immutable
class ParsedReadSnippet {
  const ParsedReadSnippet({
    required this.path,
    required this.code,
    this.startLine,
    this.endLine,
    this.requestedLineCount,
    this.isTail = false,
  });

  final String path;
  final String code;
  final int? startLine;
  final int? endLine;
  final int? requestedLineCount;
  final bool isTail;

  String get fileName {
    final normalized = path.replaceAll('\\', '/');
    final segments = normalized.split('/');
    return segments.isEmpty ? normalized : segments.last;
  }

  String get summaryLabel {
    if (startLine != null && endLine != null) {
      return 'Read $fileName:$startLine-$endLine';
    }
    if (isTail && requestedLineCount != null) {
      return 'Read $fileName (last $requestedLineCount lines)';
    }
    if (requestedLineCount != null && startLine == 1) {
      return 'Read $fileName:1-$requestedLineCount';
    }
    return 'Read $fileName';
  }

  static ParsedReadSnippet? tryParse({
    required String? command,
    required String outputBody,
  }) {
    final trimmedCommand = command?.trim();
    final trimmedBody = outputBody.trimRight();
    if (trimmedCommand == null ||
        trimmedCommand.isEmpty ||
        trimmedBody.isEmpty ||
        _looksLikeToolInvocationName(trimmedCommand)) {
      return null;
    }

    final numberedBody = _ParsedNumberedCodeBody.tryParse(trimmedBody);

    final nlWithSedMatch = RegExp(
      r'''(?:^|[;&]\s*)nl\s+-ba\s+(?:"([^"]+)"|'([^']+)'|([^\s|;]+))\s*\|\s*sed\s+-n\s+["'](\d+),(\d+)p["']''',
      multiLine: true,
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(trimmedCommand);
    if (nlWithSedMatch != null) {
      final path = _firstNonEmptyGroup(nlWithSedMatch, 1, 2, 3);
      final startLine = int.tryParse(nlWithSedMatch.group(4) ?? '');
      final endLine = int.tryParse(nlWithSedMatch.group(5) ?? '');
      if (path != null && startLine != null && endLine != null) {
        return ParsedReadSnippet(
          path: path,
          code: numberedBody?.code ?? trimmedBody,
          startLine: numberedBody?.startLine ?? startLine,
          endLine: numberedBody?.endLine ?? endLine,
        );
      }
    }

    final gitShowWithSedMatch = RegExp(
      r'''(?:^|[;&]\s*)git\s+show\s+[^\s:]+:(?:"([^"]+)"|'([^']+)'|([^\s|;]+))\s*\|\s*sed\s+-n\s+["'](\d+),(\d+)p["']''',
      multiLine: true,
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(trimmedCommand);
    if (gitShowWithSedMatch != null) {
      final path = _firstNonEmptyGroup(gitShowWithSedMatch, 1, 2, 3);
      final startLine = int.tryParse(gitShowWithSedMatch.group(4) ?? '');
      final endLine = int.tryParse(gitShowWithSedMatch.group(5) ?? '');
      if (path != null && startLine != null && endLine != null) {
        return ParsedReadSnippet(
          path: path,
          code: trimmedBody,
          startLine: startLine,
          endLine: endLine,
        );
      }
    }

    final sedMatch = RegExp(
      r'''(?:^|[;&]\s*)sed\s+-n\s+["'](\d+),(\d+)p["']\s+(?:--\s+)?(?:"([^"]+)"|'([^']+)'|([^\s|;]+))''',
      multiLine: true,
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(trimmedCommand);
    if (sedMatch != null) {
      final path = _firstNonEmptyGroup(sedMatch, 3, 4, 5);
      final startLine = int.tryParse(sedMatch.group(1) ?? '');
      final endLine = int.tryParse(sedMatch.group(2) ?? '');
      if (path != null && startLine != null && endLine != null) {
        return ParsedReadSnippet(
          path: path,
          code: trimmedBody,
          startLine: startLine,
          endLine: endLine,
        );
      }
    }

    final headMatch = RegExp(
      r'''(?:^|[;&]\s*)head\s+-n\s+(\d+)\s+(?:--\s+)?(?:"([^"]+)"|'([^']+)'|([^\s|;]+))''',
      multiLine: true,
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(trimmedCommand);
    if (headMatch != null) {
      final path = _firstNonEmptyGroup(headMatch, 2, 3, 4);
      final requestedLineCount = int.tryParse(headMatch.group(1) ?? '');
      if (path != null && requestedLineCount != null) {
        final actualLineCount = '\n'.allMatches(trimmedBody).length + 1;
        return ParsedReadSnippet(
          path: path,
          code: trimmedBody,
          startLine: 1,
          endLine: actualLineCount,
          requestedLineCount: requestedLineCount,
        );
      }
    }

    final tailMatch = RegExp(
      r'''(?:^|[;&]\s*)tail\s+-n\s+(\d+)\s+(?:--\s+)?(?:"([^"]+)"|'([^']+)'|([^\s|;]+))''',
      multiLine: true,
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(trimmedCommand);
    if (tailMatch != null) {
      final path = _firstNonEmptyGroup(tailMatch, 2, 3, 4);
      final requestedLineCount = int.tryParse(tailMatch.group(1) ?? '');
      if (path != null && requestedLineCount != null) {
        return ParsedReadSnippet(
          path: path,
          code: trimmedBody,
          startLine: numberedBody?.startLine,
          endLine: numberedBody?.endLine,
          requestedLineCount: requestedLineCount,
          isTail: true,
        );
      }
    }

    final catMatch = RegExp(
      r'''(?:^|[;&]\s*)cat\s+(?:--\s+)?(?:"([^"]+)"|'([^']+)'|([^\s|;]+))''',
      multiLine: true,
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(trimmedCommand);
    if (catMatch != null) {
      final path = _firstNonEmptyGroup(catMatch, 1, 2, 3);
      if (path != null) {
        return ParsedReadSnippet(
          path: path,
          code: trimmedBody,
          startLine: numberedBody?.startLine,
          endLine: numberedBody?.endLine,
        );
      }
    }

    if (numberedBody != null) {
      final nlMatch = RegExp(
        r'''(?:^|[;&]\s*)nl\s+-ba\s+(?:"([^"]+)"|'([^']+)'|([^\s|;]+))''',
        multiLine: true,
        caseSensitive: false,
        dotAll: true,
      ).firstMatch(trimmedCommand);
      final path = nlMatch == null
          ? null
          : _firstNonEmptyGroup(nlMatch, 1, 2, 3);
      if (path != null) {
        return ParsedReadSnippet(
          path: path,
          code: numberedBody.code,
          startLine: numberedBody.startLine,
          endLine: numberedBody.endLine,
        );
      }
    }

    return null;
  }
}

class _ParsedNumberedCodeBody {
  const _ParsedNumberedCodeBody({
    required this.code,
    required this.startLine,
    required this.endLine,
  });

  final String code;
  final int startLine;
  final int endLine;

  static _ParsedNumberedCodeBody? tryParse(String body) {
    final lines = body.split('\n');
    if (lines.isEmpty) {
      return null;
    }

    final cleanedLines = <String>[];
    int? startLine;
    int? endLine;

    for (final line in lines) {
      final match = RegExp(r'^\s*(\d+)\t?(.*)$').firstMatch(line);
      if (match == null) {
        return null;
      }

      final lineNumber = int.tryParse(match.group(1) ?? '');
      if (lineNumber == null) {
        return null;
      }
      startLine ??= lineNumber;
      endLine = lineNumber;
      cleanedLines.add(match.group(2) ?? '');
    }

    if (startLine == null || endLine == null) {
      return null;
    }

    return _ParsedNumberedCodeBody(
      code: cleanedLines.join('\n'),
      startLine: startLine,
      endLine: endLine,
    );
  }
}

String? _firstNonEmptyGroup(
  RegExpMatch match,
  int first,
  int second,
  int third,
) {
  for (final index in <int>[first, second, third]) {
    final value = match.group(index);
    if (value != null && value.trim().isNotEmpty) {
      return value.trim();
    }
  }
  return null;
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
