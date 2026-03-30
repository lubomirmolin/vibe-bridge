import 'dart:async';

import 'package:codex_linux_shell/src/bridge_shell_api_client.dart';
import 'package:codex_linux_shell/src/contracts.dart';
import 'package:codex_linux_shell/src/release_updater.dart';
import 'package:codex_linux_shell/src/runtime_supervisor.dart';
import 'package:codex_linux_shell/src/shell_presentation.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

class ShellController extends ChangeNotifier {
  ShellController({
    ShellBridgeClient? bridgeClient,
    RuntimeSupervisor? runtimeSupervisor,
    TailscaleCliChecker? tailscaleCliChecker,
    CodexCliChecker? codexCliChecker,
    ShellReleaseUpdater? releaseUpdater,
    Future<String> Function()? appVersionProvider,
    Duration degradedPollInterval = const Duration(seconds: 2),
    Duration healthyPollInterval = const Duration(seconds: 5),
  }) : _bridgeClient = bridgeClient ?? BridgeShellApiClient(),
       _runtimeSupervisor = runtimeSupervisor ?? RuntimeSupervisor(),
       _tailscaleCliChecker = tailscaleCliChecker ?? LinuxTailscaleCliChecker(),
       _codexCliChecker = codexCliChecker ?? LinuxCodexCliChecker(),
       _releaseUpdater = releaseUpdater ?? GitHubShellReleaseUpdater(),
       _appVersionProvider =
           appVersionProvider ??
           (() async => (await PackageInfo.fromPlatform()).version),
       _degradedPollInterval = degradedPollInterval,
       _healthyPollInterval = healthyPollInterval;

  final ShellBridgeClient _bridgeClient;
  final RuntimeSupervisor _runtimeSupervisor;
  final TailscaleCliChecker _tailscaleCliChecker;
  final CodexCliChecker _codexCliChecker;
  final ShellReleaseUpdater _releaseUpdater;
  final Future<String> Function() _appVersionProvider;
  final Duration _degradedPollInterval;
  final Duration _healthyPollInterval;

  ShellPresentationState _state = ShellPresentationState.initial();
  ShellPresentationState get state => _state;

  String? _activeTrustedDeviceId;
  PairingSessionResponseDto? _cachedPairingSession;
  LinuxUpdateCheckResult? _latestUpdateCheckResult;
  bool _disposed = false;
  Future<void>? _supervisionLoop;

  void startRuntimeSupervision() {
    _supervisionLoop ??= _runSupervisionLoop();
  }

  Future<void> shutdown() async {
    _disposed = true;
    await _runtimeSupervisor.shutdownBridgeIfManaged();
  }

