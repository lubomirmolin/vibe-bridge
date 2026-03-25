import 'package:codex_mobile_companion/features/pairing/presentation/bridge_home_page.dart';
import 'package:codex_mobile_companion/features/threads/presentation/thread_list_page.dart';
import 'package:flutter/widgets.dart';

Widget buildPairingStartupDestination() {
  return const BridgeHomePage(autoOpenThreadsOnPairing: false);
}

Widget buildLocalLoopbackDestination({required String bridgeApiBaseUrl}) {
  return ThreadListPage(
    bridgeApiBaseUrl: bridgeApiBaseUrl,
    autoOpenPreviouslySelectedThread: true,
  );
}
