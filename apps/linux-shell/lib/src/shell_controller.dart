import 'dart:async';

import 'package:codex_linux_shell/src/bridge_shell_api_client.dart';
import 'package:codex_linux_shell/src/contracts.dart';
import 'package:codex_linux_shell/src/runtime_supervisor.dart';
import 'package:codex_linux_shell/src/shell_presentation.dart';
import 'package:flutter/foundation.dart';

class ShellController extends ChangeNotifier {
  ShellController({
    ShellBridgeClient? bridgeClient,
    RuntimeSupervisor? runtimeSupervisor,
    TailscaleCliChecker? tailscaleCliChecker,
    CodexCliChecker? codexCliChecker,
    Duration degradedPollInterval = const Duration(seconds: 2),
    Duration healthyPollInterval = const Duration(seconds: 5),
  }) : _bridgeClient = bridgeClient ?? BridgeShellApiClient(),
       _runtimeSupervisor = runtimeSupervisor ?? RuntimeSupervisor(),
       _tailscaleCliChecker = tailscaleCliChecker ?? LinuxTailscaleCliChecker(),
       _codexCliChecker = codexCliChecker ?? LinuxCodexCliChecker(),
       _degradedPollInterval = degradedPollInterval,
       _healthyPollInterval = healthyPollInterval;

  final ShellBridgeClient _bridgeClient;
  final RuntimeSupervisor _runtimeSupervisor;
  final TailscaleCliChecker _tailscaleCliChecker;
  final CodexCliChecker _codexCliChecker;
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

  Future<void> checkTailscaleAvailability() async {
    if (_state.isCheckingTailscale || _disposed) {
      return;
    }

    _emit(_state.copyWith(isCheckingTailscale: true));
    try {
      final tailscale = await _readTailscalePresentation();
      _emit(
        _state.copyWith(
          tailscale: tailscale,
          runtimeDetail: tailscale.detail,
          clearErrorMessage: true,
        ),
      );

      if (tailscale.isInstalled && tailscale.isAuthenticated) {
        await refreshRuntimeState();
      } else {
        _applyTailscaleRequiredState(
          message: tailscale.detail,
          tailscale: tailscale,
        );
      }
    } finally {
      _emit(_state.copyWith(isCheckingTailscale: false));
    }
  }

  Future<void> checkCodexAvailability() async {
    if (_state.isCheckingCodex || _disposed) {
      return;
    }

    _emit(_state.copyWith(isCheckingCodex: true));
    try {
      final codex = await _readCodexPresentation();
      _emit(
        _state.copyWith(
          codex: codex,
          runtimeDetail: codex.detail,
          clearErrorMessage: codex.requiresSetup,
        ),
      );
      if (codex.isReady) {
        await refreshRuntimeState();
      }
    } finally {
      _emit(_state.copyWith(isCheckingCodex: false));
    }
  }

  Future<void> savePreferredCodexBinaryPath(String path) async {
    if (_state.isSavingCodexPath || _disposed) {
      return;
    }

    _emit(_state.copyWith(isSavingCodexPath: true));
    try {
      final codex = await _codexCliChecker.savePreferredBinaryPath(path);
      _emit(
        _state.copyWith(
          codex: _toCodexPresentation(codex),
          runtimeDetail:
              'Saved the selected Codex binary. Restarting the local runtime to apply it.',
          clearErrorMessage: true,
        ),
      );

      if (_runtimeSupervisor.managesProcess) {
        await restartLocalRuntime();
      } else {
        await refreshRuntimeState();
      }
    } catch (error) {
      _emit(
        _state.copyWith(
          errorMessage: 'Could not use the selected Codex binary: $error',
        ),
      );
    } finally {
      _emit(_state.copyWith(isSavingCodexPath: false));
    }
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
      final codex = await _readCodexPresentation();
      if (!_isShellOperational(health)) {
        final pairingMessage =
            health.pairingRoute.message ??
            'Private pairing route is unavailable.';
        if (!health.pairingRoute.reachable &&
            _looksLikeTailscaleProblem(pairingMessage)) {
          final tailscale = await _readTailscalePresentation();
          _applyTailscaleRequiredState(
            message: pairingMessage,
            tailscale: tailscale,
          );
          return;
        }
        _applyDegradedState(
          health.pairingRoute.reachable
              ? health.runtime.detail
              : pairingMessage,
          codex: codex,
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
        runtimeDetail: health.runtime.state == 'degraded' && codex.requiresSetup
            ? codex.detail
            : health.runtime.detail,
        speechStatus: speechStatus,
        runtimeIssue: health.runtime.state == 'degraded' && !codex.requiresSetup
            ? health.runtime.detail
            : null,
        codex: codex,
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

  bool _isShellOperational(BridgeHealthResponseDto health) {
    return health.status == 'ok' && health.pairingRoute.reachable;
  }

  bool _looksLikeTailscaleProblem(String message) {
    final normalized = message.toLowerCase();
    return normalized.contains('tailscale');
  }

  Future<TailscalePresentation> _readTailscalePresentation() async {
    final status = await _tailscaleCliChecker.check();
    return TailscalePresentation(
      statusLabel: status.statusLabel,
      detail: status.detail,
      installHint: status.installHint,
      isInstalled: status.isInstalled,
      isAuthenticated: status.isAuthenticated,
      binaryPath: status.binaryPath,
    );
  }

  Future<CodexPresentation> _readCodexPresentation() async {
    final status = await _codexCliChecker.check();
    return _toCodexPresentation(status);
  }

  CodexPresentation _toCodexPresentation(CodexCliStatus status) {
    return CodexPresentation(
      statusLabel: status.statusLabel,
      detail: status.detail,
      nextStep: status.nextStep,
      isReady: status.isReady,
      binaryPath: status.binaryPath,
      sourceLabel: status.sourceLabel,
    );
  }

  void _applyHealthyState({
    required BridgeTrustStatusDto? trustStatus,
    required int runningThreadCount,
    required String bridgeRuntimeLabel,
    required String runtimeDetail,
    required SpeechModelStatusDto? speechStatus,
    required CodexPresentation codex,
    String? runtimeIssue,
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
        codex: codex,
        tailscale: _state.tailscale.copyWith(
          statusLabel: 'Connected',
          detail: 'Tailscale route is available for private pairing.',
          isInstalled: true,
          isAuthenticated: true,
          installHint: '',
        ),
        errorMessage: runtimeIssue,
        clearErrorMessage: runtimeIssue == null,
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

  void _applyDegradedState(String message, {CodexPresentation? codex}) {
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
        codex: codex ?? _state.codex,
        clearPairingSession: true,
        errorMessage: message,
      ),
    );
  }

  void _applyTailscaleRequiredState({
    required String message,
    required TailscalePresentation tailscale,
  }) {
    _trustedPhoneId = null;
    _emit(
      _state.copyWith(
        shellState: ShellRuntimeState.needsTailscale,
        bridgeRuntimeLabel: 'Tailscale required',
        pairedDeviceLabel: tailscale.isInstalled
            ? 'Awaiting tailnet connection'
            : 'Tailscale not installed',
        activeSessionLabel: 'Unavailable',
        runningThreadCount: 0,
        runtimeDetail: message,
        tailscale: tailscale,
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
