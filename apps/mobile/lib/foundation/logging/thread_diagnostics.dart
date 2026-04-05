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
  ThreadDiagnosticsService();

  static const int _maxRecords = 1200;

  final String _sessionId = DateTime.now().microsecondsSinceEpoch.toString();
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

  Future<String> export({String? threadId, int limit = 500}) async {
    final file = await _resolveLogFile();
    if (!await file.exists()) {
      return '';
    }

    final lines = await file.readAsLines();
    final normalizedThreadId = threadId?.trim();
    final filtered = <String>[];
    for (final line in lines.reversed) {
      if (line.trim().isEmpty) {
        continue;
      }
      if (normalizedThreadId != null && normalizedThreadId.isNotEmpty) {
        try {
          final decoded = jsonDecode(line);
          if (decoded is Map<String, dynamic>) {
            final recordThreadId = (decoded['threadId'] as String?)?.trim();
            if (recordThreadId != normalizedThreadId) {
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

    return filtered.reversed.join('\n');
  }

  Future<void> clear() async {
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
    return _logFileFuture ??= () async {
      final directory = await getApplicationSupportDirectory();
      return File('${directory.path}/thread_diagnostics.ndjson');
    }();
  }

  Future<void> _trimIfNeeded(File file) async {
    final lines = await file.readAsLines();
    if (lines.length <= _maxRecords) {
      return;
    }
    final retained = lines.sublist(lines.length - _maxRecords);
    await file.writeAsString('${retained.join('\n')}\n');
  }
}
