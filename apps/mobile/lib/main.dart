import 'package:codex_mobile_companion/features/pairing/presentation/pairing_flow_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

void main() {
  runApp(const ProviderScope(child: CodexMobileApp()));
}

class CodexMobileApp extends StatelessWidget {
  const CodexMobileApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Codex Mobile Companion',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
      ),
      home: const PairingFlowPage(),
    );
  }
}
