import 'package:vibe_bridge/app_startup_page.dart';
import 'package:vibe_bridge/foundation/navigation/app_navigator.dart';
import 'package:vibe_bridge/foundation/platform/macos_window_chrome.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:codex_ui/codex_ui.dart';

void main() {
  runApp(const ProviderScope(child: VibeBridgeApp()));
}

class VibeBridgeApp extends StatelessWidget {
  const VibeBridgeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: appNavigatorKey,
      title: 'Vibe bridge',
      theme: AppTheme.darkTheme,
      builder: (context, child) =>
          MacosWindowChromeFrame(child: child ?? const SizedBox.shrink()),
      home: const AppStartupPage(),
    );
  }
}
