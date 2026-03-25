import 'dart:async';
import 'dart:developer' as developer;
import 'dart:convert';

import 'package:codex_mobile_companion/features/pairing/data/pairing_bridge_api.dart';
import 'package:codex_mobile_companion/features/pairing/domain/pairing_qr_payload.dart';
import 'package:codex_mobile_companion/features/pairing/domain/pairing_qr_validator.dart';
import 'package:codex_mobile_companion/foundation/storage/secure_store.dart';
import 'package:codex_mobile_companion/foundation/storage/secure_store_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final secureStoreProvider = appSecureStoreProvider;

final nowUtcProvider = Provider<DateTime>((ref) {
  return DateTime.now().toUtc();
});

final pairingBridgeApiProvider = Provider<PairingBridgeApi>((ref) {
  return const HttpPairingBridgeApi();
});

final phoneDisplayNameProvider = Provider<String>((ref) {
  return 'Codex Mobile Companion Phone';
});

final pairingControllerProvider =
    StateNotifierProvider<PairingController, PairingState>((ref) {
      return PairingController(
        secureStore: ref.watch(secureStoreProvider),
        bridgeApi: ref.watch(pairingBridgeApiProvider),
        phoneDisplayName: ref.watch(phoneDisplayNameProvider),
        nowUtc: () => ref.read(nowUtcProvider),
      );
    });

enum PairingStep { unpaired, scanning, review, paired }

enum BridgeConnectionState { connected, reconnecting, disconnected }

class PairingState {
  const PairingState({
    required this.step,
    required this.consumedSessionIds,
    required this.bridgeConnectionState,
    required this.rePairRequiredForSecurity,
    required this.savedBridges,
    required this.activeBridgeId,
    required this.isRestoringSavedBridges,
    this.pendingPayload,
    this.trustedBridge,
    this.errorMessage,
    this.isPersistingTrust = false,
  });

  final PairingStep step;
  final PairingQrPayload? pendingPayload;
  final TrustedBridgeIdentity? trustedBridge;
  final String? errorMessage;
  final Set<String> consumedSessionIds;
  final BridgeConnectionState bridgeConnectionState;
  final bool rePairRequiredForSecurity;
  final List<TrustedBridgeIdentity> savedBridges;
  final String? activeBridgeId;
  final bool isRestoringSavedBridges;
  final bool isPersistingTrust;

  int get savedBridgeCount => savedBridges.length;

  bool get canRunMutatingActions =>
      step == PairingStep.paired &&
      bridgeConnectionState == BridgeConnectionState.connected;

  factory PairingState.initial() {
    return const PairingState(
      step: PairingStep.unpaired,
      consumedSessionIds: <String>{},
      bridgeConnectionState: BridgeConnectionState.connected,
      rePairRequiredForSecurity: false,
      savedBridges: <TrustedBridgeIdentity>[],
      activeBridgeId: null,
      isRestoringSavedBridges: true,
    );
  }

  PairingState copyWith({
    PairingStep? step,
    PairingQrPayload? pendingPayload,
    bool clearPendingPayload = false,
    TrustedBridgeIdentity? trustedBridge,
    bool clearTrustedBridge = false,
    String? errorMessage,
    bool clearErrorMessage = false,
    Set<String>? consumedSessionIds,
    BridgeConnectionState? bridgeConnectionState,
    bool? rePairRequiredForSecurity,
    List<TrustedBridgeIdentity>? savedBridges,
    String? activeBridgeId,
    bool clearActiveBridgeId = false,
    bool? isRestoringSavedBridges,
    bool? isPersistingTrust,
  }) {
    return PairingState(
      step: step ?? this.step,
      pendingPayload: clearPendingPayload
          ? null
          : (pendingPayload ?? this.pendingPayload),
      trustedBridge: clearTrustedBridge
          ? null
          : (trustedBridge ?? this.trustedBridge),
      errorMessage: clearErrorMessage
          ? null
          : (errorMessage ?? this.errorMessage),
      consumedSessionIds: Set<String>.unmodifiable(
        consumedSessionIds ?? this.consumedSessionIds,
      ),
      bridgeConnectionState:
          bridgeConnectionState ?? this.bridgeConnectionState,
      rePairRequiredForSecurity:
          rePairRequiredForSecurity ?? this.rePairRequiredForSecurity,
      savedBridges: List<TrustedBridgeIdentity>.unmodifiable(
        savedBridges ?? this.savedBridges,
      ),
      activeBridgeId: clearActiveBridgeId
          ? null
          : (activeBridgeId ?? this.activeBridgeId),
      isRestoringSavedBridges:
          isRestoringSavedBridges ?? this.isRestoringSavedBridges,
      isPersistingTrust: isPersistingTrust ?? this.isPersistingTrust,
    );
  }
}

