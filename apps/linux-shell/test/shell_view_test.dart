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

    expect(find.text('Starting Bridge'), findsOneWidget);
    expect(find.text('Codex Bridge'), findsOneWidget);
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
    expect(find.text('Pair Device'), findsOneWidget);
  });

  testWidgets('renders paired idle state', (tester) async {
    await _pumpShellView(
      tester,
      _state(shellState: ShellRuntimeState.pairedIdle),
    );

    expect(find.text('Device Paired'), findsOneWidget);
    expect(find.text('Connected'), findsWidgets);
  });

  testWidgets('renders paired active state', (tester) async {
    await _pumpShellView(
      tester,
      _state(shellState: ShellRuntimeState.pairedActive, runningThreadCount: 3),
    );

    expect(find.text('Connected'), findsWidgets);
    expect(find.text('3 sessions'), findsOneWidget);
  });

  testWidgets('renders degraded state', (tester) async {
    await _pumpShellView(
      tester,
      _state(shellState: ShellRuntimeState.degraded),
    );

    expect(find.text('Bridge Degraded'), findsOneWidget);
    expect(find.text('Connection Details'), findsOneWidget);
  });

  testWidgets('renders tailscale required prompt', (tester) async {
    await _pumpShellView(
      tester,
      _state(
        shellState: ShellRuntimeState.needsTailscale,
        tailscale: const TailscalePresentation(
          statusLabel: 'Not Installed',
          detail:
              'Tailscale CLI was not found. Install it and then run `sudo tailscale up` to enable the private pairing route.',
          installHint: 'curl -fsSL https://tailscale.com/install.sh | sh',
          isInstalled: false,
          isAuthenticated: false,
        ),
      ),
    );

    expect(find.text('Tailscale Required'), findsWidgets);
    expect(
      find.text('curl -fsSL https://tailscale.com/install.sh | sh'),
      findsOneWidget,
    );
    expect(find.text('Check Again'), findsWidgets);
  });
}

Widget _wrap(ShellPresentationState state) {
  return MaterialApp(
    home: ShellView(
      state: state,
      onCheckTailscale: () async {},
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
  TailscalePresentation? tailscale,
}) {
  return ShellPresentationState.initial().copyWith(
    shellState: shellState,
    supervisorStatusLabel: 'Managed locally',
    bridgeRuntimeLabel: 'managed (auto)',
    pairedDeviceLabel: switch (shellState) {
      ShellRuntimeState.unpaired => 'Not paired',
      ShellRuntimeState.needsTailscale => 'Tailscale not installed',
      ShellRuntimeState.degraded => 'Unavailable',
      _ => 'Pixel 9 (phone-1)',
    },
    activeSessionLabel: switch (shellState) {
      ShellRuntimeState.unpaired => 'No active session',
      ShellRuntimeState.needsTailscale => 'Unavailable',
      ShellRuntimeState.degraded => 'Unavailable',
      _ => 'session-1',
    },
    runningThreadCount: runningThreadCount,
    runtimeDetail: switch (shellState) {
      ShellRuntimeState.starting => 'Preparing bridge runtime.',
      ShellRuntimeState.degraded => 'Bridge unreachable.',
      ShellRuntimeState.needsTailscale =>
        'Private pairing route is unavailable until Tailscale is installed.',
      _ => 'Bridge runtime healthy.',
    },
    tailscale:
        tailscale ??
        const TailscalePresentation(
          statusLabel: 'Connected',
          detail: 'Tailscale route is available for private pairing.',
          installHint: '',
          isInstalled: true,
          isAuthenticated: true,
        ),
    trayAvailable: true,
    trayStatusDetail: 'Tray integration is active.',
    pairingSession: pairingSession,
  );
}
