import 'package:vibe_bridge/features/threads/domain/thread_activity_item.dart';
import 'package:vibe_bridge/foundation/contracts/bridge_contracts.dart';
import 'package:flutter/foundation.dart';

const Duration _assistantReplayDedupWindow = Duration(minutes: 2);

List<ThreadActivityItem> replaceTimelineItems(
  List<ThreadTimelineEntryDto> timeline,
) {
  return List<ThreadActivityItem>.unmodifiable(
    timeline.map(ThreadActivityItem.fromTimelineEntry),
  );
}

List<ThreadActivityItem> mergeTimelineEntries({
  required List<ThreadActivityItem> currentItems,
  required List<ThreadTimelineEntryDto> timeline,
}) {
  if (timeline.isEmpty) {
    return currentItems;
  }

  final nextItems = List<ThreadActivityItem>.from(currentItems);
  for (final entry in timeline) {
    final nextItem = ThreadActivityItem.fromTimelineEntry(entry);
    final existingIndex = findTimelineMergeIndex(
      items: nextItems,
      candidate: nextItem,
    );
    if (existingIndex >= 0) {
      nextItems[existingIndex] = preferTimelineMergedItem(
        current: nextItems[existingIndex],
        candidate: nextItem,
      );
    } else {
      nextItems.add(nextItem);
    }
  }

  return List<ThreadActivityItem>.unmodifiable(nextItems);
}

List<ThreadActivityItem> prependTimelineEntries({
  required List<ThreadActivityItem> currentItems,
  required List<ThreadTimelineEntryDto> timeline,
  required Set<String> knownEventIds,
}) {
  if (timeline.isEmpty) {
    return currentItems;
  }

  final prependedItems = <ThreadActivityItem>[];
  for (final entry in timeline) {
    final nextItem = ThreadActivityItem.fromTimelineEntry(entry);
    if (knownEventIds.contains(entry.eventId) ||
        findTimelineMergeIndex(items: currentItems, candidate: nextItem) >= 0 ||
        findTimelineMergeIndex(items: prependedItems, candidate: nextItem) >=
            0) {
      continue;
    }

    prependedItems.add(nextItem);
    knownEventIds.add(entry.eventId);
  }

  if (prependedItems.isEmpty) {
    return currentItems;
  }

  final currentItemsWithBoundary = currentItems.isEmpty
      ? currentItems
      : List<ThreadActivityItem>.unmodifiable(<ThreadActivityItem>[
          currentItems.first.copyWith(startsNewVisualGroup: true),
          ...currentItems.skip(1),
        ]);

  return List<ThreadActivityItem>.unmodifiable(<ThreadActivityItem>[
    ...prependedItems,
    ...currentItemsWithBoundary,
  ]);
}

int findTimelineMergeIndex({
  required List<ThreadActivityItem> items,
  required ThreadActivityItem candidate,
}) {
  final exactIndex = items.indexWhere(
    (item) => item.eventId == candidate.eventId,
  );
  if (exactIndex >= 0) {
    return exactIndex;
  }

  final equivalentIndex = items.indexWhere(
    (item) =>
        _isEquivalentTimelineActivityItem(existing: item, candidate: candidate),
  );
  if (equivalentIndex >= 0) {
    return equivalentIndex;
  }

  return _findReplayAssistantMergeIndex(items: items, candidate: candidate);
}

ThreadActivityItem preferTimelineMergedItem({
  required ThreadActivityItem current,
  required ThreadActivityItem candidate,
}) {
  if (current.eventId == candidate.eventId) {
    return candidate;
  }

  switch (candidate.type) {
    case ThreadActivityItemType.userPrompt:
      return candidate.messageImageUrls.length > current.messageImageUrls.length
          ? candidate
          : current;
    case ThreadActivityItemType.assistantOutput:
      final currentBody = _normalizeActivityBody(current.body);
      final candidateBody = _normalizeActivityBody(candidate.body);
      if (candidateBody.length > currentBody.length &&
          candidateBody.startsWith(currentBody)) {
        return candidate;
      }
      if (currentBody.length > candidateBody.length &&
          currentBody.startsWith(candidateBody)) {
        return current;
      }
      return candidateBody.length >= currentBody.length ? candidate : current;
    case ThreadActivityItemType.planUpdate:
    case ThreadActivityItemType.terminalOutput:
    case ThreadActivityItemType.fileChange:
    case ThreadActivityItemType.lifecycleUpdate:
    case ThreadActivityItemType.approvalRequest:
    case ThreadActivityItemType.securityEvent:
    case ThreadActivityItemType.generic:
      return candidate;
  }
}