  Future<void> stopBridgeExplicitly() async {
    _disposed = true;
    await _runtimeSupervisor.stopManagedBridge();
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

  Future<void> checkForUpdates() async {
    final panel = _state.updatePanel;
    if (panel.isChecking || panel.isInstalling || _disposed) {
      return;
    }

    _latestUpdateCheckResult = null;
    _emit(
      _state.copyWith(
        updatePanel: panel.copyWith(
          stateLabel: 'Checking',
          detail: 'Checking GitHub releases…',
          isChecking: true,
          isInstalling: false,
          canInstall: false,
          showOpenReleases: false,
          clearLatestVersion: true,
        ),
      ),
    );

    try {
      final currentVersion = await _appVersionProvider();
      final result = await _releaseUpdater.checkForUpdates(
        currentVersion: currentVersion,
      );

      if (result.isUpdateAvailable) {
        _latestUpdateCheckResult = result;
        _emit(
          _state.copyWith(
            updatePanel: _state.updatePanel.copyWith(
              stateLabel: 'Available',
              detail: result.asset == null
                  ? 'Version ${result.latestVersion} is available, but this release has no installable Linux shell asset.'
                  : 'Version ${result.latestVersion} is ready to download and install.',
              isChecking: false,
              isInstalling: false,
              canInstall: result.asset != null,
              showOpenReleases: result.asset == null,
              latestVersion: result.latestVersion.toString(),
              releaseUrl: result.releaseUrl.toString(),
            ),
          ),
        );
      } else {
        _emit(
          _state.copyWith(
            updatePanel: _state.updatePanel.copyWith(
              stateLabel: 'Up to Date',
              detail: 'You are up to date ($currentVersion).',
              isChecking: false,
              isInstalling: false,
              canInstall: false,
              showOpenReleases: false,
              latestVersion: result.latestVersion.toString(),
              releaseUrl: result.releaseUrl.toString(),
            ),
          ),
        );
      }
    } catch (error) {
      _emit(
        _state.copyWith(
          updatePanel: _state.updatePanel.copyWith(
            stateLabel: 'Failed',
            detail: '$error',
            isChecking: false,
            isInstalling: false,
            canInstall: false,
            showOpenReleases: true,
            clearLatestVersion: true,
          ),
        ),
      );
    }
  }

  Future<bool> installUpdate() async {
    final panel = _state.updatePanel;
    final updateCheckResult = _latestUpdateCheckResult;
    if (panel.isInstalling ||
        updateCheckResult == null ||
        !updateCheckResult.isUpdateAvailable ||
        updateCheckResult.asset == null ||
        _disposed) {
      return false;
    }

    _emit(
      _state.copyWith(
        updatePanel: panel.copyWith(
          stateLabel: 'Downloading',
          detail: 'Downloading update…',
          isChecking: false,
          isInstalling: true,
          canInstall: false,
        ),
      ),
    );

    try {
      await _releaseUpdater.prepareAndLaunchInstall(
        updateCheckResult,
        onProgress: (progress) {
          switch (progress.stage) {
            case LinuxInstallProgressStage.downloading:
              final detail = progress.fraction == null
                  ? 'Downloading update…'
                  : 'Downloading update: ${(progress.fraction! * 100).round()}%';
              _emit(
                _state.copyWith(
                  updatePanel: _state.updatePanel.copyWith(
                    stateLabel: 'Downloading',
                    detail: detail,
                    isInstalling: true,
                    canInstall: false,
                  ),
                ),
              );
            case LinuxInstallProgressStage.installing:
              _emit(
                _state.copyWith(
                  updatePanel: _state.updatePanel.copyWith(
                    stateLabel: 'Installing',
                    detail: 'Preparing installation…',
                    isInstalling: true,
                    canInstall: false,
                  ),
                ),
              );
            case LinuxInstallProgressStage.relaunching:
              _emit(
                _state.copyWith(
                  updatePanel: _state.updatePanel.copyWith(
                    stateLabel: 'Relaunching',
                    detail: 'Installing and relaunching…',
                    isInstalling: true,
                    canInstall: false,
                  ),
                ),
              );
          }
        },
      );
      return true;
    } catch (error) {
      _emit(
        _state.copyWith(
          updatePanel: _state.updatePanel.copyWith(
            stateLabel: 'Failed',
            detail: '$error',
            isInstalling: false,
            canInstall: true,
            showOpenReleases: true,
          ),
        ),
      );
      return false;
    }
  }

  Future<void> openReleasesPage() async {
    try {
      await _releaseUpdater.openReleasesPage();
    } catch (error) {
      _emit(
        _state.copyWith(
          updatePanel: _state.updatePanel.copyWith(
            stateLabel: 'Failed',
            detail: 'Could not open Releases: $error',
            showOpenReleases: true,
          ),
        ),
      );
    }
  }

  Future<void> ensureSpeechModelOnDesktop() async {
    if (_state.isInstallingSpeechModel || _disposed) {
      return;
    }

    _emit(_state.copyWith(isInstallingSpeechModel: true));
    try {
      await _bridgeClient.ensureSpeechModel();
      final speechStatus = await _safeFetchSpeechStatus();
      _emit(
        _state.copyWith(
          speechPanel: _speechPanelFor(speechStatus),
          clearErrorMessage: true,
        ),
      );
    } catch (error) {
      _emit(
        _state.copyWith(
          speechPanel: const SpeechPanelPresentation(
            stateLabel: 'Failed',
            detail: 'Speech runtime request failed.',
            isReadOnly: false,
          ).copyWith(detail: '$error'),
          errorMessage: 'Failed to start speech model install: $error',
        ),
      );
    } finally {
      _emit(_state.copyWith(isInstallingSpeechModel: false));
    }
  }

  Future<void> removeSpeechModelFromDesktop() async {
    if (_state.isRemovingSpeechModel || _disposed) {
      return;
    }

    _emit(_state.copyWith(isRemovingSpeechModel: true));
    try {
      await _bridgeClient.removeSpeechModel();
      final speechStatus = await _safeFetchSpeechStatus();
      _emit(
        _state.copyWith(
          speechPanel: _speechPanelFor(speechStatus),
          clearErrorMessage: true,
        ),
      );
    } catch (error) {
      _emit(
        _state.copyWith(
          speechPanel: const SpeechPanelPresentation(
            stateLabel: 'Failed',
            detail: 'Speech runtime request failed.',
            isReadOnly: false,
          ).copyWith(detail: '$error'),
          errorMessage: 'Failed to remove speech model: $error',
        ),
      );
    } finally {
      _emit(_state.copyWith(isRemovingSpeechModel: false));
    }
  }

  Future<void> setLocalNetworkPairingEnabled(bool enabled) async {
    if (_state.isUpdatingNetworkSettings || _disposed) {
      return;
    }

    _emit(_state.copyWith(isUpdatingNetworkSettings: true));
    try {
      final settings = await _bridgeClient.setLocalNetworkPairingEnabled(
        enabled,
      );
      _emit(
        _state.copyWith(
          localNetworkPairingEnabled: settings.localNetworkPairingEnabled,
          pairingRoutes: settings.routes,
          errorMessage: settings.message,
          clearErrorMessage: settings.message == null,
        ),
      );
      await refreshRuntimeState();
    } catch (error) {
      _emit(
        _state.copyWith(
          errorMessage: 'Failed to update local network pairing: $error',
        ),
      );
    } finally {
      _emit(_state.copyWith(isUpdatingNetworkSettings: false));
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
        networkSettings: health.networkSettings,
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

  Future<void> revokeActiveTrustedDeviceFromDesktop() async {
    if (_state.isRevokingTrust) {
      return;
    }

    _emit(_state.copyWith(isRevokingTrust: true));
    try {
      final response = await _bridgeClient.revokeTrust(
        deviceId: _activeTrustedDeviceId,
      );
      if (response.revoked) {
        _emit(
          _state.copyWith(
            runtimeDetail:
                'The active trusted device was revoked. It must pair again before reconnecting.',
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
            errorMessage: 'No active trusted device was available to revoke.',
          ),
        );
      }
    } catch (error) {
      _emit(
        _state.copyWith(
          errorMessage:
              'Failed to revoke the active device from Linux shell: $error',
        ),
      );
    } finally {
      _emit(_state.copyWith(isRevokingTrust: false));
    }
  }

  Future<void> revokeAllTrustedDevicesFromDesktop() async {
    if (_state.isRevokingTrust) {
      return;
    }

    _emit(_state.copyWith(isRevokingTrust: true));
    try {
      final response = await _bridgeClient.revokeTrust();
      if (response.revoked) {
        _emit(
          _state.copyWith(
            runtimeDetail:
                'All trusted devices were revoked. New pairings now require a fresh QR handshake.',
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
            errorMessage: 'No trusted devices were available to revoke.',
          ),
        );
      }
    } catch (error) {
      _emit(
        _state.copyWith(
          errorMessage:
              'Failed to revoke trusted devices from Linux shell: $error',
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

    final session = _state.pairingSession ?? _cachedPairingSession;
    if (session != null && _isPairingSessionUsable(session)) {
      if (_state.pairingSession == null) {
        _emit(
          _state.copyWith(pairingSession: session, clearErrorMessage: true),
        );
      }
      return;
    }
    await refreshPairingSession();
  }

  Future<void> refreshPairingSession({bool force = false}) async {
    if (!_state.canGeneratePairingQr || _state.isLoadingPairing) {
      return;
    }

    final cachedSession = _state.pairingSession ?? _cachedPairingSession;
    if (!force &&
        cachedSession != null &&
        _isPairingSessionUsable(cachedSession)) {
      if (_state.pairingSession == null) {
        _emit(
          _state.copyWith(
            pairingSession: cachedSession,
            clearErrorMessage: true,
          ),
        );
      }
      return;
    }

    _emit(_state.copyWith(isLoadingPairing: true));
    try {
      final session = await _bridgeClient.fetchPairingSession();
      _cachedPairingSession = session;
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

  bool _isPairingSessionUsable(PairingSessionResponseDto session) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return session.pairingSession.expiresAtEpochSeconds > now;
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
    required BridgeNetworkSettingsDto networkSettings,
    required CodexPresentation codex,
    String? runtimeIssue,
  }) {
    final trustedDevices = _buildTrustedDevicePresentation(trustStatus);
    final shellState = trustedDevices.isEmpty
        ? ShellRuntimeState.unpaired
        : runningThreadCount > 0
        ? ShellRuntimeState.pairedActive
        : ShellRuntimeState.pairedIdle;

    final activeDevice = trustedDevices
        .where((device) => device.isActive)
        .fold<TrustedDevicePresentation?>(
          null,
          (current, device) => current == null
              ? device
              : ((device.finalizedAtEpochSeconds ?? 0) >
                    (current.finalizedAtEpochSeconds ?? 0))
              ? device
              : current,
        );
    _activeTrustedDeviceId =
        activeDevice?.deviceId ??
        (trustedDevices.isEmpty ? null : trustedDevices.first.deviceId);
    final activeSessionCount = trustedDevices
        .where((device) => device.isActive)
        .length;
    _emit(
      _state.copyWith(
        shellState: shellState,
        bridgeRuntimeLabel: bridgeRuntimeLabel,
        pairedDeviceLabel: trustedDevices.isEmpty
            ? 'Not paired'
            : trustedDevices.length == 1
            ? trustedDevices.first.displayLabel
            : '${trustedDevices.length} trusted devices',
        activeSessionLabel: activeSessionCount == 0
            ? 'No active sessions'
            : activeSessionCount == 1
            ? activeDevice?.sessionId ?? '1 active session'
            : '$activeSessionCount active sessions',
        runningThreadCount: runningThreadCount,
        runtimeDetail: runtimeDetail,
        speechPanel: _speechPanelFor(speechStatus),
        codex: codex,
        localNetworkPairingEnabled: networkSettings.localNetworkPairingEnabled,
        pairingRoutes: networkSettings.routes,
        trustedDevices: trustedDevices,
        tailscale: _state.tailscale.copyWith(
          statusLabel: 'Connected',
          detail: 'Tailscale route is available for private pairing.',
          isInstalled: true,
          isAuthenticated: true,
          installHint: '',
        ),
        errorMessage: runtimeIssue,
        clearErrorMessage: runtimeIssue == null,
      ),
    );
  }

  void _applyStartingState({
    required String bridgeLabel,
    required String detail,
  }) {
    _activeTrustedDeviceId = null;
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
          downloadProgress: null,
        ),
        localNetworkPairingEnabled: false,
        pairingRoutes: const <BridgeApiRouteDto>[],
        trustedDevices: const <TrustedDevicePresentation>[],
        clearPairingSession: true,
        clearErrorMessage: true,
      ),
    );
  }

  void _applyDegradedState(String message, {CodexPresentation? codex}) {
    _activeTrustedDeviceId = null;
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
          downloadProgress: null,
        ),
        codex: codex ?? _state.codex,
        localNetworkPairingEnabled: false,
        pairingRoutes: const <BridgeApiRouteDto>[],
        trustedDevices: const <TrustedDevicePresentation>[],
        clearPairingSession: true,
        errorMessage: message,
      ),
    );
  }

