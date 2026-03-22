import 'package:codex_mobile_companion/features/approvals/presentation/approvals_queue_page.dart';
import 'package:codex_mobile_companion/features/pairing/application/pairing_controller.dart';
import 'package:codex_mobile_companion/features/settings/application/runtime_access_mode.dart';
import 'package:codex_mobile_companion/features/settings/presentation/settings_page.dart';
import 'package:codex_mobile_companion/features/threads/presentation/thread_list_page.dart';
import 'package:codex_mobile_companion/foundation/layout/adaptive_layout.dart';
import 'package:codex_mobile_companion/foundation/theme/app_theme.dart';
import 'package:codex_mobile_companion/foundation/theme/liquid_styles.dart';
import 'package:codex_mobile_companion/shared/widgets/badges.dart';
import 'package:codex_mobile_companion/shared/widgets/connection_status_banner.dart';
import 'package:flutter/material.dart';
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
    final pairingState = ref.watch(pairingControllerProvider);

    String modeString = 'READ ONLY';
    if (accessMode == AccessMode.controlWithApprovals) {
      modeString = 'APPROVALS';
    } else if (accessMode == AccessMode.fullControl) {
      modeString = 'FULL CONTROL';
    }

    final layout = AdaptiveLayoutInfo.fromMediaQuery(MediaQuery.of(context));

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isWideLayout = layout.isWideLayout;
            final contentWidth = layout.constrainedContentWidth(
              constraints.maxWidth,
            );

            return Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                width: contentWidth,
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: isWideLayout ? 32 : 24,
                    vertical: 24,
                  ),
                  child: isWideLayout
                      ? _WideHomeLayout(
                          bridgeName: bridgeName,
                          bridgeId: bridgeId,
                          connectionBanner: ConnectionStatusBanner(
                            state: _homeConnectionBannerState(
                              pairingState.bridgeConnectionState,
                            ),
                            detail: _homeConnectionBannerDetail(pairingState),
                          ),
                          cards: _buildFeatureCards(context, modeString),
                        )
                      : _CompactHomeLayout(
                          bridgeName: bridgeName,
                          bridgeId: bridgeId,
                          connectionBanner: ConnectionStatusBanner(
                            state: _homeConnectionBannerState(
                              pairingState.bridgeConnectionState,
                            ),
                            detail: _homeConnectionBannerDetail(pairingState),
                          ),
                          cards: _buildFeatureCards(context, modeString),
                        ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  List<Widget> _buildFeatureCards(BuildContext context, String modeString) {
    return [
      _FeatureCard(
        title: 'Active Threads',
        subtitle: 'Monitor & steer sessions',
        icon: PhosphorIcons.pulse(PhosphorIconsStyle.duotone),
        iconColor: AppTheme.textMain,
        iconBg: AppTheme.surfaceZinc800,
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => ThreadListPage(
                bridgeApiBaseUrl: bridgeApiBaseUrl,
                autoOpenPreviouslySelectedThread: false,
              ),
            ),
          );
        },
      ),
      _FeatureCard(
        title: 'Approvals Queue',
        subtitle: 'Actions require review',
        icon: PhosphorIcons.shieldWarning(PhosphorIconsStyle.duotone),
        iconColor: AppTheme.amber,
        iconBg: AppTheme.amber.withValues(alpha: 0.1),
        badge: const StatusBadge(
          text: 'ACTION NEEDED',
          variant: BadgeVariant.warning,
        ),
        glowColor: AppTheme.amber,
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) =>
                  ApprovalsQueuePage(bridgeApiBaseUrl: bridgeApiBaseUrl),
            ),
          );
        },
      ),
      _FeatureCard(
        title: 'Security Settings',
        subtitle: 'Mode: $modeString',
        icon: PhosphorIcons.gear(PhosphorIconsStyle.duotone),
        iconColor: AppTheme.textMain,
        iconBg: AppTheme.surfaceZinc800,
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => SettingsPage(bridgeApiBaseUrl: bridgeApiBaseUrl),
            ),
          );
        },
      ),
    ];
  }
}

class _CompactHomeLayout extends StatelessWidget {
  const _CompactHomeLayout({
    required this.bridgeName,
    required this.bridgeId,
    required this.connectionBanner,
    required this.cards,
  });

