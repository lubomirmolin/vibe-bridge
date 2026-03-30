import Foundation

enum SharedContract {
    static let version = "2026-03-29"
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

enum BridgeAPIRouteKindDTO: String, Codable {
    case tailscale
    case localNetwork = "local_network"
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

enum SpeechModelStateDTO: String, Codable {
    case unsupported
    case notInstalled = "not_installed"
    case installing
    case ready
    case busy
    case failed
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

struct ThreadListResponseDTO: Codable, Equatable {
    let contractVersion: String
    let threads: [ThreadSummaryDTO]

    enum CodingKeys: String, CodingKey {
        case contractVersion = "contract_version"
        case threads
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
    let bridgeAPIRoutes: [BridgeAPIRouteDTO]
    let pairingSession: PairingSessionDTO
    let qrPayload: String

    enum CodingKeys: String, CodingKey {
        case contractVersion = "contract_version"
        case bridgeIdentity = "bridge_identity"
        case bridgeAPIRoutes = "bridge_api_routes"
        case pairingSession = "pairing_session"
        case qrPayload = "qr_payload"
    }
}

struct PairingRevokeResponseDTO: Codable, Equatable {
    let contractVersion: String
    let revoked: Bool

    enum CodingKeys: String, CodingKey {
        case contractVersion = "contract_version"
        case revoked
    }
}

struct BridgeHealthResponseDTO: Decodable, Equatable {
    let status: String
    let runtime: BridgeRuntimeSnapshotDTO
    let pairingRoute: BridgePairingRouteHealthDTO
    let networkSettings: BridgeNetworkSettingsDTO
    let trust: BridgeTrustStatusDTO?
    let api: BridgeAPISurfaceDTO

    enum CodingKeys: String, CodingKey {
        case status
        case runtime
        case pairingRoute = "pairing_route"
        case networkSettings = "network_settings"
        case trust
        case api
    }
}

struct BridgeRuntimeSnapshotDTO: Codable, Equatable {
    let mode: String
    let state: String
    let endpoint: String?
    let pid: UInt32?
    let detail: String
}

struct BridgePairingRouteHealthDTO: Codable, Equatable {
    let reachable: Bool
    let advertisedBaseURL: String?
    let routes: [BridgeAPIRouteDTO]
    let message: String?

    enum CodingKeys: String, CodingKey {
        case reachable
        case advertisedBaseURL = "advertised_base_url"
        case routes
        case message
    }
}

struct BridgeAPIRouteDTO: Codable, Equatable {
    let id: String
    let kind: BridgeAPIRouteKindDTO
    let baseURL: String
    let reachable: Bool
    let isPreferred: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case baseURL = "base_url"
        case reachable
        case isPreferred = "is_preferred"
    }
}

struct BridgeNetworkSettingsDTO: Codable, Equatable {
    let contractVersion: String
    let localNetworkPairingEnabled: Bool
    let routes: [BridgeAPIRouteDTO]
    let message: String?

    enum CodingKeys: String, CodingKey {
        case contractVersion = "contract_version"
        case localNetworkPairingEnabled = "local_network_pairing_enabled"
        case routes
        case message
    }
}

struct BridgeTrustStatusDTO: Decodable, Equatable {
    let trustedPhone: BridgeTrustedPhoneDTO?
    let activeSession: BridgeActiveSessionDTO?
    let trustedDevices: [BridgeTrustedDeviceDTO]
    let trustedSessions: [BridgeTrustedSessionDTO]

    enum CodingKeys: String, CodingKey {
        case trustedPhone = "trusted_phone"
        case activeSession = "active_session"
        case trustedDevices = "trusted_devices"
        case trustedSessions = "trusted_sessions"
    }

    init(
        trustedPhone: BridgeTrustedPhoneDTO?,
        activeSession: BridgeActiveSessionDTO?,
        trustedDevices: [BridgeTrustedDeviceDTO] = [],
        trustedSessions: [BridgeTrustedSessionDTO] = []
    ) {
        self.trustedPhone = trustedPhone
        self.activeSession = activeSession
        self.trustedDevices = trustedDevices.isEmpty
            ? trustedPhone.map { [BridgeTrustedDeviceDTO(phone: $0)] } ?? []
            : trustedDevices
        self.trustedSessions = trustedSessions.isEmpty
            ? activeSession.map { [BridgeTrustedSessionDTO(session: $0)] } ?? []
            : trustedSessions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let trustedPhone = try container.decodeIfPresent(
            BridgeTrustedPhoneDTO.self,
            forKey: .trustedPhone
        )
        let activeSession = try container.decodeIfPresent(
            BridgeActiveSessionDTO.self,
            forKey: .activeSession
        )
        let trustedDevices = try container.decodeIfPresent(
            [BridgeTrustedDeviceDTO].self,
            forKey: .trustedDevices
        ) ?? []
        let trustedSessions = try container.decodeIfPresent(
            [BridgeTrustedSessionDTO].self,
            forKey: .trustedSessions
        ) ?? []
        self.init(
            trustedPhone: trustedPhone,
            activeSession: activeSession,
            trustedDevices: trustedDevices,
            trustedSessions: trustedSessions
        )
    }
}

struct BridgeTrustedPhoneDTO: Codable, Equatable {
    let phoneID: String
    let phoneName: String
    let pairedAtEpochSeconds: UInt64