class PairingController extends StateNotifier<PairingState> {
  PairingController({
    required SecureStore secureStore,
    required PairingBridgeApi bridgeApi,
    required String phoneDisplayName,
    required DateTime Function() nowUtc,
  }) : _secureStore = secureStore,
       _bridgeApi = bridgeApi,
       _phoneDisplayName = phoneDisplayName,
       _nowUtc = nowUtc,
       super(PairingState.initial()) {
    _restoreTrustedBridge();
  }

  final SecureStore _secureStore;
  final PairingBridgeApi _bridgeApi;
  final String _phoneDisplayName;
  final DateTime Function() _nowUtc;
  Timer? _reconnectTimer;
  bool _isReconnectInProgress = false;
  bool _isDisposed = false;

  Future<void> _restoreTrustedBridge() async {
    _logDiagnostic(
      'restore_started',
      details: <String, Object?>{
        'step': state.step.name,
        'saved_bridge_count': state.savedBridgeCount,
        'active_bridge_id': state.activeBridgeId,
      },
    );
    try {
      final savedBridgeRegistry = await _readSavedBridgeRegistry();
      if (savedBridgeRegistry != null && savedBridgeRegistry.hasConnections) {
        _logDiagnostic(
          'restore_saved_registry_found',
          details: <String, Object?>{
            'connection_count': savedBridgeRegistry.connections.length,
            'active_bridge_id': savedBridgeRegistry.activeBridgeId,
          },
        );
        await _restoreSavedBridgeRegistry(savedBridgeRegistry);
        return;
      }

      final raw = await _secureStore.readSecret(
        SecureValueKey.trustedBridgeIdentity,
      );
      if (raw == null) {
        _logDiagnostic('restore_no_local_trust');
        return;
      }

      final sessionToken = await _secureStore.readSecret(
        SecureValueKey.sessionToken,
      );
      if (sessionToken == null || sessionToken.trim().isEmpty) {
        _logDiagnostic('restore_missing_session_token');
        await _clearLocalTrust();
        return;
      }

      try {
        final decoded = jsonDecode(raw);
        if (decoded is! Map<String, dynamic>) {
          throw const FormatException(
            'Trusted bridge identity must be an object.',
          );
        }

        final trustedBridge = TrustedBridgeIdentity.fromJson(decoded);
        final migratedRegistry = _SavedBridgeRegistry.single(
          trustedBridge: trustedBridge,
          sessionToken: sessionToken.trim(),
          selectedAtEpochSeconds: _nowUtc().millisecondsSinceEpoch ~/ 1000,
        );
        _logDiagnostic(
          'restore_migrating_legacy_trust',
          details: <String, Object?>{
            'bridge_id': trustedBridge.bridgeId,
            'bridge_name': trustedBridge.bridgeName,
          },
        );
        await _writeSavedBridgeRegistry(migratedRegistry);
        await _restoreSavedBridgeRegistry(migratedRegistry);
      } on FormatException {
        _logDiagnostic('restore_invalid_legacy_trust');
        await _clearLocalTrust();
      }
    } finally {
      if (!_isDisposed) {
        _logDiagnostic(
          'restore_finished',
          details: <String, Object?>{
            'step': state.step.name,
            'saved_bridge_count': state.savedBridgeCount,
            'active_bridge_id': state.activeBridgeId,
            'trusted_bridge_id': state.trustedBridge?.bridgeId,
            'connection_state': state.bridgeConnectionState.name,
          },
        );
        state = state.copyWith(isRestoringSavedBridges: false);
      }
    }
  }

  void openScanner() {
    state = state.copyWith(
      step: PairingStep.scanning,
      clearPendingPayload: true,
      clearErrorMessage: true,
      bridgeConnectionState: BridgeConnectionState.connected,
      rePairRequiredForSecurity: false,
    );
  }

  void submitScannedPayload(String rawPayload) {
    final result = validatePairingQrPayload(
      rawPayload,
      nowUtc: _nowUtc(),
      consumedSessionIds: state.consumedSessionIds,
    );

    if (!result.isValid) {
      state = state.copyWith(
        step: PairingStep.scanning,
        clearPendingPayload: true,
        errorMessage: result.message,
      );
      return;
    }

    state = state.copyWith(
      step: PairingStep.review,
      pendingPayload: result.payload,
      clearErrorMessage: true,
      rePairRequiredForSecurity: false,
    );
  }

