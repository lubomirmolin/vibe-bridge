import 'dart:async';

import 'package:codex_mobile_companion/features/pairing/domain/pairing_qr_payload.dart';
import 'package:codex_mobile_companion/features/settings/application/runtime_access_mode.dart';
import 'package:codex_mobile_companion/features/settings/data/settings_bridge_api.dart';
import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:codex_mobile_companion/foundation/storage/secure_store.dart';
import 'package:codex_mobile_companion/foundation/storage/secure_store_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final deviceSettingsControllerProvider = StateNotifierProvider.autoDispose
    .family<DeviceSettingsController, DeviceSettingsState, String>((
      ref,
      bridgeApiBaseUrl,
    ) {
      return DeviceSettingsController(
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        bridgeApi: ref.watch(settingsBridgeApiProvider),
        secureStore: ref.watch(appSecureStoreProvider),
        onAccessModeChanged: (accessMode) {
          ref.read(runtimeAccessModeProvider(bridgeApiBaseUrl).notifier).state =
              accessMode;
        },
      );
    });

class DeviceSettingsState {
  const DeviceSettingsState({
    this.accessMode,
    this.securityEvents = const <SecurityEventRecordDto>[],
    this.isAccessModeLoading = true,
    this.isAccessModeUpdating = false,
    this.isSecurityEventsLoading = true,
    this.accessModeErrorMessage,
    this.securityEventsErrorMessage,
  });

  final AccessMode? accessMode;
  final List<SecurityEventRecordDto> securityEvents;
  final bool isAccessModeLoading;
  final bool isAccessModeUpdating;
  final bool isSecurityEventsLoading;
  final String? accessModeErrorMessage;
  final String? securityEventsErrorMessage;

  DeviceSettingsState copyWith({
    AccessMode? accessMode,
    bool clearAccessMode = false,
    List<SecurityEventRecordDto>? securityEvents,
    bool? isAccessModeLoading,
    bool? isAccessModeUpdating,
    bool? isSecurityEventsLoading,
    String? accessModeErrorMessage,
    bool clearAccessModeErrorMessage = false,
    String? securityEventsErrorMessage,
    bool clearSecurityEventsErrorMessage = false,
  }) {
    return DeviceSettingsState(
      accessMode: clearAccessMode ? null : (accessMode ?? this.accessMode),
      securityEvents: securityEvents ?? this.securityEvents,
      isAccessModeLoading: isAccessModeLoading ?? this.isAccessModeLoading,
      isAccessModeUpdating: isAccessModeUpdating ?? this.isAccessModeUpdating,
      isSecurityEventsLoading:
          isSecurityEventsLoading ?? this.isSecurityEventsLoading,
      accessModeErrorMessage: clearAccessModeErrorMessage
          ? null
          : (accessModeErrorMessage ?? this.accessModeErrorMessage),
      securityEventsErrorMessage: clearSecurityEventsErrorMessage
          ? null
          : (securityEventsErrorMessage ?? this.securityEventsErrorMessage),
    );
  }
}

class DeviceSettingsController extends StateNotifier<DeviceSettingsState> {
  DeviceSettingsController({
    required String bridgeApiBaseUrl,
    required SettingsBridgeApi bridgeApi,
    required SecureStore secureStore,
    required void Function(AccessMode accessMode) onAccessModeChanged,
  }) : _bridgeApiBaseUrl = bridgeApiBaseUrl,
       _bridgeApi = bridgeApi,
       _secureStore = secureStore,
       _onAccessModeChanged = onAccessModeChanged,
       super(const DeviceSettingsState()) {
    unawaited(refresh());
  }

  final String _bridgeApiBaseUrl;
  final SettingsBridgeApi _bridgeApi;
  final SecureStore _secureStore;
  final void Function(AccessMode accessMode) _onAccessModeChanged;

  Future<void> refresh() async {
    await Future.wait<void>([
      refreshAccessMode(showLoading: true),
      refreshSecurityEvents(showLoading: true),
    ]);
  }

