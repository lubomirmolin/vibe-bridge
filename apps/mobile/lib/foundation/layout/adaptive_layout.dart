import 'dart:math' as math;

import 'package:flutter/material.dart';

class AdaptiveLayoutInfo {
  const AdaptiveLayoutInfo({
    required this.windowSize,
    required this.verticalFoldBounds,
  });

  static const double tabletBreakpoint = 900;
  static const double maxContentWidth = 1440;
  static const double splitPaneMinWidth = 360;

  final Size windowSize;
  final Rect? verticalFoldBounds;

  factory AdaptiveLayoutInfo.fromMediaQuery(MediaQueryData mediaQuery) {
    final verticalFold = mediaQuery.displayFeatures
        .map((feature) => feature.bounds)
        .where((bounds) {
          return bounds.width > 0 &&
              bounds.height >= mediaQuery.size.height * 0.6 &&
              bounds.left > 0 &&
              bounds.right < mediaQuery.size.width;
        })
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

    return windowSize.width >= tabletBreakpoint;
  }

  bool get hasSeparatingFold => verticalFoldBounds != null && isWideLayout;

  double constrainedContentWidth(double availableWidth) {
    return math.min(availableWidth, maxContentWidth);
  }
}
