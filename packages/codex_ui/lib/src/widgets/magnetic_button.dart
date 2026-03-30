import 'dart:ui';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

enum MagneticButtonVariant { primary, secondary, danger }

class MagneticButton extends StatefulWidget {
  final Widget child;
  final VoidCallback onClick;
  final MagneticButtonVariant variant;
  final EdgeInsetsGeometry padding;
  final bool isCircle;
  final Color? backgroundColorOverride;
  final Color? foregroundColorOverride;

  const MagneticButton({
    super.key,
    required this.child,
    required this.onClick,
    this.variant = MagneticButtonVariant.primary,
    this.padding = const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
    this.isCircle = false,
    this.backgroundColorOverride,
    this.foregroundColorOverride,
  });

  @override
  State<MagneticButton> createState() => _MagneticButtonState();
}

class _MagneticButtonState extends State<MagneticButton> {
  Offset _dragOffset = Offset.zero;
  bool _isHovered = false;
  bool _isPressed = false;

  void _updateOffset(Offset localPosition, Size size) {
    final centerX = size.width / 2;
    final centerY = size.height / 2;

    setState(() {
      _dragOffset = Offset(
        (localPosition.dx - centerX) * 0.2,
        (localPosition.dy - centerY) * 0.2,
      );
    });
  }

  void _resetOffset() {
    setState(() {
      _isHovered = false;
      _isPressed = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isActive = _isHovered || _isPressed;

    BoxDecoration decoration;
    Color textColor;
    double blurSigma = 0;
    List<BoxShadow>? shadows;

    switch (widget.variant) {
      case MagneticButtonVariant.primary:
        decoration = BoxDecoration(
          color: isActive ? Colors.white : AppTheme.surfaceZinc100,
          borderRadius: BorderRadius.circular(9999),
        );
        textColor = AppTheme.background;
        break;
      case MagneticButtonVariant.secondary:
        blurSigma = 16.0;
        shadows = const [
          BoxShadow(
            color: Colors.black45,
            offset: Offset(0, 6),
            blurRadius: 12,
          ),
        ];
        decoration = BoxDecoration(
          color: isActive
              ? Colors.white.withValues(alpha: 0.15)
              : Colors.white.withValues(alpha: 0.05),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.2),
            width: 1,
          ),
          borderRadius: BorderRadius.circular(9999),
        );
        textColor = AppTheme.textMain;
        break;
      case MagneticButtonVariant.danger:
        decoration = BoxDecoration(
          color: isActive
              ? AppTheme.rose.withValues(alpha: 0.2)
              : AppTheme.rose.withValues(alpha: 0.1),
          border: Border.all(color: AppTheme.rose.withValues(alpha: 0.2)),
          borderRadius: BorderRadius.circular(9999),
        );
        textColor = AppTheme.rose;
        break;
    }

    if (widget.backgroundColorOverride != null) {
      decoration = decoration.copyWith(color: widget.backgroundColorOverride);
    }
    if (widget.foregroundColorOverride != null) {
      textColor = widget.foregroundColorOverride!;
    }

    Widget innerContainer = AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
      decoration: decoration,
      padding: widget.isCircle ? EdgeInsets.zero : widget.padding,
      alignment: Alignment.center,
      child: DefaultTextStyle(
        style: Theme.of(context).textTheme.bodyMedium!.copyWith(
          color: textColor,
          fontWeight: FontWeight.w500,
          letterSpacing: -0.5,
        ),
        child: IconTheme(
          data: IconThemeData(color: textColor),
          child: widget.child,
        ),
      ),
    );

    if (blurSigma > 0) {
      innerContainer = ClipRRect(
        borderRadius: BorderRadius.circular(9999),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
          child: innerContainer,
        ),
      );
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => _resetOffset(),
      onHover: (event) {
        final box = context.findRenderObject() as RenderBox?;
        if (box != null) {
          _updateOffset(event.localPosition, box.size);
        }
      },
      child: Listener(
        onPointerDown: (event) {
          setState(() => _isPressed = true);
          final box = context.findRenderObject() as RenderBox?;
          if (box != null) _updateOffset(event.localPosition, box.size);
        },
        onPointerMove: (event) {
          final box = context.findRenderObject() as RenderBox?;
          if (box != null) _updateOffset(event.localPosition, box.size);
        },
        onPointerUp: (_) => _resetOffset(),
        onPointerCancel: (_) => _resetOffset(),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onClick,
          child: TweenAnimationBuilder<Offset>(
            duration: isActive
                ? const Duration(milliseconds: 50)
                : const Duration(milliseconds: 600),
            curve: isActive ? Curves.easeOut : Curves.elasticOut,
            tween: Tween<Offset>(
              begin: Offset.zero,
              end: isActive ? _dragOffset : Offset.zero,
            ),
            builder: (context, offset, child) {
              return Transform.translate(offset: offset, child: child);
            },
            child: AnimatedScale(
              duration: const Duration(milliseconds: 150),
              curve: Curves.easeOut,
              scale: _isPressed ? 0.98 : 1.0,
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(9999),
                  boxShadow: shadows,
                ),
                child: innerContainer,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