    enum CodingKeys: String, CodingKey {
        case phoneID = "phone_id"
        case phoneName = "phone_name"
        case pairedAtEpochSeconds = "paired_at_epoch_seconds"
    }
}

struct BridgeTrustedDeviceDTO: Decodable, Equatable, Identifiable {
    let deviceID: String
    let deviceName: String
    let pairedAtEpochSeconds: UInt64

    var id: String { deviceID }

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case deviceName = "device_name"
        case pairedAtEpochSeconds = "paired_at_epoch_seconds"
        case phoneID = "phone_id"
        case phoneName = "phone_name"
    }

    init(deviceID: String, deviceName: String, pairedAtEpochSeconds: UInt64) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.pairedAtEpochSeconds = pairedAtEpochSeconds
    }

    init(phone: BridgeTrustedPhoneDTO) {
        self.init(
            deviceID: phone.phoneID,
            deviceName: phone.phoneName,
            pairedAtEpochSeconds: phone.pairedAtEpochSeconds
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let deviceID = try container.decodeIfPresent(String.self, forKey: .deviceID)
            ?? container.decode(String.self, forKey: .phoneID)
        let deviceName = try container.decodeIfPresent(String.self, forKey: .deviceName)
            ?? container.decode(String.self, forKey: .phoneName)
        let pairedAtEpochSeconds = try container.decode(UInt64.self, forKey: .pairedAtEpochSeconds)
        self.init(
            deviceID: deviceID,
            deviceName: deviceName,
            pairedAtEpochSeconds: pairedAtEpochSeconds
        )
    }
}

struct BridgeActiveSessionDTO: Codable, Equatable {
    let phoneID: String
    let sessionID: String
    let finalizedAtEpochSeconds: UInt64

    enum CodingKeys: String, CodingKey {
        case phoneID = "phone_id"
        case sessionID = "session_id"
        case finalizedAtEpochSeconds = "finalized_at_epoch_seconds"
    }
}

struct BridgeTrustedSessionDTO: Decodable, Equatable, Identifiable {
    let deviceID: String
    let sessionID: String
    let finalizedAtEpochSeconds: UInt64

    var id: String { sessionID }

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case sessionID = "session_id"
        case finalizedAtEpochSeconds = "finalized_at_epoch_seconds"
        case phoneID = "phone_id"
    }

    init(deviceID: String, sessionID: String, finalizedAtEpochSeconds: UInt64) {
        self.deviceID = deviceID
        self.sessionID = sessionID
        self.finalizedAtEpochSeconds = finalizedAtEpochSeconds
    }

    init(session: BridgeActiveSessionDTO) {
        self.init(
            deviceID: session.phoneID,
            sessionID: session.sessionID,
            finalizedAtEpochSeconds: session.finalizedAtEpochSeconds
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let deviceID = try container.decodeIfPresent(String.self, forKey: .deviceID)
            ?? container.decode(String.self, forKey: .phoneID)
        let sessionID = try container.decode(String.self, forKey: .sessionID)
        let finalizedAtEpochSeconds = try container.decode(
            UInt64.self,
            forKey: .finalizedAtEpochSeconds
        )
        self.init(
            deviceID: deviceID,
            sessionID: sessionID,
            finalizedAtEpochSeconds: finalizedAtEpochSeconds
        )
    }
}

struct BridgeAPISurfaceDTO: Codable, Equatable {
    let endpoints: [String]
    let seededThreadCount: Int

    enum CodingKeys: String, CodingKey {
        case endpoints
        case seededThreadCount = "seeded_thread_count"
    }
}

struct SpeechModelStatusDTO: Codable, Equatable {
    let contractVersion: String
    let provider: String
    let modelID: String
    let state: SpeechModelStateDTO
    let downloadProgress: UInt8?
    let lastError: String?
    let installedBytes: UInt64?

    enum CodingKeys: String, CodingKey {
        case contractVersion = "contract_version"
        case provider
        case modelID = "model_id"
        case state
        case downloadProgress = "download_progress"
        case lastError = "last_error"
        case installedBytes = "installed_bytes"
    }
}

struct SpeechModelMutationAcceptedDTO: Codable, Equatable {
    let contractVersion: String
    let provider: String
    let modelID: String
    let state: SpeechModelStateDTO
    let message: String

    enum CodingKeys: String, CodingKey {
        case contractVersion = "contract_version"
        case provider
        case modelID = "model_id"
        case state
        case message
    }
}