  void cancelReview() {
    final destinationStep = state.trustedBridge == null
        ? PairingStep.unpaired
        : PairingStep.paired;
    state = state.copyWith(
      step: destinationStep,
      clearPendingPayload: true,
      clearErrorMessage: true,
      rePairRequiredForSecurity: false,
      isPersistingTrust: false,
    );
  }

  Future<void> confirmTrust() async {
    final payload = state.pendingPayload;
    if (payload == null || state.isPersistingTrust) {
      return;
    }

    state = state.copyWith(isPersistingTrust: true, clearErrorMessage: true);
    final phoneId = await _readOrCreatePhoneId();
    final finalizeResult = await _bridgeApi.finalizeTrust(
      payload: payload,
      phoneId: phoneId,
      phoneName: _phoneDisplayName,
    );

    if (!finalizeResult.isSuccess) {
      state = state.copyWith(
        step: finalizeResult.requiresRescan
            ? PairingStep.scanning
            : PairingStep.review,
        clearPendingPayload: finalizeResult.requiresRescan,
        isPersistingTrust: false,
        errorMessage: finalizeResult.message,
      );
      return;
    }

    final pairedAtUtc = _nowUtc();
    final trust = TrustedBridgeIdentity(
      bridgeId: finalizeResult.bridgeId!,
      bridgeName: finalizeResult.bridgeName!,
      bridgeApiBaseUrl: finalizeResult.bridgeApiBaseUrl!,
      bridgeApiRoutes: finalizeResult.bridgeApiRoutes!,
      sessionId: payload.sessionId,
      pairedAtEpochSeconds: pairedAtUtc.millisecondsSinceEpoch ~/ 1000,
    );
    final selectedAtEpochSeconds = pairedAtUtc.millisecondsSinceEpoch ~/ 1000;
    final previousBridgeId = state.trustedBridge?.bridgeId;
    final registry =
        (await _readSavedBridgeRegistry())?.upsert(
          _SavedBridgeConnection(
            trustedBridge: trust,
            sessionToken: finalizeResult.sessionToken!,
            lastSelectedAtEpochSeconds: selectedAtEpochSeconds,
          ),
          makeActive: true,
        ) ??
        _SavedBridgeRegistry.single(
          trustedBridge: trust,
          sessionToken: finalizeResult.sessionToken!,
          selectedAtEpochSeconds: selectedAtEpochSeconds,
        );

    _logDiagnostic(
      'confirm_trust_persisting',
      details: <String, Object?>{
        'bridge_id': trust.bridgeId,
        'bridge_name': trust.bridgeName,
        'previous_bridge_id': previousBridgeId,
        'saved_bridge_count': registry.connections.length,
        'active_bridge_id': registry.activeBridgeId,
      },
    );

    await _writeSavedBridgeRegistry(
      registry,
      clearCachedThreadState:
          previousBridgeId != null && previousBridgeId != trust.bridgeId,
    );

    final consumedSessionIds = Set<String>.from(state.consumedSessionIds)
      ..add(payload.sessionId);

    state = state.copyWith(
      step: PairingStep.paired,
      trustedBridge: trust,
      savedBridges: registry.orderedTrustedBridges,
      activeBridgeId: registry.activeBridgeId,
      clearPendingPayload: true,
      clearErrorMessage: true,
      bridgeConnectionState: BridgeConnectionState.connected,
      rePairRequiredForSecurity: false,
      isPersistingTrust: false,
      consumedSessionIds: consumedSessionIds,
    );
    _cancelReconnectTimer();
  }

  Future<void> retryTrustedBridgeConnection() async {
    _cancelReconnectTimer();

    final savedBridgeRegistry = await _readSavedBridgeRegistry();
    if (savedBridgeRegistry == null || !savedBridgeRegistry.hasConnections) {
      return;
    }

    state = state.copyWith(
      bridgeConnectionState: BridgeConnectionState.reconnecting,
      clearErrorMessage: true,
    );

    await _restoreSavedBridgeRegistry(savedBridgeRegistry);
  }

