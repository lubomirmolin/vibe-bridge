import 'package:vibe_bridge/foundation/contracts/bridge_contracts.dart';
import 'package:vibe_bridge/foundation/logging/structured_logger.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('structured logger emits security-audit envelope', () {
    final sink = InMemoryLogSink<Map<String, dynamic>>();
    final logger = StructuredLogger<Map<String, dynamic>>(sink);

    logger.logSecurityAudit(
      severity: LogSeverity.warn,
      eventId: 'evt-security-1',
      threadId: 'thread-123',
      occurredAt: '2026-03-17T18:02:00Z',
      auditEvent: const SecurityAuditEventDto(
        actor: 'mobile-device-1',
        action: 'approve',
        target: 'git.push',
        outcome: 'allowed',
        reason: 'full_control_mode',
      ),
      payloadMapper: (event) => event.toJson(),
    );

    final records = logger.records();
    expect(records.length, 1);
    expect(records.first.event.contractVersion, contractVersion);
    expect(records.first.event.kind, BridgeEventKind.securityAudit);
    expect(records.first.event.payload['target'], 'git.push');
  });
}
