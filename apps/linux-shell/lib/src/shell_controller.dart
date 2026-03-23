import 'dart:async';

import 'package:codex_linux_shell/src/bridge_shell_api_client.dart';
import 'package:codex_linux_shell/src/contracts.dart';
import 'package:codex_linux_shell/src/runtime_supervisor.dart';
import 'package:flutter/foundation.dart';

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

class ShellController extends ChangeNotifier {
  ShellController({
    ShellBridgeClient? bridgeClient,
    RuntimeSupervisor? runtimeSupervisor,
    Duration degradedPollInterval = const Duration(seconds: 2),
    Duration healthyPollInterval = const Duration(seconds: 5),
  }) : _bridgeClient = bridgeClient ?? BridgeShellApiClient(),
       _runtimeSupervisor = runtimeSupervisor ?? RuntimeSupervisor(),
       _degradedPollInterval = degradedPollInterval,
       _healthyPollInterval = healthyPollInterval;

  final ShellBridgeClient _bridgeClient;
  final RuntimeSupervisor _runtimeSupervisor;
  final Duration _degradedPollInterval;
  final Duration _healthyPollInterval;

  ShellPresentationState _state = ShellPresentationState.initial();
  ShellPresentationState get state => _state;

  String? _trustedPhoneId;
  bool _disposed = false;
  Future<void>? _supervisionLoop;

  void startRuntimeSupervision() {
    _supervisionLoop ??= _runSupervisionLoop();
  }

  Future<void> shutdown() async {
    _disposed = true;
    await _runtimeSupervisor.shutdownBridgeIfManaged();
  }

  void setTrayAvailability({required bool available, required String detail}) {
    _emit(_state.copyWith(trayAvailable: available, trayStatusDetail: detail));
  }

  Future<void> refreshRuntimeState() async {
    if (_state.isRefreshingRuntime || _disposed) {
      return;
    }

    _emit(_state.copyWith(isRefreshingRuntime: true));
    RuntimeLaunchSnapshot? launchSnapshot;
    try {
      launchSnapshot = await _runtimeSupervisor.prepareBridgeForConnection();
      _emit(_state.copyWith(supervisorStatusLabel: launchSnapshot.statusLabel));

      final health = await _bridgeClient.fetchHealth();
      if (!_isHealthy(health)) {
        _applyDegradedState(
          health.pairingRoute.reachable
              ? health.runtime.detail
              : health.pairingRoute.message ??
                    'Private pairing route is unavailable.',
        );
        return;
      }

      final threads = await _bridgeClient.fetchThreads();
      final speechStatus = await _safeFetchSpeechStatus();
      final runningCount = threads.threads
          .where((thread) => thread.status == ThreadStatus.running)
          .length;
      _applyHealthyState(
        trustStatus: health.trust,
        runningThreadCount: runningCount,
        bridgeRuntimeLabel: '${health.runtime.state} (${health.runtime.mode})',
        runtimeDetail: health.runtime.detail,
        speechStatus: speechStatus,
      );

      if (_state.shellState == ShellRuntimeState.unpaired) {
        await refreshPairingSessionIfNeeded();
      }
    } on RuntimeSupervisorException catch (error) {
      _applyDegradedState('Linux runtime startup failed: ${error.message}');
    } catch (error) {
      if (launchSnapshot?.isLaunching ?? false) {
        _applyStartingState(
          bridgeLabel: launchSnapshot!.statusLabel,
          detail: launchSnapshot.detail,
        );
      } else {
        _applyDegradedState('Bridge supervision retrying: $error');
      }
    } finally {
      _emit(_state.copyWith(isRefreshingRuntime: false));
    }
  }

  Future<void> restartLocalRuntime() async {
    if (_state.isRestartingRuntime) {
      return;
    }

    _emit(_state.copyWith(isRestartingRuntime: true));
    try {
      final snapshot = await _runtimeSupervisor.restartBridge();
      _applyStartingState(
        bridgeLabel: snapshot.statusLabel,
        detail: snapshot.detail,
      );
      await refreshRuntimeState();
    } catch (error) {
      _applyDegradedState('Linux runtime restart failed: $error');
    } finally {
      _emit(_state.copyWith(isRestartingRuntime: false));
    }
  }

  Future<void> revokeTrustedPhoneFromDesktop() async {
    if (_state.isRevokingTrust) {
      return;
    }

    _emit(_state.copyWith(isRevokingTrust: true));
    try {
      final response = await _bridgeClient.revokeTrust(
        phoneId: _trustedPhoneId,
      );
      if (response.revoked) {
        _emit(
          _state.copyWith(
            runtimeDetail:
                'Desktop trust revoked. The phone must pair again before reconnecting.',
            clearErrorMessage: true,
          ),
        );
        await refreshRuntimeState();
        if (_state.shellState == ShellRuntimeState.unpaired) {
          await refreshPairingSessionIfNeeded();
        }
      } else {
        _emit(
          _state.copyWith(
            errorMessage: 'No trusted phone was available to revoke.',
          ),
        );
      }
    } catch (error) {
      _emit(
        _state.copyWith(
          errorMessage: 'Failed to revoke trust from Linux shell: $error',
        ),
      );
    } finally {
      _emit(_state.copyWith(isRevokingTrust: false));
    }
  }

  Future<void> refreshPairingSessionIfNeeded() async {
    if (!_state.shouldShowPairingQr || _state.isLoadingPairing) {
      return;
    }

    final session = _state.pairingSession;
    if (session != null) {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      if (session.pairingSession.expiresAtEpochSeconds > now + 15) {
        return;
      }
    }
    await refreshPairingSession();
  }

