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
      final controller = ShellController(
        bridgeClient: _FakeShellBridgeClient(),
        runtimeSupervisor: _FakeRuntimeSupervisor(),
        codexCliChecker: _FakeCodexCliChecker(),
      );

      await controller.refreshRuntimeState();

      expect(controller.state.shellState, ShellRuntimeState.unpaired);
      expect(controller.state.pairingSession, isNotNull);
      expect(controller.state.runtimeDetail, contains('ws://127.0.0.1:4222'));
      expect(controller.state.errorMessage, isNull);
    },
  );
}

class _FakeShellBridgeClient implements ShellBridgeClient {
  @override
  Future<BridgeHealthResponseDto> fetchHealth() async {
    return const BridgeHealthResponseDto(
      status: 'ok',
      runtime: BridgeRuntimeSnapshotDto(
        mode: 'auto',
        state: 'degraded',
        endpoint: null,
        pid: null,
        detail:
            'notification stream unavailable: failed to connect to codex app-server websocket '
            '\'ws://127.0.0.1:4222\': URL error: Unable to connect to ws://127.0.0.1:4222/',
      ),
      pairingRoute: BridgePairingRouteHealthDto(
        reachable: true,
        advertisedBaseUrl: 'https://lubo.taild54ede.ts.net',
        message: null,
      ),
      trust: BridgeTrustStatusDto(trustedPhone: null, activeSession: null),
      api: BridgeApiSurfaceDto(endpoints: <String>[], seededThreadCount: 0),
    );
  }

  @override
  Future<PairingSessionResponseDto> fetchPairingSession() async {
    return PairingSessionResponseDto(
      contractVersion: SharedContract.version,
      bridgeIdentity: const PairingBridgeIdentityDto(
        bridgeId: 'bridge-id',
        displayName: 'Codex Mobile Companion',
        apiBaseUrl: 'https://lubo.taild54ede.ts.net',
      ),
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
      state: SpeechModelState.unsupported,
      downloadProgress: null,
      lastError: 'unsupported',
      installedBytes: null,
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
  Future<PairingRevokeResponseDto> revokeTrust({String? phoneId}) async {
    return const PairingRevokeResponseDto(
      contractVersion: SharedContract.version,
      revoked: false,
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
