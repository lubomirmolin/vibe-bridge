import 'package:vibe_bridge/features/bridges/domain/pairing_qr_payload.dart';

enum PairingValidationError {
  malformed('This QR code is invalid. Please rescan from the host bridge.'),
  expired('This pairing QR code expired. Please rescan from the host bridge.'),
  reused(
    'This pairing QR code was already used. Please rescan from the host bridge.',
  ),
  privateRouteRequired(
    'This QR does not advertise a supported Tailscale or local-network bridge route. Please rescan from the host bridge.',
  );

  const PairingValidationError(this.message);

  final String message;
}

class PairingValidationResult {
  const PairingValidationResult._({
    this.payload,
    this.error,
    required this.message,
  });

  final PairingQrPayload? payload;
  final PairingValidationError? error;
  final String message;

  bool get isValid => payload != null;

  factory PairingValidationResult.valid(PairingQrPayload payload) {
    return PairingValidationResult._(
      payload: payload,
      message: 'Valid pairing payload.',
    );
  }

  factory PairingValidationResult.invalid(PairingValidationError error) {
    return PairingValidationResult._(error: error, message: error.message);
  }
}

PairingValidationResult validatePairingQrPayload(
  String rawPayload, {
  required DateTime nowUtc,
  required Set<String> consumedSessionIds,
}) {
  try {
    final payload = decodePairingQrPayload(rawPayload);

    final expiresAtUtc = payload.expiresAtUtc;
    if (expiresAtUtc != null && !expiresAtUtc.isAfter(nowUtc.toUtc())) {
      return PairingValidationResult.invalid(PairingValidationError.expired);
    }

    if (consumedSessionIds.contains(payload.sessionId)) {
      return PairingValidationResult.invalid(PairingValidationError.reused);
    }

    if (payload.orderedReachableRoutes.isEmpty) {
      return PairingValidationResult.invalid(
        PairingValidationError.privateRouteRequired,
      );
    }

    return PairingValidationResult.valid(payload);
  } on FormatException {
    return PairingValidationResult.invalid(PairingValidationError.malformed);
  }
}
