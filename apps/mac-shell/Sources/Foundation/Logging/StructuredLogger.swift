import Foundation

enum LogSeverity {
    case debug
    case info
    case warn
    case error
}

struct LogRecord<TPayload: Codable & Equatable>: Equatable {
    let severity: LogSeverity
    let category: String
    let event: BridgeEventEnvelope<TPayload>
}

protocol LogSink {
    associatedtype Payload: Codable & Equatable

    func append(_ record: LogRecord<Payload>)
    func records() -> [LogRecord<Payload>]
}

final class InMemoryLogSink<TPayload: Codable & Equatable>: LogSink {
    typealias Payload = TPayload

    private var entries: [LogRecord<TPayload>] = []

    func append(_ record: LogRecord<TPayload>) {
        entries.append(record)
    }

    func records() -> [LogRecord<TPayload>] {
        entries
    }
}

final class StructuredLogger<TPayload: Codable & Equatable> {
    private let sink: InMemoryLogSink<TPayload>

    init(sink: InMemoryLogSink<TPayload>) {
        self.sink = sink
    }

    func logEvent(_ severity: LogSeverity, event: BridgeEventEnvelope<TPayload>) {
        sink.append(LogRecord(
            severity: severity,
            category: "bridge_event",
            event: event
        ))
    }

    func records() -> [LogRecord<TPayload>] {
        sink.records()
    }
}
