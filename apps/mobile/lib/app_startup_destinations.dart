import 'package:vibe_bridge/features/bridges/presentation/bridge_home_page.dart';
import 'package:vibe_bridge/features/threads/presentation/thread_list_page.dart';
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