  Future<void> refreshAccessMode({bool showLoading = true}) async {
    if (showLoading) {
      state = state.copyWith(
        isAccessModeLoading: true,
        clearAccessModeErrorMessage: true,
      );
    }

    try {
      final accessMode = await _bridgeApi.fetchAccessMode(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
      );

      _onAccessModeChanged(accessMode);
      state = state.copyWith(
        accessMode: accessMode,
        isAccessModeLoading: false,
        clearAccessModeErrorMessage: true,
      );
    } on SettingsBridgeException catch (error) {
      state = state.copyWith(
        isAccessModeLoading: false,
        accessModeErrorMessage: error.message,
      );
    } catch (_) {
      state = state.copyWith(
        isAccessModeLoading: false,
        accessModeErrorMessage: 'Couldn’t load access mode right now.',
      );
    }
  }

  Future<bool> setAccessMode({
    required AccessMode accessMode,
    required TrustedBridgeIdentity trustedBridge,
  }) async {
    if (state.isAccessModeUpdating) {
      return false;
    }

    final phoneId = await _secureStore.readSecret(
      SecureValueKey.pairingPrivateKey,
    );
    final sessionToken = await _secureStore.readSecret(
      SecureValueKey.sessionToken,
    );
    if (phoneId == null ||
        phoneId.trim().isEmpty ||
        sessionToken == null ||
        sessionToken.trim().isEmpty) {
      state = state.copyWith(
        accessModeErrorMessage:
            'Trusted session data is missing. Re-pair this phone from your Mac.',
      );
      return false;
    }

    state = state.copyWith(
      isAccessModeUpdating: true,
      clearAccessModeErrorMessage: true,
    );

    try {
      final updatedMode = await _bridgeApi.setAccessMode(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
        accessMode: accessMode,
        phoneId: phoneId.trim(),
        bridgeId: trustedBridge.bridgeId,
        sessionToken: sessionToken.trim(),
        actor: 'mobile-settings',
      );

      _onAccessModeChanged(updatedMode);
      state = state.copyWith(
        accessMode: updatedMode,
        isAccessModeUpdating: false,
        clearAccessModeErrorMessage: true,
      );
      return true;
    } on SettingsBridgeException catch (error) {
      state = state.copyWith(
        isAccessModeUpdating: false,
        accessModeErrorMessage: error.message,
      );
      return false;
    } catch (_) {
      state = state.copyWith(
        isAccessModeUpdating: false,
        accessModeErrorMessage: 'Couldn’t update access mode right now.',
      );
      return false;
    }
  }

  Future<void> refreshSecurityEvents({bool showLoading = true}) async {
    if (showLoading) {
      state = state.copyWith(
        isSecurityEventsLoading: true,
        clearSecurityEventsErrorMessage: true,
      );
    }

    try {
      final events = await _bridgeApi.fetchSecurityEvents(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
      );
      final sortedEvents = events.toList(growable: false)
        ..sort(_compareSecurityEventsNewestFirst);

      state = state.copyWith(
        securityEvents: sortedEvents,
        isSecurityEventsLoading: false,
        clearSecurityEventsErrorMessage: true,
      );
    } on SettingsBridgeException catch (error) {
      state = state.copyWith(
        isSecurityEventsLoading: false,
        securityEventsErrorMessage: error.message,
      );
    } catch (_) {
      state = state.copyWith(
        isSecurityEventsLoading: false,
        securityEventsErrorMessage:
            'Couldn’t load recent security events right now.',
      );
    }
  }
}

int _compareSecurityEventsNewestFirst(
  SecurityEventRecordDto left,
  SecurityEventRecordDto right,
) {
  final leftTimestamp = DateTime.tryParse(left.event.occurredAt)?.toUtc();
  final rightTimestamp = DateTime.tryParse(right.event.occurredAt)?.toUtc();

  if (leftTimestamp != null && rightTimestamp != null) {
    final byTimestamp = rightTimestamp.compareTo(leftTimestamp);
    if (byTimestamp != 0) {
      return byTimestamp;
    }
  } else if (leftTimestamp != null) {
    return -1;
  } else if (rightTimestamp != null) {
    return 1;
  }

  return right.event.occurredAt.compareTo(left.event.occurredAt);
}
