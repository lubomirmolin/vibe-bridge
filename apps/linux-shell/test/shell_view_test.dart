import 'package:codex_linux_shell/src/contracts.dart';
import 'package:codex_linux_shell/src/shell_presentation.dart';
import 'package:codex_linux_shell/src/shell_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  testWidgets('renders starting state', (tester) async {
    await _pumpShellView(
      tester,
      _state(shellState: ShellRuntimeState.starting),
    );

    expect(find.text('Starting Up'), findsOneWidget);
    expect(find.text('Starting'), findsWidgets);
  });

  testWidgets('renders unpaired state with qr payload', (tester) async {
    await _pumpShellView(
      tester,
      _state(
        shellState: ShellRuntimeState.unpaired,
        pairingSession: PairingSessionResponseDto(
          contractVersion: SharedContract.version,
          bridgeIdentity: const PairingBridgeIdentityDto(
            bridgeId: 'bridge-1',
            displayName: 'Codex Host',
            apiBaseUrl: 'http://127.0.0.1:3110',
          ),
          pairingSession: const PairingSessionDto(
            sessionId: 'session-1',
            pairingToken: 'token',
            issuedAtEpochSeconds: 100,
            expiresAtEpochSeconds: 200,
          ),
          qrPayload: 'codex://pair?session=session-1',
        ),
      ),
    );

    expect(find.byKey(const Key('pairing-qr')), findsOneWidget);
    expect(
      find.text('Scan this QR from the mobile app to trust the Linux host.'),
      findsOneWidget,
    );
  });

  testWidgets('renders paired idle state', (tester) async {
    await _pumpShellView(
      tester,
      _state(shellState: ShellRuntimeState.pairedIdle),
    );

    expect(find.text('Host Paired'), findsOneWidget);
    expect(find.text('Paired (Idle)'), findsWidgets);
  });

  testWidgets('renders paired active state', (tester) async {
    await _pumpShellView(
      tester,
      _state(shellState: ShellRuntimeState.pairedActive, runningThreadCount: 3),
    );

    expect(find.text('Paired (Active)'), findsWidgets);
    expect(find.text('3'), findsOneWidget);
  });

  testWidgets('renders degraded state', (tester) async {
    await _pumpShellView(
      tester,
      _state(shellState: ShellRuntimeState.degraded),
    );

    expect(find.text('Bridge Degraded'), findsOneWidget);
    expect(find.text('Degraded'), findsWidgets);
  });

  testWidgets('renders speech unsupported as read only', (tester) async {
    await _pumpShellView(tester, _state());

    expect(find.text('Linux Speech'), findsOneWidget);
    expect(find.text('READ ONLY'), findsOneWidget);
    expect(
      find.text(
        'Speech transcription is not available from the Linux shell yet.',
      ),
      findsOneWidget,
    );
  });
}

Widget _wrap(ShellPresentationState state) {
  return MaterialApp(
    home: ShellView(
      state: state,
      onRefreshQr: () async {},
      onRestartRuntime: () async {},
      onRevokeTrust: () async {},
    ),
  );
}

Future<void> _pumpShellView(
  WidgetTester tester,
  ShellPresentationState state,
) async {
  tester.view.physicalSize = const Size(1600, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(_wrap(state));
}

ShellPresentationState _state({
  ShellRuntimeState shellState = ShellRuntimeState.unpaired,
  int runningThreadCount = 0,
  PairingSessionResponseDto? pairingSession,
}) {
  return ShellPresentationState.initial().copyWith(
    shellState: shellState,
    supervisorStatusLabel: 'Managed locally',
    bridgeRuntimeLabel: 'managed (auto)',
    pairedDeviceLabel: shellState == ShellRuntimeState.unpaired
        ? 'Not paired'
        : 'Pixel 9 (phone-1)',
    activeSessionLabel: shellState == ShellRuntimeState.unpaired
        ? 'No active session'
        : 'session-1',
    runningThreadCount: runningThreadCount,
    runtimeDetail: 'Bridge runtime healthy.',
    trayAvailable: true,
    trayStatusDetail: 'Tray integration is active.',
    pairingSession: pairingSession,
  );
}
