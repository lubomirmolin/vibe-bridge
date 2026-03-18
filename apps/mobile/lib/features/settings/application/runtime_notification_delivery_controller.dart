import 'dart:async';

import 'package:codex_mobile_companion/features/settings/application/notification_preferences_controller.dart';
import 'package:codex_mobile_companion/features/threads/data/thread_live_stream.dart';
import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final runtimeNotificationDeliveryControllerProvider = StateNotifierProvider
    .autoDispose
    .family<
      RuntimeNotificationDeliveryController,
      RuntimeNotificationDeliveryState,
      String
    >((ref, bridgeApiBaseUrl) {
      final controller = RuntimeNotificationDeliveryController(
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        liveStream: ref.watch(threadLiveStreamProvider),
        initialPreferences: ref.read(notificationPreferencesControllerProvider),
      );

      ref.listen<NotificationPreferencesState>(
        notificationPreferencesControllerProvider,
        (_, next) {
          controller.updatePreferences(next);
        },
      );

      return controller;
    });

enum RuntimeNotificationKind { approval, liveActivity }

class RuntimeNotificationEntry {
  const RuntimeNotificationEntry({
    required this.deliveryId,
    required this.eventId,
    required this.threadId,
    required this.kind,
    required this.title,
    required this.message,
    required this.occurredAt,
  });

  final String deliveryId;
  final String eventId;
  final String threadId;
  final RuntimeNotificationKind kind;
  final String title;
  final String message;
  final String occurredAt;
}

class RuntimeNotificationDeliveryState {
  const RuntimeNotificationDeliveryState({
    this.pendingNotifications = const <RuntimeNotificationEntry>[],
    this.recentNotifications = const <RuntimeNotificationEntry>[],
    this.approvalNotificationsEnabled = true,
    this.liveActivityNotificationsEnabled = true,
    this.preferencesRestored = false,
  });

  final List<RuntimeNotificationEntry> pendingNotifications;
  final List<RuntimeNotificationEntry> recentNotifications;
  final bool approvalNotificationsEnabled;
  final bool liveActivityNotificationsEnabled;
  final bool preferencesRestored;

  RuntimeNotificationDeliveryState copyWith({
    List<RuntimeNotificationEntry>? pendingNotifications,
    List<RuntimeNotificationEntry>? recentNotifications,
    bool? approvalNotificationsEnabled,
    bool? liveActivityNotificationsEnabled,
    bool? preferencesRestored,
  }) {
    return RuntimeNotificationDeliveryState(
      pendingNotifications: pendingNotifications ?? this.pendingNotifications,
      recentNotifications: recentNotifications ?? this.recentNotifications,
      approvalNotificationsEnabled:
          approvalNotificationsEnabled ?? this.approvalNotificationsEnabled,
      liveActivityNotificationsEnabled:
          liveActivityNotificationsEnabled ??
          this.liveActivityNotificationsEnabled,
      preferencesRestored: preferencesRestored ?? this.preferencesRestored,
    );
  }
}

