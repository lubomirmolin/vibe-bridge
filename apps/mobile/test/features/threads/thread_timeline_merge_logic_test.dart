import 'package:flutter_test/flutter_test.dart';
import 'package:vibe_bridge/features/threads/application/thread_timeline_merge.dart';
import 'package:vibe_bridge/features/threads/domain/thread_activity_item.dart';
import 'package:vibe_bridge/foundation/contracts/bridge_contracts.dart';

void main() {
  test(
    'merges synthetic visible user prompt with canonical same-turn prompt even when timestamps are far apart',
    () {
      final existing = _userPrompt(
        eventId: 'turn-123-visible-user-prompt',
        occurredAt: '2026-04-06T09:00:00.000Z',
        text: 'Hello',
      );
      final candidate = _userPrompt(
        eventId: 'turn-123-item-user-1',
        occurredAt: '2026-04-06T09:00:08.000Z',
        text: 'Hello',
      );

      final mergeIndex = findTimelineMergeIndex(
        items: <ThreadActivityItem>[existing],
        candidate: candidate,
      );

      expect(mergeIndex, 0);
      final merged = preferTimelineMergedItem(
        current: existing,
        candidate: candidate,
      );
      expect(merged.eventId, candidate.eventId);
    },
  );

  test(
    'merges synthetic visible user prompt with same-turn canonical prompt when only synthetic carries images',
    () {
      final existing = _userPrompt(
        eventId: 'turn-123-visible-user-prompt',
        occurredAt: '2026-04-06T09:00:00.000Z',
        text: 'Hello',
        images: const <String>['data:image/png;base64,AAA'],
      );
      final candidate = _userPrompt(
        eventId: 'turn-123-item-user-1',
        occurredAt: '2026-04-06T09:00:08.000Z',
        text: 'Hello',
      );

      final mergeIndex = findTimelineMergeIndex(
        items: <ThreadActivityItem>[existing],
        candidate: candidate,
      );

      expect(mergeIndex, 0);
      final merged = preferTimelineMergedItem(
        current: existing,
        candidate: candidate,
      );
      expect(merged.eventId, existing.eventId);
      expect(merged.messageImageUrls, existing.messageImageUrls);
    },
  );

  test(
    'does not merge user prompts from different turns when only text matches',
    () {
      final existing = _userPrompt(
        eventId: 'turn-111-visible-user-prompt',
        occurredAt: '2026-04-06T09:00:00.000Z',
        text: 'Hello',
      );
      final candidate = _userPrompt(
        eventId: 'turn-222-item-user-1',
        occurredAt: '2026-04-06T09:00:08.000Z',
        text: 'Hello',
      );

      final mergeIndex = findTimelineMergeIndex(
        items: <ThreadActivityItem>[existing],
        candidate: candidate,
      );

      expect(mergeIndex, -1);
    },
  );

  test('merges user prompts with matching client message id identity', () {
    final existing = _userPrompt(
      eventId: 'event-local-user-1',
      occurredAt: '2026-04-06T09:00:00.000Z',
      text: 'Hello',
      clientMessageId: 'client-42',
    );
    final candidate = _userPrompt(
      eventId: 'turn-123-item-user-1',
      occurredAt: '2026-04-06T09:01:10.000Z',
      text: 'Hello',
      clientMessageId: 'client-42',
    );

    final mergeIndex = findTimelineMergeIndex(
      items: <ThreadActivityItem>[existing],
      candidate: candidate,
    );

    expect(mergeIndex, 0);
  });

  test(
    'mergeTimelineEntries reinserts older snapshot assistant output ahead of newer live terminal events',
    () {
      final merged = mergeTimelineEntries(
        currentItems: <ThreadActivityItem>[
          _userPrompt(
            eventId: 'evt-user',
            occurredAt: '2026-04-06T09:00:00.000Z',
            text: 'Split these commits',
          ),
          _terminalOutput(
            eventId: 'evt-live-command',
            occurredAt: '2026-04-06T09:00:12.000Z',
            summary: r'$ git status',
          ),
        ],
        timeline: <ThreadTimelineEntryDto>[
          _assistantOutputEntry(
            eventId: 'evt-snapshot-assistant',
            occurredAt: '2026-04-06T09:00:05.000Z',
            text: "I'm checking the worktree first.",
          ),
        ],
      );

      expect(merged.map((item) => item.eventId).toList(), <String>[
        'evt-user',
        'evt-snapshot-assistant',
        'evt-live-command',
      ]);
    },
  );

  test('replaceTimelineItems normalizes unsorted timeline entries', () {
    final replaced = replaceTimelineItems(<ThreadTimelineEntryDto>[
      _terminalOutputEntry(
        eventId: 'evt-command',
        occurredAt: '2026-04-06T09:00:12.000Z',
        summary: r'$ git status',
      ),
      _userPromptEntry(
        eventId: 'evt-user',
        occurredAt: '2026-04-06T09:00:00.000Z',
        text: 'Split these commits',
      ),
      _assistantOutputEntry(
        eventId: 'evt-assistant',
        occurredAt: '2026-04-06T09:00:05.000Z',
        text: "I'm checking the worktree first.",
      ),
    ]);

    expect(replaced.map((item) => item.eventId).toList(), <String>[
      'evt-user',
      'evt-assistant',
      'evt-command',
    ]);
  });

  test(
    'replaceTimelineItems orders same-turn same-timestamp user before work',
    () {
      final replaced = replaceTimelineItems(<ThreadTimelineEntryDto>[
        _terminalOutputEntry(
          eventId: 'turn-123-call_status',
          occurredAt: '2026-04-06T09:00:12.000Z',
          summary: r'$ git status',
        ),
        _assistantOutputEntry(
          eventId: 'turn-123-item-2',
          occurredAt: '2026-04-06T09:00:12.000Z',
          text: "I'm checking the worktree first.",
        ),
        _userPromptEntry(
          eventId: 'turn-123-item-1',
          occurredAt: '2026-04-06T09:00:12.000Z',
          text: 'Split these commits',
        ),
        _terminalOutputEntry(
          eventId: 'turn-123-call_ls',
          occurredAt: '2026-04-06T09:00:12.000Z',
          summary: r'$ ls',
        ),
      ]);

      expect(replaced.map((item) => item.eventId).toList(), <String>[
        'turn-123-item-1',
        'turn-123-item-2',
        'turn-123-call_status',
        'turn-123-call_ls',
      ]);
    },
  );

  test(
    'prependTimelineEntries reorders older same-turn work behind existing user prompt',
    () {
      final prepended = prependTimelineEntries(
        currentItems: <ThreadActivityItem>[
          _userPrompt(
            eventId: 'turn-123-item-1',
            occurredAt: '2026-04-06T09:00:12.000Z',
            text: 'Split these commits',
          ),
          _assistantOutput(
            eventId: 'turn-123-item-2',
            occurredAt: '2026-04-06T09:00:12.000Z',
            text: "I'm checking the worktree first.",
          ),
        ],
        timeline: <ThreadTimelineEntryDto>[
          _terminalOutputEntry(
            eventId: 'turn-123-call_status',
            occurredAt: '2026-04-06T09:00:12.000Z',
            summary: r'$ git status',
          ),
          _terminalOutputEntry(
            eventId: 'turn-123-call_ls',
            occurredAt: '2026-04-06T09:00:12.000Z',
            summary: r'$ ls',
          ),
        ],
        knownEventIds: <String>{'turn-123-item-1', 'turn-123-item-2'},
      );

      expect(prepended.map((item) => item.eventId).toList(), <String>[
        'turn-123-item-1',
        'turn-123-item-2',
        'turn-123-call_status',
        'turn-123-call_ls',
      ]);
    },
  );
}