  Future<void> refreshPairingSession() async {
    if (!_state.shouldShowPairingQr || _state.isLoadingPairing) {
      return;
    }

    _emit(_state.copyWith(isLoadingPairing: true));
    try {
      final session = await _bridgeClient.fetchPairingSession();
      _emit(_state.copyWith(pairingSession: session, clearErrorMessage: true));
    } catch (error) {
      _emit(
        _state.copyWith(
          errorMessage:
              'Failed to generate pairing QR from bridge data: $error',
          clearPairingSession: true,
        ),
      );
    } finally {
      _emit(_state.copyWith(isLoadingPairing: false));
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<void> _runSupervisionLoop() async {
    while (!_disposed) {
      await refreshRuntimeState();
      await Future<void>.delayed(
        _state.shellState == ShellRuntimeState.degraded
            ? _degradedPollInterval
            : _healthyPollInterval,
      );
    }
  }

  Future<SpeechModelStatusDto?> _safeFetchSpeechStatus() async {
    try {
      return await _bridgeClient.fetchSpeechModelStatus();
    } catch (_) {
      return null;
    }
  }

  bool _isHealthy(BridgeHealthResponseDto health) {
    return health.status == 'ok' &&
        health.pairingRoute.reachable &&
        health.runtime.state != 'degraded';
  }

  void _applyHealthyState({
    required BridgeTrustStatusDto? trustStatus,
    required int runningThreadCount,
    required String bridgeRuntimeLabel,
    required String runtimeDetail,
    required SpeechModelStatusDto? speechStatus,
  }) {
    final shellState = trustStatus?.trustedPhone == null
        ? ShellRuntimeState.unpaired
        : runningThreadCount > 0
        ? ShellRuntimeState.pairedActive
        : ShellRuntimeState.pairedIdle;

    _trustedPhoneId = trustStatus?.trustedPhone?.phoneId;
    _emit(
      _state.copyWith(
        shellState: shellState,
        bridgeRuntimeLabel: bridgeRuntimeLabel,
        pairedDeviceLabel: trustStatus?.trustedPhone == null
            ? 'Not paired'
            : '${trustStatus!.trustedPhone!.phoneName} (${trustStatus.trustedPhone!.phoneId})',
        activeSessionLabel:
            trustStatus?.activeSession?.sessionId ?? 'No active session',
        runningThreadCount: runningThreadCount,
        runtimeDetail: runtimeDetail,
        speechPanel: _speechPanelFor(speechStatus),
        clearErrorMessage: true,
        clearPairingSession: shellState != ShellRuntimeState.unpaired,
      ),
    );
  }

  void _applyStartingState({
    required String bridgeLabel,
    required String detail,
  }) {
    _trustedPhoneId = null;
    _emit(
      _state.copyWith(
        shellState: ShellRuntimeState.starting,
        bridgeRuntimeLabel: bridgeLabel,
        pairedDeviceLabel: 'Waiting for bridge',
        activeSessionLabel: 'Waiting for bridge',
        runningThreadCount: 0,
        runtimeDetail: detail,
        speechPanel: const SpeechPanelPresentation(
          stateLabel: 'Unsupported',
          detail:
              'Speech transcription is not available from the Linux shell yet.',
          isReadOnly: true,
        ),
        clearPairingSession: true,
        clearErrorMessage: true,
      ),
    );
  }

  void _applyDegradedState(String message) {
    _trustedPhoneId = null;
    _emit(
      _state.copyWith(
        shellState: ShellRuntimeState.degraded,
        bridgeRuntimeLabel: 'Unavailable',
        pairedDeviceLabel: 'Unavailable',
        activeSessionLabel: 'Unavailable',
        runningThreadCount: 0,
        runtimeDetail: message,
        speechPanel: const SpeechPanelPresentation(
          stateLabel: 'Unsupported',
          detail:
              'Speech transcription is not available from the Linux shell yet.',
          isReadOnly: true,
        ),
        clearPairingSession: true,
        errorMessage: message,
      ),
    );
  }

  SpeechPanelPresentation _speechPanelFor(SpeechModelStatusDto? status) {
    if (status == null) {
      return const SpeechPanelPresentation(
        stateLabel: 'Unsupported',
        detail:
            'Speech transcription is not available from the Linux shell yet.',
        isReadOnly: true,
      );
    }

    final detail = switch (status.state) {
      SpeechModelState.notInstalled =>
        'Parakeet is not installed. Linux shell stays read-only for speech.',
      SpeechModelState.installing =>
        'Parakeet install is in progress elsewhere. Linux shell remains read-only.',
      SpeechModelState.ready =>
        'Bridge reports speech ready, but Linux shell does not manage speech yet.',
      SpeechModelState.busy =>
        'Bridge speech runtime is busy. Linux shell remains read-only.',
      SpeechModelState.failed =>
        status.lastError ?? 'Speech runtime is unavailable right now.',
      SpeechModelState.unsupported =>
        status.lastError ??
            'Speech transcription is only available when the macOS shell provides a speech helper.',
    };

    return SpeechPanelPresentation(
      stateLabel: switch (status.state) {
        SpeechModelState.unsupported => 'Unsupported',
        SpeechModelState.notInstalled => 'Not Installed',
        SpeechModelState.installing => 'Installing',
        SpeechModelState.ready => 'Ready',
        SpeechModelState.busy => 'Busy',
        SpeechModelState.failed => 'Failed',
      },
      detail: detail,
      isReadOnly: true,
    );
  }

  void _emit(ShellPresentationState nextState) {
    if (_disposed) {
      return;
    }
    _state = nextState;
    notifyListeners();
  }
}
