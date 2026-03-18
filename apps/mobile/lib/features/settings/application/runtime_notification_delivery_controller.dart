import 'dart:async';
import 'dart:convert';

import 'package:codex_mobile_companion/features/settings/application/notification_preferences_controller.dart';
import 'package:codex_mobile_companion/features/settings/data/runtime_platform_notifications.dart';
import 'package:codex_mobile_companion/features/threads/data/thread_live_stream.dart';
import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:codex_mobile_companion/foundation/storage/secure_store.dart';
import 'package:codex_mobile_companion/foundation/storage/secure_store_provider.dart';
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
        secureStore: ref.watch(appSecureStoreProvider),
        runtimePlatformNotifications: ref.watch(
          runtimePlatformNotificationsProvider,
        ),
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

enum RuntimeNotificationTargetType { threadDetail, approvalDetail }

class RuntimeNotificationTarget {
  const RuntimeNotificationTarget({
    required this.type,
    required this.threadId,
    this.approvalId,
  });

  final RuntimeNotificationTargetType type;
  final String threadId;
  final String? approvalId;

  factory RuntimeNotificationTarget.fromJson(Map<String, dynamic> json) {
    final targetType = json['target_type'] as String;
    return RuntimeNotificationTarget(
      type: targetType == 'approval_detail'
          ? RuntimeNotificationTargetType.approvalDetail
          : RuntimeNotificationTargetType.threadDetail,
      threadId: json['thread_id'] as String,
      approvalId: json['approval_id'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'target_type': switch (type) {
        RuntimeNotificationTargetType.threadDetail => 'thread_detail',
        RuntimeNotificationTargetType.approvalDetail => 'approval_detail',
      },
      'thread_id': threadId,
      'approval_id': approvalId,
    };
  }
}

class RuntimeNotificationEntry {
  const RuntimeNotificationEntry({
    required this.deliveryId,
    required this.eventId,
    required this.threadId,
    required this.kind,
    required this.title,
    required this.message,
    required this.occurredAt,
    required this.target,
  });

  final String deliveryId;
  final String eventId;
  final String threadId;
  final RuntimeNotificationKind kind;
  final String title;
  final String message;
  final String occurredAt;
  final RuntimeNotificationTarget target;
}

class RuntimeNotificationLaunchRequest {
  const RuntimeNotificationLaunchRequest({
    required this.requestId,
    required this.eventId,
    required this.target,
  });

  final String requestId;
  final String eventId;
  final RuntimeNotificationTarget target;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{'event_id': eventId, 'target': target.toJson()};
  }

  factory RuntimeNotificationLaunchRequest.fromJson(
    Map<String, dynamic> json, {
    required String requestId,
  }) {
    return RuntimeNotificationLaunchRequest(
      requestId: requestId,
      eventId: json['event_id'] as String,
      target: RuntimeNotificationTarget.fromJson(
        json['target'] as Map<String, dynamic>,
      ),
    );
  }
}

class RuntimeNotificationDeliveryState {
  const RuntimeNotificationDeliveryState({
    this.pendingNotifications = const <RuntimeNotificationEntry>[],
    this.recentNotifications = const <RuntimeNotificationEntry>[],
    this.pendingLaunchRequests = const <RuntimeNotificationLaunchRequest>[],
    this.approvalNotificationsEnabled = true,
    this.liveActivityNotificationsEnabled = true,
    this.preferencesRestored = false,
  });

  final List<RuntimeNotificationEntry> pendingNotifications;
  final List<RuntimeNotificationEntry> recentNotifications;
  final List<RuntimeNotificationLaunchRequest> pendingLaunchRequests;
  final bool approvalNotificationsEnabled;
  final bool liveActivityNotificationsEnabled;
  final bool preferencesRestored;