ThreadActivityItem _userPrompt({
  required String eventId,
  required String occurredAt,
  required String text,
  String? clientMessageId,
  List<String> images = const <String>[],
}) {
  return ThreadActivityItem.fromTimelineEntry(
    ThreadTimelineEntryDto(
      eventId: eventId,
      kind: BridgeEventKind.messageDelta,
      occurredAt: occurredAt,
      summary: text,
      payload: <String, dynamic>{
        'type': 'userMessage',
        'role': 'user',
        'text': text,
        if (images.isNotEmpty) 'images': images,
        ...?clientMessageId == null
            ? null
            : <String, dynamic>{'client_message_id': clientMessageId},
      },
    ),
  );
}

ThreadActivityItem _terminalOutput({
  required String eventId,
  required String occurredAt,
  required String summary,
}) {
  return ThreadActivityItem.fromTimelineEntry(
    _terminalOutputEntry(
      eventId: eventId,
      occurredAt: occurredAt,
      summary: summary,
    ),
  );
}

ThreadActivityItem _assistantOutput({
  required String eventId,
  required String occurredAt,
  required String text,
}) {
  return ThreadActivityItem.fromTimelineEntry(
    _assistantOutputEntry(eventId: eventId, occurredAt: occurredAt, text: text),
  );
}

ThreadTimelineEntryDto _userPromptEntry({
  required String eventId,
  required String occurredAt,
  required String text,
  String? clientMessageId,
  List<String> images = const <String>[],
}) {
  return ThreadTimelineEntryDto(
    eventId: eventId,
    kind: BridgeEventKind.messageDelta,
    occurredAt: occurredAt,
    summary: text,
    payload: <String, dynamic>{
      'type': 'userMessage',
      'role': 'user',
      'text': text,
      if (images.isNotEmpty) 'images': images,
      ...?clientMessageId == null
          ? null
          : <String, dynamic>{'client_message_id': clientMessageId},
    },
  );
}

ThreadTimelineEntryDto _assistantOutputEntry({
  required String eventId,
  required String occurredAt,
  required String text,
}) {
  return ThreadTimelineEntryDto(
    eventId: eventId,
    kind: BridgeEventKind.messageDelta,
    occurredAt: occurredAt,
    summary: text,
    payload: <String, dynamic>{
      'type': 'agentMessage',
      'role': 'assistant',
      'text': text,
    },
  );
}

ThreadTimelineEntryDto _terminalOutputEntry({
  required String eventId,
  required String occurredAt,
  required String summary,
}) {
  return ThreadTimelineEntryDto(
    eventId: eventId,
    kind: BridgeEventKind.commandDelta,
    occurredAt: occurredAt,
    summary: summary,
    payload: <String, dynamic>{'command': 'exec_command', 'output': summary},
  );
}