  Future<void> _restoreSavedBridgeRegistry(
    _SavedBridgeRegistry savedBridgeRegistry,
  ) async {
    final activeConnection = savedBridgeRegistry.activeConnection;
    _logDiagnostic(
      'restore_registry_selected',
      details: <String, Object?>{
        'connection_count': savedBridgeRegistry.connections.length,
        'active_bridge_id': savedBridgeRegistry.activeBridgeId,
        'active_connection_bridge_id': activeConnection?.trustedBridge.bridgeId,
      },
    );
    if (activeConnection == null) {
      await _clearLocalTrust(clearCachedThreadState: true);
      state = state.copyWith(
        step: PairingStep.unpaired,
        clearTrustedBridge: true,
        clearPendingPayload: true,
        bridgeConnectionState: BridgeConnectionState.connected,
        rePairRequiredForSecurity: false,
        savedBridges: const <TrustedBridgeIdentity>[],
        clearActiveBridgeId: true,
      );
      return;
    }

    final trustedBridge = activeConnection.trustedBridge;
    final phoneId = await _readOrCreatePhoneId();
    final handshake = await _bridgeApi.handshake(
      trustedBridge: trustedBridge,
      phoneId: phoneId,
      sessionToken: activeConnection.sessionToken,
    );
    _logDiagnostic(
      'restore_handshake_result',
      details: <String, Object?>{
        'bridge_id': trustedBridge.bridgeId,
        'is_trusted': handshake.isTrusted,
        'connectivity_unavailable': handshake.connectivityUnavailable,
        'requires_repair': handshake.requiresRePair,
        'message': handshake.message,
      },
    );

    if (handshake.isTrusted) {
      final refreshedTrustedBridge = _refreshTrustedBridgeIdentity(
        trustedBridge,
        handshake,
      );
      final refreshedRegistry = savedBridgeRegistry.replace(
        activeConnection.copyWith(trustedBridge: refreshedTrustedBridge),
      );
      await _writeSavedBridgeRegistry(refreshedRegistry);

      _cancelReconnectTimer();
      state = state.copyWith(
        step: PairingStep.paired,
        trustedBridge: refreshedTrustedBridge,
        savedBridges: refreshedRegistry.orderedTrustedBridges,
        activeBridgeId: refreshedRegistry.activeBridgeId,
        bridgeConnectionState: BridgeConnectionState.connected,
        rePairRequiredForSecurity: false,
        clearErrorMessage: true,
      );
      return;
    }

    if (handshake.connectivityUnavailable) {
      state = state.copyWith(
        step: PairingStep.paired,
        trustedBridge: trustedBridge,
        savedBridges: savedBridgeRegistry.orderedTrustedBridges,
        activeBridgeId: savedBridgeRegistry.activeBridgeId,
        bridgeConnectionState: BridgeConnectionState.disconnected,
        rePairRequiredForSecurity: false,
        errorMessage:
            handshake.message ??
            'Private bridge path is currently unreachable. Reconnect to Tailscale and retry.',
      );
      _scheduleReconnect();
      return;
    }

    final requiresRePairForSecurity = handshake.requiresRePair;
    _cancelReconnectTimer();
    final updatedRegistry = savedBridgeRegistry.remove(trustedBridge.bridgeId);
    if (updatedRegistry.hasConnections) {
      await _writeSavedBridgeRegistry(
        updatedRegistry,
        clearCachedThreadState: true,
      );
      state = state.copyWith(
        step: PairingStep.paired,
        trustedBridge: updatedRegistry.activeConnection?.trustedBridge,
        savedBridges: updatedRegistry.orderedTrustedBridges,
        activeBridgeId: updatedRegistry.activeBridgeId,
        bridgeConnectionState: BridgeConnectionState.reconnecting,
        rePairRequiredForSecurity: false,
        clearErrorMessage: true,
      );
      await _restoreSavedBridgeRegistry(updatedRegistry);
      return;
    }

    await _clearLocalTrust(clearCachedThreadState: true);
    state = state.copyWith(
      step: PairingStep.unpaired,
      clearTrustedBridge: true,
      clearPendingPayload: true,
      bridgeConnectionState: BridgeConnectionState.connected,
      rePairRequiredForSecurity: requiresRePairForSecurity,
      savedBridges: const <TrustedBridgeIdentity>[],
      clearActiveBridgeId: true,
      errorMessage: _resolveUntrustedHandshakeMessage(handshake),
    );
  }

  String _resolveUntrustedHandshakeMessage(PairingHandshakeResult handshake) {
    if (handshake.requiresRePair) {
      return handshake.message ??
          'Security check failed. Stored trust no longer matches the active bridge, so re-pairing is required.';
    }

    return handshake.message ??
        'Stored trust is no longer accepted by the bridge. Re-pair from the host bridge.';
  }

