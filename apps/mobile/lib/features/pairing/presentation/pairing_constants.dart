import 'package:mobile_scanner/mobile_scanner.dart';

/// Constants used across the pairing flow UI.
class PairingConstants {
  PairingConstants._();

  // Timing
  static const Duration cameraMountDelay = Duration(milliseconds: 100);
  static const Duration layoutTransition = Duration(milliseconds: 620);
  static const Duration flipReveal = Duration(milliseconds: 1400);
  static const Duration swipeHint = Duration(milliseconds: 900);
  static const Duration titleSwitcher = Duration(milliseconds: 360);
  static const Duration centerSwitcher = Duration(milliseconds: 420);
  static const Duration buttonSwitcher = Duration(milliseconds: 220);

  // Layout
  static const double scanCardSize = 250.0;
  static const double scanCardRadius = 32.0;
  static const double footerBaseHeight = 132.0;

  // Animation intervals
  static const double flipRevealSwapPoint = 0.50;
  static const double centerAnimationStart = 0.18;
}

/// Represents different types of scanner issues that can occur during pairing.
enum PairingScannerIssueType { permissionDenied, scannerFailure }

/// Immutable class representing a scanner issue with details.
class PairingScannerIssue {
  const PairingScannerIssue._(this.type, {this.details});

  const PairingScannerIssue.permissionDenied()
      : this._(PairingScannerIssueType.permissionDenied);

  const PairingScannerIssue.failure({String? details})
      : this._(PairingScannerIssueType.scannerFailure, details: details);

  factory PairingScannerIssue.fromScannerException(
    MobileScannerException error,
  ) {
    if (error.errorCode == MobileScannerErrorCode.permissionDenied) {
      return const PairingScannerIssue.permissionDenied();
    }

    final details = error.errorDetails?.message;
    return PairingScannerIssue.failure(
      details: details == null || details.trim().isEmpty
          ? null
          : details.trim(),
    );
  }

  final PairingScannerIssueType type;
  final String? details;

  @override
  bool operator ==(Object other) {
    return other is PairingScannerIssue &&
        other.type == type &&
        other.details == details;
  }

  @override
  int get hashCode => Object.hash(type, details);
}
