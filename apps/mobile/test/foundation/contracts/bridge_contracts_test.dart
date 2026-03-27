import 'dart:convert';
import 'dart:io';

import 'package:vibe_bridge/foundation/contracts/bridge_contracts.dart';
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
    expect(summary.repository, 'vibe-bridge-companion');
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

  test('thread summary decoding fails on unknown thread status', () {
    final fixturePath =
        '${_repoRootPath()}/shared/contracts/fixtures/thread_summary.json';
    final fixtureJson =
        jsonDecode(File(fixturePath).readAsStringSync())
            as Map<String, dynamic>;
    final invalidFixture = Map<String, dynamic>.from(fixtureJson)
      ..['status'] = 'not_a_real_status';

    expect(
      () => ThreadSummaryDto.fromJson(invalidFixture),
      throwsA(
        isA<FormatException>()
            .having(
              (error) => error.message,
              'message',
              contains('ThreadStatus'),
            )
            .having(
              (error) => error.message,
              'message',
              contains('not_a_real_status'),
            ),
      ),
    );
  });

  test('bridge event decoding fails on unknown event kind', () {
    final fixturePath =
        '${_repoRootPath()}/shared/contracts/fixtures/bridge_event_message_delta.json';
    final fixtureJson =
        jsonDecode(File(fixturePath).readAsStringSync())
            as Map<String, dynamic>;
    final invalidFixture = Map<String, dynamic>.from(fixtureJson)
      ..['kind'] = 'not_a_real_kind';

    expect(
      () => BridgeEventEnvelope<Map<String, dynamic>>.fromJson(
        invalidFixture,
        (payload) => payload,
      ),
      throwsA(
        isA<FormatException>()
            .having(
              (error) => error.message,
              'message',
              contains('BridgeEventKind'),
            )
            .having(
              (error) => error.message,
              'message',
              contains('not_a_real_kind'),
            ),
      ),
    );
  });

  test('access mode decoding fails on unknown wire value', () {
    expect(
      () => accessModeFromWire('not_a_real_access_mode'),
      throwsA(
        isA<FormatException>()
            .having((error) => error.message, 'message', contains('AccessMode'))
            .having(
              (error) => error.message,
              'message',
              contains('not_a_real_access_mode'),
            ),
      ),
    );
  });
}
