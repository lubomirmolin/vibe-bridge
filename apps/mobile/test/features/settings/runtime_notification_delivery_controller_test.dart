import 'dart:async';
import 'dart:convert';

import 'package:codex_mobile_companion/features/settings/application/notification_preferences_controller.dart';
import 'package:codex_mobile_companion/features/settings/application/runtime_notification_delivery_controller.dart';
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