  RuntimeNotificationDeliveryState copyWith({
    List<RuntimeNotificationEntry>? pendingNotifications,
    List<RuntimeNotificationEntry>? recentNotifications,
    List<RuntimeNotificationLaunchRequest>? pendingLaunchRequests,
    bool? approvalNotificationsEnabled,
    bool? liveActivityNotificationsEnabled,
    bool? preferencesRestored,
  }) {
    return RuntimeNotificationDeliveryState(
      pendingNotifications: pendingNotifications ?? this.pendingNotifications,
      recentNotifications: recentNotifications ?? this.recentNotifications,
      pendingLaunchRequests:
          pendingLaunchRequests ?? this.pendingLaunchRequests,
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
    required SecureStore secureStore,
    required RuntimePlatformNotifications runtimePlatformNotifications,
    required NotificationPreferencesState initialPreferences,
  }) : _bridgeApiBaseUrl = bridgeApiBaseUrl,
       _liveStream = liveStream,
       _secureStore = secureStore,
       _runtimePlatformNotifications = runtimePlatformNotifications,
       super(
         RuntimeNotificationDeliveryState(
           approvalNotificationsEnabled:
               initialPreferences.approvalNotificationsEnabled,
           liveActivityNotificationsEnabled:
               initialPreferences.liveActivityNotificationsEnabled,
           preferencesRestored: !initialPreferences.isLoading,
         ),
       ) {
    unawaited(_initialize());
  }

  final String _bridgeApiBaseUrl;
  final ThreadLiveStream _liveStream;
  final SecureStore _secureStore;
  final RuntimePlatformNotifications _runtimePlatformNotifications;

  final Set<String> _seenEventIds = <String>{};
  final List<String> _seenEventOrder = <String>[];
  final Set<String> _consumedLaunchEventIds = <String>{};
  final List<String> _consumedLaunchEventOrder = <String>[];

  ThreadLiveSubscription? _liveSubscription;
  StreamSubscription<BridgeEventEnvelope<Map<String, dynamic>>>?
  _liveEventSubscription;
  StreamSubscription<String>? _openedNotificationPayloadSubscription;
  Timer? _reconnectTimer;
  int _deliverySequence = 0;
  int _launchRequestSequence = 0;
  bool _isReconnectInProgress = false;
  bool _isDisposed = false;
  bool _systemNotificationDeliveryAvailable = false;

  static const _maxRecentNotifications = 25;
  static const _maxSeenEventIds = 200;
  static const _maxConsumedLaunchEventIds = 200;

  Future<void> _initialize() async {
    final bootstrap = await _runtimePlatformNotifications.initialize();
    _systemNotificationDeliveryAvailable =
        bootstrap.systemNotificationsAvailable;

    _openedNotificationPayloadSubscription = _runtimePlatformNotifications
        .openedPayloads
        .listen(_handleOpenedNotificationPayload);

    await Future.wait<void>([
      _restoreSeenEventIds(),
      _restorePendingLaunchRequest(),
    ]);

    final initialLaunchPayload = bootstrap.initialLaunchPayload;
    if (initialLaunchPayload != null) {
      await _enqueueLaunchRequestFromPayload(initialLaunchPayload);
    }

    await _startLiveSubscription();
  }

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

  Future<void> requestOpenNotification(String deliveryId) async {
    RuntimeNotificationEntry? notification;
    for (final entry in state.recentNotifications) {
      if (entry.deliveryId == deliveryId) {
        notification = entry;
        break;
      }
    }

    if (notification == null) {
      return;
    }

    await _enqueueLaunchRequest(
      eventId: notification.eventId,
      target: notification.target,
    );
  }

