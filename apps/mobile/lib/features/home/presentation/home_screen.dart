import 'package:codex_mobile_companion/features/approvals/presentation/approvals_queue_page.dart';
import 'package:codex_mobile_companion/features/settings/application/runtime_access_mode.dart';
import 'package:codex_mobile_companion/features/settings/presentation/settings_page.dart';
import 'package:codex_mobile_companion/features/threads/presentation/thread_list_page.dart';
import 'package:codex_mobile_companion/foundation/theme/app_theme.dart';
import 'package:codex_mobile_companion/foundation/theme/liquid_styles.dart';
import 'package:codex_mobile_companion/shared/widgets/badges.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

class HomeScreen extends ConsumerWidget {
  final String bridgeApiBaseUrl;
  final String bridgeName;
  final String bridgeId;

  const HomeScreen({
    super.key,
    required this.bridgeApiBaseUrl,
    required this.bridgeName,
    required this.bridgeId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accessMode = ref.watch(runtimeAccessModeProvider(bridgeApiBaseUrl));

    String modeString = 'READ ONLY';
    if (accessMode == AccessMode.controlWithApprovals) {
      modeString = 'APPROVALS';
    } else if (accessMode == AccessMode.fullControl) {
      modeString = 'FULL CONTROL';
    }

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 32),
              Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: AppTheme.emerald,
                      shape: BoxShape.circle,
                      boxShadow: [BoxShadow(color: AppTheme.emerald, blurRadius: 10, spreadRadius: 2)],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    'CONNECTED',
                    style: GoogleFonts.jetBrainsMono(
                      color: AppTheme.emerald,
                      fontSize: 12,
                      letterSpacing: 2.0,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Text(bridgeName, style: Theme.of(context).textTheme.displaySmall),
              const SizedBox(height: 8),
              Row(
                children: [
                  Text(
                    'ID: $bridgeId',
                    style: const TextStyle(
                      color: AppTheme.textSubtle,
                      fontSize: 12,
                      fontFamily: 'JetBrains Mono',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 32),

              Expanded(
                child: ListView(
                  physics: const BouncingScrollPhysics(),
                  children: [
                    _FeatureCard(
                      title: 'Active Threads',
                      subtitle: 'Monitor & steer sessions',
                      icon: PhosphorIcons.pulse(PhosphorIconsStyle.duotone),
                      iconColor: AppTheme.textMain,
                      iconBg: AppTheme.surfaceZinc800,
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => ThreadListPage(bridgeApiBaseUrl: bridgeApiBaseUrl),
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 16),
                    _FeatureCard(
                      title: 'Approvals Queue',
                      subtitle: 'Actions require review',
                      icon: PhosphorIcons.shieldWarning(PhosphorIconsStyle.duotone),
                      iconColor: AppTheme.amber,
                      iconBg: AppTheme.amber.withOpacity(0.1),
                      badge: const StatusBadge(text: 'ACTION NEEDED', variant: BadgeVariant.warning),
                      glowColor: AppTheme.amber,
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => ApprovalsQueuePage(bridgeApiBaseUrl: bridgeApiBaseUrl),
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 16),
                    _FeatureCard(
                      title: 'Security Settings',
                      subtitle: 'Mode: $modeString',
                      icon: PhosphorIcons.gear(PhosphorIconsStyle.duotone),
                      iconColor: AppTheme.textMain,
                      iconBg: AppTheme.surfaceZinc800,
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => SettingsPage(bridgeApiBaseUrl: bridgeApiBaseUrl)),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FeatureCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final Color iconColor;
  final Color iconBg;
  final VoidCallback onTap;
  final Widget? badge;
  final Color? glowColor;

  const _FeatureCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.iconColor,
    required this.iconBg,
    required this.onTap,
    this.badge,
    this.glowColor,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: LiquidStyles.liquidGlass.copyWith(borderRadius: BorderRadius.circular(32)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(color: iconBg, borderRadius: BorderRadius.circular(16)),
                      child: PhosphorIcon(icon, color: iconColor, size: 24),
                    ),
                    if (badge != null)
                      badge!
                    else
                      PhosphorIcon(PhosphorIcons.arrowRight(), color: AppTheme.textSubtle),
                  ],
                ),
                const SizedBox(height: 32),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w500,
                    letterSpacing: -0.5,
                    color: AppTheme.textMain,
                  ),
                ),
                const SizedBox(height: 4),
                Text(subtitle, style: const TextStyle(fontSize: 14, color: AppTheme.textSubtle)),
              ],
            ),
          ),
          if (glowColor != null)
            Positioned(
              top: 0,
              right: 0,
              child: Container(
                width: 100,
                height: 100,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(color: glowColor!.withOpacity(0.15), blurRadius: 60, spreadRadius: 10),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
