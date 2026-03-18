import 'dart:async';
import 'dart:convert';

import 'package:codex_mobile_companion/foundation/storage/secure_store.dart';
import 'package:codex_mobile_companion/foundation/storage/secure_store_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final notificationPreferencesControllerProvider =
    StateNotifierProvider<
      NotificationPreferencesController,
      NotificationPreferencesState
    >((ref) {
      return NotificationPreferencesController(
        secureStore: ref.watch(appSecureStoreProvider),
      );
    });

class NotificationPreferencesState {
  const NotificationPreferencesState({
    this.approvalNotificationsEnabled = true,
    this.liveActivityNotificationsEnabled = true,
    this.isLoading = true,
  });

  final bool approvalNotificationsEnabled;
  final bool liveActivityNotificationsEnabled;
  final bool isLoading;

  NotificationPreferencesState copyWith({
    bool? approvalNotificationsEnabled,
    bool? liveActivityNotificationsEnabled,
    bool? isLoading,
  }) {
    return NotificationPreferencesState(
      approvalNotificationsEnabled:
          approvalNotificationsEnabled ?? this.approvalNotificationsEnabled,
      liveActivityNotificationsEnabled:
          liveActivityNotificationsEnabled ??
          this.liveActivityNotificationsEnabled,
      isLoading: isLoading ?? this.isLoading,
    );
  }
}

class NotificationPreferencesController
    extends StateNotifier<NotificationPreferencesState> {
  NotificationPreferencesController({required SecureStore secureStore})
    : _secureStore = secureStore,
      super(const NotificationPreferencesState()) {
    unawaited(_restore());
  }

  final SecureStore _secureStore;

  Future<void> setApprovalNotificationsEnabled(bool enabled) async {
    state = state.copyWith(
      approvalNotificationsEnabled: enabled,
      isLoading: false,
    );
    await _persist();
  }

  Future<void> setLiveActivityNotificationsEnabled(bool enabled) async {
    state = state.copyWith(
      liveActivityNotificationsEnabled: enabled,
      isLoading: false,
    );
    await _persist();
  }

  Future<void> _restore() async {
    final raw = await _secureStore.readSecret(
      SecureValueKey.notificationPreferences,
    );
    if (raw == null || raw.trim().isEmpty) {
      state = state.copyWith(isLoading: false);
      return;
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException(
          'Notification preferences must be an object.',
        );
      }

      state = state.copyWith(
        approvalNotificationsEnabled:
            decoded['approval_notifications_enabled'] as bool? ?? true,
        liveActivityNotificationsEnabled:
            decoded['live_activity_notifications_enabled'] as bool? ?? true,
        isLoading: false,
      );
    } on FormatException {
      state = state.copyWith(isLoading: false);
    } on TypeError {
      state = state.copyWith(isLoading: false);
    }
  }

  Future<void> _persist() {
    final payload = jsonEncode(<String, dynamic>{
      'approval_notifications_enabled': state.approvalNotificationsEnabled,
      'live_activity_notifications_enabled':
          state.liveActivityNotificationsEnabled,
    });

    return _secureStore.writeSecret(
      SecureValueKey.notificationPreferences,
      payload,
    );
  }
}
