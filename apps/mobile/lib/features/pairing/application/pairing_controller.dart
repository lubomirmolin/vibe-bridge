import 'dart:async';
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

enum BridgeConnectionState { connected, disconnected }

class PairingState {
  const PairingState({
    required this.step,
    required this.consumedSessionIds,
    required this.bridgeConnectionState,
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
  final bool isPersistingTrust;

  bool get canRunMutatingActions =>
      step == PairingStep.paired &&
      bridgeConnectionState == BridgeConnectionState.connected;

  factory PairingState.initial() {
    return const PairingState(
      step: PairingStep.unpaired,
      consumedSessionIds: <String>{},
      bridgeConnectionState: BridgeConnectionState.connected,
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
    final raw = await _secureStore.readSecret(
      SecureValueKey.trustedBridgeIdentity,
    );
    if (raw == null) {
      return;
    }

    final sessionToken = await _secureStore.readSecret(
      SecureValueKey.sessionToken,
    );
    if (sessionToken == null || sessionToken.trim().isEmpty) {
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
      await _restoreTrustedBridgeSession(
        trustedBridge: trustedBridge,
        sessionToken: sessionToken,
      );
    } on FormatException {
      await _clearLocalTrust();
    }
  }

  void openScanner() {
    state = state.copyWith(
      step: PairingStep.scanning,
      clearPendingPayload: true,
      clearErrorMessage: true,
      bridgeConnectionState: BridgeConnectionState.connected,
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
      isPersistingTrust: false,
    );
  }

  Future<void> confirmTrust() async {
    final payload = state.pendingPayload;
    if (payload == null || state.isPersistingTrust) {
      return;
    }

    if (state.trustedBridge != null &&
        state.trustedBridge!.bridgeId != payload.bridgeId) {
      state = state.copyWith(
        errorMessage:
            'This phone is already paired with a different Mac. Reset trust before replacing it.',
      );
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

    final trust = TrustedBridgeIdentity.fromPayload(
      payload,
      pairedAtUtc: _nowUtc(),
    );

    await _secureStore.writeSecret(
      SecureValueKey.trustedBridgeIdentity,
      jsonEncode(trust.toJson()),
    );
    await _secureStore.writeSecret(
      SecureValueKey.sessionToken,
      finalizeResult.sessionToken!,
    );

    final consumedSessionIds = Set<String>.from(state.consumedSessionIds)
      ..add(payload.sessionId);

    state = state.copyWith(
      step: PairingStep.paired,
      trustedBridge: trust,
      clearPendingPayload: true,
      clearErrorMessage: true,
      bridgeConnectionState: BridgeConnectionState.connected,
      isPersistingTrust: false,
      consumedSessionIds: consumedSessionIds,
    );
    _cancelReconnectTimer();
  }

  Future<void> retryTrustedBridgeConnection() async {
    _cancelReconnectTimer();

    final trustedBridge = state.trustedBridge;
    if (trustedBridge == null) {
      return;
    }

    final sessionToken = await _secureStore.readSecret(
      SecureValueKey.sessionToken,
    );
    if (sessionToken == null || sessionToken.trim().isEmpty) {
      await _clearLocalTrust();
      state = state.copyWith(
        step: PairingStep.unpaired,
        clearTrustedBridge: true,
        clearPendingPayload: true,
        bridgeConnectionState: BridgeConnectionState.connected,
        errorMessage: 'Stored trust is incomplete. Re-pair from your Mac.',
      );
      return;
    }

    await _restoreTrustedBridgeSession(
      trustedBridge: trustedBridge,
      sessionToken: sessionToken,
    );
  }

  Future<void> _restoreTrustedBridgeSession({
    required TrustedBridgeIdentity trustedBridge,
    required String sessionToken,
  }) async {
    final phoneId = await _readOrCreatePhoneId();
    final handshake = await _bridgeApi.handshake(
      trustedBridge: trustedBridge,
      phoneId: phoneId,
      sessionToken: sessionToken,
    );

    if (handshake.isTrusted) {
      _cancelReconnectTimer();
      state = state.copyWith(
        step: PairingStep.paired,
        trustedBridge: trustedBridge,
        bridgeConnectionState: BridgeConnectionState.connected,
        clearErrorMessage: true,
      );
      return;
    }

    if (handshake.connectivityUnavailable) {
      state = state.copyWith(
        step: PairingStep.paired,
        trustedBridge: trustedBridge,
        bridgeConnectionState: BridgeConnectionState.disconnected,
        errorMessage:
            handshake.message ??
            'Private bridge path is currently unreachable. Reconnect to Tailscale and retry.',
      );
      _scheduleReconnect();
      return;
    }

    _cancelReconnectTimer();
    await _clearLocalTrust();
    state = state.copyWith(
      step: PairingStep.unpaired,
      clearTrustedBridge: true,
      clearPendingPayload: true,
      bridgeConnectionState: BridgeConnectionState.connected,
      errorMessage:
          handshake.message ??
          'Stored trust is no longer accepted by the bridge. Re-pair from your Mac.',
    );
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

    final trustedBridge = state.trustedBridge;
    if (trustedBridge == null) {
      return;
    }

    final sessionToken = await _secureStore.readSecret(
      SecureValueKey.sessionToken,
    );
    if (sessionToken == null || sessionToken.trim().isEmpty) {
      await _clearLocalTrust();
      state = state.copyWith(
        step: PairingStep.unpaired,
        clearTrustedBridge: true,
        clearPendingPayload: true,
        bridgeConnectionState: BridgeConnectionState.connected,
        errorMessage: 'Stored trust is incomplete. Re-pair from your Mac.',
      );
      return;
    }

    _isReconnectInProgress = true;
    try {
      await _restoreTrustedBridgeSession(
        trustedBridge: trustedBridge,
        sessionToken: sessionToken,
      );
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

    await _clearLocalTrust(clearCachedThreadState: true);
    state = state.copyWith(
      step: PairingStep.unpaired,
      clearTrustedBridge: true,
      clearPendingPayload: true,
      bridgeConnectionState: BridgeConnectionState.connected,
      consumedSessionIds: const <String>{},
      isPersistingTrust: false,
      errorMessage:
          warningMessage ??
          'This phone was unpaired. Scan a fresh pairing QR to reconnect.',
    );
  }

  Future<void> _clearLocalTrust({bool clearCachedThreadState = false}) async {
    await _secureStore.removeSecret(SecureValueKey.trustedBridgeIdentity);
    await _secureStore.removeSecret(SecureValueKey.sessionToken);

    if (clearCachedThreadState) {
      await _secureStore.removeSecret(SecureValueKey.threadListCache);
      await _secureStore.removeSecret(SecureValueKey.threadDetailsCache);
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

  @override
  void dispose() {
    _isDisposed = true;
    _cancelReconnectTimer();
    super.dispose();
  }
}
