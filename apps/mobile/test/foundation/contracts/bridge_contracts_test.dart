import 'dart:convert';
import 'dart:io';

import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:flutter_test/flutter_test.dart';

String _repoRootPath() {
  final current = Directory.current;
  if (File('${current.path}/pubspec.yaml').existsSync()) {
    return current.parent.parent.path;
  }

  return current.path;
}

void main() {
  test('thread summary fixture maps to shared DTO contract', () {
    final fixturePath =
        '${_repoRootPath()}/shared/contracts/fixtures/thread_summary.json';
    final fixtureJson =
        jsonDecode(File(fixturePath).readAsStringSync())
            as Map<String, dynamic>;

    final summary = ThreadSummaryDto.fromJson(fixtureJson);

    expect(summary.contractVersion, contractVersion);
    expect(summary.threadId, 'thread-123');
    expect(summary.status, ThreadStatus.running);
    expect(summary.repository, 'codex-mobile-companion');
  });

  test('bridge event fixture maps to shared envelope', () {
    final fixturePath =
        '${_repoRootPath()}/shared/contracts/fixtures/bridge_event_message_delta.json';
    final fixtureJson =
        jsonDecode(File(fixturePath).readAsStringSync())
            as Map<String, dynamic>;

    final event = BridgeEventEnvelope<Map<String, dynamic>>.fromJson(
      fixtureJson,
      (payload) => payload,
    );

    expect(event.contractVersion, contractVersion);
    expect(event.kind, BridgeEventKind.messageDelta);
    expect(event.payload['delta'], 'Working on foundation contracts');
  });
}
