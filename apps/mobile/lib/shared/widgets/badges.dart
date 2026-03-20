import 'package:codex_mobile_companion/foundation/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

enum BadgeVariant { defaultVariant, active, warning, danger }

class StatusBadge extends StatelessWidget {
  final String text;
  final BadgeVariant variant;

  const StatusBadge({
    super.key,
    required this.text,
    this.variant = BadgeVariant.defaultVariant,
  });

  @override
  Widget build(BuildContext context) {
    Color borderColor;
    Color textColor;
    Color backgroundColor;

    switch (variant) {
      case BadgeVariant.active:
        borderColor = AppTheme.emerald.withValues(alpha: 0.3);
        textColor = const Color(0xFF34D399); // emerald-400
        backgroundColor = AppTheme.emerald.withValues(alpha: 0.1);
        break;
      case BadgeVariant.warning:
        borderColor = AppTheme.amber.withValues(alpha: 0.3);
        textColor = const Color(0xFFFBBF24); // amber-400
        backgroundColor = AppTheme.amber.withValues(alpha: 0.1);
        break;
      case BadgeVariant.danger:
        borderColor = AppTheme.rose.withValues(alpha: 0.3);
        textColor = const Color(0xFFFB7185); // rose-400
        backgroundColor = AppTheme.rose.withValues(alpha: 0.1);
        break;
      case BadgeVariant.defaultVariant:
      default:
        borderColor = AppTheme.surfaceZinc800; // border-zinc-800
        textColor = AppTheme.textMuted; // text-zinc-400
        backgroundColor = Colors.transparent;
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: backgroundColor,
        border: Border.all(color: borderColor),
        borderRadius: BorderRadius.circular(9999),
      ),
      child: Text(
        text,
        style: GoogleFonts.jetBrainsMono(
          color: textColor,
          fontSize: 10,
          letterSpacing: 1.0,
        ),
      ),
    );
  }
}