int _findReplayAssistantMergeIndex({
  required List<ThreadActivityItem> items,
  required ThreadActivityItem candidate,
}) {
  if (candidate.type != ThreadActivityItemType.assistantOutput) {
    return -1;
  }

  final candidateBody = _normalizeActivityBody(candidate.body);
  if (candidateBody.isEmpty) {
    return -1;
  }

  for (var index = items.length - 1; index >= 0; index -= 1) {
    final existing = items[index];
    if (existing.type == ThreadActivityItemType.userPrompt) {
      break;
    }
    if (existing.type != ThreadActivityItemType.assistantOutput) {
      continue;
    }
    if (!_areEquivalentAssistantBodies(existing.body, candidateBody)) {
      continue;
    }
    if (!_areTimelineMomentsWithinReplayWindow(
      existing.occurredAt,
      candidate.occurredAt,
    )) {
      continue;
    }
    return index;
  }

  return -1;
}

bool _isEquivalentTimelineActivityItem({
  required ThreadActivityItem existing,
  required ThreadActivityItem candidate,
}) {
  if (existing.kind != candidate.kind || existing.type != candidate.type) {
    return false;
  }
  if (!_areTimelineMomentsEquivalent(
    existing.occurredAt,
    candidate.occurredAt,
  )) {
    return false;
  }

  switch (candidate.type) {
    case ThreadActivityItemType.userPrompt:
      return _normalizeActivityBody(existing.body) ==
              _normalizeActivityBody(candidate.body) &&
          setEquals(
            existing.messageImageUrls.toSet(),
            candidate.messageImageUrls.toSet(),
          );
    case ThreadActivityItemType.assistantOutput:
      return _areEquivalentAssistantBodies(existing.body, candidate.body);
    case ThreadActivityItemType.planUpdate:
    case ThreadActivityItemType.terminalOutput:
    case ThreadActivityItemType.fileChange:
    case ThreadActivityItemType.lifecycleUpdate:
    case ThreadActivityItemType.approvalRequest:
    case ThreadActivityItemType.securityEvent:
    case ThreadActivityItemType.generic:
      return false;
  }
}

bool _areTimelineMomentsEquivalent(String left, String right) {
  if (left == right) {
    return true;
  }

  final leftTime = DateTime.tryParse(left);
  final rightTime = DateTime.tryParse(right);
  if (leftTime == null || rightTime == null) {
    return false;
  }

  return leftTime.difference(rightTime).abs() <= const Duration(seconds: 2);
}

bool _areTimelineMomentsWithinReplayWindow(String left, String right) {
  if (left == right) {
    return true;
  }

  final leftTime = DateTime.tryParse(left);
  final rightTime = DateTime.tryParse(right);
  if (leftTime == null || rightTime == null) {
    return false;
  }

  return leftTime.difference(rightTime).abs() <= _assistantReplayDedupWindow;
}

bool _areEquivalentAssistantBodies(String left, String right) {
  final normalizedLeft = _normalizeActivityBody(left);
  final normalizedRight = _normalizeActivityBody(right);
  if (normalizedLeft.isEmpty || normalizedRight.isEmpty) {
    return false;
  }

  final compactLeft = _compactActivityBody(normalizedLeft);
  final compactRight = _compactActivityBody(normalizedRight);

  return normalizedLeft == normalizedRight ||
      compactLeft == compactRight ||
      normalizedLeft.startsWith(normalizedRight) ||
      normalizedRight.startsWith(normalizedLeft);
}

String _normalizeActivityBody(String body) => body.trim();

String _compactActivityBody(String body) {
  return body.replaceAll(RegExp(r'\s+'), '');
}
