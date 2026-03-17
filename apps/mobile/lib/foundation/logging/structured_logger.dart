import '../contracts/bridge_contracts.dart';

enum LogSeverity { debug, info, warn, error }

class LogRecord<TPayload> {
  const LogRecord({
    required this.severity,
    required this.category,
    required this.event,
  });

  final LogSeverity severity;
  final String category;
  final BridgeEventEnvelope<TPayload> event;
}

abstract class LogSink<TPayload> {
  void append(LogRecord<TPayload> record);
  List<LogRecord<TPayload>> records();
}

class InMemoryLogSink<TPayload> implements LogSink<TPayload> {
  final List<LogRecord<TPayload>> _records = <LogRecord<TPayload>>[];

  @override
  void append(LogRecord<TPayload> record) {
    _records.add(record);
  }

  @override
  List<LogRecord<TPayload>> records() =>
      List<LogRecord<TPayload>>.unmodifiable(_records);
}

class StructuredLogger<TPayload> {
  StructuredLogger(this._sink);

  final LogSink<TPayload> _sink;

  void logEvent(LogSeverity severity, BridgeEventEnvelope<TPayload> event) {
    _sink.append(
      LogRecord<TPayload>(
        severity: severity,
        category: 'bridge_event',
        event: event,
      ),
    );
  }

  void logSecurityAudit({
    required LogSeverity severity,
    required String eventId,
    required String threadId,
    required String occurredAt,
    required SecurityAuditEventDto auditEvent,
    required TPayload Function(SecurityAuditEventDto event) payloadMapper,
  }) {
    logEvent(
      severity,
      BridgeEventEnvelope<TPayload>(
        contractVersion: contractVersion,
        eventId: eventId,
        threadId: threadId,
        kind: BridgeEventKind.securityAudit,
        occurredAt: occurredAt,
        payload: payloadMapper(auditEvent),
      ),
    );
  }

  List<LogRecord<TPayload>> records() => _sink.records();
}
