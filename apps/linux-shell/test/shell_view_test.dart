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
          bridgeApiRoutes: const <BridgeApiRouteDto>[
            const BridgeApiRouteDto(
              id: 'tailscale',
              kind: BridgeApiRouteKind.tailscale,
              baseUrl: 'http://127.0.0.1:3110',
              reachable: true,
              isPreferred: true,
            ),
          ],
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
      _state(
        shellState: ShellRuntimeState.pairedIdle,
        trustedDevices: const <TrustedDevicePresentation>[
          TrustedDevicePresentation(
            deviceId: 'phone-1',
            deviceName: 'Pixel 9',
            pairedAtEpochSeconds: 100,
            sessionId: 'session-1',
            finalizedAtEpochSeconds: 110,
          ),
        ],
      ),
    );

    expect(find.text('Trusted Devices'), findsWidgets);
    expect(find.text('Connected'), findsWidgets);
  });

  testWidgets('renders paired active state', (tester) async {
    await _pumpShellView(
      tester,
      _state(
        shellState: ShellRuntimeState.pairedActive,
        runningThreadCount: 3,
        trustedDevices: const <TrustedDevicePresentation>[
          TrustedDevicePresentation(
            deviceId: 'phone-1',
            deviceName: 'Pixel 9',
            pairedAtEpochSeconds: 100,
            sessionId: 'session-1',
            finalizedAtEpochSeconds: 110,
          ),
        ],
      ),
    );

    expect(find.text('Connected'), findsWidgets);
    expect(find.text('3 sessions'), findsOneWidget);
  });

  testWidgets('renders multiple trusted devices and paired QR actions', (
    tester,
  ) async {
    await _pumpShellView(
      tester,
      _state(
        shellState: ShellRuntimeState.pairedIdle,
        trustedDevices: const <TrustedDevicePresentation>[
          TrustedDevicePresentation(
            deviceId: 'phone-1',
            deviceName: 'Pixel 9',
            pairedAtEpochSeconds: 100,
            sessionId: 'session-1',
            finalizedAtEpochSeconds: 110,
          ),
          TrustedDevicePresentation(
            deviceId: 'tablet-2',
            deviceName: 'iPad Mini',
            pairedAtEpochSeconds: 120,
          ),
        ],
        pairingSession: PairingSessionResponseDto(
          contractVersion: SharedContract.version,
          bridgeIdentity: const PairingBridgeIdentityDto(
            bridgeId: 'bridge-1',
            displayName: 'Codex Host',
            apiBaseUrl: 'http://127.0.0.1:3110',
          ),
          bridgeApiRoutes: const <BridgeApiRouteDto>[
            const BridgeApiRouteDto(
              id: 'tailscale',
              kind: BridgeApiRouteKind.tailscale,
              baseUrl: 'http://127.0.0.1:3110',
              reachable: true,
              isPreferred: true,
            ),
          ],
          pairingSession: const PairingSessionDto(
            sessionId: 'session-2',
            pairingToken: 'token',
            issuedAtEpochSeconds: 100,
            expiresAtEpochSeconds: 200,
          ),
          qrPayload: 'codex://pair?session=session-2',
        ),
      ),
    );

    expect(find.text('Trusted Devices'), findsWidgets);
    expect(find.text('Pixel 9'), findsOneWidget);
    expect(find.text('iPad Mini'), findsOneWidget);
    expect(find.text('Refresh Pairing Code'), findsOneWidget);
    expect(find.text('Unpair Active Device'), findsOneWidget);
    expect(find.text('Unpair All Devices'), findsOneWidget);
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

  testWidgets('renders codex setup prompt without hiding pairing flow', (
    tester,
  ) async {
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
          bridgeApiRoutes: const <BridgeApiRouteDto>[
            const BridgeApiRouteDto(
              id: 'tailscale',
              kind: BridgeApiRouteKind.tailscale,
              baseUrl: 'http://127.0.0.1:3110',
              reachable: true,
              isPreferred: true,
            ),
          ],
          pairingSession: const PairingSessionDto(
            sessionId: 'session-1',
            pairingToken: 'token',
            issuedAtEpochSeconds: 100,
            expiresAtEpochSeconds: 200,
          ),
          qrPayload: 'codex://pair?session=session-1',
        ),
        codex: const CodexPresentation(
          statusLabel: 'Codex Not Found',
          detail:
              'Codex CLI is not available to the Linux shell yet. Choose the `codex` binary so the bridge can start the local runtime for threads and approvals.',
          nextStep: 'Choose the codex binary',
          isReady: false,
        ),
      ),
    );

    expect(find.text('Codex CLI Needed'), findsOneWidget);
    expect(find.text('Choose Binary'), findsOneWidget);
    expect(find.byKey(const Key('pairing-qr')), findsOneWidget);
  });

  testWidgets('renders network and speech controls', (tester) async {
    await _pumpShellView(
      tester,
      _state(
        pairingRoutes: const <BridgeApiRouteDto>[
          const BridgeApiRouteDto(
            id: 'tailscale',
            kind: BridgeApiRouteKind.tailscale,
            baseUrl: 'https://host.tailnet.ts.net',
            reachable: true,
            isPreferred: true,
          ),
          const BridgeApiRouteDto(
            id: 'local_network',
            kind: BridgeApiRouteKind.localNetwork,
            baseUrl: 'http://192.168.1.10:3110',
            reachable: true,
            isPreferred: false,
          ),
        ],
        localNetworkPairingEnabled: true,
        speechPanel: const SpeechPanelPresentation(
          stateLabel: 'Ready',
          detail: 'Speech runtime is managed by the local bridge.',
          isReadOnly: false,
        ),
      ),
    );

    expect(find.text('Pairing Routes'), findsWidgets);
    expect(find.text('Enable Local Network Pairing'), findsOneWidget);
    expect(find.text('Speech'), findsWidgets);
    expect(find.text('Download Parakeet'), findsOneWidget);
    expect(find.text('Remove Parakeet'), findsOneWidget);
  });
}

