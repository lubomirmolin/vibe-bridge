import 'dart:async';

/// Reusable reconnection scheduler that encapsulates the timer-based
/// retry pattern used across controllers that maintain live bridge
/// connections.
///
/// Usage:
/// ```dart
/// late final ReconnectScheduler _reconnectScheduler;
///
/// MyController() {
///   _reconnectScheduler = ReconnectScheduler(
///     onReconnect: _runReconnect,
///     isDisposed: () => _isDisposed,
///   );
/// }
/// ```
class ReconnectScheduler {
  ReconnectScheduler({
    required Future<void> Function() onReconnect,
    required bool Function() isDisposed,
    Duration delay = const Duration(seconds: 2),
  })  : _onReconnect = onReconnect,
        _isDisposed = isDisposed,
        _delay = delay;

  final Future<void> Function() _onReconnect;
  final bool Function() _isDisposed;
  final Duration _delay;
  Timer? _timer;
  bool _isInProgress = false;

  bool get isInProgress => _isInProgress;

  void schedule() {
    if (_isDisposed() || _isInProgress || _timer?.isActive == true) {
      return;
    }

    _timer = Timer(_delay, () {
      unawaited(run());
    });
  }

  Future<void> run() async {
    if (_isDisposed() || _isInProgress) {
      return;
    }

    _isInProgress = true;
    try {
      await _onReconnect();
    } finally {
      _isInProgress = false;
    }
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
  }

  void dispose() {
    cancel();
  }
}
