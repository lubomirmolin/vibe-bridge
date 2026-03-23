import 'package:codex_mobile_companion/features/pairing/domain/pairing_qr_payload.dart';

enum PairingValidationError { malformed, expired, reused, privateRouteRequired }

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
    return PairingValidationResult._(error: error, message: _messageFor(error));
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

String _messageFor(PairingValidationError error) {
  switch (error) {
    case PairingValidationError.malformed:
      return 'This QR code is invalid. Please rescan from your Mac.';
    case PairingValidationError.expired:
      return 'This pairing QR code expired. Please rescan from your Mac.';
    case PairingValidationError.reused:
      return 'This pairing QR code was already used. Please rescan from your Mac.';
    case PairingValidationError.privateRouteRequired:
      return 'This QR does not advertise a supported Tailscale or local-network bridge route. Please rescan from your Mac.';
  }
}
