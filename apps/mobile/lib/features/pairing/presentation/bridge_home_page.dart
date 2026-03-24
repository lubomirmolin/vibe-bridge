import 'connection_overview_page.dart';

class BridgeHomePage extends ConnectionOverviewPage {
  const BridgeHomePage({
    super.key,
    super.enableCameraPreview = true,
    super.enableAnimatedBackground,
    super.initialScannerIssue,
    super.autoOpenThreadsOnPairing = false,
  });
}
