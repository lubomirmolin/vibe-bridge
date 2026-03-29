import 'package:codex_linux_shell/src/bridge_shell_api_client.dart';
import 'package:codex_linux_shell/src/contracts.dart';
import 'package:codex_linux_shell/src/runtime_supervisor.dart';
import 'package:codex_linux_shell/src/shell_controller.dart';
import 'package:codex_linux_shell/src/shell_presentation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'refreshRuntimeState keeps pairing available when codex runtime is degraded',
    () async {
      final bridgeClient = _FakeShellBridgeClient();
      final controller = ShellController(
        bridgeClient: bridgeClient,
        runtimeSupervisor: _FakeRuntimeSupervisor(),
        codexCliChecker: _FakeCodexCliChecker(),
      );

      await controller.refreshRuntimeState();

      expect(controller.state.shellState, ShellRuntimeState.unpaired);
      expect(controller.state.pairingSession, isNotNull);
      expect(controller.state.runtimeDetail, contains('ws://127.0.0.1:4222'));
      expect(controller.state.errorMessage, isNull);
      expect(bridgeClient.fetchPairingSessionCallCount, 1);
    },
  );

  test('refreshRuntimeState reuses an unexpired pairing session', () async {
    final bridgeClient = _FakeShellBridgeClient();
    final controller = ShellController(
      bridgeClient: bridgeClient,
      runtimeSupervisor: _FakeRuntimeSupervisor(),
      codexCliChecker: _FakeCodexCliChecker(),
    );

    await controller.refreshRuntimeState();
    await controller.refreshRuntimeState();

    expect(controller.state.shellState, ShellRuntimeState.unpaired);
    expect(controller.state.pairingSession, isNotNull);
    expect(bridgeClient.fetchPairingSessionCallCount, 1);
  });

  test('paired runtime keeps a generated pairing code visible', () async {
    final bridgeClient = _FakeShellBridgeClient(
      trust: const BridgeTrustStatusDto(
        trustedDevices: <BridgeTrustedDeviceDto>[
          BridgeTrustedDeviceDto(
            deviceId: 'phone-1',
            deviceName: 'Pixel 9',
            pairedAtEpochSeconds: 100,
          ),
        ],
        trustedSessions: <BridgeTrustedSessionDto>[],
      ),
    );
    final controller = ShellController(
      bridgeClient: bridgeClient,
      runtimeSupervisor: _FakeRuntimeSupervisor(),
      codexCliChecker: _FakeCodexCliChecker(),
    );

    await controller.refreshRuntimeState();
    await controller.refreshPairingSession(force: true);
    final firstSessionId =
        controller.state.pairingSession?.pairingSession.sessionId;

    await controller.refreshRuntimeState();

    expect(controller.state.shellState, ShellRuntimeState.pairedIdle);
    expect(controller.state.pairingSession, isNotNull);
    expect(
      controller.state.pairingSession?.pairingSession.sessionId,
      firstSessionId,
    );
    expect(bridgeClient.fetchPairingSessionCallCount, 1);
  });

  test('can toggle local network pairing from the controller', () async {
    final bridgeClient = _FakeShellBridgeClient();
    final controller = ShellController(
      bridgeClient: bridgeClient,
      runtimeSupervisor: _FakeRuntimeSupervisor(),
      codexCliChecker: _FakeCodexCliChecker(),
    );

    await controller.refreshRuntimeState();
    await controller.setLocalNetworkPairingEnabled(true);

    expect(controller.state.localNetworkPairingEnabled, isTrue);
    expect(controller.state.pairingRoutes, isNotEmpty);
  });

  test('can request speech model installation from the controller', () async {
    final bridgeClient = _FakeShellBridgeClient();
    final controller = ShellController(
      bridgeClient: bridgeClient,
      runtimeSupervisor: _FakeRuntimeSupervisor(),
      codexCliChecker: _FakeCodexCliChecker(),
    );

    await controller.refreshRuntimeState();
    await controller.ensureSpeechModelOnDesktop();

    expect(controller.state.speechPanel.stateLabel, 'Ready');
    expect(controller.state.speechPanel.isReadOnly, isFalse);
  });
}

