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
