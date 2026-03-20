import 'package:codex_mobile_companion/features/threads/domain/thread_activity_item.dart';

class ThreadTimelineBlock {
  const ThreadTimelineBlock._({this.item, this.exploration});

  factory ThreadTimelineBlock.activity(
    ThreadActivityItem item, {
    ThreadTimelineExplorationSummary? exploration,
  }) {
    return ThreadTimelineBlock._(item: item, exploration: exploration);
  }

  factory ThreadTimelineBlock.exploration(
    ThreadTimelineExplorationSummary exploration,
  ) {
    return ThreadTimelineBlock._(exploration: exploration);
  }

  final ThreadActivityItem? item;
  final ThreadTimelineExplorationSummary? exploration;
}

class ThreadTimelineExplorationSummary {
  const ThreadTimelineExplorationSummary({
    required this.files,
    required this.searchCount,
  });

  final List<String> files;
  final int searchCount;

  String get label {
    final parts = <String>[];
    if (files.isNotEmpty) {
      parts.add(
        'Explored ${files.length} ${files.length == 1 ? 'file' : 'files'}',
      );
    }
    if (searchCount > 0) {
      parts.add('$searchCount ${searchCount == 1 ? 'search' : 'searches'}');
    }
    if (parts.isEmpty) {
      return 'Explored activity';
    }
    if (parts.length == 1) {
      return parts.first;
    }
    return '${parts.first}, ${parts.sublist(1).join(', ')}';
  }
}

List<ThreadTimelineBlock> buildThreadTimelineBlocks(
  List<ThreadActivityItem> items,
) {
  final blocks = <ThreadTimelineBlock>[];
  var index = 0;

  while (index < items.length) {
    final item = items[index];
    final exploration = _ExplorationSummaryBuilder();

    if (_isExplorationItem(item)) {
      var scanIndex = index;
      while (scanIndex < items.length && _isExplorationItem(items[scanIndex])) {
        exploration.add(items[scanIndex]);
        scanIndex += 1;
      }

      if (exploration.hasContent) {
        blocks.add(ThreadTimelineBlock.exploration(exploration.build()));
        index = scanIndex;
        continue;
      }
    }

    var scanIndex = index + 1;
    while (scanIndex < items.length && _isExplorationItem(items[scanIndex])) {
      exploration.add(items[scanIndex]);
      scanIndex += 1;
    }

    blocks.add(
      ThreadTimelineBlock.activity(
        item,
        exploration: exploration.hasContent ? exploration.build() : null,
      ),
    );
    index = scanIndex;
  }

  return blocks;
}

String timelineLeadingBlockSignature(List<ThreadActivityItem> items) {
  final blocks = buildThreadTimelineBlocks(items);
  if (blocks.isEmpty) {
    return 'empty';
  }

  final firstBlock = blocks.first;
  if (firstBlock.item != null) {
    return 'activity:${firstBlock.item!.eventId}';
  }

  return 'exploration';
}

class _ExplorationSummaryBuilder {
  final List<String> _files = <String>[];
  final Set<String> _seenFiles = <String>{};
  int _searchCount = 0;

  bool get hasContent => _files.isNotEmpty || _searchCount > 0;

  void add(ThreadActivityItem item) {
    final presentation = item.presentation;
    if (presentation == null) {
      return;
    }

    switch (presentation.entryKind) {
      case ThreadActivityPresentationEntryKind.search:
        _searchCount += 1;
        return;
      case ThreadActivityPresentationEntryKind.read:
        final label = presentation.entryLabel;
        if (label != null && _seenFiles.add(label)) {
          _files.add(label);
        }
        return;
      case ThreadActivityPresentationEntryKind.generic:
        return;
    }
  }

  ThreadTimelineExplorationSummary build() {
    return ThreadTimelineExplorationSummary(
      files: List<String>.unmodifiable(_files),
      searchCount: _searchCount,
    );
  }
}

bool _isExplorationItem(ThreadActivityItem item) {
  return item.presentation?.groupKind ==
      ThreadActivityPresentationGroupKind.exploration;
}
