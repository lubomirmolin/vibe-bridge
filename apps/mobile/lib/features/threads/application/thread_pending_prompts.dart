import 'package:flutter/foundation.dart';
import 'package:vibe_bridge/features/threads/domain/thread_activity_item.dart';

const Duration _pendingPromptMatchLeadSkew = Duration(seconds: 2);

class PendingPromptReconcileMatch {
  const PendingPromptReconcileMatch({
    required this.pendingItem,
    required this.canonicalItem,
  });

  final ThreadActivityItem pendingItem;
  final ThreadActivityItem canonicalItem;
}

class PendingPromptReconcileResult {
  const PendingPromptReconcileResult({
    required this.remainingItems,
    required this.matches,
    required this.unmatchedItems,
    required this.canonicalPromptCount,
    required this.lastCanonicalPromptAt,
  });

  final List<ThreadActivityItem> remainingItems;
  final List<PendingPromptReconcileMatch> matches;
  final List<ThreadActivityItem> unmatchedItems;
  final int canonicalPromptCount;
  final String? lastCanonicalPromptAt;
}

PendingPromptReconcileResult reconcilePendingLocalUserPrompts({
  required List<ThreadActivityItem> canonicalItems,
  required List<ThreadActivityItem> pendingItems,
}) {
  final canonicalUserPrompts = canonicalItems
      .where((item) => item.type == ThreadActivityItemType.userPrompt)
      .toList(growable: false);

  if (canonicalUserPrompts.isEmpty) {
    return PendingPromptReconcileResult(
      remainingItems: pendingItems,
      matches: const <PendingPromptReconcileMatch>[],
      unmatchedItems: pendingItems,
      canonicalPromptCount: 0,
      lastCanonicalPromptAt: null,
    );
  }

  final remainingItems = <ThreadActivityItem>[];
  final matches = <PendingPromptReconcileMatch>[];
  final unmatchedItems = <ThreadActivityItem>[];
  var searchStart = 0;

  for (final pendingItem in pendingItems) {
    final matchIndex = _findCanonicalPendingPromptMatchIndex(
      canonicalUserPrompts: canonicalUserPrompts,
      pendingItem: pendingItem,
      searchStart: searchStart,
    );
    if (matchIndex >= 0) {
      matches.add(
        PendingPromptReconcileMatch(
          pendingItem: pendingItem,
          canonicalItem: canonicalUserPrompts[matchIndex],
        ),
      );
      searchStart = matchIndex + 1;
      continue;
    }

    remainingItems.add(pendingItem);
    unmatchedItems.add(pendingItem);
  }

  return PendingPromptReconcileResult(
    remainingItems: List<ThreadActivityItem>.unmodifiable(remainingItems),
    matches: List<PendingPromptReconcileMatch>.unmodifiable(matches),
    unmatchedItems: List<ThreadActivityItem>.unmodifiable(unmatchedItems),
    canonicalPromptCount: canonicalUserPrompts.length,
    lastCanonicalPromptAt: canonicalUserPrompts.last.occurredAt,
  );
}

List<ThreadActivityItem> markPendingPromptsFailed(
  List<ThreadActivityItem> pendingItems, {
  required String errorMessage,
}) {
  return List<ThreadActivityItem>.unmodifiable(
    pendingItems
        .map((item) {
          if (item.localMessageState !=
              ThreadActivityLocalMessageState.sending) {
            return item;
          }
          return item.copyWith(
            localMessageState: ThreadActivityLocalMessageState.failed,
            localErrorMessage: errorMessage,
          );
        })
        .toList(growable: false),
  );
}

DateTime? pendingPromptFailureGraceDeadline({
  required DateTime? submittedAt,
  required DateTime? settledAt,
  required Duration graceWindow,
}) {
  if (submittedAt == null) {
    return null;
  }

  final settlementAnchor = settledAt ?? submittedAt;
  final submittedDeadline = submittedAt.add(graceWindow);
  final settlementDeadline = settlementAnchor.add(graceWindow);
  return submittedDeadline.isAfter(settlementDeadline)
      ? submittedDeadline
      : settlementDeadline;
}

int _findCanonicalPendingPromptMatchIndex({
  required List<ThreadActivityItem> canonicalUserPrompts,
  required ThreadActivityItem pendingItem,
  required int searchStart,
}) {
  final pendingClientMessageId = pendingItem.clientMessageId;
  if (pendingClientMessageId != null && pendingClientMessageId.isNotEmpty) {
    final exactClientMessageMatch = canonicalUserPrompts.indexWhere(
      (candidate) => candidate.clientMessageId == pendingClientMessageId,
      searchStart,
    );
    if (exactClientMessageMatch >= 0) {
      return exactClientMessageMatch;
    }
  }

  final normalizedPendingBody = _normalizeActivityBody(pendingItem.body);
  final pendingImages = pendingItem.messageImageUrls.toSet();

  for (
    var index = searchStart;
    index < canonicalUserPrompts.length;
    index += 1
  ) {
    final candidate = canonicalUserPrompts[index];
    final normalizedCandidateBody = _normalizeActivityBody(candidate.body);
    if (normalizedPendingBody != normalizedCandidateBody) {
      continue;
    }
    if (!_isCanonicalPromptTimeCompatible(
      pendingOccurredAt: pendingItem.occurredAt,
      candidateOccurredAt: candidate.occurredAt,
    )) {
      continue;
    }

    final candidateImages = candidate.messageImageUrls.toSet();
    if (pendingImages.isNotEmpty &&
        candidateImages.isNotEmpty &&
        !setEquals(pendingImages, candidateImages)) {
      continue;
    }
    return index;
  }

  return -1;
}

bool _isCanonicalPromptTimeCompatible({
  required String pendingOccurredAt,
  required String candidateOccurredAt,
}) {
  final pendingTime = DateTime.tryParse(pendingOccurredAt);
  final candidateTime = DateTime.tryParse(candidateOccurredAt);
  if (pendingTime == null || candidateTime == null) {
    return true;
  }

  return !candidateTime.isBefore(
    pendingTime.subtract(_pendingPromptMatchLeadSkew),
  );
}

String _normalizeActivityBody(String body) => body.trim();
