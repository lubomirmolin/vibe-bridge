import 'dart:async';

import 'package:codex_mobile_companion/foundation/platform/app_platform.dart';
import 'package:codex_mobile_companion/foundation/startup/local_desktop_bridge_api.dart';
import 'package:codex_ui/codex_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_startup_destinations.dart' as startup_destinations;

class AppStartupPage extends ConsumerStatefulWidget {
  const AppStartupPage({super.key});

  @override
  ConsumerState<AppStartupPage> createState() => _AppStartupPageState();
}

class _AppStartupPageState extends ConsumerState<AppStartupPage> {
  _StartupRoute _route = const _StartupRoute.loading();

  @override
  void initState() {
    super.initState();
    unawaited(_bootstrap());
  }

  Future<void> _bootstrap() async {
    final platform = ref.read(appPlatformProvider);
    final localDesktopConfig = ref.read(localDesktopConfigProvider);

    if (!platform.supportsLocalLoopbackBridge || !localDesktopConfig.enabled) {
      if (!mounted) {
        return;
      }
      setState(() {
        _route = const _StartupRoute.pairing();
      });
      return;
    }

    final probeResult = await ref
        .read(localDesktopBridgeApiProvider)
        .probe(bridgeApiBaseUrl: localDesktopConfig.bridgeApiBaseUrl);
    if (!mounted) {
      return;
    }

    setState(() {
      _route = probeResult.isReachable
          ? _StartupRoute.localDesktop(localDesktopConfig.bridgeApiBaseUrl)
          : _StartupRoute.localDesktopUnavailable(
              localDesktopConfig.bridgeApiBaseUrl,
              probeResult.errorMessage,
            );
    });
  }

  @override
  Widget build(BuildContext context) {
    return switch (_route.kind) {
      _StartupRouteKind.loading => const _StartupLoadingView(),
      _StartupRouteKind.pairing =>
        startup_destinations.buildPairingStartupDestination(),
      _StartupRouteKind.localDesktop =>
        startup_destinations.buildLocalLoopbackDestination(
          bridgeApiBaseUrl: _route.bridgeApiBaseUrl!,
        ),
      _StartupRouteKind.localDesktopUnavailable => _LocalDesktopUnavailableView(
        bridgeApiBaseUrl: _route.bridgeApiBaseUrl!,
        message: _route.message,
        onRetry: _bootstrap,
        onOpenPairing: () {
          setState(() {
            _route = const _StartupRoute.pairing();
          });
        },
      ),
    };
  }
}

enum _StartupRouteKind {
  loading,
  pairing,
  localDesktop,
  localDesktopUnavailable,
}

class _StartupRoute {
  const _StartupRoute._({
    required this.kind,
    this.bridgeApiBaseUrl,
    this.message,
  });

  const _StartupRoute.loading() : this._(kind: _StartupRouteKind.loading);

  const _StartupRoute.pairing() : this._(kind: _StartupRouteKind.pairing);

  const _StartupRoute.localDesktop(String bridgeApiBaseUrl)
    : this._(
        kind: _StartupRouteKind.localDesktop,
        bridgeApiBaseUrl: bridgeApiBaseUrl,
      );

  const _StartupRoute.localDesktopUnavailable(
    String bridgeApiBaseUrl,
    String? message,
  ) : this._(
        kind: _StartupRouteKind.localDesktopUnavailable,
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        message: message,
      );

  final _StartupRouteKind kind;
  final String? bridgeApiBaseUrl;
  final String? message;
}

class _StartupLoadingView extends StatelessWidget {
  const _StartupLoadingView();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: AppTheme.background,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: AppTheme.emerald),
            SizedBox(height: 16),
            Text(
              'Checking local bridge…',
              key: Key('startup-loading-message'),
              style: TextStyle(color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }
}

class _LocalDesktopUnavailableView extends StatelessWidget {
  const _LocalDesktopUnavailableView({
    required this.bridgeApiBaseUrl,
    required this.message,
    required this.onRetry,
    required this.onOpenPairing,
  });

  final String bridgeApiBaseUrl;
  final String? message;
  final Future<void> Function() onRetry;
  final VoidCallback onOpenPairing;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: AppTheme.surfaceZinc800.withValues(alpha: 0.72),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
              ),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  key: const Key('local-desktop-unavailable-view'),
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Local bridge unavailable',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      message ??
                          'Couldn’t connect to the bridge running on this machine.',
                      key: const Key('local-desktop-unavailable-message'),
                      style: const TextStyle(color: AppTheme.textMuted),
                    ),
                    const SizedBox(height: 16),
                    SelectableText(
                      bridgeApiBaseUrl,
                      key: const Key('local-desktop-bridge-base-url'),
                      style: const TextStyle(
                        color: Colors.white,
                        fontFamily: 'JetBrainsMono',
                      ),
                    ),
                    const SizedBox(height: 20),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        FilledButton(
                          onPressed: () {
                            unawaited(onRetry());
                          },
                          child: const Text('Retry'),
                        ),
                        const SizedBox(width: 12),
                        OutlinedButton(
                          onPressed: onOpenPairing,
                          child: const Text('Open Pairing'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
