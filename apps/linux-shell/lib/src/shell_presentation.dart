import 'package:codex_linux_shell/src/contracts.dart';

enum ShellRuntimeState {
  starting,
  unpaired,
  pairedIdle,
  pairedActive,
  needsTailscale,
  degraded,
}

class TailscalePresentation {
  const TailscalePresentation({
    required this.statusLabel,
    required this.detail,
    required this.installHint,
    required this.isInstalled,
    required this.isAuthenticated,
    this.binaryPath,
  });

  const TailscalePresentation.initial()
    : statusLabel = 'Unchecked',
      detail = 'Tailscale status has not been checked yet.',
      installHint = 'curl -fsSL https://tailscale.com/install.sh | sh',
      isInstalled = false,
      isAuthenticated = false,
      binaryPath = null;

  final String statusLabel;
  final String detail;
  final String installHint;
  final bool isInstalled;
  final bool isAuthenticated;
  final String? binaryPath;

  TailscalePresentation copyWith({
    String? statusLabel,
    String? detail,
    String? installHint,
    bool? isInstalled,
    bool? isAuthenticated,
    String? binaryPath,
  }) {
    return TailscalePresentation(
      statusLabel: statusLabel ?? this.statusLabel,
      detail: detail ?? this.detail,
      installHint: installHint ?? this.installHint,
      isInstalled: isInstalled ?? this.isInstalled,
      isAuthenticated: isAuthenticated ?? this.isAuthenticated,
      binaryPath: binaryPath ?? this.binaryPath,
    );
  }
}

class CodexPresentation {
  const CodexPresentation({
    required this.statusLabel,
    required this.detail,
    required this.nextStep,
    required this.isReady,
    this.binaryPath,
    this.sourceLabel,
  });

  const CodexPresentation.initial()
    : statusLabel = 'Unchecked',
      detail =
          'Codex CLI status has not been checked yet. The shell can still pair a device, but threads and approvals need a local Codex runtime.',
      nextStep = 'Check for Codex CLI',
      isReady = false,
      binaryPath = null,
      sourceLabel = null;

  final String statusLabel;
  final String detail;
  final String nextStep;
  final bool isReady;
  final String? binaryPath;
  final String? sourceLabel;

  bool get requiresSetup => !isReady;

  CodexPresentation copyWith({
    String? statusLabel,
    String? detail,
    String? nextStep,
    bool? isReady,
    String? binaryPath,
    String? sourceLabel,
  }) {
    return CodexPresentation(
      statusLabel: statusLabel ?? this.statusLabel,
      detail: detail ?? this.detail,
      nextStep: nextStep ?? this.nextStep,
      isReady: isReady ?? this.isReady,
      binaryPath: binaryPath ?? this.binaryPath,
      sourceLabel: sourceLabel ?? this.sourceLabel,
    );
  }
}

class SpeechPanelPresentation {
  const SpeechPanelPresentation({
    required this.stateLabel,
    required this.detail,
    required this.isReadOnly,
    this.downloadProgress,
  });

  final String stateLabel;
  final String detail;
  final bool isReadOnly;
  final int? downloadProgress;

  SpeechPanelPresentation copyWith({
    String? stateLabel,
    String? detail,
    bool? isReadOnly,
    int? downloadProgress,
  }) {
    return SpeechPanelPresentation(
      stateLabel: stateLabel ?? this.stateLabel,
      detail: detail ?? this.detail,
      isReadOnly: isReadOnly ?? this.isReadOnly,
      downloadProgress: downloadProgress ?? this.downloadProgress,
    );
  }
}

class TrustedDevicePresentation {
  const TrustedDevicePresentation({
    required this.deviceId,
    required this.deviceName,
    required this.pairedAtEpochSeconds,
    this.sessionId,
    this.finalizedAtEpochSeconds,
  });

  final String deviceId;
  final String deviceName;
  final int pairedAtEpochSeconds;
  final String? sessionId;
  final int? finalizedAtEpochSeconds;

  bool get isActive => sessionId != null && sessionId!.trim().isNotEmpty;