  final String bridgeName;
  final String bridgeId;
  final Widget connectionBanner;
  final List<Widget> cards;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _HomeHeader(
          bridgeName: bridgeName,
          bridgeId: bridgeId,
          connectionBanner: connectionBanner,
        ),
        const SizedBox(height: 32),
        Expanded(
          child: ListView.separated(
            physics: const BouncingScrollPhysics(),
            itemCount: cards.length,
            separatorBuilder: (_, _) => const SizedBox(height: 16),
            itemBuilder: (context, index) => cards[index],
          ),
        ),
      ],
    );
  }
}

class _WideHomeLayout extends StatelessWidget {
  const _WideHomeLayout({
    required this.bridgeName,
    required this.bridgeId,
    required this.connectionBanner,
    required this.cards,
  });

  final String bridgeName;
  final String bridgeId;
  final Widget connectionBanner;
  final List<Widget> cards;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 5,
          child: Padding(
            padding: const EdgeInsets.only(right: 28),
            child: _HomeHeader(
              bridgeName: bridgeName,
              bridgeId: bridgeId,
              connectionBanner: connectionBanner,
              wide: true,
            ),
          ),
        ),
        Container(width: 1, color: Colors.white10),
        const SizedBox(width: 28),
        Expanded(
          flex: 7,
          child: GridView.count(
            key: const Key('home-wide-grid'),
            physics: const BouncingScrollPhysics(),
            crossAxisCount: 2,
            mainAxisSpacing: 20,
            crossAxisSpacing: 20,
            childAspectRatio: 1.18,
            children: cards,
          ),
        ),
      ],
    );
  }
}

class _HomeHeader extends StatelessWidget {
  const _HomeHeader({
    required this.bridgeName,
    required this.bridgeId,
    required this.connectionBanner,
    this.wide = false,
  });

  final String bridgeName;
  final String bridgeId;
  final Widget connectionBanner;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Codex Mobile',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w500,
            letterSpacing: -0.5,
          ),
        ),
        const SizedBox(height: 16),
        connectionBanner,
        const SizedBox(height: 24),
        Text(bridgeName, style: Theme.of(context).textTheme.displaySmall),
        const SizedBox(height: 8),
        Text(
          'ID: $bridgeId',
          style: const TextStyle(
            color: AppTheme.textSubtle,
            fontSize: 12,
            fontFamily: 'JetBrains Mono',
          ),
        ),
        if (wide) ...[
          const SizedBox(height: 28),
          Text(
            'Large-screen workspace keeps session controls dense and readable across tablets, landscape phones, and foldables.',
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: AppTheme.textMuted,
              height: 1.5,
            ),
          ),
        ],
      ],
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
            decoration: LiquidStyles.liquidGlass.copyWith(
              borderRadius: BorderRadius.circular(32),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: iconBg,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: PhosphorIcon(icon, color: iconColor, size: 24),
                    ),
                    if (badge != null)
                      badge!
                    else
                      PhosphorIcon(
                        PhosphorIcons.arrowRight(),
                        color: AppTheme.textSubtle,
                      ),
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
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontSize: 14,
                    color: AppTheme.textSubtle,
                  ),
                ),
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
                    BoxShadow(
                      color: glowColor!.withValues(alpha: 0.15),
                      blurRadius: 60,
                      spreadRadius: 10,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

ConnectionBannerState _homeConnectionBannerState(BridgeConnectionState state) {
  switch (state) {
    case BridgeConnectionState.connected:
      return ConnectionBannerState.connected;
    case BridgeConnectionState.reconnecting:
      return ConnectionBannerState.reconnecting;
    case BridgeConnectionState.disconnected:
      return ConnectionBannerState.disconnected;
  }
}

String _homeConnectionBannerDetail(PairingState pairingState) {
  switch (pairingState.bridgeConnectionState) {
    case BridgeConnectionState.connected:
      return 'Bridge reachable. Controls are live.';
    case BridgeConnectionState.reconnecting:
      return 'Trying to restore the trusted bridge session.';
    case BridgeConnectionState.disconnected:
      return pairingState.errorMessage ??
          'Private bridge path is unreachable right now.';
  }
}
