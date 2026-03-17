import Foundation

enum SharedContract {
    static let version = "2026-03-17"
}

enum ThreadStatus: String, Codable {
    case idle
    case running
    case completed
    case interrupted
    case failed
}

enum AccessMode: String, Codable {
    case readOnly = "read_only"
    case controlWithApprovals = "control_with_approvals"
    case fullControl = "full_control"
}

enum BridgeEventKind: String, Codable {
    case messageDelta = "message_delta"
    case planDelta = "plan_delta"
    case commandDelta = "command_delta"
    case fileChange = "file_change"
    case approvalRequested = "approval_requested"
    case threadStatusChanged = "thread_status_changed"
    case securityAudit = "security_audit"
}

struct ThreadSummaryDTO: Codable, Equatable {
    let contractVersion: String
    let threadID: String
    let title: String
    let status: ThreadStatus
    let workspace: String
    let repository: String
    let branch: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case contractVersion = "contract_version"
        case threadID = "thread_id"
        case title
        case status
        case workspace
        case repository
        case branch
        case updatedAt = "updated_at"
    }
}

struct SecurityAuditEventDTO: Codable, Equatable {
    let actor: String
    let action: String
    let target: String
    let outcome: String
    let reason: String
}

struct BridgeEventEnvelope<TPayload: Codable & Equatable>: Codable, Equatable {
    let contractVersion: String
    let eventID: String
    let threadID: String
    let kind: BridgeEventKind
    let occurredAt: String
    let payload: TPayload

    enum CodingKeys: String, CodingKey {
        case contractVersion = "contract_version"
        case eventID = "event_id"
        case threadID = "thread_id"
        case kind
        case occurredAt = "occurred_at"
        case payload
    }
}

struct PairingBridgeIdentityDTO: Codable, Equatable {
    let bridgeID: String
    let displayName: String
    let apiBaseURL: String

    enum CodingKeys: String, CodingKey {
        case bridgeID = "bridge_id"
        case displayName = "display_name"
        case apiBaseURL = "api_base_url"
    }
}

struct PairingSessionDTO: Codable, Equatable {
    let sessionID: String
    let pairingToken: String
    let issuedAtEpochSeconds: UInt64
    let expiresAtEpochSeconds: UInt64

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case pairingToken = "pairing_token"
        case issuedAtEpochSeconds = "issued_at_epoch_seconds"
        case expiresAtEpochSeconds = "expires_at_epoch_seconds"
    }
}

struct PairingSessionResponseDTO: Codable, Equatable {
    let contractVersion: String
    let bridgeIdentity: PairingBridgeIdentityDTO
    let pairingSession: PairingSessionDTO
    let qrPayload: String

    enum CodingKeys: String, CodingKey {
        case contractVersion = "contract_version"
        case bridgeIdentity = "bridge_identity"
        case pairingSession = "pairing_session"
        case qrPayload = "qr_payload"
    }
}
