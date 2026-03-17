use serde_json::Value;
use shared_contracts::{BridgeEventEnvelope, BridgeEventKind, SecurityAuditEventDto};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LogSeverity {
    Debug,
    Info,
    Warn,
    Error,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LogRecord {
    pub severity: LogSeverity,
    pub category: &'static str,
    pub event: BridgeEventEnvelope<Value>,
}

pub trait LogSink {
    fn append(&mut self, record: LogRecord);
    fn records(&self) -> &[LogRecord];
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct InMemoryLogSink {
    records: Vec<LogRecord>,
}

impl LogSink for InMemoryLogSink {
    fn append(&mut self, record: LogRecord) {
        self.records.push(record);
    }

    fn records(&self) -> &[LogRecord] {
        &self.records
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StructuredLogger<TSink>
where
    TSink: LogSink,
{
    sink: TSink,
}

impl<TSink> StructuredLogger<TSink>
where
    TSink: LogSink,
{
    pub fn new(sink: TSink) -> Self {
        Self { sink }
    }

    pub fn log_event(&mut self, severity: LogSeverity, event: BridgeEventEnvelope<Value>) {
        self.sink.append(LogRecord {
            severity,
            category: "bridge_event",
            event,
        });
    }

    pub fn log_security_audit(
        &mut self,
        severity: LogSeverity,
        event_id: impl Into<String>,
        thread_id: impl Into<String>,
        occurred_at: impl Into<String>,
        audit_event: SecurityAuditEventDto,
    ) {
        let payload = serde_json::to_value(audit_event)
            .expect("security audit event serialization should never fail");
        let event = BridgeEventEnvelope::new(
            event_id,
            thread_id,
            BridgeEventKind::SecurityAudit,
            occurred_at,
            payload,
        );

        self.log_event(severity, event);
    }

    pub fn sink(&self) -> &TSink {
        &self.sink
    }
}

#[cfg(test)]
mod tests {
    use super::{InMemoryLogSink, LogSeverity, LogSink, StructuredLogger};
    use shared_contracts::{BridgeEventKind, CONTRACT_VERSION, SecurityAuditEventDto};

    #[test]
    fn security_audit_records_use_shared_contract_envelope() {
        let mut logger = StructuredLogger::new(InMemoryLogSink::default());

        logger.log_security_audit(
            LogSeverity::Warn,
            "evt-security-1",
            "thread-123",
            "2026-03-17T18:02:00Z",
            SecurityAuditEventDto {
                actor: "mobile-device-1".to_string(),
                action: "approve".to_string(),
                target: "git.push".to_string(),
                outcome: "allowed".to_string(),
                reason: "full_control_mode".to_string(),
            },
        );

        let records = logger.sink().records();
        assert_eq!(records.len(), 1);
        assert_eq!(records[0].event.contract_version, CONTRACT_VERSION);
        assert_eq!(records[0].event.kind, BridgeEventKind::SecurityAudit);
        assert_eq!(records[0].event.payload["target"], "git.push");
    }
}
