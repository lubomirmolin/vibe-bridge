import 'package:vibe_bridge/foundation/contracts/bridge_contracts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final runtimeAccessModeProvider = StateProvider.family<AccessMode?, String>(
  (ref, bridgeApiBaseUrl) => null,
);
