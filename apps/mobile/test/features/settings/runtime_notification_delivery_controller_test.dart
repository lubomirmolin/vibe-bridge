import 'dart:async';
import 'dart:convert';

import 'package:codex_mobile_companion/features/settings/application/notification_preferences_controller.dart';
import 'package:codex_mobile_companion/features/settings/application/runtime_notification_delivery_controller.dart';
import 'package:codex_mobile_companion/features/settings/data/runtime_platform_notifications.dart';
import 'package:codex_mobile_companion/features/threads/data/thread_live_stream.dart';
import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:codex_mobile_companion/foundation/storage/secure_store.dart';
import 'package:codex_mobile_companion/foundation/storage/secure_store_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'approval notification delivery follows runtime preference changes',
    () async {
      final liveStream = FakeThreadLiveStream();
      final container = ProviderContainer(
        overrides: [
          appSecureStoreProvider.overrideWithValue(InMemorySecureStore()),
          threadLiveStreamProvider.overrideWithValue(liveStream),
        ],
      );
      addTearDown(container.dispose);

      final subscription = container.listen(
        runtimeNotificationDeliveryControllerProvider(_bridgeApiBaseUrl),
        (_, _) {},
      );
      addTearDown(subscription.close);

      await Future<void>.delayed(Duration.zero);

      liveStream.emit(
        _event(
          eventId: 'evt-approval-1',
          kind: BridgeEventKind.approvalRequested,
          payload: {
            'action': 'git_pull',
            'reason': 'Approval required for protected branch pull.',
          },
        ),
      );
      await Future<void>.delayed(Duration.zero);

      var state = container.read(
        runtimeNotificationDeliveryControllerProvider(_bridgeApiBaseUrl),
      );
      expect(state.pendingNotifications, hasLength(1));
      expect(
        state.pendingNotifications.single.kind,
        RuntimeNotificationKind.approval,
      );

      container
          .read(
            runtimeNotificationDeliveryControllerProvider(
              _bridgeApiBaseUrl,
            ).notifier,
          )
          .acknowledgeAllPending();

      await container
          .read(notificationPreferencesControllerProvider.notifier)
          .setApprovalNotificationsEnabled(false);
      await Future<void>.delayed(Duration.zero);

      liveStream.emit(
        _event(
          eventId: 'evt-approval-2',
          kind: BridgeEventKind.approvalRequested,
          payload: {
            'action': 'git_push',
            'reason': 'Suppressed while disabled',
          },
        ),
      );
      await Future<void>.delayed(Duration.zero);

      state = container.read(
        runtimeNotificationDeliveryControllerProvider(_bridgeApiBaseUrl),
      );
      expect(state.pendingNotifications, isEmpty);

      await container
          .read(notificationPreferencesControllerProvider.notifier)
          .setApprovalNotificationsEnabled(true);
      await Future<void>.delayed(Duration.zero);

      liveStream.emit(
        _event(
          eventId: 'evt-approval-3',
          kind: BridgeEventKind.approvalRequested,
          payload: {
            'action': 'git_push',
            'reason': 'Delivered after re-enable',
          },
        ),
      );
      await Future<void>.delayed(Duration.zero);

      state = container.read(
        runtimeNotificationDeliveryControllerProvider(_bridgeApiBaseUrl),
      );
      expect(state.pendingNotifications, hasLength(1));
      expect(state.pendingNotifications.single.eventId, 'evt-approval-3');
    },
  );

  test(
    'live activity notification delivery follows runtime preference changes',
    () async {
      final liveStream = FakeThreadLiveStream();
      final container = ProviderContainer(
        overrides: [
          appSecureStoreProvider.overrideWithValue(InMemorySecureStore()),
          threadLiveStreamProvider.overrideWithValue(liveStream),
        ],
      );
      addTearDown(container.dispose);

      final subscription = container.listen(
        runtimeNotificationDeliveryControllerProvider(_bridgeApiBaseUrl),
        (_, _) {},
      );
      addTearDown(subscription.close);

      await Future<void>.delayed(Duration.zero);

      await container
          .read(notificationPreferencesControllerProvider.notifier)
          .setLiveActivityNotificationsEnabled(false);
      await Future<void>.delayed(Duration.zero);

      liveStream.emit(
        _event(
          eventId: 'evt-live-1',
          kind: BridgeEventKind.messageDelta,
          payload: {
            'delta': 'Suppressed while live notifications are disabled',
          },
        ),
      );
      await Future<void>.delayed(Duration.zero);

      var state = container.read(
        runtimeNotificationDeliveryControllerProvider(_bridgeApiBaseUrl),
      );
      expect(state.pendingNotifications, isEmpty);

      await container
          .read(notificationPreferencesControllerProvider.notifier)
          .setLiveActivityNotificationsEnabled(true);
      await Future<void>.delayed(Duration.zero);

      liveStream.emit(
        _event(
          eventId: 'evt-live-2',
          kind: BridgeEventKind.threadStatusChanged,
          payload: {'status': 'completed', 'reason': 'turn_complete'},
        ),
      );
      await Future<void>.delayed(Duration.zero);

      state = container.read(
        runtimeNotificationDeliveryControllerProvider(_bridgeApiBaseUrl),
      );
      expect(state.pendingNotifications, hasLength(1));
      expect(
        state.pendingNotifications.single.kind,
        RuntimeNotificationKind.liveActivity,
      );
      expect(state.pendingNotifications.single.eventId, 'evt-live-2');
    },
  );

  test(
    'cold-start notification delivery stays fail-closed until preferences restore',
    () async {
      final persistedStore = InMemorySecureStore();
      await persistedStore.writeSecret(
        SecureValueKey.notificationPreferences,
        jsonEncode(<String, dynamic>{
          'approval_notifications_enabled': false,
          'live_activity_notifications_enabled': false,
        }),
      );

      final delayedStore = DelayedReadSecureStore(
        delegate: persistedStore,
        readDelay: const Duration(milliseconds: 25),
      );
      final liveStream = FakeThreadLiveStream();
      final container = ProviderContainer(
        overrides: [
          appSecureStoreProvider.overrideWithValue(delayedStore),
          threadLiveStreamProvider.overrideWithValue(liveStream),
        ],
      );
      addTearDown(container.dispose);

      final subscription = container.listen(
        runtimeNotificationDeliveryControllerProvider(_bridgeApiBaseUrl),
        (_, _) {},
      );
      addTearDown(subscription.close);

      await Future<void>.delayed(Duration.zero);

      liveStream.emit(
        _event(
          eventId: 'evt-cold-start-1',
          kind: BridgeEventKind.approvalRequested,
          payload: {'reason': 'Should be suppressed while settings restore'},
        ),
      );
      await Future<void>.delayed(Duration.zero);

      var state = container.read(
        runtimeNotificationDeliveryControllerProvider(_bridgeApiBaseUrl),
      );
      expect(state.preferencesRestored, isFalse);
      expect(state.pendingNotifications, isEmpty);

      await Future<void>.delayed(const Duration(milliseconds: 40));

      state = container.read(
        runtimeNotificationDeliveryControllerProvider(_bridgeApiBaseUrl),
      );
      expect(state.preferencesRestored, isTrue);
      expect(state.approvalNotificationsEnabled, isFalse);
      expect(state.liveActivityNotificationsEnabled, isFalse);
      expect(state.pendingNotifications, isEmpty);

      liveStream.emit(
        _event(
          eventId: 'evt-cold-start-2',
          kind: BridgeEventKind.approvalRequested,
          payload: {
            'reason': 'Still suppressed after disabled preferences restore',
          },
        ),
      );
      await Future<void>.delayed(Duration.zero);

      state = container.read(
        runtimeNotificationDeliveryControllerProvider(_bridgeApiBaseUrl),
      );
      expect(state.pendingNotifications, isEmpty);

      await container
          .read(notificationPreferencesControllerProvider.notifier)
          .setApprovalNotificationsEnabled(true);
      await Future<void>.delayed(Duration.zero);

      liveStream.emit(
        _event(
          eventId: 'evt-cold-start-3',
          kind: BridgeEventKind.approvalRequested,
          payload: {'reason': 'Delivered after explicit re-enable'},
        ),
      );
      await Future<void>.delayed(Duration.zero);

      state = container.read(
        runtimeNotificationDeliveryControllerProvider(_bridgeApiBaseUrl),
      );
      expect(state.pendingNotifications, hasLength(1));
      expect(state.pendingNotifications.single.eventId, 'evt-cold-start-3');
    },
  );

  test(
    'restored seen event IDs suppress duplicate notification delivery after cold start',
    () async {
      final persistedStore = InMemorySecureStore();
      await persistedStore.writeSecret(
        SecureValueKey.runtimeNotificationSeenEventIds,
        jsonEncode(<String>['evt-seen-1']),
      );

      final liveStream = FakeThreadLiveStream();
      final container = ProviderContainer(
        overrides: [
          appSecureStoreProvider.overrideWithValue(persistedStore),
          threadLiveStreamProvider.overrideWithValue(liveStream),
        ],
      );
      addTearDown(container.dispose);

      final subscription = container.listen(
        runtimeNotificationDeliveryControllerProvider(_bridgeApiBaseUrl),
        (_, _) {},
      );
      addTearDown(subscription.close);

      await Future<void>.delayed(Duration.zero);

      liveStream.emit(
        _event(
          eventId: 'evt-seen-1',
          kind: BridgeEventKind.approvalRequested,
          payload: {'reason': 'Already seen before restart'},
        ),
      );
      await Future<void>.delayed(Duration.zero);

      var state = container.read(
        runtimeNotificationDeliveryControllerProvider(_bridgeApiBaseUrl),
      );
      expect(state.pendingNotifications, isEmpty);

      liveStream.emit(
        _event(
          eventId: 'evt-seen-2',
          kind: BridgeEventKind.approvalRequested,
          payload: {'reason': 'New notification after restart'},
        ),
      );
      await Future<void>.delayed(Duration.zero);

      state = container.read(
        runtimeNotificationDeliveryControllerProvider(_bridgeApiBaseUrl),
      );
      expect(state.pendingNotifications, hasLength(1));
      expect(state.pendingNotifications.single.eventId, 'evt-seen-2');
    },
  );

  test(
    'restores and clears persisted launch requests for cold-start routing',
    () async {
      final persistedStore = InMemorySecureStore();
      await persistedStore.writeSecret(
        SecureValueKey.runtimeNotificationPendingLaunchTarget,
        jsonEncode(<String, dynamic>{
          'event_id': 'evt-launch-1',
          'target': <String, dynamic>{
            'target_type': 'thread_detail',
            'thread_id': 'thread-cold-start',
          },
        }),
      );

      final liveStream = FakeThreadLiveStream();
      final container = ProviderContainer(
        overrides: [
          appSecureStoreProvider.overrideWithValue(persistedStore),
          threadLiveStreamProvider.overrideWithValue(liveStream),
        ],
      );
      addTearDown(container.dispose);

      final subscription = container.listen(
        runtimeNotificationDeliveryControllerProvider(_bridgeApiBaseUrl),
        (_, _) {},
      );
      addTearDown(subscription.close);

      await Future<void>.delayed(Duration.zero);

      final state = container.read(
        runtimeNotificationDeliveryControllerProvider(_bridgeApiBaseUrl),
      );
      expect(state.pendingLaunchRequests, hasLength(1));
      expect(state.pendingLaunchRequests.single.eventId, 'evt-launch-1');
      expect(
        state.pendingLaunchRequests.single.target.threadId,
        'thread-cold-start',
      );

      final controller = container.read(
        runtimeNotificationDeliveryControllerProvider(
          _bridgeApiBaseUrl,
        ).notifier,
      );
      await controller.acknowledgeLaunchRequest(
        state.pendingLaunchRequests.single.requestId,
      );

      final nextState = container.read(
        runtimeNotificationDeliveryControllerProvider(_bridgeApiBaseUrl),
      );
      expect(nextState.pendingLaunchRequests, isEmpty);
      expect(
        await persistedStore.readSecret(
          SecureValueKey.runtimeNotificationPendingLaunchTarget,
        ),
        isNull,
      );
    },
  );

  test(
    'cold-start launch payload from platform notification is restored without pre-seeded secure-store launch state',
    () async {
      final liveStream = FakeThreadLiveStream();
      final platformNotifications = FakeRuntimePlatformNotifications(
        bootstrap: const RuntimePlatformNotificationBootstrap(
          systemNotificationsAvailable: true,
          initialLaunchPayload:
              '{"event_id":"evt-platform-cold-start","target":{"target_type":"thread_detail","thread_id":"thread-platform-cold-start"}}',
        ),
      );

      final container = ProviderContainer(
        overrides: [
          appSecureStoreProvider.overrideWithValue(InMemorySecureStore()),
          threadLiveStreamProvider.overrideWithValue(liveStream),
          runtimePlatformNotificationsProvider.overrideWithValue(
            platformNotifications,
          ),
        ],
      );
      addTearDown(container.dispose);

      final subscription = container.listen(
        runtimeNotificationDeliveryControllerProvider(_bridgeApiBaseUrl),
        (_, _) {},
      );
      addTearDown(subscription.close);

      await Future<void>.delayed(Duration.zero);

      final state = container.read(
        runtimeNotificationDeliveryControllerProvider(_bridgeApiBaseUrl),
      );
      expect(state.pendingLaunchRequests, hasLength(1));
      expect(
        state.pendingLaunchRequests.single.eventId,
        'evt-platform-cold-start',
      );
      expect(
        state.pendingLaunchRequests.single.target.threadId,
        'thread-platform-cold-start',
      );
    },
  );

  test(
    'system-notification delivery posts to platform and opens through platform payload callbacks',
    () async {
      final liveStream = FakeThreadLiveStream();
      final platformNotifications = FakeRuntimePlatformNotifications(
        bootstrap: const RuntimePlatformNotificationBootstrap(
          systemNotificationsAvailable: true,
        ),
      );

      final container = ProviderContainer(
        overrides: [
          appSecureStoreProvider.overrideWithValue(InMemorySecureStore()),
          threadLiveStreamProvider.overrideWithValue(liveStream),
          runtimePlatformNotificationsProvider.overrideWithValue(
            platformNotifications,
          ),
        ],
      );
      addTearDown(container.dispose);

      final subscription = container.listen(
        runtimeNotificationDeliveryControllerProvider(_bridgeApiBaseUrl),
        (_, _) {},
      );
      addTearDown(subscription.close);

      await Future<void>.delayed(Duration.zero);

      liveStream.emit(
        _event(
          eventId: 'evt-platform-open-1',
          kind: BridgeEventKind.approvalRequested,
          payload: {
            'approval_id': 'approval-123',
            'thread_id': 'thread-123',
            'reason': 'Approval from platform notification path.',
          },
        ),
      );
      await Future<void>.delayed(Duration.zero);

      var state = container.read(
        runtimeNotificationDeliveryControllerProvider(_bridgeApiBaseUrl),
      );
      expect(state.pendingNotifications, isEmpty);
      expect(platformNotifications.shownNotifications, hasLength(1));

      platformNotifications.emitOpenedPayload(
        '{"event_id":"evt-platform-open-1","target":{"target_type":"approval_detail","thread_id":"thread-123","approval_id":"approval-123"}}',
      );
      await Future<void>.delayed(Duration.zero);

      state = container.read(
        runtimeNotificationDeliveryControllerProvider(_bridgeApiBaseUrl),
      );
      expect(state.pendingLaunchRequests, hasLength(1));
      expect(state.pendingLaunchRequests.single.eventId, 'evt-platform-open-1');
      expect(
        state.pendingLaunchRequests.single.target.type,
        RuntimeNotificationTargetType.approvalDetail,
      );
      expect(
        state.pendingLaunchRequests.single.target.approvalId,
        'approval-123',
      );
    },
  );
}

