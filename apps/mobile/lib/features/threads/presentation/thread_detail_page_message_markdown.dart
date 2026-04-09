part of 'thread_detail_page.dart';

class _ThreadTextBlock extends StatelessWidget {
  const _ThreadTextBlock({
    required this.block,
    required this.textStyle,
    required this.blockIndex,
  });

  final _MessageTextBlock block;
  final TextStyle textStyle;
  final int blockIndex;

  @override
  Widget build(BuildContext context) {
    switch (block.kind) {
      case _MessageTextBlockKind.paragraph:
        return _ThreadInlineText(
          key: Key('thread-message-text-$blockIndex'),
          text: block.text,
          textStyle: textStyle,
        );
      case _MessageTextBlockKind.list:
        return _ThreadListBlock(
          blockIndex: blockIndex,
          items: block.items,
          textStyle: textStyle,
        );
    }
  }
}

class _ThreadListBlock extends StatelessWidget {
  const _ThreadListBlock({
    required this.blockIndex,
    required this.items,
    required this.textStyle,
  });

  final int blockIndex;
  final List<_MessageListItem> items;
  final TextStyle textStyle;

  @override
  Widget build(BuildContext context) {
    final markerWidth = _markerColumnWidth(items);
    return Column(
      key: Key('thread-message-list-$blockIndex'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var index = 0; index < items.length; index++) ...[
          if (index > 0) const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: markerWidth,
                child: Text(
                  items[index].marker,
                  key: Key(
                    'thread-message-list-$blockIndex-item-$index-marker',
                  ),
                  style: GoogleFonts.jetBrainsMono(
                    textStyle: textStyle.copyWith(
                      fontSize: textStyle.fontSize,
                      height: textStyle.height,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              Expanded(
                child: _ThreadInlineText(
                  key: Key('thread-message-list-$blockIndex-item-$index-text'),
                  text: items[index].text,
                  textStyle: textStyle,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  double _markerColumnWidth(List<_MessageListItem> items) {
    final markerLength = items
        .map((entry) => entry.marker.length)
        .fold<int>(0, math.max);
    return markerLength <= 1 ? 18 : (markerLength * 9 + 10).toDouble();
  }
}

enum _MessageTextBlockKind { paragraph, list }

class _MessageTextBlock {
  const _MessageTextBlock._({
    required this.kind,
    this.text = '',
    this.items = const <_MessageListItem>[],
  });

  factory _MessageTextBlock.paragraph(String text) =>
      _MessageTextBlock._(kind: _MessageTextBlockKind.paragraph, text: text);

  factory _MessageTextBlock.list(List<_MessageListItem> items) =>
      _MessageTextBlock._(kind: _MessageTextBlockKind.list, items: items);

  final _MessageTextBlockKind kind;
  final String text;
  final List<_MessageListItem> items;
}

class _MessageListItem {
  const _MessageListItem({required this.marker, required this.text});

  final String marker;
  final String text;

  _MessageListItem copyWith({String? marker, String? text}) {
    return _MessageListItem(
      marker: marker ?? this.marker,
      text: text ?? this.text,
    );
  }
}

class _MessageTextBlockParser {
  static final RegExp _unorderedListPattern = RegExp(r'^\s*[-*]\s+(.+?)\s*$');
  static final RegExp _orderedListPattern = RegExp(
    r'^\s*(\d+[\.\)])\s+(.+?)\s*$',
  );

  static List<_MessageTextBlock> parse(String text) {
    if (text.trim().isEmpty) {
      return const <_MessageTextBlock>[];
    }

    final blocks = <_MessageTextBlock>[];
    final paragraphLines = <String>[];
    final listItems = <_MessageListItem>[];
    final lines = text.split('\n');

    void flushParagraph() {
      if (paragraphLines.isEmpty) {
        return;
      }
      blocks.add(_MessageTextBlock.paragraph(paragraphLines.join('\n')));
      paragraphLines.clear();
    }

    void flushList() {
      if (listItems.isEmpty) {
        return;
      }
      blocks.add(_MessageTextBlock.list(List<_MessageListItem>.of(listItems)));
      listItems.clear();
    }

    for (final line in lines) {
      if (line.trim().isEmpty) {
        flushParagraph();
        flushList();
        continue;
      }

      final unorderedMatch = _unorderedListPattern.firstMatch(line);
      if (unorderedMatch != null) {
        flushParagraph();
        listItems.add(
          _MessageListItem(marker: '•', text: unorderedMatch.group(1)!.trim()),
        );
        continue;
      }

      final orderedMatch = _orderedListPattern.firstMatch(line);
      if (orderedMatch != null) {
        flushParagraph();
        listItems.add(
          _MessageListItem(
            marker: orderedMatch.group(1)!.trim(),
            text: orderedMatch.group(2)!.trim(),
          ),
        );
        continue;
      }

      if (listItems.isNotEmpty && _looksLikeListContinuation(line)) {
        final previous = listItems.removeLast();
        listItems.add(
          previous.copyWith(text: '${previous.text}\n${line.trim()}'),
        );
        continue;
      }

      flushList();
      paragraphLines.add(line);
    }

    flushParagraph();
    flushList();
    return blocks;
  }

  static bool _looksLikeListContinuation(String line) {
    return line.startsWith('  ') || line.startsWith('\t');
  }
}
