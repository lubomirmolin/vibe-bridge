import 'dart:convert';

import 'package:codex_mobile_companion/features/pairing/domain/pairing_qr_payload.dart';
import 'package:codex_mobile_companion/features/pairing/domain/pairing_qr_validator.dart';
import 'package:codex_mobile_companion/foundation/storage/secure_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final secureStoreProvider = Provider<SecureStore>((ref) {
  return InMemorySecureStore();
});

final nowUtcProvider = Provider<DateTime>((ref) {
  return DateTime.now().toUtc();
});

final pairingControllerProvider =
    StateNotifierProvider<PairingController, PairingState>((ref) {
      return PairingController(
        secureStore: ref.watch(secureStoreProvider),
        nowUtc: () => ref.read(nowUtcProvider),
      );
    });

enum PairingStep { unpaired, scanning, review, paired }

class PairingState {
  const PairingState({
    required this.step,
    required this.consumedSessionIds,
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
  final bool isPersistingTrust;

  factory PairingState.initial() {
    return const PairingState(
      step: PairingStep.unpaired,
      consumedSessionIds: <String>{},
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
      isPersistingTrust: isPersistingTrust ?? this.isPersistingTrust,
    );
  }
}

class PairingController extends StateNotifier<PairingState> {
  PairingController({
    required SecureStore secureStore,
    required DateTime Function() nowUtc,
  }) : _secureStore = secureStore,
       _nowUtc = nowUtc,
       super(PairingState.initial()) {
    _restoreTrustedBridge();
  }

  final SecureStore _secureStore;
  final DateTime Function() _nowUtc;

  Future<void> _restoreTrustedBridge() async {
    final raw = await _secureStore.readSecret(
      SecureValueKey.trustedBridgeIdentity,
    );
    if (raw == null) {
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
      state = state.copyWith(
        step: PairingStep.paired,
        trustedBridge: trustedBridge,
      );
    } on FormatException {
      await _secureStore.removeSecret(SecureValueKey.trustedBridgeIdentity);
    }
  }

  void openScanner() {
    state = state.copyWith(
      step: PairingStep.scanning,
      clearPendingPayload: true,
      clearErrorMessage: true,
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

    state = state.copyWith(isPersistingTrust: true, clearErrorMessage: true);
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
      payload.pairingToken,
    );

    final consumedSessionIds = Set<String>.from(state.consumedSessionIds)
      ..add(payload.sessionId);

    state = state.copyWith(
      step: PairingStep.paired,
      trustedBridge: trust,
      clearPendingPayload: true,
      clearErrorMessage: true,
      isPersistingTrust: false,
      consumedSessionIds: consumedSessionIds,
    );
  }
}
