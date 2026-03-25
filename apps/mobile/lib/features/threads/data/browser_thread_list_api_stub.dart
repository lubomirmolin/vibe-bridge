import 'package:codex_mobile_companion/features/threads/data/browser_thread_list_api.dart';
import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';

BrowserThreadListApi createBrowserThreadListApi() {
  return const UnsupportedBrowserThreadListApi();
}

class UnsupportedBrowserThreadListApi implements BrowserThreadListApi {
  const UnsupportedBrowserThreadListApi();

  @override
  Future<List<ThreadSummaryDto>> fetchThreads({
    required String bridgeApiBaseUrl,
  }) async {
    throw const BrowserThreadListException(
      'Browser thread list is unavailable on this platform.',
    );
  }
}

class BrowserThreadListException implements Exception {
  const BrowserThreadListException(this.message);

  final String message;

  @override
  String toString() => message;
}
