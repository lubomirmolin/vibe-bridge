import 'dart:math' as math;

import 'package:flutter/material.dart';

class AdaptiveLayoutInfo {
  const AdaptiveLayoutInfo({
    required this.windowSize,
    required this.verticalFoldBounds,
  });

  static const double tabletBreakpoint = 720;
  static const double shortestSideWideBreakpoint = 700;
  static const double maxContentWidth = 1440;
  static const double splitPaneMinWidth = 320;

  final Size windowSize;
  final Rect? verticalFoldBounds;

  factory AdaptiveLayoutInfo.fromMediaQuery(MediaQueryData mediaQuery) {
    final verticalFold = mediaQuery.displayFeatures
        .where((feature) {
          final bounds = feature.bounds;
          final spansHeight = bounds.height >= mediaQuery.size.height * 0.6;
          final splitsScreen =
              bounds.left > 0 && bounds.right < mediaQuery.size.width;
          return spansHeight && splitsScreen;
        })
        .map((feature) => feature.bounds)
        .cast<Rect?>()
        .firstWhere((bounds) => bounds != null, orElse: () => null);

    return AdaptiveLayoutInfo(
      windowSize: mediaQuery.size,
      verticalFoldBounds: verticalFold,
    );
  }

  bool get isWideLayout {
    if (verticalFoldBounds != null) {
      final leftWidth = verticalFoldBounds!.left;
      final rightWidth = windowSize.width - verticalFoldBounds!.right;
      return leftWidth >= splitPaneMinWidth && rightWidth >= splitPaneMinWidth;
    }

    return windowSize.width >= tabletBreakpoint ||
        windowSize.shortestSide >= shortestSideWideBreakpoint;
  }

  bool get hasSeparatingFold => verticalFoldBounds != null && isWideLayout;

  double constrainedContentWidth(double availableWidth) {
    return math.min(availableWidth, maxContentWidth);
  }
}
