import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:codex_mobile_companion/foundation/theme/app_theme.dart';
import 'package:codex_mobile_companion/foundation/theme/liquid_styles.dart';

enum MagneticButtonVariant { primary, secondary, danger }

class MagneticButton extends StatefulWidget {
  final Widget child;
  final VoidCallback onClick;
  final MagneticButtonVariant variant;
  final EdgeInsetsGeometry padding;

  const MagneticButton({
    super.key,
    required this.child,
    required this.onClick,
    this.variant = MagneticButtonVariant.primary,
    this.padding = const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
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

    switch (widget.variant) {
      case MagneticButtonVariant.primary:
        decoration = BoxDecoration(
          color: isActive ? Colors.white : AppTheme.surfaceZinc100,
          borderRadius: BorderRadius.circular(9999),
        );
        textColor = AppTheme.background;
        break;
      case MagneticButtonVariant.secondary:
        decoration = LiquidStyles.liquidGlass.copyWith(
          color: isActive ? Colors.white.withValues(alpha: 0.1) : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(9999),
        );
        textColor = AppTheme.textMain;
        break;
      case MagneticButtonVariant.danger:
        decoration = BoxDecoration(
          color: isActive ? AppTheme.rose.withValues(alpha: 0.2) : AppTheme.rose.withValues(alpha: 0.1),
          border: Border.all(color: AppTheme.rose.withOpacity(0.2)),
          borderRadius: BorderRadius.circular(9999),
        );
        textColor = AppTheme.rose;
        break;
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
            duration: isActive ? const Duration(milliseconds: 50) : const Duration(milliseconds: 600),
            curve: isActive ? Curves.easeOut : Curves.elasticOut,
            tween: Tween<Offset>(begin: Offset.zero, end: isActive ? _dragOffset : Offset.zero),
            builder: (context, offset, child) {
              return Transform.translate(
                offset: offset,
                child: child,
              );
            },
            child: AnimatedScale(
              duration: const Duration(milliseconds: 150),
              curve: Curves.easeOut,
              scale: _isPressed ? 0.98 : 1.0,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOut,
                decoration: decoration,
                padding: widget.padding,
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
              ),
            ),
          ),
        ),
      ),
    );
  }
}