const _bridgeApiBaseUrl = 'https://bridge.ts.net';

BridgeEventEnvelope<Map<String, dynamic>> _event({
  required String eventId,
  required BridgeEventKind kind,
  required Map<String, dynamic> payload,
}) {
  return BridgeEventEnvelope<Map<String, dynamic>>(
    contractVersion: contractVersion,
    eventId: eventId,
    threadId: 'thread-123',
    kind: kind,
    occurredAt: '2026-03-18T12:00:00Z',
    payload: payload,
  );
}

class FakeThreadLiveStream implements ThreadLiveStream {
  final List<StreamController<BridgeEventEnvelope<Map<String, dynamic>>>>
  _controllers =
      <StreamController<BridgeEventEnvelope<Map<String, dynamic>>>>[];

  @override
  Future<ThreadLiveSubscription> subscribe({
    required String bridgeApiBaseUrl,
    String? threadId,
  }) async {
    final controller =
        StreamController<BridgeEventEnvelope<Map<String, dynamic>>>();
    _controllers.add(controller);

    return ThreadLiveSubscription(
      events: controller.stream,
      close: () async {
        _controllers.remove(controller);
        if (!controller.isClosed) {
          await controller.close();
        }
      },
    );
  }

  void emit(BridgeEventEnvelope<Map<String, dynamic>> event) {
    for (final controller
        in List<
          StreamController<BridgeEventEnvelope<Map<String, dynamic>>>
        >.from(_controllers)) {
      if (!controller.isClosed) {
        controller.add(event);
      }
    }
  }
}