Widget _wrap(ShellPresentationState state) {
  return MaterialApp(
    home: ShellView(
      state: state,
      onCheckTailscale: () async {},
      onCheckCodex: () async {},
      onCheckForUpdates: () async {},
      onInstallUpdate: () async {},
      onOpenReleasesPage: () async {},
      onChooseCodexBinary: () async {},
      onRefreshQr: () async {},
      onRestartRuntime: () async {},
      onInstallSpeechModel: () async {},
      onRemoveSpeechModel: () async {},
      onSetLocalNetworkPairingEnabled: (_) async {},
      onRevokeActiveDevice: () async {},
      onRevokeAllDevices: () async {},
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
  CodexPresentation? codex,
  SpeechPanelPresentation? speechPanel,
  bool? localNetworkPairingEnabled,
  List<BridgeApiRouteDto>? pairingRoutes,
  List<TrustedDevicePresentation>? trustedDevices,
}) {
  return ShellPresentationState.initial().copyWith(
    shellState: shellState,
    supervisorStatusLabel: 'Managed locally',
    bridgeRuntimeLabel: 'managed (auto)',
    pairedDeviceLabel: switch (shellState) {
      ShellRuntimeState.unpaired => 'Not paired',
      ShellRuntimeState.needsTailscale => 'Tailscale not installed',
      ShellRuntimeState.degraded => 'Unavailable',
      _ =>
        trustedDevices != null && trustedDevices.length > 1
            ? '${trustedDevices.length} trusted devices'
            : 'Pixel 9 (phone-1)',
    },
    activeSessionLabel: switch (shellState) {
      ShellRuntimeState.unpaired => 'No active sessions',
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
    speechPanel: speechPanel,
    localNetworkPairingEnabled: localNetworkPairingEnabled,
    pairingRoutes: pairingRoutes,
    tailscale:
        tailscale ??
        const TailscalePresentation(
          statusLabel: 'Connected',
          detail: 'Tailscale route is available for private pairing.',
          installHint: '',
          isInstalled: true,
          isAuthenticated: true,
        ),
    codex:
        codex ??
        const CodexPresentation(
          statusLabel: 'Codex Ready',
          detail:
              'Codex CLI is available from NVM. The Linux shell can use it to start the local runtime.',
          nextStep: '',
          isReady: true,
          binaryPath: '/home/lubo/.nvm/versions/node/v24.14.0/bin/codex',
          sourceLabel: 'NVM',
        ),
    trayAvailable: true,
    trayStatusDetail: 'Tray integration is active.',
    trustedDevices: trustedDevices ?? const <TrustedDevicePresentation>[],
    pairingSession: pairingSession,
  );
}
