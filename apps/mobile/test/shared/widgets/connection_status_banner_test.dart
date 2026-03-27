import 'package:vibe_bridge/shared/widgets/connection_status_banner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('initial connected state stays hidden', (tester) async {
    await tester.pumpWidget(
      _buildBanner(state: ConnectionBannerState.connected),
    );

    expect(find.text('CONNECTED'), findsNothing);
  });

  testWidgets('connected stays hidden after a short reconnect blip', (
    tester,
  ) async {
    const recoveryThreshold = Duration(milliseconds: 500);

    await tester.pumpWidget(
      _buildBanner(
        state: ConnectionBannerState.disconnected,
        minimumNotConnectedDurationToShowConnected: recoveryThreshold,
      ),
    );
    expect(find.text('DISCONNECTED'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(
      _buildBanner(
        state: ConnectionBannerState.connected,
        minimumNotConnectedDurationToShowConnected: recoveryThreshold,
      ),
    );
    await tester.pump();

    expect(find.text('CONNECTED'), findsNothing);
  });

  testWidgets(
    'connected appears after a meaningful disconnect and auto-hides',
    (tester) async {
      const recoveryThreshold = Duration(milliseconds: 500);
      const showConnectedFor = Duration(milliseconds: 300);

      await tester.pumpWidget(
        _buildBanner(
          state: ConnectionBannerState.disconnected,
          minimumNotConnectedDurationToShowConnected: recoveryThreshold,
          showConnectedFor: showConnectedFor,
        ),
      );
      expect(find.text('DISCONNECTED'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpWidget(
        _buildBanner(
          state: ConnectionBannerState.connected,
          minimumNotConnectedDurationToShowConnected: recoveryThreshold,
          showConnectedFor: showConnectedFor,
        ),
      );
      await tester.pump();

      expect(find.text('CONNECTED'), findsOneWidget);

      await tester.pump(showConnectedFor + const Duration(milliseconds: 200));

      expect(find.text('CONNECTED'), findsNothing);
    },
  );
}

Widget _buildBanner({
  required ConnectionBannerState state,
  Duration showConnectedFor = const Duration(milliseconds: 900),
  Duration minimumNotConnectedDurationToShowConnected = const Duration(
    seconds: 1,
  ),
}) {
  return MaterialApp(
    home: Scaffold(
      body: ConnectionStatusBanner(
        state: state,
        detail: 'status detail',
        showConnectedFor: showConnectedFor,
        minimumNotConnectedDurationToShowConnected:
            minimumNotConnectedDurationToShowConnected,
      ),
    ),
  );
}
