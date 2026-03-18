import 'package:codex_mobile_companion/foundation/storage/secure_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final appSecureStoreProvider = Provider<SecureStore>((ref) {
  return PersistedSecureStore();
});
