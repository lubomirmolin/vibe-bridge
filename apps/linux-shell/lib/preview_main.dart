import 'package:codex_linux_shell/src/contracts.dart';
import 'package:codex_linux_shell/src/shell_presentation.dart';
import 'package:codex_linux_shell/src/shell_view.dart';
import 'package:codex_ui/codex_ui.dart';
import 'package:flutter/material.dart';

void main() {
  runApp(const CodexLinuxShellPreviewApp());
}

enum PreviewScenario {
  starting,
  unpaired,
  pairedIdle,
  pairedActive,
  needsTailscale,
  needsCodex,
  degraded,
}

class CodexLinuxShellPreviewApp extends StatelessWidget {
  const CodexLinuxShellPreviewApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Codex Linux Shell Preview',
      theme: AppTheme.darkTheme,
      home: const _PreviewHome(),
    );
  }
}

class _PreviewHome extends StatefulWidget {
  const _PreviewHome();

  @override
  State<_PreviewHome> createState() => _PreviewHomeState();
}

class _PreviewHomeState extends State<_PreviewHome> {
  var _scenario = PreviewScenario.unpaired;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        ShellView(
          state: _stateFor(_scenario),
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
        SafeArea(
          child: Align(
            alignment: Alignment.topRight,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Container(
                width: 280,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppTheme.surfaceZinc900.withValues(alpha: 0.92),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: AppTheme.surfaceZinc800),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.32),
                      blurRadius: 24,
                      offset: Offset(0, 12),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Preview Mode',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: AppTheme.textMain,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Fake data only. Use this on macOS or Chrome to review the visual treatment.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppTheme.textMuted,
                        height: 1.45,
                      ),
                    ),
                    const SizedBox(height: 14),
                    DropdownButtonFormField<PreviewScenario>(
                      initialValue: _scenario,
                      dropdownColor: AppTheme.surfaceZinc900,
                      decoration: InputDecoration(
                        labelText: 'Scenario',
                        labelStyle: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(color: AppTheme.textMuted),
                        filled: true,
                        fillColor: AppTheme.background.withValues(alpha: 0.72),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide.none,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide(
                            color: AppTheme.surfaceZinc800,
                          ),
                        ),
                      ),
                      items: PreviewScenario.values.map((scenario) {
                        return DropdownMenuItem(
                          value: scenario,
                          child: Text(_scenarioLabel(scenario)),
                        );
                      }).toList(),
                      onChanged: (selection) {
                        if (selection == null) {
                          return;
                        }
                        setState(() {
                          _scenario = selection;
                        });
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

String _scenarioLabel(PreviewScenario scenario) {
  return switch (scenario) {
    PreviewScenario.starting => 'Starting',
    PreviewScenario.unpaired => 'Unpaired',
    PreviewScenario.pairedIdle => 'Paired (Idle)',
    PreviewScenario.pairedActive => 'Paired (Active)',
    PreviewScenario.needsTailscale => 'Needs Tailscale',
    PreviewScenario.needsCodex => 'Needs Codex',
    PreviewScenario.degraded => 'Degraded',
  };
}

ShellPresentationState _stateFor(PreviewScenario scenario) {
  final shellState = switch (scenario) {
    PreviewScenario.starting => ShellRuntimeState.starting,
    PreviewScenario.unpaired => ShellRuntimeState.unpaired,
    PreviewScenario.pairedIdle => ShellRuntimeState.pairedIdle,
    PreviewScenario.pairedActive => ShellRuntimeState.pairedActive,
    PreviewScenario.needsTailscale => ShellRuntimeState.needsTailscale,
    PreviewScenario.needsCodex => ShellRuntimeState.unpaired,
    PreviewScenario.degraded => ShellRuntimeState.degraded,
  };

  return ShellPresentationState.initial().copyWith(
    shellState: shellState,
    supervisorStatusLabel: switch (scenario) {
      PreviewScenario.starting => 'Launching managed runtime',
      PreviewScenario.unpaired => 'Managed locally',
      PreviewScenario.pairedIdle => 'Attached to local bridge',
      PreviewScenario.pairedActive => 'Managed locally',
      PreviewScenario.needsTailscale => 'Waiting for pairing route',
      PreviewScenario.needsCodex => 'Managed locally',
      PreviewScenario.degraded => 'Bridge unreachable',
    },
    bridgeRuntimeLabel: switch (scenario) {
      PreviewScenario.starting => 'Starting',
      PreviewScenario.needsTailscale => 'Tailscale required',
      PreviewScenario.degraded => 'Unavailable',
      PreviewScenario.needsCodex => 'degraded (auto)',
      _ => 'managed (auto)',
    },
    pairedDeviceLabel: switch (scenario) {
      PreviewScenario.unpaired => 'Not paired',
      PreviewScenario.starting => 'Awaiting handshake',
      PreviewScenario.needsTailscale => 'Tailscale not installed',
      PreviewScenario.needsCodex => 'Not paired',
      PreviewScenario.pairedIdle => '2 trusted devices',
      PreviewScenario.pairedActive => '2 trusted devices',
      PreviewScenario.degraded => 'Unavailable',
    },
    activeSessionLabel: switch (scenario) {
      PreviewScenario.pairedActive => 'session-7f4d',
      PreviewScenario.pairedIdle => 'session-7f4d',
      PreviewScenario.starting => 'Waiting for bridge',
      PreviewScenario.needsTailscale => 'Unavailable',
      PreviewScenario.degraded => 'Unavailable',
      _ => 'No active sessions',
    },
    runningThreadCount: switch (scenario) {
      PreviewScenario.pairedActive => 3,
      _ => 0,
    },
    runtimeDetail: switch (scenario) {
      PreviewScenario.starting =>
        'Preparing the bundled bridge-server and checking local health.',
      PreviewScenario.unpaired =>
        'Bridge runtime healthy. Waiting for a device to trust this host.',
      PreviewScenario.pairedIdle =>
        'Bridge runtime healthy. Host paired and ready for mobile control.',
      PreviewScenario.pairedActive =>
        'Bridge runtime healthy. A trusted device currently has an active session.',
      PreviewScenario.needsTailscale =>
        'Private pairing route is unavailable until Tailscale is installed and connected.',
      PreviewScenario.needsCodex =>
        'Codex CLI is not available to the Linux shell yet. Choose the `codex` binary so the bridge can start the local runtime for threads and approvals.',
      PreviewScenario.degraded =>
        'Bridge supervision is retrying because the local runtime is unavailable.',
    },
    tailscale: scenario == PreviewScenario.needsTailscale
        ? const TailscalePresentation(
            statusLabel: 'Not Installed',
            detail:
                'Tailscale CLI was not found. Install it and then run `sudo tailscale up` to enable the private pairing route.',
            installHint: 'curl -fsSL https://tailscale.com/install.sh | sh',
            isInstalled: false,
            isAuthenticated: false,
          )
        : const TailscalePresentation(
            statusLabel: 'Connected',
            detail: 'Tailscale route is available for private pairing.',
            installHint: '',
            isInstalled: true,
            isAuthenticated: true,
          ),
    codex: scenario == PreviewScenario.needsCodex
        ? const CodexPresentation(
            statusLabel: 'Codex Not Found',
            detail:
                'Codex CLI is not available to the Linux shell yet. Choose the `codex` binary so the bridge can start the local runtime for threads and approvals.',
            nextStep: 'Choose the codex binary',
            isReady: false,
          )
        : const CodexPresentation(
            statusLabel: 'Codex Ready',
            detail:
                'Codex CLI is available from NVM. The Linux shell can use it to start the local runtime.',
            nextStep: '',
            isReady: true,
            binaryPath: '/home/lubo/.nvm/versions/node/v24.14.0/bin/codex',
            sourceLabel: 'NVM',
          ),
    localNetworkPairingEnabled: true,
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
    speechPanel: const SpeechPanelPresentation(
      stateLabel: 'Ready',
      detail: 'Speech runtime is managed by the local bridge.',
      isReadOnly: false,
    ),
    trayAvailable: true,
    trayStatusDetail:
        'Preview tray detail only. No real tray integration here.',
    trustedDevices: switch (scenario) {
      PreviewScenario.pairedIdle => const <TrustedDevicePresentation>[
        TrustedDevicePresentation(
          deviceId: 'phone-1',
          deviceName: 'Pixel 9 Pro',
          pairedAtEpochSeconds: 1735689600,
          sessionId: 'session-7f4d',
          finalizedAtEpochSeconds: 1735689700,
        ),
        TrustedDevicePresentation(
          deviceId: 'tablet-2',
          deviceName: 'iPad Mini',
          pairedAtEpochSeconds: 1735689800,
        ),
      ],
      PreviewScenario.pairedActive => const <TrustedDevicePresentation>[
        TrustedDevicePresentation(
          deviceId: 'phone-1',
          deviceName: 'Pixel 9 Pro',
          pairedAtEpochSeconds: 1735689600,
          sessionId: 'session-7f4d',
          finalizedAtEpochSeconds: 1735689700,
        ),
        TrustedDevicePresentation(
          deviceId: 'tablet-2',
          deviceName: 'iPad Mini',
          pairedAtEpochSeconds: 1735689800,
          sessionId: 'session-9b2a',
          finalizedAtEpochSeconds: 1735689900,
        ),
      ],
      _ => const <TrustedDevicePresentation>[],
    },
    pairingSession:
        scenario == PreviewScenario.unpaired ||
            scenario == PreviewScenario.needsCodex ||
            scenario == PreviewScenario.pairedIdle ||
            scenario == PreviewScenario.pairedActive
        ? PairingSessionResponseDto(
            contractVersion: SharedContract.version,
            bridgeIdentity: const PairingBridgeIdentityDto(
              bridgeId: 'bridge-preview',
              displayName: 'Codex Host',
              apiBaseUrl: 'http://127.0.0.1:3110',
            ),
            bridgeApiRoutes: const <BridgeApiRouteDto>[
              const BridgeApiRouteDto(
                id: 'tailscale',
                kind: BridgeApiRouteKind.tailscale,
                baseUrl: 'https://host.tailnet.ts.net',
                reachable: true,
                isPreferred: true,
              ),
            ],
            pairingSession: const PairingSessionDto(
              sessionId: 'preview-session',
              pairingToken: 'preview-token',
              issuedAtEpochSeconds: 1735689600,
              expiresAtEpochSeconds: 1735693200,
            ),
            qrPayload: 'codex://pair?session=preview-session',
          )
        : null,
    errorMessage: scenario == PreviewScenario.degraded
        ? 'Preview failure banner: runtime health check exceeded retry budget.'
        : null,
  );
}
