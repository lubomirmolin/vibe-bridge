import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final runtimeAccessModeProvider = StateProvider.family<AccessMode?, String>(
  (ref, bridgeApiBaseUrl) => null,
);
