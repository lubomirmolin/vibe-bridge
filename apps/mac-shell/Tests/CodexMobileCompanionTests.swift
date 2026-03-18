import XCTest
@testable import CodexMobileCompanion

final class CodexMobileCompanionTests: XCTestCase {
    func testShellScaffoldBuilds() {
        XCTAssertTrue(true)
    }

    func testThreadSummaryDecodesSharedFixtureShape() throws {
        let json = """
        {
          "contract_version": "2026-03-17",
          "thread_id": "thread-123",
          "title": "Implement shared contracts",
          "status": "running",
          "workspace": "/workspace/codex-mobile-companion",
          "repository": "codex-mobile-companion",
          "branch": "master",
          "updated_at": "2026-03-17T18:00:00Z"
        }
        """

        let decoded = try JSONDecoder().decode(
            ThreadSummaryDTO.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(decoded.contractVersion, SharedContract.version)
        XCTAssertEqual(decoded.status, .running)
        XCTAssertEqual(decoded.repository, "codex-mobile-companion")
    }

    func testSecureStoreLifecycleAndKeyNames() {
        let store = InMemorySecureStore()

        store.writeSecret("token-1", for: .sessionToken)
        XCTAssertEqual(store.readSecret(for: .sessionToken), "token-1")

        store.removeSecret(for: .sessionToken)
        XCTAssertNil(store.readSecret(for: .sessionToken))

        XCTAssertEqual(SecureValueKey.pairingPrivateKey.rawValue, "pairing_private_key")
        XCTAssertEqual(SecureValueKey.sessionToken.rawValue, "session_token")
        XCTAssertEqual(SecureValueKey.trustedBridgeIdentity.rawValue, "trusted_bridge_identity")
    }

    func testPersistenceBoundaryMatchesSharedScopeNames() {
        let boundary = PersistenceBoundary(baseDirectory: URL(fileURLWithPath: "/tmp/shell"))

        XCTAssertEqual(
            boundary.sqliteURL(for: .threadsCache).path,
            "/tmp/shell/state/threads-cache.sqlite"
        )
        XCTAssertFalse(boundary.requiresSecureStore(for: .securityAudit))
    }

    func testPairingSessionResponseDecodesBridgeIdentityAndSession() throws {
        let json = """
        {
          "contract_version": "2026-03-17",
          "bridge_identity": {
            "bridge_id": "bridge-74dbf8ad31e2af1b",
            "display_name": "Codex Mobile Companion",
            "api_base_url": "http://127.0.0.1:3110"
          },
          "pairing_session": {
            "session_id": "pairing-session-1",
            "pairing_token": "ptk-aabbccdd",
            "issued_at_epoch_seconds": 1,
            "expires_at_epoch_seconds": 301
          },
          "qr_payload": "bridge-74dbf8ad31e2af1b|pairing-session-1"
        }
        """

        let decoded = try JSONDecoder().decode(
            PairingSessionResponseDTO.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(decoded.contractVersion, SharedContract.version)
        XCTAssertEqual(decoded.bridgeIdentity.bridgeID, "bridge-74dbf8ad31e2af1b")
        XCTAssertEqual(decoded.pairingSession.sessionID, "pairing-session-1")
        XCTAssertEqual(decoded.bridgeIdentity.apiBaseURL, "http://127.0.0.1:3110")
    }

    func testShellStateResolverMapsUnpairedPairedIdleAndPairedActive() {
        XCTAssertEqual(
            ShellStateResolver.resolveShellState(trustStatus: nil, runningThreadCount: 0),
            .unpaired
        )

        XCTAssertEqual(
            ShellStateResolver.resolveShellState(
                trustStatus: Self.trustStatus(),
                runningThreadCount: 0
            ),
            .pairedIdle
        )

        XCTAssertEqual(
            ShellStateResolver.resolveShellState(
                trustStatus: Self.trustStatus(),
                runningThreadCount: 2
            ),
            .pairedActive
        )
    }

    func testShellStateResolverTreatsOfflineRuntimeAsDegraded() {
        let health = Self.healthResponse(
            runtimeState: "degraded",
            trustStatus: nil,
            pairingRouteReachable: false,
            pairingRouteMessage: "route unavailable"
        )

        switch ShellStateResolver.resolveRuntimeHealth(health) {
        case .healthy:
            XCTFail("Expected degraded resolution")
        case let .degraded(message):
            XCTAssertEqual(message, "route unavailable")
        }
    }

    @MainActor
    func testPairingViewModelLoadsSessionAndCreatesQRCodeWhenUnpaired() async {
        let client = StubShellBridgeClient(
            healthResults: [.success(Self.healthResponse(runtimeState: "managed", trustStatus: nil))],
            threadResults: [.success(Self.threadListResponse(statuses: []))],
            pairingResults: [.success(Self.samplePairingResponse)]
        )
        let viewModel = PairingEntryViewModel(bridgeClient: client)

        await viewModel.refreshRuntimeState()

        XCTAssertEqual(viewModel.shellState, .unpaired)
        XCTAssertEqual(viewModel.pairingSession?.pairingSession.sessionID, "pairing-session-42")
        XCTAssertNotNil(viewModel.qrImage)
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testPairingViewModelReportsBridgeFailureForUnpairedQRCodeFetch() async {
        let client = StubShellBridgeClient(
            healthResults: [.success(Self.healthResponse(runtimeState: "managed", trustStatus: nil))],
            threadResults: [.success(Self.threadListResponse(statuses: []))],
            pairingResults: [.failure(StubError.bridgeUnavailable)]
        )
        let viewModel = PairingEntryViewModel(bridgeClient: client)

        await viewModel.refreshRuntimeState()

        XCTAssertEqual(viewModel.shellState, .unpaired)
        XCTAssertNil(viewModel.pairingSession)
        XCTAssertNil(viewModel.qrImage)
        XCTAssertNotNil(viewModel.errorMessage)
    }

    @MainActor
    func testPairingViewModelTransitionsFromDegradedToPairedIdleAfterRecovery() async {
        let client = StubShellBridgeClient(
            healthResults: [
                .failure(StubError.bridgeUnavailable),
                .success(Self.healthResponse(runtimeState: "managed", trustStatus: Self.trustStatus()))
            ],
            threadResults: [.success(Self.threadListResponse(statuses: []))],
            pairingResults: []
        )
        let viewModel = PairingEntryViewModel(bridgeClient: client)

        await viewModel.refreshRuntimeState()
        XCTAssertEqual(viewModel.shellState, .degraded)

        await viewModel.refreshRuntimeState()
        XCTAssertEqual(viewModel.shellState, .pairedIdle)
        XCTAssertEqual(viewModel.pairedDeviceLabel, "Primary Phone (phone-1)")
        XCTAssertEqual(viewModel.activeSessionLabel, "pairing-session-42")
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testPairingViewModelShowsPairedActiveWhenRunningThreadsExist() async {
        let client = StubShellBridgeClient(
            healthResults: [.success(Self.healthResponse(runtimeState: "managed", trustStatus: Self.trustStatus()))],
            threadResults: [.success(Self.threadListResponse(statuses: [.running, .completed]))],
            pairingResults: []
        )
        let viewModel = PairingEntryViewModel(bridgeClient: client)

        await viewModel.refreshRuntimeState()

        XCTAssertEqual(viewModel.shellState, .pairedActive)
        XCTAssertEqual(viewModel.runningThreadCount, 1)
        XCTAssertNil(viewModel.pairingSession)
    }

    @MainActor
    func testPairingViewModelRevokesTrustFromDesktopAndReturnsToUnpaired() async {
        let client = StubShellBridgeClient(
            healthResults: [
                .success(Self.healthResponse(runtimeState: "managed", trustStatus: Self.trustStatus())),
                .success(Self.healthResponse(runtimeState: "managed", trustStatus: nil)),
            ],
            threadResults: [
                .success(Self.threadListResponse(statuses: [])),
                .success(Self.threadListResponse(statuses: [])),
            ],
            pairingResults: [.success(Self.samplePairingResponse)],
            revokeResults: [.success(Self.sampleRevokeResponse)]
        )
        let viewModel = PairingEntryViewModel(bridgeClient: client)

        await viewModel.refreshRuntimeState()
        XCTAssertEqual(viewModel.shellState, .pairedIdle)

        await viewModel.revokeTrustedPhoneFromDesktop()

        XCTAssertEqual(viewModel.shellState, .unpaired)
        XCTAssertNil(viewModel.errorMessage)
        let revokedPhoneIDs = await client.revokedPhoneIDs()
        XCTAssertEqual(revokedPhoneIDs, ["phone-1"])
    }

    @MainActor
    func testPairingViewModelReportsDesktopRevokeFailure() async {
        let client = StubShellBridgeClient(
            healthResults: [.success(Self.healthResponse(runtimeState: "managed", trustStatus: Self.trustStatus()))],
            threadResults: [.success(Self.threadListResponse(statuses: []))],
            pairingResults: [],
            revokeResults: [.failure(StubError.bridgeUnavailable)]
        )
        let viewModel = PairingEntryViewModel(bridgeClient: client)

        await viewModel.refreshRuntimeState()
        XCTAssertEqual(viewModel.shellState, .pairedIdle)

        await viewModel.revokeTrustedPhoneFromDesktop()

        XCTAssertEqual(viewModel.shellState, .pairedIdle)
        XCTAssertNotNil(viewModel.errorMessage)
    }

    private static func healthResponse(
        runtimeState: String,
        trustStatus: BridgeTrustStatusDTO?,
        pairingRouteReachable: Bool = true,
        pairingRouteMessage: String? = nil
    ) -> BridgeHealthResponseDTO {
        BridgeHealthResponseDTO(
            status: "ok",
            runtime: BridgeRuntimeSnapshotDTO(
                mode: "auto",
                state: runtimeState,
                endpoint: "ws://127.0.0.1:4222",
                pid: 123,
                detail: runtimeState == "degraded" ? "runtime degraded" : "runtime healthy"
            ),
            pairingRoute: BridgePairingRouteHealthDTO(
                reachable: pairingRouteReachable,
                advertisedBaseURL: pairingRouteReachable ? "https://bridge.ts.net" : nil,
                message: pairingRouteMessage
            ),
            trust: trustStatus,
            api: BridgeAPISurfaceDTO(endpoints: ["GET /health"], seededThreadCount: 0)
        )
    }

    private static func trustStatus() -> BridgeTrustStatusDTO {
        BridgeTrustStatusDTO(
            trustedPhone: BridgeTrustedPhoneDTO(
                phoneID: "phone-1",
                phoneName: "Primary Phone",
                pairedAtEpochSeconds: 100
            ),
            activeSession: BridgeActiveSessionDTO(
                phoneID: "phone-1",
                sessionID: "pairing-session-42",
                finalizedAtEpochSeconds: 120
            )
        )
    }

    private static func threadListResponse(statuses: [ThreadStatus]) -> ThreadListResponseDTO {
        ThreadListResponseDTO(
            contractVersion: SharedContract.version,
            threads: statuses.enumerated().map { index, status in
                ThreadSummaryDTO(
                    contractVersion: SharedContract.version,
                    threadID: "thread-\(index)",
                    title: "Thread \(index)",
                    status: status,
                    workspace: "/workspace/codex-mobile-companion",
                    repository: "codex-mobile-companion",
                    branch: "master",
                    updatedAt: "2026-03-18T12:00:00Z"
                )
            }
        )
    }

    private static let samplePairingResponse = PairingSessionResponseDTO(
        contractVersion: SharedContract.version,
        bridgeIdentity: PairingBridgeIdentityDTO(
            bridgeID: "bridge-sample",
            displayName: "Codex Mobile Companion",
            apiBaseURL: "http://127.0.0.1:3110"
        ),
        pairingSession: PairingSessionDTO(
            sessionID: "pairing-session-42",
            pairingToken: "ptk-42",
            issuedAtEpochSeconds: 100,
            expiresAtEpochSeconds: UInt64(Date().timeIntervalSince1970) + 400
        ),
        qrPayload: "bridge-sample|pairing-session-42|ptk-42"
    )

    private static let sampleRevokeResponse = PairingRevokeResponseDTO(
        contractVersion: SharedContract.version,
        revoked: true
    )
}

private struct StubShellBridgeClient: ShellBridgeClient {
    private let store: StubShellBridgeResponseStore

    init(
        healthResults: [Result<BridgeHealthResponseDTO, Error>],
        threadResults: [Result<ThreadListResponseDTO, Error>],
        pairingResults: [Result<PairingSessionResponseDTO, Error>],
        revokeResults: [Result<PairingRevokeResponseDTO, Error>] = []
    ) {
        self.store = StubShellBridgeResponseStore(
            healthResults: healthResults,
            threadResults: threadResults,
            pairingResults: pairingResults,
            revokeResults: revokeResults
        )
    }

    func fetchHealth() async throws -> BridgeHealthResponseDTO {
        try await store.nextHealth()
    }

    func fetchThreads() async throws -> ThreadListResponseDTO {
        try await store.nextThreadList()
    }

    func fetchPairingSession() async throws -> PairingSessionResponseDTO {
        try await store.nextPairing()
    }

    func revokeTrust(phoneID: String?) async throws -> PairingRevokeResponseDTO {
        try await store.nextRevoke(phoneID: phoneID)
    }

    func revokedPhoneIDs() async -> [String?] {
        await store.revokedPhoneIDs()
    }
}

private actor StubShellBridgeResponseStore {
    private var healthResults: [Result<BridgeHealthResponseDTO, Error>]
    private var threadResults: [Result<ThreadListResponseDTO, Error>]
    private var pairingResults: [Result<PairingSessionResponseDTO, Error>]
    private var revokeResults: [Result<PairingRevokeResponseDTO, Error>]
    private var recordedRevokedPhoneIDs: [String?] = []

    init(
        healthResults: [Result<BridgeHealthResponseDTO, Error>],
        threadResults: [Result<ThreadListResponseDTO, Error>],
        pairingResults: [Result<PairingSessionResponseDTO, Error>],
        revokeResults: [Result<PairingRevokeResponseDTO, Error>]
    ) {
        self.healthResults = healthResults
        self.threadResults = threadResults
        self.pairingResults = pairingResults
        self.revokeResults = revokeResults
    }

    func nextHealth() throws -> BridgeHealthResponseDTO {
        guard !healthResults.isEmpty else {
            throw StubError.missingHealthResult
        }
        return try healthResults.removeFirst().get()
    }

    func nextThreadList() throws -> ThreadListResponseDTO {
        guard !threadResults.isEmpty else {
            throw StubError.missingThreadResult
        }
        return try threadResults.removeFirst().get()
    }

    func nextPairing() throws -> PairingSessionResponseDTO {
        guard !pairingResults.isEmpty else {
            throw StubError.missingPairingResult
        }
        return try pairingResults.removeFirst().get()
    }

    func nextRevoke(phoneID: String?) throws -> PairingRevokeResponseDTO {
        recordedRevokedPhoneIDs.append(phoneID)
        guard !revokeResults.isEmpty else {
            throw StubError.missingRevokeResult
        }
        return try revokeResults.removeFirst().get()
    }

    func revokedPhoneIDs() -> [String?] {
        recordedRevokedPhoneIDs
    }
}

private enum StubError: LocalizedError {
    case bridgeUnavailable
    case missingHealthResult
    case missingThreadResult
    case missingPairingResult
    case missingRevokeResult

    var errorDescription: String? {
        switch self {
        case .bridgeUnavailable:
            return "bridge unavailable"
        case .missingHealthResult:
            return "missing stub health result"
        case .missingThreadResult:
            return "missing stub thread result"
        case .missingPairingResult:
            return "missing stub pairing result"
        case .missingRevokeResult:
            return "missing stub revoke result"
        }
    }
}
