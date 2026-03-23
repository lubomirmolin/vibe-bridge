import 'package:codex_linux_shell/src/contracts.dart';
import 'package:codex_linux_shell/src/shell_presentation.dart';
import 'package:codex_linux_shell/src/shell_view.dart';
import 'package:codex_ui/codex_ui.dart';
import 'package:flutter/material.dart';

void main() {
  runApp(const CodexLinuxShellPreviewApp());
}

enum PreviewScenario { starting, unpaired, pairedIdle, pairedActive, degraded }

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
          onRefreshQr: () async {},
          onRestartRuntime: () async {},
          onRevokeTrust: () async {},
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
    PreviewScenario.degraded => 'Degraded',
  };
}

ShellPresentationState _stateFor(PreviewScenario scenario) {
  final shellState = switch (scenario) {
    PreviewScenario.starting => ShellRuntimeState.starting,
    PreviewScenario.unpaired => ShellRuntimeState.unpaired,
    PreviewScenario.pairedIdle => ShellRuntimeState.pairedIdle,
    PreviewScenario.pairedActive => ShellRuntimeState.pairedActive,
    PreviewScenario.degraded => ShellRuntimeState.degraded,
  };

  return ShellPresentationState.initial().copyWith(
    shellState: shellState,
    supervisorStatusLabel: switch (scenario) {
      PreviewScenario.starting => 'Launching managed runtime',
      PreviewScenario.unpaired => 'Managed locally',
      PreviewScenario.pairedIdle => 'Attached to local bridge',
      PreviewScenario.pairedActive => 'Managed locally',
      PreviewScenario.degraded => 'Bridge unreachable',
    },
    bridgeRuntimeLabel: switch (scenario) {
      PreviewScenario.starting => 'Starting',
      PreviewScenario.degraded => 'Unavailable',
      _ => 'managed (auto)',
    },
    pairedDeviceLabel: switch (scenario) {
      PreviewScenario.unpaired => 'Not paired',
      PreviewScenario.starting => 'Awaiting handshake',
      _ => 'Pixel 9 Pro (phone-1)',
    },
    activeSessionLabel: switch (scenario) {
      PreviewScenario.pairedActive => 'session-7f4d',
      PreviewScenario.pairedIdle => 'session-7f4d',
      _ => 'No active session',
    },
    runningThreadCount: switch (scenario) {
      PreviewScenario.pairedActive => 3,
      _ => 0,
    },
    runtimeDetail: switch (scenario) {
      PreviewScenario.starting =>
        'Preparing the bundled bridge-server and checking local health.',
      PreviewScenario.unpaired =>
        'Bridge runtime healthy. Waiting for a phone to trust this host.',
      PreviewScenario.pairedIdle =>
        'Bridge runtime healthy. Host paired and ready for mobile control.',
      PreviewScenario.pairedActive =>
        'Bridge runtime healthy. A paired phone currently has an active session.',
      PreviewScenario.degraded =>
        'Bridge supervision is retrying because the local runtime is unavailable.',
    },
    trayAvailable: true,
    trayStatusDetail:
        'Preview tray detail only. No real tray integration here.',
    pairingSession: scenario == PreviewScenario.unpaired
        ? PairingSessionResponseDto(
            contractVersion: SharedContract.version,
            bridgeIdentity: const PairingBridgeIdentityDto(
              bridgeId: 'bridge-preview',
              displayName: 'Codex Host',
              apiBaseUrl: 'http://127.0.0.1:3110',
            ),
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
