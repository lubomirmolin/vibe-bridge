import 'package:codex_mobile_companion/features/pairing/presentation/pairing_flow_page.dart';
import 'package:codex_mobile_companion/features/settings/presentation/runtime_notification_delivery_surface.dart';
import 'package:codex_mobile_companion/foundation/navigation/app_navigator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:codex_mobile_companion/foundation/theme/app_theme.dart';
void main() {
  runApp(const ProviderScope(child: CodexMobileApp()));
}

class CodexMobileApp extends StatelessWidget {
  const CodexMobileApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: appNavigatorKey,
      title: 'Codex Mobile Companion',
      theme: AppTheme.darkTheme,
      builder: (context, child) {
        return RuntimeNotificationDeliverySurface(
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: const PairingFlowPage(autoOpenThreadsOnPairing: true),
    );
  }
}