  TrustedBridgeIdentity _refreshTrustedBridgeIdentity(
    TrustedBridgeIdentity trustedBridge,
    PairingHandshakeResult handshake,
  ) {
    final bridgeId = handshake.bridgeId;
    final bridgeName = handshake.bridgeName;
    final bridgeApiBaseUrl = handshake.bridgeApiBaseUrl;
    final bridgeApiRoutes = handshake.bridgeApiRoutes;
    final sessionId = handshake.sessionId;

    if (bridgeId == null ||
        bridgeName == null ||
        bridgeApiBaseUrl == null ||
        sessionId == null) {
      return trustedBridge;
    }

    final resolvedBridgeApiRoutes =
        bridgeApiRoutes ?? trustedBridge.bridgeApiRoutes;

    if (bridgeId == trustedBridge.bridgeId &&
        bridgeName == trustedBridge.bridgeName &&
        bridgeApiBaseUrl == trustedBridge.bridgeApiBaseUrl &&
        _sameBridgeApiRoutes(
          resolvedBridgeApiRoutes,
          trustedBridge.bridgeApiRoutes,
        ) &&
        sessionId == trustedBridge.sessionId) {
      return trustedBridge;
    }

    return TrustedBridgeIdentity(
      bridgeId: bridgeId,
      bridgeName: bridgeName,
      bridgeApiBaseUrl: bridgeApiBaseUrl,
      bridgeApiRoutes: resolvedBridgeApiRoutes,
      sessionId: sessionId,
      pairedAtEpochSeconds: trustedBridge.pairedAtEpochSeconds,
    );
  }

  bool _sameBridgeApiRoutes(
    List<BridgeApiRoute> left,
    List<BridgeApiRoute> right,
  ) {
    if (left.length != right.length) {
      return false;
    }

    for (var index = 0; index < left.length; index += 1) {
      final leftRoute = left[index];
      final rightRoute = right[index];
      if (leftRoute.id != rightRoute.id ||
          leftRoute.kind != rightRoute.kind ||
          leftRoute.baseUrl != rightRoute.baseUrl ||
          leftRoute.reachable != rightRoute.reachable ||
          leftRoute.isPreferred != rightRoute.isPreferred) {
        return false;
      }
    }

    return true;
  }

  void _scheduleReconnect() {
    if (_isDisposed || _reconnectTimer?.isActive == true) {
      return;
    }

    _reconnectTimer = Timer(const Duration(seconds: 2), () {
      unawaited(_runReconnect());
    });
  }

  Future<void> _runReconnect() async {
    if (_isDisposed || _isReconnectInProgress) {
      return;
    }

    if (state.step != PairingStep.paired ||
        state.bridgeConnectionState != BridgeConnectionState.disconnected) {
      return;
    }

    final savedBridgeRegistry = await _readSavedBridgeRegistry();
    if (savedBridgeRegistry == null || !savedBridgeRegistry.hasConnections) {
      await _clearLocalTrust(clearCachedThreadState: true);
      state = state.copyWith(
        step: PairingStep.unpaired,
        clearTrustedBridge: true,
        clearPendingPayload: true,
        bridgeConnectionState: BridgeConnectionState.connected,
        rePairRequiredForSecurity: true,
        savedBridges: const <TrustedBridgeIdentity>[],
        clearActiveBridgeId: true,
        errorMessage:
            'Stored trust is incomplete. Re-pair from the host bridge.',
      );
      return;
    }

    _isReconnectInProgress = true;
    try {
      state = state.copyWith(
        bridgeConnectionState: BridgeConnectionState.reconnecting,
        clearErrorMessage: true,
      );
      await _restoreSavedBridgeRegistry(savedBridgeRegistry);
    } finally {
      _isReconnectInProgress = false;
    }
  }