class _FakeShellBridgeClient implements ShellBridgeClient {
  _FakeShellBridgeClient({
    this.trust = const BridgeTrustStatusDto(
      trustedDevices: <BridgeTrustedDeviceDto>[],
      trustedSessions: <BridgeTrustedSessionDto>[],
    ),
  });

  int fetchPairingSessionCallCount = 0;
  final BridgeTrustStatusDto trust;
  bool localNetworkPairingEnabled = false;
  SpeechModelState speechState = SpeechModelState.notInstalled;

  @override
  Future<BridgeHealthResponseDto> fetchHealth() async {
    return BridgeHealthResponseDto(
      status: 'ok',
      runtime: const BridgeRuntimeSnapshotDto(
        mode: 'auto',
        state: 'degraded',
        endpoint: null,
        pid: null,
        detail:
            'notification stream unavailable: failed to connect to codex app-server websocket '
            '\'ws://127.0.0.1:4222\': URL error: Unable to connect to ws://127.0.0.1:4222/',
      ),
      pairingRoute: const BridgePairingRouteHealthDto(
        reachable: true,
        advertisedBaseUrl: 'https://lubo.taild54ede.ts.net',
        routes: <BridgeApiRouteDto>[
          const BridgeApiRouteDto(
            id: 'tailscale',
            kind: BridgeApiRouteKind.tailscale,
            baseUrl: 'https://lubo.taild54ede.ts.net',
            reachable: true,
            isPreferred: true,
          ),
        ],
        message: null,
      ),
      networkSettings: BridgeNetworkSettingsDto(
        contractVersion: SharedContract.version,
        localNetworkPairingEnabled: localNetworkPairingEnabled,
        routes: <BridgeApiRouteDto>[
          const BridgeApiRouteDto(
            id: 'tailscale',
            kind: BridgeApiRouteKind.tailscale,
            baseUrl: 'https://lubo.taild54ede.ts.net',
            reachable: true,
            isPreferred: true,
          ),
          if (localNetworkPairingEnabled)
            const BridgeApiRouteDto(
              id: 'local_network',
              kind: BridgeApiRouteKind.localNetwork,
              baseUrl: 'http://192.168.1.10:3110',
              reachable: true,
              isPreferred: false,
            ),
        ],
        message: null,
      ),
      trust: trust,
      api: const BridgeApiSurfaceDto(
        endpoints: <String>[],
        seededThreadCount: 0,
      ),
    );
  }

  @override
  Future<PairingSessionResponseDto> fetchPairingSession() async {
    fetchPairingSessionCallCount += 1;
    return PairingSessionResponseDto(
      contractVersion: SharedContract.version,
      bridgeIdentity: const PairingBridgeIdentityDto(
        bridgeId: 'bridge-id',
        displayName: 'Codex Mobile Companion',
        apiBaseUrl: 'https://lubo.taild54ede.ts.net',
      ),
      bridgeApiRoutes: const <BridgeApiRouteDto>[
        const BridgeApiRouteDto(
          id: 'tailscale',
          kind: BridgeApiRouteKind.tailscale,
          baseUrl: 'https://lubo.taild54ede.ts.net',
          reachable: true,
          isPreferred: true,
        ),
      ],
      pairingSession: const PairingSessionDto(
        sessionId: 'pairing-session-1',
        pairingToken: 'token',
        issuedAtEpochSeconds: 1,
        expiresAtEpochSeconds: 9999999999,
      ),
      qrPayload: 'qr-payload',
    );
  }

  @override
  Future<SpeechModelStatusDto> fetchSpeechModelStatus() async {
    return SpeechModelStatusDto(
      contractVersion: SharedContract.version,
      provider: 'fluid_audio',
      modelId: 'parakeet',
      state: speechState,
      downloadProgress: null,
      lastError: speechState == SpeechModelState.unsupported
          ? 'unsupported'
          : null,
      installedBytes: speechState == SpeechModelState.ready ? 1024 : null,
    );
  }

