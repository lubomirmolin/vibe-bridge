import 'dart:convert';

import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:codex_mobile_companion/foundation/storage/secure_store.dart';
import 'package:codex_mobile_companion/foundation/storage/secure_store_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final threadCacheRepositoryProvider = Provider<ThreadCacheRepository>((ref) {
  return SecureStoreThreadCacheRepository(
    secureStore: ref.watch(appSecureStoreProvider),
    nowUtc: () => DateTime.now().toUtc(),
  );
});

class CachedThreadListSnapshot {
  const CachedThreadListSnapshot({
    required this.cachedAtUtc,
    required this.threads,
  });

  final DateTime cachedAtUtc;
  final List<ThreadSummaryDto> threads;
}

class CachedThreadDetailSnapshot {
  const CachedThreadDetailSnapshot({
    required this.cachedAtUtc,
    required this.detail,
    required this.timeline,
  });

  final DateTime cachedAtUtc;
  final ThreadDetailDto detail;
  final List<ThreadTimelineEntryDto> timeline;
}

abstract class ThreadCacheRepository {
  Future<void> saveThreadList(List<ThreadSummaryDto> threads);

  Future<CachedThreadListSnapshot?> readThreadList();

  Future<void> saveThreadDetail({
    required ThreadDetailDto detail,
    required List<ThreadTimelineEntryDto> timeline,
  });

  Future<CachedThreadDetailSnapshot?> readThreadDetail(String threadId);

  Future<void> saveSelectedThreadId(String threadId);

  Future<String?> readSelectedThreadId();
}

class SecureStoreThreadCacheRepository implements ThreadCacheRepository {
  SecureStoreThreadCacheRepository({
    required SecureStore secureStore,
    required DateTime Function() nowUtc,
  }) : _secureStore = secureStore,
       _nowUtc = nowUtc;

  final SecureStore _secureStore;
  final DateTime Function() _nowUtc;

  @override
  Future<void> saveThreadList(List<ThreadSummaryDto> threads) async {
    final payload = <String, dynamic>{
      'cached_at_epoch_seconds': _nowUtc().millisecondsSinceEpoch ~/ 1000,
      'threads': threads
          .map((thread) => thread.toJson())
          .toList(growable: false),
    };

    await _secureStore.writeSecret(
      SecureValueKey.threadListCache,
      jsonEncode(payload),
    );
  }

  @override
  Future<CachedThreadListSnapshot?> readThreadList() async {
    final raw = await _secureStore.readSecret(SecureValueKey.threadListCache);
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return null;
      }

      final cachedAtUtc = _readCachedAt(decoded);
      final threadsJson = decoded['threads'];
      if (threadsJson is! List) {
        return null;
      }

      final threads = threadsJson
          .map((entry) {
            if (entry is! Map<String, dynamic>) {
              throw const FormatException(
                'Thread cache entry must be an object.',
              );
            }
            return ThreadSummaryDto.fromJson(entry);
          })
          .toList(growable: false);

      return CachedThreadListSnapshot(
        cachedAtUtc: cachedAtUtc,
        threads: threads,
      );
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> saveThreadDetail({
    required ThreadDetailDto detail,
    required List<ThreadTimelineEntryDto> timeline,
  }) async {
    final detailsCache = await _readMutableDetailsCache();
    final threads = _readMutableThreadMap(detailsCache);

    threads[detail.threadId] = <String, dynamic>{
      'cached_at_epoch_seconds': _nowUtc().millisecondsSinceEpoch ~/ 1000,
      'detail': detail.toJson(),
      'timeline': timeline
          .map((event) => event.toJson())
          .toList(growable: false),
    };

    await _secureStore.writeSecret(
      SecureValueKey.threadDetailsCache,
      jsonEncode(detailsCache),
    );
  }

  @override
  Future<CachedThreadDetailSnapshot?> readThreadDetail(String threadId) async {
    final detailsCache = await _readMutableDetailsCache();
    final threads = _readMutableThreadMap(detailsCache);
    final entry = threads[threadId];
    if (entry is! Map<String, dynamic>) {
      return null;
    }

    try {
      final cachedAtUtc = _readCachedAt(entry);
      final detailJson = entry['detail'];
      final timelineJson = entry['timeline'];

      if (detailJson is! Map<String, dynamic> || timelineJson is! List) {
        return null;
      }

      final timeline = timelineJson
          .map((event) {
            if (event is! Map<String, dynamic>) {
              throw const FormatException(
                'Timeline cache entry must be an object.',
              );
            }
            return ThreadTimelineEntryDto.fromJson(event);
          })
          .toList(growable: false);

      return CachedThreadDetailSnapshot(
        cachedAtUtc: cachedAtUtc,
        detail: ThreadDetailDto.fromJson(detailJson),
        timeline: timeline,
      );
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> saveSelectedThreadId(String threadId) async {
    final normalizedThreadId = threadId.trim();
    if (normalizedThreadId.isEmpty) {
      await _secureStore.removeSecret(SecureValueKey.selectedThreadId);
      return;
    }

    await _secureStore.writeSecret(
      SecureValueKey.selectedThreadId,
      normalizedThreadId,
    );
  }

  @override
  Future<String?> readSelectedThreadId() async {
    final raw = await _secureStore.readSecret(SecureValueKey.selectedThreadId);
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }

    return raw.trim();
  }

  Future<Map<String, dynamic>> _readMutableDetailsCache() async {
    final raw = await _secureStore.readSecret(
      SecureValueKey.threadDetailsCache,
    );
    if (raw == null || raw.trim().isEmpty) {
      return <String, dynamic>{'threads': <String, dynamic>{}};
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return <String, dynamic>{'threads': <String, dynamic>{}};
      }

      final threads = decoded['threads'];
      if (threads is Map<String, dynamic>) {
        return <String, dynamic>{'threads': Map<String, dynamic>.from(threads)};
      }

      return <String, dynamic>{'threads': <String, dynamic>{}};
    } on FormatException {
      return <String, dynamic>{'threads': <String, dynamic>{}};
    }
  }

  Map<String, dynamic> _readMutableThreadMap(Map<String, dynamic> cache) {
    final threads = cache['threads'];
    if (threads is! Map<String, dynamic>) {
      final nextThreads = <String, dynamic>{};
      cache['threads'] = nextThreads;
      return nextThreads;
    }

    return threads;
  }
}

DateTime _readCachedAt(Map<String, dynamic> json) {
  final epochSeconds = json['cached_at_epoch_seconds'];
  if (epochSeconds is! int) {
    throw const FormatException('Missing cache timestamp.');
  }

  return DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000, isUtc: true);
}