  void _cancelReconnectTimer() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  Future<void> unpairFromMobileSettings() async {
    _cancelReconnectTimer();

    final trustedBridge = state.trustedBridge;
    String? warningMessage;

    if (trustedBridge != null) {
      final phoneId = await _secureStore.readSecret(
        SecureValueKey.pairingPrivateKey,
      );
      final revokeResult = await _bridgeApi.revokeTrust(
        trustedBridge: trustedBridge,
        phoneId: phoneId,
      );

      if (!revokeResult.isSuccess) {
        warningMessage = revokeResult.message;
      }
    }

    final savedBridgeRegistry = await _readSavedBridgeRegistry();
    if (trustedBridge == null ||
        savedBridgeRegistry == null ||
        !savedBridgeRegistry.hasConnections) {
      await _clearLocalTrust(clearCachedThreadState: true);
      state = state.copyWith(
        step: PairingStep.unpaired,
        clearTrustedBridge: true,
        clearPendingPayload: true,
        bridgeConnectionState: BridgeConnectionState.connected,
        rePairRequiredForSecurity: false,
        savedBridges: const <TrustedBridgeIdentity>[],
        clearActiveBridgeId: true,
        consumedSessionIds: const <String>{},
        isPersistingTrust: false,
        errorMessage:
            warningMessage ??
            'This device was unpaired. Scan a fresh pairing QR to reconnect.',
      );
      return;
    }

    final updatedRegistry = savedBridgeRegistry.remove(trustedBridge.bridgeId);
    if (!updatedRegistry.hasConnections) {
      await _clearLocalTrust(clearCachedThreadState: true);
      state = state.copyWith(
        step: PairingStep.unpaired,
        clearTrustedBridge: true,
        clearPendingPayload: true,
        bridgeConnectionState: BridgeConnectionState.connected,
        rePairRequiredForSecurity: false,
        savedBridges: const <TrustedBridgeIdentity>[],
        clearActiveBridgeId: true,
        consumedSessionIds: const <String>{},
        isPersistingTrust: false,
        errorMessage:
            warningMessage ??
            'This device was unpaired. Scan a fresh pairing QR to reconnect.',
      );
      return;
    }

    await _writeSavedBridgeRegistry(
      updatedRegistry,
      clearCachedThreadState: true,
    );
    state = state.copyWith(
      step: PairingStep.paired,
      trustedBridge: updatedRegistry.activeConnection?.trustedBridge,
      savedBridges: updatedRegistry.orderedTrustedBridges,
      activeBridgeId: updatedRegistry.activeBridgeId,
      clearPendingPayload: true,
      bridgeConnectionState: BridgeConnectionState.reconnecting,
      rePairRequiredForSecurity: false,
      consumedSessionIds: const <String>{},
      isPersistingTrust: false,
      errorMessage:
          warningMessage ??
          'This device was removed. Reconnected to another saved bridge.',
    );
    await _restoreSavedBridgeRegistry(updatedRegistry);
  }

  Future<void> _clearLocalTrust({bool clearCachedThreadState = false}) async {
    await _secureStore.removeSecret(SecureValueKey.savedBridgeRegistry);
    await _secureStore.removeSecret(SecureValueKey.trustedBridgeIdentity);
    await _secureStore.removeSecret(SecureValueKey.sessionToken);

    if (clearCachedThreadState) {
      await _secureStore.removeSecret(SecureValueKey.threadListCache);
      await _secureStore.removeSecret(SecureValueKey.selectedThreadId);
    }
  }

  Future<String> _readOrCreatePhoneId() async {
    final existing = await _secureStore.readSecret(
      SecureValueKey.pairingPrivateKey,
    );
    if (existing != null && existing.trim().isNotEmpty) {
      return existing.trim();
    }

    final generated =
        'phone-${_nowUtc().microsecondsSinceEpoch.toRadixString(16)}';
    await _secureStore.writeSecret(SecureValueKey.pairingPrivateKey, generated);
    return generated;
  }

  Future<void> activateSavedBridge(String bridgeId) async {
    final savedBridgeRegistry = await _readSavedBridgeRegistry();
    if (savedBridgeRegistry == null ||
        !savedBridgeRegistry.hasBridge(bridgeId)) {
      return;
    }

    final updatedRegistry = savedBridgeRegistry.setActive(
      bridgeId,
      selectedAtEpochSeconds: _nowUtc().millisecondsSinceEpoch ~/ 1000,
    );
    await _writeSavedBridgeRegistry(
      updatedRegistry,
      clearCachedThreadState: true,
    );
    _cancelReconnectTimer();
    state = state.copyWith(
      step: PairingStep.paired,
      trustedBridge: updatedRegistry.activeConnection?.trustedBridge,
      savedBridges: updatedRegistry.orderedTrustedBridges,
      activeBridgeId: updatedRegistry.activeBridgeId,
      bridgeConnectionState: BridgeConnectionState.reconnecting,
      rePairRequiredForSecurity: false,
      clearErrorMessage: true,
    );
    await _restoreSavedBridgeRegistry(updatedRegistry);
  }

