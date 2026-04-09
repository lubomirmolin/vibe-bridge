import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

final threadDiagnosticsServiceProvider = Provider<ThreadDiagnosticsService>((
  ref,
) {
  final service = ThreadDiagnosticsService();
  ref.onDispose(service.dispose);
  return service;
});

class ThreadDiagnosticsService {
  ThreadDiagnosticsService({Future<File> Function()? logFileResolver})
    : _logFileResolver = logFileResolver ?? _defaultLogFileResolver;

  static const int _maxRecords = 1200;

  final String _sessionId = DateTime.now().microsecondsSinceEpoch.toString();
  final Future<File> Function() _logFileResolver;
  Future<void> _pendingWrite = Future<void>.value();
  Future<File>? _logFileFuture;
  bool _isDisposed = false;

  String get sessionId => _sessionId;

  Future<void> record({
    required String kind,
    String? threadId,
    Map<String, Object?> data = const <String, Object?>{},
  }) {
    if (_isDisposed) {
      return Future<void>.value();
    }

    final payload = <String, Object?>{
      'ts': DateTime.now().toUtc().toIso8601String(),
      'sessionId': _sessionId,
      'kind': kind,
      'threadId': threadId?.trim().isEmpty ?? true ? null : threadId?.trim(),
      'data': data,
    };
    final encoded = jsonEncode(payload);

    _pendingWrite = _pendingWrite
        .then((_) async {
          final file = await _resolveLogFile();
          await file.parent.create(recursive: true);
          await file.writeAsString('$encoded\n', mode: FileMode.append);
          await _trimIfNeeded(file);
        })
        .catchError((Object _) {
          // Diagnostics should never break product behavior.
        });
    return _pendingWrite;
  }

  Future<String> export({
    String? threadId,
    int limit = 500,
    bool includeFallbackRecent = false,
    int fallbackLimit = 200,
  }) async {
    await _flushPendingWrites();
    final file = await _resolveLogFile();
    if (!await file.exists()) {
      return '';
    }

    final lines = await file.readAsLines();
    final normalizedThreadId = threadId?.trim();
    final filtered = _collectLines(
      lines,
      threadId: normalizedThreadId,
      limit: limit,
    );
    if (filtered.isNotEmpty ||
        !includeFallbackRecent ||
        normalizedThreadId == null ||
        normalizedThreadId.isEmpty) {
      return filtered.reversed.join('\n');
    }

    final fallback = _collectLines(lines, limit: fallbackLimit);
    if (fallback.isEmpty) {
      return '';
    }

    return [
      'No exact diagnostics matched threadId=$normalizedThreadId. Showing recent session diagnostics instead.',
      '',
      ...fallback.reversed,
    ].join('\n');
  }

  Future<void> clear() async {
    await _flushPendingWrites();
    final file = await _resolveLogFile();
    if (await file.exists()) {
      await file.writeAsString('');
    }
  }

  Future<String> describeLogLocation() async {
    final file = await _resolveLogFile();
    return file.path;
  }

  void dispose() {
    _isDisposed = true;
  }

  Future<File> _resolveLogFile() {
    return _logFileFuture ??= _logFileResolver();
  }

  Future<void> _trimIfNeeded(File file) async {
    final lines = await file.readAsLines();
    if (lines.length <= _maxRecords) {
      return;
    }
    final retained = lines.sublist(lines.length - _maxRecords);
    await file.writeAsString('${retained.join('\n')}\n');
  }

  Future<void> _flushPendingWrites() async {
    await _pendingWrite;
  }
}

List<String> _collectLines(
  List<String> lines, {
  String? threadId,
  required int limit,
}) {
  final filtered = <String>[];
  for (final line in lines.reversed) {
    if (line.trim().isEmpty) {
      continue;
    }
    if (threadId != null && threadId.isNotEmpty) {
      try {
        final decoded = jsonDecode(line);
        if (decoded is Map<String, dynamic>) {
          final recordThreadId = (decoded['threadId'] as String?)?.trim();
          if (recordThreadId != threadId) {
            continue;
          }
        }
      } catch (_) {
        continue;
      }
    }
    filtered.add(line);
    if (filtered.length >= limit) {
      break;
    }
  }
  return filtered;
}

Future<File> _defaultLogFileResolver() async {
  final directory = await getApplicationSupportDirectory();
  return File('${directory.path}/thread_diagnostics.ndjson');
}