  String get displayLabel => '$deviceName ($deviceId)';
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
    required this.isCheckingTailscale,
    required this.isCheckingCodex,
    required this.isSavingCodexPath,
    required this.isInstallingSpeechModel,
    required this.isRemovingSpeechModel,
    required this.isUpdatingNetworkSettings,
    required this.trayAvailable,
    required this.trayStatusDetail,
    required this.tailscale,
    required this.codex,
    required this.localNetworkPairingEnabled,
    required this.pairingRoutes,
    required this.trustedDevices,
    required this.pairingSession,
    required this.errorMessage,
  });

  factory ShellPresentationState.initial() {
    return const ShellPresentationState(
      shellState: ShellRuntimeState.degraded,
      supervisorStatusLabel: 'Not started',
      bridgeRuntimeLabel: 'Unavailable',
      pairedDeviceLabel: 'Not paired',
      activeSessionLabel: 'No active sessions',
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
      isCheckingTailscale: false,
      isCheckingCodex: false,
      isSavingCodexPath: false,
      isInstallingSpeechModel: false,
      isRemovingSpeechModel: false,
      isUpdatingNetworkSettings: false,
      trayAvailable: false,
      trayStatusDetail: 'System tray not initialized yet.',
      tailscale: TailscalePresentation.initial(),
      codex: CodexPresentation.initial(),
      localNetworkPairingEnabled: false,
      pairingRoutes: <BridgeApiRouteDto>[],
      trustedDevices: <TrustedDevicePresentation>[],
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
  final bool isCheckingTailscale;
  final bool isCheckingCodex;
  final bool isSavingCodexPath;
  final bool isInstallingSpeechModel;
  final bool isRemovingSpeechModel;
  final bool isUpdatingNetworkSettings;
  final bool trayAvailable;
  final String trayStatusDetail;
  final TailscalePresentation tailscale;
  final CodexPresentation codex;
  final bool localNetworkPairingEnabled;
  final List<BridgeApiRouteDto> pairingRoutes;
  final List<TrustedDevicePresentation> trustedDevices;
  final PairingSessionResponseDto? pairingSession;
  final String? errorMessage;

  bool get shouldShowPairingQr => shellState == ShellRuntimeState.unpaired;
  bool get canGeneratePairingQr =>
      shellState == ShellRuntimeState.unpaired ||
      shellState == ShellRuntimeState.pairedIdle ||
      shellState == ShellRuntimeState.pairedActive;
  bool get requiresTailscaleSetup =>
      shellState == ShellRuntimeState.needsTailscale;
  bool get requiresCodexSetup => codex.requiresSetup;
  bool get canRevokeTrust =>
      trustedDevices.isNotEmpty &&
      (shellState == ShellRuntimeState.pairedIdle ||
          shellState == ShellRuntimeState.pairedActive);
  bool get canRevokeActiveDevice =>
      canRevokeTrust && trustedDevices.any((device) => device.isActive);
  int get trustedDeviceCount => trustedDevices.length;
  int get activeSessionCount =>
      trustedDevices.where((device) => device.isActive).length;
  bool get canInstallSpeechModel =>
      !isInstallingSpeechModel &&
      !isRemovingSpeechModel &&
      speechPanel.stateLabel != 'Ready' &&
      speechPanel.stateLabel != 'Unsupported' &&
      shellState != ShellRuntimeState.degraded;
  bool get canRemoveSpeechModel =>
      !isInstallingSpeechModel &&
      !isRemovingSpeechModel &&
      speechPanel.stateLabel == 'Ready';
  String get routeSummaryLabel {
    final reachableCount = pairingRoutes.where((route) => route.reachable).length;
    return '$reachableCount/${pairingRoutes.length} reachable';
  }

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
    bool? isCheckingTailscale,
    bool? isCheckingCodex,
    bool? isSavingCodexPath,
    bool? isInstallingSpeechModel,
    bool? isRemovingSpeechModel,
    bool? isUpdatingNetworkSettings,
    bool? trayAvailable,
    String? trayStatusDetail,
    TailscalePresentation? tailscale,
    CodexPresentation? codex,
    bool? localNetworkPairingEnabled,
    List<BridgeApiRouteDto>? pairingRoutes,
    List<TrustedDevicePresentation>? trustedDevices,
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
      isCheckingTailscale: isCheckingTailscale ?? this.isCheckingTailscale,
      isCheckingCodex: isCheckingCodex ?? this.isCheckingCodex,
      isSavingCodexPath: isSavingCodexPath ?? this.isSavingCodexPath,
      isInstallingSpeechModel:
          isInstallingSpeechModel ?? this.isInstallingSpeechModel,
      isRemovingSpeechModel:
          isRemovingSpeechModel ?? this.isRemovingSpeechModel,
      isUpdatingNetworkSettings:
          isUpdatingNetworkSettings ?? this.isUpdatingNetworkSettings,
      trayAvailable: trayAvailable ?? this.trayAvailable,
      trayStatusDetail: trayStatusDetail ?? this.trayStatusDetail,
      tailscale: tailscale ?? this.tailscale,
      codex: codex ?? this.codex,
      localNetworkPairingEnabled:
          localNetworkPairingEnabled ?? this.localNetworkPairingEnabled,
      pairingRoutes: pairingRoutes ?? this.pairingRoutes,
      trustedDevices: trustedDevices ?? this.trustedDevices,
      pairingSession: clearPairingSession
          ? null
          : pairingSession ?? this.pairingSession,
      errorMessage: clearErrorMessage
          ? null
          : errorMessage ?? this.errorMessage,
    );
  }
}