  Future<_SavedBridgeRegistry?> _readSavedBridgeRegistry() async {
    final raw = await _secureStore.readSecret(
      SecureValueKey.savedBridgeRegistry,
    );
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Saved bridge registry must be an object.');
      }
      return _SavedBridgeRegistry.fromJson(decoded);
    } on FormatException {
      await _secureStore.removeSecret(SecureValueKey.savedBridgeRegistry);
      return null;
    }
  }

  Future<void> _writeSavedBridgeRegistry(
    _SavedBridgeRegistry savedBridgeRegistry, {
    bool clearCachedThreadState = false,
  }) async {
    _logDiagnostic(
      'write_saved_registry',
      details: <String, Object?>{
        'connection_count': savedBridgeRegistry.connections.length,
        'active_bridge_id': savedBridgeRegistry.activeBridgeId,
        'clear_cached_thread_state': clearCachedThreadState,
      },
    );
    if (savedBridgeRegistry.hasConnections) {
      await _secureStore.writeSecret(
        SecureValueKey.savedBridgeRegistry,
        jsonEncode(savedBridgeRegistry.toJson()),
      );
    } else {
      await _secureStore.removeSecret(SecureValueKey.savedBridgeRegistry);
    }

    final activeConnection = savedBridgeRegistry.activeConnection;
    if (activeConnection == null) {
      await _secureStore.removeSecret(SecureValueKey.trustedBridgeIdentity);
      await _secureStore.removeSecret(SecureValueKey.sessionToken);
    } else {
      await _secureStore.writeSecret(
        SecureValueKey.trustedBridgeIdentity,
        jsonEncode(activeConnection.trustedBridge.toJson()),
      );
      await _secureStore.writeSecret(
        SecureValueKey.sessionToken,
        activeConnection.sessionToken,
      );
    }

    if (clearCachedThreadState) {
      await _secureStore.removeSecret(SecureValueKey.threadListCache);
      await _secureStore.removeSecret(SecureValueKey.selectedThreadId);
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    _cancelReconnectTimer();
    super.dispose();
  }

  void _logDiagnostic(
    String event, {
    Map<String, Object?> details = const <String, Object?>{},
  }) {
    developer.log('$event ${jsonEncode(details)}', name: 'PairingController');
  }
}

class _SavedBridgeConnection {
  const _SavedBridgeConnection({
    required this.trustedBridge,
    required this.sessionToken,
    required this.lastSelectedAtEpochSeconds,
  });

  final TrustedBridgeIdentity trustedBridge;
  final String sessionToken;
  final int lastSelectedAtEpochSeconds;

  factory _SavedBridgeConnection.fromJson(Map<String, dynamic> json) {
    return _SavedBridgeConnection(
      trustedBridge: TrustedBridgeIdentity.fromJson(
        json['bridge'] as Map<String, dynamic>? ?? const <String, dynamic>{},
      ),
      sessionToken: json['session_token'] as String? ?? '',
      lastSelectedAtEpochSeconds:
          json['last_selected_at_epoch_seconds'] as int? ??
          json['paired_at_epoch_seconds'] as int? ??
          0,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'bridge': trustedBridge.toJson(),
      'session_token': sessionToken,
      'last_selected_at_epoch_seconds': lastSelectedAtEpochSeconds,
    };
  }

  _SavedBridgeConnection copyWith({
    TrustedBridgeIdentity? trustedBridge,
    String? sessionToken,
    int? lastSelectedAtEpochSeconds,
  }) {
    return _SavedBridgeConnection(
      trustedBridge: trustedBridge ?? this.trustedBridge,
      sessionToken: sessionToken ?? this.sessionToken,
      lastSelectedAtEpochSeconds:
          lastSelectedAtEpochSeconds ?? this.lastSelectedAtEpochSeconds,
    );
  }
}

class _SavedBridgeRegistry {
  const _SavedBridgeRegistry({
    required this.connections,
    required this.activeBridgeId,
  });

  final List<_SavedBridgeConnection> connections;
  final String? activeBridgeId;

  bool get hasConnections => connections.isNotEmpty;

  _SavedBridgeConnection? get activeConnection {
    final activeBridgeId = this.activeBridgeId;
    if (activeBridgeId == null || activeBridgeId.trim().isEmpty) {
      return connections.isEmpty ? null : connections.first;
    }

    for (final connection in connections) {
      if (connection.trustedBridge.bridgeId == activeBridgeId) {
        return connection;
      }
    }

    return connections.isEmpty ? null : connections.first;
  }