class DelayedReadSecureStore implements SecureStore {
  DelayedReadSecureStore({
    required InMemorySecureStore delegate,
    required Duration readDelay,
  }) : _delegate = delegate,
       _readDelay = readDelay;

  final InMemorySecureStore _delegate;
  final Duration _readDelay;

  @override
  Future<String?> readSecret(SecureValueKey key) async {
    await Future<void>.delayed(_readDelay);
    return _delegate.readSecret(key);
  }

  @override
  Future<void> writeSecret(SecureValueKey key, String value) {
    return _delegate.writeSecret(key, value);
  }

  @override
  Future<void> removeSecret(SecureValueKey key) {
    return _delegate.removeSecret(key);
  }
}

class FakeRuntimePlatformNotifications implements RuntimePlatformNotifications {
  FakeRuntimePlatformNotifications({
    required RuntimePlatformNotificationBootstrap bootstrap,
  }) : _bootstrap = bootstrap;

  final RuntimePlatformNotificationBootstrap _bootstrap;
  final List<({int notificationId, String title, String body, String payload})>
  shownNotifications =
      <({int notificationId, String title, String body, String payload})>[];

  final StreamController<String> _openedPayloadController =
      StreamController<String>.broadcast();

  @override
  Stream<String> get openedPayloads => _openedPayloadController.stream;

  @override
  Future<RuntimePlatformNotificationBootstrap> initialize() async {
    return _bootstrap;
  }

  @override
  Future<bool> showNotification({
    required int notificationId,
    required String title,
    required String body,
    required String payload,
  }) async {
    shownNotifications.add((
      notificationId: notificationId,
      title: title,
      body: body,
      payload: payload,
    ));
    return _bootstrap.systemNotificationsAvailable;
  }

  void emitOpenedPayload(String payload) {
    _openedPayloadController.add(payload);
  }

  @override
  Future<void> dispose() async {
    await _openedPayloadController.close();
  }
}
