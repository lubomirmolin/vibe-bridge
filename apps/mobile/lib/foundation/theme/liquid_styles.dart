import 'dart:ui';
import 'package:flutter/material.dart';

class LiquidStyles {
  static BoxDecoration get liquidGlass {
    return BoxDecoration(
      color: Colors.white.withOpacity(0.05),
      border: Border.all(color: Colors.white.withOpacity(0.1)),
      borderRadius: BorderRadius.circular(32),
      boxShadow: [
        BoxShadow(
          color: Colors.white.withOpacity(0.1),
          offset: const Offset(0, 1),
          blurRadius: 0,
          spreadRadius: 0,
          blurStyle: BlurStyle.inner,
        ),
      ],
    );
  }

  static BoxDecoration get liquidGlassHeavy {
    return BoxDecoration(
      color: const Color(0xFF18181B).withOpacity(0.8), // zinc-900 with opacity
      border: Border.all(color: Colors.white.withOpacity(0.1)),
      borderRadius: BorderRadius.circular(32),
      boxShadow: [
        BoxShadow(
          color: Colors.white.withOpacity(0.05),
          offset: const Offset(0, 1),
          blurStyle: BlurStyle.inner,
        ),
        BoxShadow(
          color: Colors.black.withOpacity(0.5),
          offset: const Offset(0, 20),
          blurRadius: 40,
          spreadRadius: -15,
        ),
      ],
    );
  }

  /// Helper to wrap any widget with the actual blur filter
  static Widget applyGlass(Widget child, {BoxDecoration? decoration, double sigma = 20}) {
    return ClipRRect(
      borderRadius: decoration?.borderRadius?.resolve(TextDirection.ltr) ?? BorderRadius.circular(32),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: Container(
          decoration: decoration ?? liquidGlass,
          child: child,
        ),
      ),
    );
  }
}
