import 'package:codex_mobile_companion/features/threads/presentation/browser_thread_list_page.dart';
import 'package:codex_ui/codex_ui.dart';
import 'package:flutter/material.dart';

Widget buildPairingStartupDestination() {
  return const _BrowserPairingUnavailableView();
}

Widget buildLocalLoopbackDestination({required String bridgeApiBaseUrl}) {
  return BrowserThreadListPage(bridgeApiBaseUrl: bridgeApiBaseUrl);
}

class _BrowserPairingUnavailableView extends StatelessWidget {
  const _BrowserPairingUnavailableView();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: AppTheme.background,
      body: Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Browser mode does not support the QR pairing flow. Start the local bridge and connect through localhost instead.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppTheme.textMuted),
          ),
        ),
      ),
    );
  }
}
