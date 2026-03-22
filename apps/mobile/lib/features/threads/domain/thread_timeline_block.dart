import 'package:codex_mobile_companion/features/threads/domain/thread_activity_item.dart';

class ThreadTimelineBlock {
  const ThreadTimelineBlock._({this.item, this.exploration, this.workSummary});

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

  factory ThreadTimelineBlock.workSummary(ThreadTimelineWorkSummary summary) {
    return ThreadTimelineBlock._(workSummary: summary);
  }

  final ThreadActivityItem? item;
  final ThreadTimelineExplorationSummary? exploration;
  final ThreadTimelineWorkSummary? workSummary;
}

class ThreadTimelineWorkSummary {
  const ThreadTimelineWorkSummary({
    required this.blocks,
    required this.sourceEventIds,
    required this.actionCount,
    this.totalWallTimeSeconds,
  });

  final List<ThreadTimelineBlock> blocks;
  final List<String> sourceEventIds;
  final int actionCount;
  final double? totalWallTimeSeconds;
}

class ThreadTimelineExplorationSummary {
  const ThreadTimelineExplorationSummary({
    required this.files,
    required this.searchCount,
    required this.searchLabels,
    required this.sourceEventIds,
    this.totalWallTimeSeconds,
  });

  final List<String> files;
  final int searchCount;
  final Map<String, int> searchLabels;
  final List<String> sourceEventIds;
  final double? totalWallTimeSeconds;

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
  return _bundleWorkBlocks(_buildBaseTimelineBlocks(items));
}

List<ThreadTimelineBlock> _buildBaseTimelineBlocks(
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
  final Map<String, int> _searchLabels = <String, int>{};
  final List<String> _sourceEventIds = <String>[];
  int _searchCount = 0;
  double _totalWallTimeSeconds = 0;
  bool _hasWallTime = false;

  bool get hasContent => _files.isNotEmpty || _searchCount > 0;

  void add(ThreadActivityItem item) {
    final presentation = item.presentation;
    if (presentation == null) {
      return;
    }

    _sourceEventIds.add(item.eventId);
    final wallTimeSeconds = item.parsedCommandOutput?.wallTimeSeconds;
    if (wallTimeSeconds != null && wallTimeSeconds > 0) {
      _totalWallTimeSeconds += wallTimeSeconds;
      _hasWallTime = true;
    }

    switch (presentation.entryKind) {
      case ThreadActivityPresentationEntryKind.search:
        _searchCount += 1;
        final label = presentation.entryLabel?.trim();
        if (label != null && label.isNotEmpty) {
          _searchLabels.update(label, (count) => count + 1, ifAbsent: () => 1);
        }
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
      searchLabels: Map<String, int>.unmodifiable(_searchLabels),
      sourceEventIds: List<String>.unmodifiable(_sourceEventIds),
      totalWallTimeSeconds: _hasWallTime ? _totalWallTimeSeconds : null,
    );
  }
}

bool _isExplorationItem(ThreadActivityItem item) {
  return item.presentation?.groupKind ==
      ThreadActivityPresentationGroupKind.exploration;
}

List<ThreadTimelineBlock> _bundleWorkBlocks(List<ThreadTimelineBlock> blocks) {
  if (blocks.isEmpty) {
    return const <ThreadTimelineBlock>[];
  }

  final bundled = <ThreadTimelineBlock>[];
  var index = 0;

  while (index < blocks.length) {
    if (!_isWorkLikeBlock(blocks[index])) {
      bundled.add(blocks[index]);
      index += 1;
      continue;
    }

    var scanIndex = index;
    while (scanIndex < blocks.length && _isWorkLikeBlock(blocks[scanIndex])) {
      scanIndex += 1;
    }

    final workBlocks = blocks.sublist(index, scanIndex);
    final sourceEventIds = <String>[];
    var actionCount = 0;
    var totalWallTimeSeconds = 0.0;
    var hasWallTime = false;

    for (final block in workBlocks) {
      final item = block.item;
      final exploration = block.exploration;
      if (item != null) {
        sourceEventIds.add(item.eventId);
        actionCount += 1;
        final wallTimeSeconds = item.parsedCommandOutput?.wallTimeSeconds;
        if (wallTimeSeconds != null && wallTimeSeconds > 0) {
          totalWallTimeSeconds += wallTimeSeconds;
          hasWallTime = true;
        }
      }

      if (exploration != null) {
        sourceEventIds.addAll(exploration.sourceEventIds);
        actionCount += exploration.sourceEventIds.length;
        final wallTimeSeconds = exploration.totalWallTimeSeconds;
        if (wallTimeSeconds != null && wallTimeSeconds > 0) {
          totalWallTimeSeconds += wallTimeSeconds;
          hasWallTime = true;
        }
      }
    }

    if (workBlocks.length == 1 && actionCount <= 1) {
      bundled.add(workBlocks.first);
      index = scanIndex;
      continue;
    }

    bundled.add(
      ThreadTimelineBlock.workSummary(
        ThreadTimelineWorkSummary(
          blocks: List<ThreadTimelineBlock>.unmodifiable(workBlocks),
          sourceEventIds: List<String>.unmodifiable(sourceEventIds),
          actionCount: actionCount,
          totalWallTimeSeconds: hasWallTime ? totalWallTimeSeconds : null,
        ),
      ),
    );
    index = scanIndex;
  }

  return List<ThreadTimelineBlock>.unmodifiable(bundled);
}

bool _isWorkLikeBlock(ThreadTimelineBlock block) {
  final item = block.item;
  if (item == null) {
    return block.exploration != null;
  }

  return item.type == ThreadActivityItemType.terminalOutput ||
      item.type == ThreadActivityItemType.fileChange;
}