class RuntimeNotificationDeliveryController
    extends StateNotifier<RuntimeNotificationDeliveryState> {
  RuntimeNotificationDeliveryController({
    required String bridgeApiBaseUrl,
    required ThreadLiveStream liveStream,
    required NotificationPreferencesState initialPreferences,
  }) : _bridgeApiBaseUrl = bridgeApiBaseUrl,
       _liveStream = liveStream,
       super(
         RuntimeNotificationDeliveryState(
           approvalNotificationsEnabled:
               initialPreferences.approvalNotificationsEnabled,
           liveActivityNotificationsEnabled:
               initialPreferences.liveActivityNotificationsEnabled,
           preferencesRestored: !initialPreferences.isLoading,
         ),
       ) {
    unawaited(_startLiveSubscription());
  }

  final String _bridgeApiBaseUrl;
  final ThreadLiveStream _liveStream;
  final Set<String> _seenEventIds = <String>{};

  ThreadLiveSubscription? _liveSubscription;
  StreamSubscription<BridgeEventEnvelope<Map<String, dynamic>>>?
  _liveEventSubscription;
  Timer? _reconnectTimer;
  int _deliverySequence = 0;
  bool _isReconnectInProgress = false;
  bool _isDisposed = false;

  void updatePreferences(NotificationPreferencesState preferences) {
    if (_isDisposed) {
      return;
    }

    state = state.copyWith(
      approvalNotificationsEnabled: preferences.approvalNotificationsEnabled,
      liveActivityNotificationsEnabled:
          preferences.liveActivityNotificationsEnabled,
      preferencesRestored: !preferences.isLoading,
    );
  }

  void acknowledgePending(String deliveryId) {
    state = state.copyWith(
      pendingNotifications: state.pendingNotifications
          .where((notification) => notification.deliveryId != deliveryId)
          .toList(growable: false),
    );
  }

  void acknowledgeAllPending() {
    if (state.pendingNotifications.isEmpty) {
      return;
    }

    state = state.copyWith(
      pendingNotifications: const <RuntimeNotificationEntry>[],
    );
  }

  Future<void> _startLiveSubscription() async {
    try {
      final subscription = await _liveStream.subscribe(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
      );
      _liveSubscription = subscription;

      _liveEventSubscription = subscription.events.listen(
        _handleLiveEvent,
        onError: (_) {
          _handleLiveStreamDisconnected();
        },
        onDone: _handleLiveStreamDisconnected,
      );
    } catch (_) {
      _handleLiveStreamDisconnected();
    }
  }

  void _handleLiveEvent(BridgeEventEnvelope<Map<String, dynamic>> event) {
    if (_seenEventIds.contains(event.eventId)) {
      return;
    }
    _seenEventIds.add(event.eventId);

    if (!state.preferencesRestored) {
      return;
    }

    if (_isApprovalNotificationEvent(event)) {
      if (!state.approvalNotificationsEnabled) {
        return;
      }

      _deliverNotification(
        event: event,
        kind: RuntimeNotificationKind.approval,
        title: 'Approval requested',
        message: _approvalMessage(event),
      );
      return;
    }

    if (_isLiveActivityNotificationEvent(event)) {
      if (!state.liveActivityNotificationsEnabled) {
        return;
      }

      _deliverNotification(
        event: event,
        kind: RuntimeNotificationKind.liveActivity,
        title: _liveActivityTitle(event),
        message: _liveActivityMessage(event),
      );
    }
  }

  void _deliverNotification({
    required BridgeEventEnvelope<Map<String, dynamic>> event,
    required RuntimeNotificationKind kind,
    required String title,
    required String message,
  }) {
    final entry = RuntimeNotificationEntry(
      deliveryId: 'notification-${_deliverySequence++}',
      eventId: event.eventId,
      threadId: event.threadId,
      kind: kind,
      title: title,
      message: message,
      occurredAt: event.occurredAt,
    );

    final nextPending = List<RuntimeNotificationEntry>.from(
      state.pendingNotifications,
    )..add(entry);

    final nextRecent = <RuntimeNotificationEntry>[
      entry,
      ...state.recentNotifications,
    ];
    if (nextRecent.length > 25) {
      nextRecent.removeRange(25, nextRecent.length);
    }

    state = state.copyWith(
      pendingNotifications: nextPending,
      recentNotifications: nextRecent,
    );
  }

  bool _isApprovalNotificationEvent(
    BridgeEventEnvelope<Map<String, dynamic>> event,
  ) {
    return event.kind == BridgeEventKind.approvalRequested;
  }

  bool _isLiveActivityNotificationEvent(
    BridgeEventEnvelope<Map<String, dynamic>> event,
  ) {
    return event.kind == BridgeEventKind.messageDelta ||
        event.kind == BridgeEventKind.threadStatusChanged;
  }

  String _approvalMessage(BridgeEventEnvelope<Map<String, dynamic>> event) {
    final payload = event.payload;
    final reason = _optionalString(payload, 'reason');
    if (reason != null) {
      return '$reason (thread ${event.threadId})';
    }

    final action = _optionalString(payload, 'action');
    final target = _optionalString(payload, 'target');
    if (action != null && target != null) {
      return '$action on $target (thread ${event.threadId})';
    }

    return 'A pending approval needs review in thread ${event.threadId}.';
  }

  String _liveActivityTitle(BridgeEventEnvelope<Map<String, dynamic>> event) {
    if (event.kind == BridgeEventKind.threadStatusChanged) {
      final status = _optionalString(event.payload, 'status');
      if (status != null) {
        return 'Thread $status';
      }
    }

    return 'Live activity update';
  }

  String _liveActivityMessage(BridgeEventEnvelope<Map<String, dynamic>> event) {
    final payload = event.payload;
    if (event.kind == BridgeEventKind.messageDelta) {
      final delta =
          _optionalString(payload, 'delta') ?? _optionalString(payload, 'text');
      if (delta != null) {
        return '$delta (thread ${event.threadId})';
      }
      return 'New assistant output is available in thread ${event.threadId}.';
    }

    final status = _optionalString(payload, 'status');
    final reason = _optionalString(payload, 'reason');
    if (status != null && reason != null) {
      return 'Status: $status • $reason (thread ${event.threadId})';
    }
    if (status != null) {
      return 'Status: $status (thread ${event.threadId})';
    }

    return 'Thread activity changed in ${event.threadId}.';
  }

  void _handleLiveStreamDisconnected() {
    if (_isDisposed) {
      return;
    }
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_isDisposed ||
        _isReconnectInProgress ||
        _reconnectTimer?.isActive == true) {
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

    _isReconnectInProgress = true;
    try {
      await _closeLiveSubscription();
      await _startLiveSubscription();
    } catch (_) {
      _scheduleReconnect();
    } finally {
      _isReconnectInProgress = false;
    }
  }

  Future<void> _closeLiveSubscription() async {
    await _liveEventSubscription?.cancel();
    _liveEventSubscription = null;

    final subscription = _liveSubscription;
    _liveSubscription = null;
    if (subscription == null) {
      return;
    }

    try {
      await subscription.close();
    } catch (_) {
      // Ignore teardown failures from already-closed sockets/streams.
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    _reconnectTimer?.cancel();
    unawaited(_closeLiveSubscription());
    super.dispose();
  }
}

String? _optionalString(Map<String, dynamic> payload, String key) {
  final value = payload[key];
  if (value is! String || value.trim().isEmpty) {
    return null;
  }

  return value.trim();
}
