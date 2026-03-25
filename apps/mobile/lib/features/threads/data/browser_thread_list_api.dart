import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'browser_thread_list_api_stub.dart'
    if (dart.library.html) 'browser_thread_list_api_web.dart'
    as impl;

abstract class BrowserThreadListApi {
  Future<List<ThreadSummaryDto>> fetchThreads({
    required String bridgeApiBaseUrl,
  });
}

final browserThreadListApiProvider = Provider<BrowserThreadListApi>((ref) {
  return impl.createBrowserThreadListApi();
});