  @override
  Future<SpeechModelMutationAcceptedDto> ensureSpeechModel() async {
    speechState = SpeechModelState.ready;
    return const SpeechModelMutationAcceptedDto(
      contractVersion: SharedContract.version,
      provider: 'fluid_audio',
      modelId: 'parakeet',
      state: SpeechModelState.ready,
      message: 'ready',
    );
  }

  @override
  Future<SpeechModelMutationAcceptedDto> removeSpeechModel() async {
    speechState = SpeechModelState.notInstalled;
    return const SpeechModelMutationAcceptedDto(
      contractVersion: SharedContract.version,
      provider: 'fluid_audio',
      modelId: 'parakeet',
      state: SpeechModelState.notInstalled,
      message: 'removed',
    );
  }

  @override
  Future<ThreadListResponseDto> fetchThreads() async {
    return const ThreadListResponseDto(
      contractVersion: SharedContract.version,
      threads: <ThreadSummaryDto>[],
    );
  }

  @override
  Future<PairingRevokeResponseDto> revokeTrust({String? deviceId}) async {
    return const PairingRevokeResponseDto(
      contractVersion: SharedContract.version,
      revoked: false,
    );
  }

  @override
  Future<BridgeNetworkSettingsDto> fetchNetworkSettings() async {
    return BridgeNetworkSettingsDto(
      contractVersion: SharedContract.version,
      localNetworkPairingEnabled: localNetworkPairingEnabled,
      routes: <BridgeApiRouteDto>[
        const BridgeApiRouteDto(
          id: 'tailscale',
          kind: BridgeApiRouteKind.tailscale,
          baseUrl: 'https://lubo.taild54ede.ts.net',
          reachable: true,
          isPreferred: true,
        ),
      ],
      message: null,
    );
  }

  @override
  Future<BridgeNetworkSettingsDto> setLocalNetworkPairingEnabled(
    bool enabled,
  ) async {
    localNetworkPairingEnabled = enabled;
    return BridgeNetworkSettingsDto(
      contractVersion: SharedContract.version,
      localNetworkPairingEnabled: enabled,
      routes: <BridgeApiRouteDto>[
        const BridgeApiRouteDto(
          id: 'tailscale',
          kind: BridgeApiRouteKind.tailscale,
          baseUrl: 'https://lubo.taild54ede.ts.net',
          reachable: true,
          isPreferred: true,
        ),
        if (enabled)
          const BridgeApiRouteDto(
            id: 'local_network',
            kind: BridgeApiRouteKind.localNetwork,
            baseUrl: 'http://192.168.1.10:3110',
            reachable: true,
            isPreferred: false,
          ),
      ],
      message: null,
    );
  }
}

class _FakeRuntimeSupervisor extends RuntimeSupervisor {
  @override
  Future<RuntimeLaunchSnapshot> prepareBridgeForConnection() async {
    return const RuntimeLaunchSnapshot(
      statusLabel: 'Managed locally',
      detail: 'Bridge is already available.',
      isLaunching: false,
    );
  }

  @override
  Future<RuntimeLaunchSnapshot> restartBridge() async {
    return const RuntimeLaunchSnapshot(
      statusLabel: 'Managed locally',
      detail: 'Bridge is already available.',
      isLaunching: false,
    );
  }

  @override
  Future<void> shutdownBridgeIfManaged() async {}
}

class _FakeCodexCliChecker implements CodexCliChecker {
  @override
  Future<CodexCliStatus> check() async {
    return const CodexCliStatus(
      isReady: true,
      statusLabel: 'Codex Ready',
      detail: 'Codex CLI is available from a saved path.',
      nextStep: '',
      binaryPath: '/usr/local/bin/codex',
      sourceLabel: 'Saved Path',
    );
  }

  @override
  Future<CodexCliStatus> savePreferredBinaryPath(String path) {
    throw UnimplementedError();
  }
}
