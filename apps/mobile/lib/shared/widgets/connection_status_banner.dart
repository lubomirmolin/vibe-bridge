import 'package:codex_mobile_companion/foundation/theme/app_theme.dart';
import 'package:codex_mobile_companion/foundation/theme/liquid_styles.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

enum ConnectionBannerState { connected, reconnecting, disconnected }

class ConnectionStatusBanner extends StatelessWidget {
  const ConnectionStatusBanner({
    super.key,
    required this.state,
    this.detail,
    this.compact = false,
  });

  final ConnectionBannerState state;
  final String? detail;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final palette = _paletteForState(state);
    final resolvedDetail = detail?.trim();

    return Container(
      key: Key('connection-status-${state.name}'),
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: compact ? 8 : 12),
      decoration: LiquidStyles.liquidGlass.copyWith(
        borderRadius: BorderRadius.circular(18),
        color: palette.background,
        border: Border.all(color: palette.border),
      ),
      child: Row(
        children: [
          _StatusGlyph(state: state, color: palette.foreground),
          const SizedBox(width: 12),
          Expanded(
            child: compact
                ? Row(
                    children: [
                      Text(
                        _labelForState(state),
                        style: GoogleFonts.jetBrainsMono(
                          color: palette.foreground,
                          fontSize: 12,
                          letterSpacing: 1.6,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (resolvedDetail != null &&
                          resolvedDetail.isNotEmpty) ...[
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            resolvedDetail,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppTheme.textMuted,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _labelForState(state),
                        style: GoogleFonts.jetBrainsMono(
                          color: palette.foreground,
                          fontSize: 12,
                          letterSpacing: 1.6,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (resolvedDetail != null &&
                          resolvedDetail.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          resolvedDetail,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppTheme.textMuted,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  static String _labelForState(ConnectionBannerState state) {
    switch (state) {
      case ConnectionBannerState.connected:
        return 'CONNECTED';
      case ConnectionBannerState.reconnecting:
        return 'RECONNECTING';
      case ConnectionBannerState.disconnected:
        return 'DISCONNECTED';
    }
  }

  static _ConnectionBannerPalette _paletteForState(
    ConnectionBannerState state,
  ) {
    switch (state) {
      case ConnectionBannerState.connected:
        return const _ConnectionBannerPalette(
          foreground: AppTheme.emerald,
          border: Color(0x3310B981),
          background: Color(0x1410B981),
        );
      case ConnectionBannerState.reconnecting:
        return const _ConnectionBannerPalette(
          foreground: AppTheme.amber,
          border: Color(0x33F59E0B),
          background: Color(0x14F59E0B),
        );
      case ConnectionBannerState.disconnected:
        return const _ConnectionBannerPalette(
          foreground: AppTheme.rose,
          border: Color(0x33F43F5E),
          background: Color(0x14F43F5E),
        );
    }
  }
}

class _StatusGlyph extends StatelessWidget {
  const _StatusGlyph({required this.state, required this.color});

  final ConnectionBannerState state;
  final Color color;

  @override
  Widget build(BuildContext context) {
    switch (state) {
      case ConnectionBannerState.connected:
        return Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(color: color.withValues(alpha: 0.45), blurRadius: 10),
            ],
          ),
        );
      case ConnectionBannerState.reconnecting:
        return PhosphorIcon(
          PhosphorIcons.arrowsClockwise(),
          color: color,
          size: 16,
        );
      case ConnectionBannerState.disconnected:
        return PhosphorIcon(PhosphorIcons.wifiSlash(), color: color, size: 16);
    }
  }
}

class _ConnectionBannerPalette {
  const _ConnectionBannerPalette({
    required this.foreground,
    required this.border,
    required this.background,
  });

  final Color foreground;
  final Color border;
  final Color background;
}
