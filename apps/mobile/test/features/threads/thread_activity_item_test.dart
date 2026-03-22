import 'package:codex_mobile_companion/features/threads/domain/parsed_command_output.dart';
import 'package:codex_mobile_companion/features/threads/domain/thread_activity_item.dart';
import 'package:codex_mobile_companion/features/threads/domain/thread_timeline_block.dart';
import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('command output with git status lines is classified as file change', () {
    final entry = ThreadTimelineEntryDto(
      eventId: 'event-1',
      kind: BridgeEventKind.commandDelta,
      occurredAt: '2026-03-19T17:35:04.000Z',
      summary: 'Command output',
      payload: <String, dynamic>{
        'output': '''
Command: /bin/zsh -lc "git status --short"
Output:
 M apps/mobile/lib/features/threads/presentation/thread_detail_page.dart
 M apps/mobile/test/features/threads/thread_list_page_test.dart
''',
      },
    );

    final item = ThreadActivityItem.fromTimelineEntry(entry);

    expect(item.type, ThreadActivityItemType.fileChange);
    expect(item.parsedCommandOutput, isNotNull);
    expect(item.parsedCommandOutput!.hasDiffBlock, isFalse);
    expect(item.parsedCommandOutput!.isStatusOnlyFileList, isTrue);
    expect(item.parsedCommandOutput!.diffPath, 'thread_detail_page.dart');
    expect(
      item.parsedCommandOutput!.outputBody,
      contains('thread_list_page_test.dart'),
    );
  });

  test('command output with git diff is parsed as file change diff', () {
    final entry = ThreadTimelineEntryDto(
      eventId: 'event-2',
      kind: BridgeEventKind.commandDelta,
      occurredAt: '2026-03-19T17:35:04.000Z',
      summary: 'Command output',
      payload: <String, dynamic>{
        'output': '''
Command: /bin/zsh -lc "git diff -- apps/mobile/test/features/threads/thread_detail_page_test.dart"
Output:
diff --git a/apps/mobile/test/features/threads/thread_detail_page_test.dart b/apps/mobile/test/features/threads/thread_detail_page_test.dart
index 1111111..2222222 100644
--- a/apps/mobile/test/features/threads/thread_detail_page_test.dart
+++ b/apps/mobile/test/features/threads/thread_detail_page_test.dart
@@ -10,1 +10,1 @@
-old line
+new line
''',
      },
    );

    final item = ThreadActivityItem.fromTimelineEntry(entry);

    expect(item.type, ThreadActivityItemType.fileChange);
    expect(item.parsedCommandOutput, isNotNull);
    expect(item.parsedCommandOutput!.hasDiffBlock, isTrue);
    expect(item.parsedCommandOutput!.diffPath, 'thread_detail_page_test.dart');
    expect(item.parsedCommandOutput!.diffAdditions, greaterThan(0));
    expect(item.parsedCommandOutput!.diffDeletions, greaterThan(0));
  });

  test('command output with apply_patch is parsed as file change diff', () {
    final entry = ThreadTimelineEntryDto(
      eventId: 'event-3',
      kind: BridgeEventKind.commandDelta,
      occurredAt: '2026-03-19T17:35:04.000Z',
      summary: 'Edited file',
      payload: <String, dynamic>{
        'output': '''
*** Begin Patch
*** Update File: /Users/lubomirmolin/PhpstormProjects/codex-mobile-companion/apps/mobile/lib/features/threads/presentation/thread_detail_page.dart
@@
-    return oldValue;
+    return newValue;
*** End Patch
''',
      },
    );

    final item = ThreadActivityItem.fromTimelineEntry(entry);

    expect(item.type, ThreadActivityItemType.fileChange);
    expect(item.parsedCommandOutput, isNotNull);
    expect(item.parsedCommandOutput!.hasDiffBlock, isTrue);
    expect(item.parsedCommandOutput!.diffPath, 'thread_detail_page.dart');
    expect(item.parsedCommandOutput!.diffAdditions, 1);
    expect(item.parsedCommandOutput!.diffDeletions, 1);
    expect(item.parsedCommandOutput!.diffDocument, isNotNull);
    expect(item.parsedCommandOutput!.diffDocument!.files, hasLength(1));
    final diffLines = item.parsedCommandOutput!.diffDocument!.files.first.lines;
    final deletedLine = diffLines.firstWhere(
      (line) => line.kind == ParsedDiffLineKind.deletion,
    );
    final addedLine = diffLines.firstWhere(
      (line) => line.kind == ParsedDiffLineKind.addition,
    );
    expect(deletedLine.oldLineNumber, 1);
    expect(addedLine.newLineNumber, 1);
  });

  test('resolved unified diff payload uses real hunk line numbers', () {
    final entry = ThreadTimelineEntryDto(
      eventId: 'event-3b',
      kind: BridgeEventKind.fileChange,
      occurredAt: '2026-03-19T17:35:04.000Z',
      summary: 'Edited file',
      payload: <String, dynamic>{
        'change': '''
*** Begin Patch
*** Update File: /tmp/thread_activity_item_test.dart
@@
-oldValue
+newValue
*** End Patch
''',
        'resolved_unified_diff': '''
diff --git a/apps/mobile/test/features/threads/thread_activity_item_test.dart b/apps/mobile/test/features/threads/thread_activity_item_test.dart
--- a/apps/mobile/test/features/threads/thread_activity_item_test.dart
+++ b/apps/mobile/test/features/threads/thread_activity_item_test.dart
@@ -95,1 +95,1 @@
-oldValue
+newValue
''',
      },
    );

    final item = ThreadActivityItem.fromTimelineEntry(entry);

    expect(item.type, ThreadActivityItemType.fileChange);
    expect(item.body, startsWith('diff --git '));
    expect(item.parsedCommandOutput, isNotNull);
    final diffLines = item.parsedCommandOutput!.diffDocument!.files.first.lines;
    final deletedLine = diffLines.firstWhere(
      (line) => line.kind == ParsedDiffLineKind.deletion,
    );
    final addedLine = diffLines.firstWhere(
      (line) => line.kind == ParsedDiffLineKind.addition,
    );
    expect(deletedLine.oldLineNumber, 95);
    expect(addedLine.newLineNumber, 95);
  });

  test(
    'resolved deleted-file diff preserves zero additions and deletion count',
    () {
      final entry = ThreadTimelineEntryDto(
        eventId: 'event-3c',
        kind: BridgeEventKind.fileChange,
        occurredAt: '2026-03-19T17:35:04.000Z',
        summary: 'Deleted file',
        payload: <String, dynamic>{
          'resolved_unified_diff': '''
diff --git a/apps/mobile/test/features/threads/thread_live_timeline_regression_test.dart b/apps/mobile/test/features/threads/thread_live_timeline_regression_test.dart
--- a/apps/mobile/test/features/threads/thread_live_timeline_regression_test.dart
+++ /dev/null
@@ -1,3 +0,0 @@
-alpha
-beta
-gamma
''',
        },
      );

      final item = ThreadActivityItem.fromTimelineEntry(entry);

      expect(item.type, ThreadActivityItemType.fileChange);
      expect(item.parsedCommandOutput, isNotNull);
      expect(
        item.parsedCommandOutput!.diffPath,
        'thread_live_timeline_regression_test.dart',
      );
      expect(item.parsedCommandOutput!.diffAdditions, 0);
      expect(item.parsedCommandOutput!.diffDeletions, 3);
      expect(
        item.parsedCommandOutput!.diffDocument!.files.first.changeType,
        ParsedDiffChangeType.deleted,
      );
    },
  );

  test('exec_command arguments are normalized into a background terminal card', () {
    final entry = ThreadTimelineEntryDto(
      eventId: 'event-4',
      kind: BridgeEventKind.commandDelta,
      occurredAt: '2026-03-19T17:35:04.000Z',
      summary: 'Called exec_command',
      payload: <String, dynamic>{
        'command': 'exec_command',
        'arguments':
            '{"cmd":"dart format apps/mobile/lib/features/threads/presentation/thread_detail_page.dart","workdir":"/Users/lubomirmolin/PhpstormProjects/codex-mobile-companion","yield_time_ms":1000}',
      },
    );

    final item = ThreadActivityItem.fromTimelineEntry(entry);

    expect(item.type, ThreadActivityItemType.terminalOutput);
    expect(item.parsedCommandOutput, isNotNull);
    expect(
      item.parsedCommandOutput!.terminalDisplayTitle,
      'Background terminal finished with dart format apps/mobile/lib/features/threads/presentation/thread_detail_page.dart',
    );
    expect(
      item.parsedCommandOutput!.terminalDisplayBody,
      contains(
        'Working directory: /Users/lubomirmolin/PhpstormProjects/codex-mobile-companion',
      ),
    );
  });

  test('file-change exec_command arguments do not render as unknown command', () {
    final entry = ThreadTimelineEntryDto(
      eventId: 'event-4b',
      kind: BridgeEventKind.commandDelta,
      occurredAt: '2026-03-19T17:35:04.000Z',
      summary: 'Called exec_command',
      payload: <String, dynamic>{
        'command': 'exec_command',
        'arguments':
            '{"cmd":"git diff -- apps/mobile/lib/features/threads/application/thread_detail_controller.dart apps/mobile/test/features/threads/thread_detail_cache_failure_test.dart","workdir":"/Users/lubomirmolin/PhpstormProjects/codex-mobile-companion","yield_time_ms":1000,"max_output_tokens":12000}',
      },
    );

    final item = ThreadActivityItem.fromTimelineEntry(entry);

    expect(item.type, ThreadActivityItemType.fileChange);
    expect(item.parsedCommandOutput, isNotNull);
    expect(
      item.parsedCommandOutput!.terminalDisplayTitle,
      startsWith('Background terminal finished with git diff -- '),
    );
    expect(
      item.parsedCommandOutput!.terminalDisplayTitle,
      isNot('Unknown command'),
    );
    expect(
      item.parsedCommandOutput!.terminalDisplayBody,
      contains(
        'Working directory: /Users/lubomirmolin/PhpstormProjects/codex-mobile-companion',
      ),
    );
  });

  test('command output parses wall time from terminal metadata', () {
    final parsed = ParsedCommandOutput.parse('''
Command: /bin/zsh -lc "rg -n foo apps/mobile/lib"
Chunk ID: abc123
Wall time: 49.2 seconds
Process exited with code 0
Original token count: 120
Output:
apps/mobile/lib/main.dart:1:foo
''');

    expect(parsed.command, 'rg -n foo apps/mobile/lib');
    expect(parsed.wallTimeSeconds, 49.2);
  });

  test('command output parses inline markdown zsh command headers', () {
    final parsed = ParsedCommandOutput.parse('''
`/bin/zsh -lc 'dart format apps/mobile/lib/main.dart'`
Formatted 1 file (0 changed) in 0.02 seconds.
''');

    expect(parsed.command, 'dart format apps/mobile/lib/main.dart');
    expect(
      parsed.terminalDisplayTitle,
      'dart format apps/mobile/lib/main.dart',
    );
    expect(
      parsed.terminalDisplayBody,
      'Formatted 1 file (0 changed) in 0.02 seconds.',
    );
  });

  test('plain MCP tool identifiers render as the command title', () {
    final parsed = ParsedCommandOutput.parse('mcp__playwright__browser_resize');

    expect(parsed.command, 'mcp__playwright__browser_resize');
    expect(parsed.terminalDisplayTitle, 'mcp__playwright__browser_resize');
    expect(parsed.terminalDisplayBody, isEmpty);
  });

  test('internal tool identifiers remain hidden-command bodies', () {
    final parsed = ParsedCommandOutput.parse('write_stdin');

    expect(parsed.command, isNull);
    expect(parsed.outputBody, 'write_stdin');
    expect(parsed.terminalDisplayTitle, 'Unknown command');
  });

  test('sed reads parse into a read snippet with an explicit line range', () {
    final parsed = ParsedCommandOutput.parse('''
Command: /bin/zsh -lc "sed -n '520,760p' downloaded-templates/styles/_custom.scss"
Output:
.bf-cart-btn-secondary {
  background: #fff;
}
''');

    expect(parsed.readSnippet, isNotNull);
    expect(
      parsed.readSnippet!.path,
      'downloaded-templates/styles/_custom.scss',
    );
    expect(parsed.readSnippet!.startLine, 520);
    expect(parsed.readSnippet!.endLine, 760);
    expect(parsed.readSnippet!.summaryLabel, 'Read _custom.scss:520-760');
  });

  test(
    'numbered nl output is normalized into clean code with line numbers',
    () {
      final parsed = ParsedCommandOutput.parse('''
Command: /bin/zsh -lc "nl -ba apps/mobile/lib/features/threads/domain/parsed_command_output.dart | sed -n '2226,2228p'"
Output:
  2226\tclass Example {
  2227\t  const Example();
  2228\t}
''');

      expect(parsed.readSnippet, isNotNull);
      expect(
        parsed.readSnippet!.path,
        'apps/mobile/lib/features/threads/domain/parsed_command_output.dart',
      );
      expect(parsed.readSnippet!.startLine, 2226);
      expect(parsed.readSnippet!.endLine, 2228);
      expect(
        parsed.readSnippet!.code,
        'class Example {\n  const Example();\n}',
      );
    },
  );

  test('consecutive work items bundle into a work summary block', () {
    final items = <ThreadActivityItem>[
      ThreadActivityItem.fromTimelineEntry(
        ThreadTimelineEntryDto(
          eventId: 'event-1',
          kind: BridgeEventKind.commandDelta,
          occurredAt: '2026-03-19T17:35:04.000Z',
          summary: 'Background terminal finished',
          payload: <String, dynamic>{
            'output': '''
Command: /bin/zsh -lc "rg -n foo apps/mobile/lib"
Wall time: 1.2 seconds
Output:
Background terminal finished with rg -n foo apps/mobile/lib
''',
          },
        ),
      ),
      ThreadActivityItem.fromTimelineEntry(
        ThreadTimelineEntryDto(
          eventId: 'event-2',
          kind: BridgeEventKind.commandDelta,
          occurredAt: '2026-03-19T17:35:06.000Z',
          summary: 'Background terminal finished',
          payload: <String, dynamic>{
            'output': '''
Command: /bin/zsh -lc "sed -n '1,20p' apps/mobile/lib/main.dart"
Wall time: 2.0 seconds
Output:
Background terminal finished with sed -n '1,20p' apps/mobile/lib/main.dart
''',
          },
          annotations: ThreadTimelineAnnotationsDto(
            groupKind: ThreadTimelineGroupKind.exploration,
            explorationKind: ThreadTimelineExplorationKind.read,
            entryLabel: 'Read main.dart',
          ),
        ),
      ),
    ];

    final blocks = buildThreadTimelineBlocks(items);

    expect(blocks, hasLength(1));
    expect(blocks.single.workSummary, isNotNull);
    expect(blocks.single.workSummary!.actionCount, 2);
    expect(blocks.single.workSummary!.totalWallTimeSeconds, 3.2);
  });

  test('file changes split bundled work into separate blocks', () {
    final items = <ThreadActivityItem>[
      ThreadActivityItem.fromTimelineEntry(
        ThreadTimelineEntryDto(
          eventId: 'event-1',
          kind: BridgeEventKind.commandDelta,
          occurredAt: '2026-03-19T17:35:04.000Z',
          summary: 'Background terminal finished',
          payload: <String, dynamic>{
            'output': '''
Command: /bin/zsh -lc "rg -n foo apps/mobile/lib"
Wall time: 1.0 seconds
Output:
Background terminal finished with rg -n foo apps/mobile/lib
''',
          },
        ),
      ),
      ThreadActivityItem.fromTimelineEntry(
        ThreadTimelineEntryDto(
          eventId: 'event-1b',
          kind: BridgeEventKind.commandDelta,
          occurredAt: '2026-03-19T17:35:04.500Z',
          summary: 'Background terminal finished',
          payload: <String, dynamic>{'output': 'Background terminal finished'},
          annotations: ThreadTimelineAnnotationsDto(
            groupKind: ThreadTimelineGroupKind.exploration,
            explorationKind: ThreadTimelineExplorationKind.search,
            entryLabel: 'Search',
          ),
        ),
      ),
      ThreadActivityItem.fromTimelineEntry(
        ThreadTimelineEntryDto(
          eventId: 'event-2',
          kind: BridgeEventKind.fileChange,
          occurredAt: '2026-03-19T17:35:05.000Z',
          summary: 'Edited file',
          payload: <String, dynamic>{
            'resolved_unified_diff': '''
diff --git a/apps/mobile/lib/main.dart b/apps/mobile/lib/main.dart
--- a/apps/mobile/lib/main.dart
+++ b/apps/mobile/lib/main.dart
@@ -1,1 +1,1 @@
-oldValue
+newValue
''',
          },
        ),
      ),
      ThreadActivityItem.fromTimelineEntry(
        ThreadTimelineEntryDto(
          eventId: 'event-3',
          kind: BridgeEventKind.commandDelta,
          occurredAt: '2026-03-19T17:35:06.000Z',
          summary: 'Background terminal finished',
          payload: <String, dynamic>{
            'output': '''
Command: /bin/zsh -lc "sed -n '1,20p' apps/mobile/lib/main.dart"
Wall time: 2.0 seconds
Output:
Background terminal finished with sed -n '1,20p' apps/mobile/lib/main.dart
''',
          },
        ),
      ),
      ThreadActivityItem.fromTimelineEntry(
        ThreadTimelineEntryDto(
          eventId: 'event-3b',
          kind: BridgeEventKind.commandDelta,
          occurredAt: '2026-03-19T17:35:06.500Z',
          summary: 'Background terminal finished',
          payload: <String, dynamic>{'output': 'Background terminal finished'},
          annotations: ThreadTimelineAnnotationsDto(
            groupKind: ThreadTimelineGroupKind.exploration,
            explorationKind: ThreadTimelineExplorationKind.read,
            entryLabel: 'Read main.dart',
          ),
        ),
      ),
    ];

    final blocks = buildThreadTimelineBlocks(items);

    expect(blocks, hasLength(3));
    expect(blocks[0].workSummary, isNotNull);
    expect(blocks[0].workSummary!.actionCount, 2);
    expect(blocks[1].item?.type, ThreadActivityItemType.fileChange);
    expect(blocks[1].workSummary, isNull);
    expect(blocks[1].exploration, isNull);
    expect(blocks[2].workSummary, isNotNull);
    expect(blocks[2].workSummary!.actionCount, 2);
  });
}