  void _applyTailscaleRequiredState({
    required String message,
    required TailscalePresentation tailscale,
  }) {
    _activeTrustedDeviceId = null;
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
          downloadProgress: null,
        ),
        localNetworkPairingEnabled: false,
        pairingRoutes: const <BridgeApiRouteDto>[],
        trustedDevices: const <TrustedDevicePresentation>[],
        clearPairingSession: true,
        clearErrorMessage: true,
      ),
    );
  }

  List<TrustedDevicePresentation> _buildTrustedDevicePresentation(
    BridgeTrustStatusDto? trustStatus,
  ) {
    if (trustStatus == null || trustStatus.trustedDevices.isEmpty) {
      return const <TrustedDevicePresentation>[];
    }

    return trustStatus.trustedDevices
        .map((device) {
          final matchingSession = trustStatus.trustedSessions
              .where((session) => session.deviceId == device.deviceId)
              .fold<BridgeTrustedSessionDto?>(
                null,
                (current, session) =>
                    current == null ||
                        session.finalizedAtEpochSeconds >
                            current.finalizedAtEpochSeconds
                    ? session
                    : current,
              );

          return TrustedDevicePresentation(
            deviceId: device.deviceId,
            deviceName: device.deviceName,
            pairedAtEpochSeconds: device.pairedAtEpochSeconds,
            sessionId: matchingSession?.sessionId,
            finalizedAtEpochSeconds: matchingSession?.finalizedAtEpochSeconds,
          );
        })
        .toList(growable: false);
  }

  SpeechPanelPresentation _speechPanelFor(SpeechModelStatusDto? status) {
    if (status == null) {
      return const SpeechPanelPresentation(
        stateLabel: 'Unsupported',
        detail:
            'Speech transcription is not available from the Linux shell yet.',
        isReadOnly: true,
        downloadProgress: null,
      );
    }

    final detail = switch (status.state) {
      SpeechModelState.notInstalled =>
        'Parakeet can be downloaded on demand from Hugging Face.',
      SpeechModelState.installing =>
        'Downloading Parakeet… ${status.downloadProgress ?? 0}%',
      SpeechModelState.ready =>
        status.installedBytes == null
            ? 'Speech runtime is managed by the local bridge.'
            : '${status.installedBytes} bytes installed',
      SpeechModelState.busy => 'Speech runtime is managed by the local bridge.',
      SpeechModelState.failed =>
        status.lastError ?? 'Speech runtime is unavailable right now.',
      SpeechModelState.unsupported =>
        status.lastError ??
            'Speech transcription is unavailable on this Linux host.',
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
      isReadOnly: status.state == SpeechModelState.unsupported,
      downloadProgress: status.downloadProgress,
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
