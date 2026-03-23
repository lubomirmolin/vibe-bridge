import 'package:codex_linux_shell/src/contracts.dart';

enum ShellRuntimeState {
  starting,
  unpaired,
  pairedIdle,
  pairedActive,
  degraded,
}

class SpeechPanelPresentation {
  const SpeechPanelPresentation({
    required this.stateLabel,
    required this.detail,
    required this.isReadOnly,
  });

  final String stateLabel;
  final String detail;
  final bool isReadOnly;

  SpeechPanelPresentation copyWith({
    String? stateLabel,
    String? detail,
    bool? isReadOnly,
  }) {
    return SpeechPanelPresentation(
      stateLabel: stateLabel ?? this.stateLabel,
      detail: detail ?? this.detail,
      isReadOnly: isReadOnly ?? this.isReadOnly,
    );
  }
}

class ShellPresentationState {
  const ShellPresentationState({
    required this.shellState,
    required this.supervisorStatusLabel,
    required this.bridgeRuntimeLabel,
    required this.pairedDeviceLabel,
    required this.activeSessionLabel,
    required this.runningThreadCount,
    required this.runtimeDetail,
    required this.speechPanel,
    required this.isLoadingPairing,
    required this.isRefreshingRuntime,
    required this.isRestartingRuntime,
    required this.isRevokingTrust,
    required this.trayAvailable,
    required this.trayStatusDetail,
    required this.pairingSession,
    required this.errorMessage,
  });

  factory ShellPresentationState.initial() {
    return const ShellPresentationState(
      shellState: ShellRuntimeState.degraded,
      supervisorStatusLabel: 'Not started',
      bridgeRuntimeLabel: 'Unavailable',
      pairedDeviceLabel: 'Not paired',
      activeSessionLabel: 'No active session',
      runningThreadCount: 0,
      runtimeDetail: 'Waiting for bridge supervision…',
      speechPanel: SpeechPanelPresentation(
        stateLabel: 'Unsupported',
        detail:
            'Speech transcription is not available from the Linux shell yet.',
        isReadOnly: true,
      ),
      isLoadingPairing: false,
      isRefreshingRuntime: false,
      isRestartingRuntime: false,
      isRevokingTrust: false,
      trayAvailable: false,
      trayStatusDetail: 'System tray not initialized yet.',
      pairingSession: null,
      errorMessage: null,
    );
  }

  final ShellRuntimeState shellState;
  final String supervisorStatusLabel;
  final String bridgeRuntimeLabel;
  final String pairedDeviceLabel;
  final String activeSessionLabel;
  final int runningThreadCount;
  final String runtimeDetail;
  final SpeechPanelPresentation speechPanel;
  final bool isLoadingPairing;
  final bool isRefreshingRuntime;
  final bool isRestartingRuntime;
  final bool isRevokingTrust;
  final bool trayAvailable;
  final String trayStatusDetail;
  final PairingSessionResponseDto? pairingSession;
  final String? errorMessage;

  bool get shouldShowPairingQr => shellState == ShellRuntimeState.unpaired;
  bool get canRevokeTrust =>
      shellState == ShellRuntimeState.pairedIdle ||
      shellState == ShellRuntimeState.pairedActive;

  ShellPresentationState copyWith({
    ShellRuntimeState? shellState,
    String? supervisorStatusLabel,
    String? bridgeRuntimeLabel,
    String? pairedDeviceLabel,
    String? activeSessionLabel,
    int? runningThreadCount,
    String? runtimeDetail,
    SpeechPanelPresentation? speechPanel,
    bool? isLoadingPairing,
    bool? isRefreshingRuntime,
    bool? isRestartingRuntime,
    bool? isRevokingTrust,
    bool? trayAvailable,
    String? trayStatusDetail,
    PairingSessionResponseDto? pairingSession,
    bool clearPairingSession = false,
    String? errorMessage,
    bool clearErrorMessage = false,
  }) {
    return ShellPresentationState(
      shellState: shellState ?? this.shellState,
      supervisorStatusLabel:
          supervisorStatusLabel ?? this.supervisorStatusLabel,
      bridgeRuntimeLabel: bridgeRuntimeLabel ?? this.bridgeRuntimeLabel,
      pairedDeviceLabel: pairedDeviceLabel ?? this.pairedDeviceLabel,
      activeSessionLabel: activeSessionLabel ?? this.activeSessionLabel,
      runningThreadCount: runningThreadCount ?? this.runningThreadCount,
      runtimeDetail: runtimeDetail ?? this.runtimeDetail,
      speechPanel: speechPanel ?? this.speechPanel,
      isLoadingPairing: isLoadingPairing ?? this.isLoadingPairing,
      isRefreshingRuntime: isRefreshingRuntime ?? this.isRefreshingRuntime,
      isRestartingRuntime: isRestartingRuntime ?? this.isRestartingRuntime,
      isRevokingTrust: isRevokingTrust ?? this.isRevokingTrust,
      trayAvailable: trayAvailable ?? this.trayAvailable,
      trayStatusDetail: trayStatusDetail ?? this.trayStatusDetail,
      pairingSession: clearPairingSession
          ? null
          : pairingSession ?? this.pairingSession,
      errorMessage: clearErrorMessage
          ? null
          : errorMessage ?? this.errorMessage,
    );
  }
}
