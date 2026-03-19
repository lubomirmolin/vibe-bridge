import 'package:codex_mobile_companion/features/threads/domain/thread_activity_item.dart';
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
  });

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
}
