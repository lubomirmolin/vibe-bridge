import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'browser_thread_detail_api_stub.dart'
    if (dart.library.html) 'browser_thread_detail_api_web.dart';
import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';

final browserThreadDetailApiProvider = Provider<BrowserThreadDetailApi>((ref) {
  return createBrowserThreadDetailApi();
});

abstract class BrowserThreadDetailApi {
  Future<ThreadSnapshotDto> fetchThreadSnapshot({
    required String bridgeApiBaseUrl,
    required String threadId,
  });

  Future<AccessMode> fetchAccessMode({required String bridgeApiBaseUrl});

  Future<AccessMode> setAccessMode({
    required String bridgeApiBaseUrl,
    required AccessMode accessMode,
  });

  Future<TurnMutationAcceptedDto> startTurn({
    required String bridgeApiBaseUrl,
    required String threadId,
    required String prompt,
  });

  Future<TurnMutationAcceptedDto> interruptTurn({
    required String bridgeApiBaseUrl,
    required String threadId,
  });
}

class BrowserThreadDetailException implements Exception {
  const BrowserThreadDetailException(this.message);

  final String message;

  @override
  String toString() => message;
}