  List<TrustedBridgeIdentity> get orderedTrustedBridges {
    final orderedConnections = connections.toList(growable: true)
      ..sort((left, right) {
        final leftIsActive = left.trustedBridge.bridgeId == activeBridgeId;
        final rightIsActive = right.trustedBridge.bridgeId == activeBridgeId;
        if (leftIsActive != rightIsActive) {
          return leftIsActive ? -1 : 1;
        }
        return right.lastSelectedAtEpochSeconds.compareTo(
          left.lastSelectedAtEpochSeconds,
        );
      });

    return orderedConnections
        .map((connection) => connection.trustedBridge)
        .toList(growable: false);
  }

  factory _SavedBridgeRegistry.fromJson(Map<String, dynamic> json) {
    final rawConnections = json['bridges'];
    if (rawConnections is! List) {
      throw const FormatException(
        'Saved bridge registry must contain bridges.',
      );
    }

    final connections = rawConnections
        .map((entry) {
          if (entry is! Map<String, dynamic>) {
            throw const FormatException(
              'Saved bridge registry entry must be an object.',
            );
          }
          return _SavedBridgeConnection.fromJson(entry);
        })
        .where((entry) => entry.sessionToken.trim().isNotEmpty)
        .toList(growable: false);

    return _SavedBridgeRegistry(
      connections: connections,
      activeBridgeId: json['active_bridge_id'] as String?,
    );
  }

  factory _SavedBridgeRegistry.single({
    required TrustedBridgeIdentity trustedBridge,
    required String sessionToken,
    required int selectedAtEpochSeconds,
  }) {
    return _SavedBridgeRegistry(
      connections: <_SavedBridgeConnection>[
        _SavedBridgeConnection(
          trustedBridge: trustedBridge,
          sessionToken: sessionToken,
          lastSelectedAtEpochSeconds: selectedAtEpochSeconds,
        ),
      ],
      activeBridgeId: trustedBridge.bridgeId,
    );
  }

  bool hasBridge(String bridgeId) {
    return connections.any((entry) => entry.trustedBridge.bridgeId == bridgeId);
  }

  _SavedBridgeRegistry upsert(
    _SavedBridgeConnection connection, {
    required bool makeActive,
  }) {
    final updatedConnections =
        connections
            .where(
              (entry) =>
                  entry.trustedBridge.bridgeId !=
                  connection.trustedBridge.bridgeId,
            )
            .toList(growable: true)
          ..add(connection);
    return _SavedBridgeRegistry(
      connections: updatedConnections,
      activeBridgeId: makeActive
          ? connection.trustedBridge.bridgeId
          : activeBridgeId,
    );
  }

  _SavedBridgeRegistry replace(_SavedBridgeConnection connection) {
    return upsert(
      connection,
      makeActive: connection.trustedBridge.bridgeId == activeBridgeId,
    );
  }

  _SavedBridgeRegistry setActive(
    String bridgeId, {
    required int selectedAtEpochSeconds,
  }) {
    final updatedConnections = connections
        .map((entry) {
          if (entry.trustedBridge.bridgeId != bridgeId) {
            return entry;
          }
          return entry.copyWith(
            lastSelectedAtEpochSeconds: selectedAtEpochSeconds,
          );
        })
        .toList(growable: false);
    return _SavedBridgeRegistry(
      connections: updatedConnections,
      activeBridgeId: bridgeId,
    );
  }

  _SavedBridgeRegistry remove(String bridgeId) {
    final updatedConnections = connections
        .where((entry) => entry.trustedBridge.bridgeId != bridgeId)
        .toList(growable: false);
    String? nextActiveBridgeId;
    if (updatedConnections.isNotEmpty) {
      final orderedConnections = updatedConnections.toList(growable: true)
        ..sort(
          (left, right) => right.lastSelectedAtEpochSeconds.compareTo(
            left.lastSelectedAtEpochSeconds,
          ),
        );
      nextActiveBridgeId = orderedConnections.first.trustedBridge.bridgeId;
    }
    return _SavedBridgeRegistry(
      connections: updatedConnections,
      activeBridgeId: nextActiveBridgeId,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'active_bridge_id': activeBridgeId,
      'bridges': connections
          .map((connection) => connection.toJson())
          .toList(growable: false),
    };
  }
}
