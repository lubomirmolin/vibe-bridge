import 'package:codex_mobile_companion/features/pairing/presentation/pairing_flow_page.dart';
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
      // Do not auto-open Active Threads on launch; user will choose explicitly.
      home: const PairingFlowPage(autoOpenThreadsOnPairing: false),
    );
  }
}
