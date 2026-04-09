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

  testWidgets(
    'disconnected banner stays hidden during a quick reconnect blip',
    (tester) async {
      const gracePeriod = Duration(seconds: 3);

      await tester.pumpWidget(
        _buildBanner(
          state: ConnectionBannerState.connected,
          minimumDisconnectedDurationToShow: gracePeriod,
        ),
      );
      expect(find.text('CONNECTED'), findsNothing);

      await tester.pumpWidget(
        _buildBanner(
          state: ConnectionBannerState.disconnected,
          minimumDisconnectedDurationToShow: gracePeriod,
        ),
      );
      await tester.pump();
      expect(find.text('DISCONNECTED'), findsNothing);

      await tester.pumpWidget(
        _buildBanner(
          state: ConnectionBannerState.reconnecting,
          minimumDisconnectedDurationToShow: gracePeriod,
        ),
      );
      await tester.pump();
      expect(find.text('RECONNECTING'), findsNothing);

      await tester.pumpWidget(
        _buildBanner(
          state: ConnectionBannerState.connected,
          minimumDisconnectedDurationToShow: gracePeriod,
        ),
      );
      await tester.pump();
      expect(find.text('CONNECTED'), findsNothing);
    },
  );

  testWidgets('disconnected banner appears after grace period elapses', (
    tester,
  ) async {
    const gracePeriod = Duration(seconds: 2);

    await tester.pumpWidget(
      _buildBanner(
        state: ConnectionBannerState.connected,
        minimumDisconnectedDurationToShow: gracePeriod,
      ),
    );

    await tester.pumpWidget(
      _buildBanner(
        state: ConnectionBannerState.disconnected,
        minimumDisconnectedDurationToShow: gracePeriod,
      ),
    );
    await tester.pump();
    expect(find.text('DISCONNECTED'), findsNothing);

    await tester.pump(gracePeriod + const Duration(milliseconds: 100));

    expect(find.text('DISCONNECTED'), findsOneWidget);
  });

  testWidgets(
    'pending show timer is cancelled when reconnecting restores before grace period',
    (tester) async {
      const gracePeriod = Duration(seconds: 3);

      await tester.pumpWidget(
        _buildBanner(
          state: ConnectionBannerState.connected,
          minimumDisconnectedDurationToShow: gracePeriod,
        ),
      );

      await tester.pumpWidget(
        _buildBanner(
          state: ConnectionBannerState.disconnected,
          minimumDisconnectedDurationToShow: gracePeriod,
        ),
      );
      await tester.pump();
      expect(find.text('DISCONNECTED'), findsNothing);

      await tester.pumpWidget(
        _buildBanner(
          state: ConnectionBannerState.connected,
          minimumDisconnectedDurationToShow: gracePeriod,
        ),
      );
      await tester.pump();

      await tester.pump(gracePeriod + const Duration(seconds: 1));
      expect(find.text('DISCONNECTED'), findsNothing);
      expect(find.text('CONNECTED'), findsNothing);
    },
  );

  testWidgets('app resume with connected state hides banner immediately', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildBanner(
        state: ConnectionBannerState.disconnected,
        minimumDisconnectedDurationToShow: Duration.zero,
      ),
    );
    await tester.pump();
    expect(find.text('DISCONNECTED'), findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pumpWidget(
      _buildBanner(state: ConnectionBannerState.connected),
    );

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(find.text('CONNECTED'), findsNothing);
    expect(find.text('DISCONNECTED'), findsNothing);
  });

  testWidgets('app resume followed by quick reconnect stays hidden', (
    tester,
  ) async {
    const gracePeriod = Duration(seconds: 3);

    await tester.pumpWidget(
      _buildBanner(
        state: ConnectionBannerState.connected,
        minimumDisconnectedDurationToShow: gracePeriod,
      ),
    );

    await tester.pumpWidget(
      _buildBanner(
        state: ConnectionBannerState.disconnected,
        minimumDisconnectedDurationToShow: gracePeriod,
      ),
    );
    await tester.pump();

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 30));

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('DISCONNECTED'), findsNothing);

    await tester.pumpWidget(
      _buildBanner(
        state: ConnectionBannerState.reconnecting,
        minimumDisconnectedDurationToShow: gracePeriod,
      ),
    );
    await tester.pump();
    expect(find.text('RECONNECTING'), findsNothing);

    await tester.pumpWidget(
      _buildBanner(
        state: ConnectionBannerState.connected,
        minimumDisconnectedDurationToShow: gracePeriod,
      ),
    );
    await tester.pump();
    expect(find.text('CONNECTED'), findsNothing);

    await tester.pump(gracePeriod + const Duration(seconds: 1));
    expect(find.text('CONNECTED'), findsNothing);
  });
}

Widget _buildBanner({
  required ConnectionBannerState state,
  Duration showConnectedFor = const Duration(milliseconds: 900),
  Duration minimumNotConnectedDurationToShowConnected = const Duration(
    seconds: 1,
  ),
  Duration minimumDisconnectedDurationToShow = Duration.zero,
}) {
  return MaterialApp(
    home: Scaffold(
      body: ConnectionStatusBanner(
        state: state,
        detail: 'status detail',
        showConnectedFor: showConnectedFor,
        minimumNotConnectedDurationToShowConnected:
            minimumNotConnectedDurationToShowConnected,
        minimumDisconnectedDurationToShow: minimumDisconnectedDurationToShow,
      ),
    ),
  );
}
