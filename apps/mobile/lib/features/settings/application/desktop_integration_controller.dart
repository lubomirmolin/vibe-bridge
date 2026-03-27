import 'dart:async';

import 'package:vibe_bridge/foundation/storage/secure_store.dart';
import 'package:vibe_bridge/foundation/storage/secure_store_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final desktopIntegrationControllerProvider =
    StateNotifierProvider<
      DesktopIntegrationController,
      DesktopIntegrationState
    >((ref) {
      return DesktopIntegrationController(
        secureStore: ref.watch(appSecureStoreProvider),
      );
    });

class DesktopIntegrationState {
  const DesktopIntegrationState({this.isEnabled = true, this.isLoading = true});

  final bool isEnabled;
  final bool isLoading;

  DesktopIntegrationState copyWith({bool? isEnabled, bool? isLoading}) {
    return DesktopIntegrationState(
      isEnabled: isEnabled ?? this.isEnabled,
      isLoading: isLoading ?? this.isLoading,
    );
  }
}

class DesktopIntegrationController
    extends StateNotifier<DesktopIntegrationState> {
  DesktopIntegrationController({required SecureStore secureStore})
    : _secureStore = secureStore,
      super(const DesktopIntegrationState()) {
    unawaited(_restore());
  }

  final SecureStore _secureStore;

  Future<void> setEnabled(bool enabled) async {
    state = state.copyWith(isEnabled: enabled, isLoading: false);
    await _secureStore.writeSecret(
      SecureValueKey.desktopIntegrationEnabled,
      enabled.toString(),
    );
  }

  Future<void> _restore() async {
    final persistedValue = await _secureStore.readSecret(
      SecureValueKey.desktopIntegrationEnabled,
    );
    if (persistedValue == null || persistedValue.trim().isEmpty) {
      state = state.copyWith(isLoading: false);
      return;
    }

    final normalizedValue = persistedValue.trim().toLowerCase();
    state = state.copyWith(
      isEnabled: normalizedValue != 'false',
      isLoading: false,
    );
  }
}