  Future<void> acknowledgeLaunchRequest(String requestId) async {
    RuntimeNotificationLaunchRequest? acknowledgedRequest;
    for (final request in state.pendingLaunchRequests) {
      if (request.requestId == requestId) {
        acknowledgedRequest = request;
        break;
      }
    }

    if (acknowledgedRequest != null) {
      _rememberConsumedLaunchEvent(acknowledgedRequest.eventId);
    }

    final remaining = state.pendingLaunchRequests
        .where((request) => request.requestId != requestId)
        .toList(growable: false);

    state = state.copyWith(pendingLaunchRequests: remaining);

    if (remaining.isEmpty) {
      await _secureStore.removeSecret(
        SecureValueKey.runtimeNotificationPendingLaunchTarget,
      );
      return;
    }

    await _persistPendingLaunchRequest(remaining.first);
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

    _rememberSeenEvent(event.eventId);

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
        target: _approvalTarget(event),
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
        target: RuntimeNotificationTarget(
          type: RuntimeNotificationTargetType.threadDetail,
          threadId: event.threadId,
        ),
        title: _liveActivityTitle(event),
        message: _liveActivityMessage(event),
      );
    }
  }

  RuntimeNotificationTarget _approvalTarget(
    BridgeEventEnvelope<Map<String, dynamic>> event,
  ) {
    final payload = event.payload;
    final threadId =
        _optionalString(payload, 'thread_id') ??
        _optionalString(payload, 'threadId') ??
        event.threadId;
    final approvalId =
        _optionalString(payload, 'approval_id') ??
        _optionalString(payload, 'approvalId');

    if (approvalId != null) {
      return RuntimeNotificationTarget(
        type: RuntimeNotificationTargetType.approvalDetail,
        threadId: threadId,
        approvalId: approvalId,
      );
    }

    return RuntimeNotificationTarget(
      type: RuntimeNotificationTargetType.threadDetail,
      threadId: threadId,
    );
  }

  void _deliverNotification({
    required BridgeEventEnvelope<Map<String, dynamic>> event,
    required RuntimeNotificationKind kind,
    required RuntimeNotificationTarget target,
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
      target: target,
    );

    final shouldUseInAppFallback = !_systemNotificationDeliveryAvailable;
    final nextPending = shouldUseInAppFallback
        ? (List<RuntimeNotificationEntry>.from(state.pendingNotifications)
            ..add(entry))
        : state.pendingNotifications;

    final nextRecent = <RuntimeNotificationEntry>[
      entry,
      ...state.recentNotifications,
    ];
    if (nextRecent.length > _maxRecentNotifications) {
      nextRecent.removeRange(_maxRecentNotifications, nextRecent.length);
    }

    state = state.copyWith(
      pendingNotifications: nextPending,
      recentNotifications: nextRecent,
    );

    if (_systemNotificationDeliveryAvailable) {
      unawaited(_showSystemNotificationOrFallback(entry));
    }
  }

  Future<void> _showSystemNotificationOrFallback(
    RuntimeNotificationEntry entry,
  ) async {
    final payload = jsonEncode(<String, dynamic>{
      'event_id': entry.eventId,
      'target': entry.target.toJson(),
    });

    final didShow = await _runtimePlatformNotifications.showNotification(
      notificationId: _notificationIdForEvent(entry.eventId),
      title: entry.title,
      body: entry.message,
      payload: payload,
    );

    if (didShow || _isDisposed) {
      return;
    }

    if (state.pendingNotifications.any(
      (notification) => notification.deliveryId == entry.deliveryId,
    )) {
      return;
    }

    state = state.copyWith(
      pendingNotifications: <RuntimeNotificationEntry>[
        ...state.pendingNotifications,
        entry,
      ],
    );
  }

  void _handleOpenedNotificationPayload(String payload) {
    unawaited(_enqueueLaunchRequestFromPayload(payload));
  }

  Future<void> _enqueueLaunchRequestFromPayload(String payload) async {
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map<String, dynamic>) {
        return;
      }

      final eventId = decoded['event_id'];
      final targetJson = decoded['target'];
      if (eventId is! String || targetJson is! Map<String, dynamic>) {
        return;
      }

      final normalizedEventId = eventId.trim();
      if (normalizedEventId.isEmpty) {
        return;
      }

      await _enqueueLaunchRequest(
        eventId: normalizedEventId,
        target: RuntimeNotificationTarget.fromJson(targetJson),
      );
    } on FormatException {
      // Ignore malformed payloads from stale notifications.
    } on TypeError {
      // Ignore malformed payloads from stale notifications.
    }
  }

  Future<void> _enqueueLaunchRequest({
    required String eventId,
    required RuntimeNotificationTarget target,
  }) async {
    if (_consumedLaunchEventIds.contains(eventId) ||
        state.pendingLaunchRequests.any(
          (request) => request.eventId == eventId,
        )) {
      return;
    }

    final request = RuntimeNotificationLaunchRequest(
      requestId: 'launch-${_launchRequestSequence++}',
      eventId: eventId,
      target: target,
    );

    state = state.copyWith(
      pendingLaunchRequests: <RuntimeNotificationLaunchRequest>[
        ...state.pendingLaunchRequests,
        request,
      ],
    );

    await _persistPendingLaunchRequest(request);
  }

  void _rememberConsumedLaunchEvent(String eventId) {
    if (_consumedLaunchEventIds.add(eventId)) {
      _consumedLaunchEventOrder.add(eventId);
    }

    while (_consumedLaunchEventOrder.length > _maxConsumedLaunchEventIds) {
      final evicted = _consumedLaunchEventOrder.removeAt(0);
      _consumedLaunchEventIds.remove(evicted);
    }
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

  void _rememberSeenEvent(String eventId) {
    if (_seenEventIds.add(eventId)) {
      _seenEventOrder.add(eventId);
    }

    while (_seenEventOrder.length > _maxSeenEventIds) {
      final evicted = _seenEventOrder.removeAt(0);
      _seenEventIds.remove(evicted);
    }

    unawaited(_persistSeenEventIds());
  }

  Future<void> _restoreSeenEventIds() async {
    try {
      final raw = await _secureStore.readSecret(
        SecureValueKey.runtimeNotificationSeenEventIds,
      );
      if (raw == null || raw.trim().isEmpty) {
        return;
      }

      final decoded = jsonDecode(raw);
      if (decoded is! List<dynamic>) {
        return;
      }

      for (final item in decoded) {
        if (item is! String) {
          continue;
        }

        final eventId = item.trim();
        if (eventId.isEmpty || _seenEventIds.contains(eventId)) {
          continue;
        }

        _seenEventIds.add(eventId);
        _seenEventOrder.add(eventId);
      }

      while (_seenEventOrder.length > _maxSeenEventIds) {
        final evicted = _seenEventOrder.removeAt(0);
        _seenEventIds.remove(evicted);
      }
    } on FormatException {
      // Ignore malformed persisted state.
    } on TypeError {
      // Ignore malformed persisted state.
    }
  }

  Future<void> _persistSeenEventIds() {
    return _secureStore.writeSecret(
      SecureValueKey.runtimeNotificationSeenEventIds,
      jsonEncode(_seenEventOrder),
    );
  }

  Future<void> _restorePendingLaunchRequest() async {
    try {
      final raw = await _secureStore.readSecret(
        SecureValueKey.runtimeNotificationPendingLaunchTarget,
      );
      if (raw == null || raw.trim().isEmpty) {
        return;
      }

      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return;
      }

      final request = RuntimeNotificationLaunchRequest.fromJson(
        decoded,
        requestId: 'launch-restored-${_launchRequestSequence++}',
      );

      state = state.copyWith(
        pendingLaunchRequests: <RuntimeNotificationLaunchRequest>[
          ...state.pendingLaunchRequests,
          request,
        ],
      );
    } on FormatException {
      // Ignore malformed persisted launch data.
    } on TypeError {
      // Ignore malformed persisted launch data.
    }
  }

  Future<void> _persistPendingLaunchRequest(
    RuntimeNotificationLaunchRequest request,
  ) {
    return _secureStore.writeSecret(
      SecureValueKey.runtimeNotificationPendingLaunchTarget,
      jsonEncode(request.toJson()),
    );
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
    unawaited(_openedNotificationPayloadSubscription?.cancel());
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

int _notificationIdForEvent(String eventId) {
  return eventId.hashCode & 0x7fffffff;
}
