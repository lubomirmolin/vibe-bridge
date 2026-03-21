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
          "qr_payload": "{\\"v\\":\\"2026-03-17\\",\\"b\\":\\"bridge-74dbf8ad31e2af1b\\",\\"u\\":\\"http://127.0.0.1:3110\\",\\"s\\":\\"pairing-session-1\\",\\"t\\":\\"ptk-aabbccdd\\"}"
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

    func testDesktopRuntimeSupervisorDefaultStateDirectoryUsesApplicationSupport() {
        let url = DesktopRuntimeSupervisor.defaultStateDirectoryURL()

        XCTAssertTrue(url.path.contains("/Library/Application Support/"))
        XCTAssertTrue(url.path.hasSuffix("/CodexMobileCompanion/bridge-core"))
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

    func testBridgeBinaryPathResolverPrefersBundledHelper() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let resourcesDirectory = tempDirectory.appendingPathComponent("Resources", isDirectory: true)
        let bundledBinary = resourcesDirectory
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("bridge-server")

        try FileManager.default.createDirectory(
            at: bundledBinary.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("bridge".utf8).write(to: bundledBinary)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: bundledBinary.path
        )

        let resolver = BridgeBinaryPathResolver(
            environment: [:],
            currentDirectoryURL: tempDirectory,
            bundleResourceURL: resourcesDirectory
        )

        XCTAssertEqual(try resolver.resolveBridgeBinaryURL().path, bundledBinary.path)
    }

    func testBridgeBinaryPathResolverPrefersExplicitEnvironmentOverride() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let explicitBinary = tempDirectory.appendingPathComponent("custom-bridge-server")
        let resourcesDirectory = tempDirectory.appendingPathComponent("Resources", isDirectory: true)
        let bundledBinary = resourcesDirectory.appendingPathComponent("bridge-server")

        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resourcesDirectory, withIntermediateDirectories: true)
        try Data("explicit".utf8).write(to: explicitBinary)
        try Data("bundled".utf8).write(to: bundledBinary)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: explicitBinary.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: bundledBinary.path
        )

        let resolver = BridgeBinaryPathResolver(
            environment: ["CODEX_MOBILE_COMPANION_BRIDGE_BINARY": explicitBinary.path],
            currentDirectoryURL: tempDirectory,
            bundleResourceURL: resourcesDirectory
        )

        XCTAssertEqual(try resolver.resolveBridgeBinaryURL().path, explicitBinary.path)
    }

    func testBridgeBinaryPathResolverResolvesCodexFromCommonUserInstallLocations() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let homeDirectory = tempDirectory.appendingPathComponent("home", isDirectory: true)
        let codexBinary = homeDirectory
            .appendingPathComponent(".bun", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("codex")

        try FileManager.default.createDirectory(
            at: codexBinary.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("codex".utf8).write(to: codexBinary)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: codexBinary.path
        )

        let resolver = BridgeBinaryPathResolver(
            environment: ["HOME": homeDirectory.path],
            currentDirectoryURL: tempDirectory,
            bundleResourceURL: nil
        )

        XCTAssertEqual(resolver.resolveCodexBinaryURL()?.path, codexBinary.path)
    }

    func testBridgePortProcessRequiresCurrentShellOwnershipForManagedBridge() {
        let bridgeBinaryURL = URL(fileURLWithPath: "/tmp/CodexMobileCompanion.app/Contents/Resources/bin/bridge-server")
        let staleBridge = BridgePortProcess(
            pid: 10,
            parentPID: 20,
            command: "\(bridgeBinaryURL.path) --host 127.0.0.1 --port 3110"
        )

        XCTAssertTrue(staleBridge.isManagedBridge(matching: bridgeBinaryURL))
        XCTAssertFalse(staleBridge.isManagedBridge(matching: bridgeBinaryURL, ownedBy: 99))
        XCTAssertTrue(staleBridge.isManagedBridge(matching: bridgeBinaryURL, ownedBy: 20))
    }

    @MainActor
    func testPairingViewModelLoadsSessionAndCreatesQRCodeWhenUnpaired() async {
        let client = StubShellBridgeClient(
            healthResults: [.success(Self.healthResponse(runtimeState: "managed", trustStatus: nil))],
            threadResults: [.success(Self.threadListResponse(statuses: []))],
            pairingResults: [.success(Self.samplePairingResponse)]
        )
        let viewModel = PairingEntryViewModel(
            bridgeClient: client,
            runtimeSupervisor: StubDesktopRuntimeSupervisor()
        )

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
        let viewModel = PairingEntryViewModel(
            bridgeClient: client,
            runtimeSupervisor: StubDesktopRuntimeSupervisor()
        )

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
        let viewModel = PairingEntryViewModel(
            bridgeClient: client,
            runtimeSupervisor: StubDesktopRuntimeSupervisor()
        )

        await viewModel.refreshRuntimeState()
        XCTAssertEqual(viewModel.shellState, .degraded)

        await viewModel.refreshRuntimeState()
        XCTAssertEqual(viewModel.shellState, .pairedIdle)
        XCTAssertEqual(viewModel.pairedDeviceLabel, "Primary Phone (phone-1)")
        XCTAssertEqual(viewModel.activeSessionLabel, "pairing-session-42")
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testPairingViewModelAutoStartsSupervisionAndRecoversWithoutManualRefresh() async {
        let client = StubShellBridgeClient(
            healthResults: [
                .failure(StubError.bridgeUnavailable),
                .success(Self.healthResponse(runtimeState: "managed", trustStatus: Self.trustStatus())),
            ],
            threadResults: [.success(Self.threadListResponse(statuses: []))],
            pairingResults: []
        )
        let viewModel = PairingEntryViewModel(
            bridgeClient: client,
            runtimeSupervisor: StubDesktopRuntimeSupervisor(),
            startSupervisionOnInit: true,
            degradedPollIntervalNanoseconds: 10_000_000,
            healthyPollIntervalNanoseconds: 5_000_000_000
        )
        defer { viewModel.stopRuntimeSupervision() }

        let recovered = await waitUntil {
            viewModel.shellState == .pairedIdle
        }

        XCTAssertTrue(recovered)
        XCTAssertEqual(viewModel.pairedDeviceLabel, "Primary Phone (phone-1)")
        XCTAssertEqual(viewModel.activeSessionLabel, "pairing-session-42")
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testPairingViewModelStopRuntimeSupervisionShutsDownManagedBridge() async {
        let runtimeSupervisor = StubDesktopRuntimeSupervisor()
        let viewModel = PairingEntryViewModel(
            bridgeClient: StubShellBridgeClient(
                healthResults: [],
                threadResults: [],
                pairingResults: []
            ),
            runtimeSupervisor: runtimeSupervisor
        )

        viewModel.stopRuntimeSupervision()

        XCTAssertEqual(runtimeSupervisor.shutdownBridgeCallCount, 1)
    }

    @MainActor
    func testPairingViewModelShowsPairedActiveWhenRunningThreadsExist() async {
        let client = StubShellBridgeClient(
            healthResults: [.success(Self.healthResponse(runtimeState: "managed", trustStatus: Self.trustStatus()))],
            threadResults: [.success(Self.threadListResponse(statuses: [.running, .completed]))],
            pairingResults: []
        )
        let viewModel = PairingEntryViewModel(
            bridgeClient: client,
            runtimeSupervisor: StubDesktopRuntimeSupervisor()
        )

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
        let viewModel = PairingEntryViewModel(
            bridgeClient: client,
            runtimeSupervisor: StubDesktopRuntimeSupervisor()
        )

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
        let viewModel = PairingEntryViewModel(
            bridgeClient: client,
            runtimeSupervisor: StubDesktopRuntimeSupervisor()
        )

        await viewModel.refreshRuntimeState()
        XCTAssertEqual(viewModel.shellState, .pairedIdle)

        await viewModel.revokeTrustedPhoneFromDesktop()

        XCTAssertEqual(viewModel.shellState, .pairedIdle)
        XCTAssertNotNil(viewModel.errorMessage)
    }

    @MainActor
    func testPairingViewModelShowsStartupStateWhileBridgeLaunchIsInProgress() async {
        let client = StubShellBridgeClient(
            healthResults: [.failure(StubError.bridgeUnavailable)],
            threadResults: [],
            pairingResults: []
        )
        let viewModel = PairingEntryViewModel(
            bridgeClient: client,
            runtimeSupervisor: StubDesktopRuntimeSupervisor(
                prepareResults: [
                    .success(
                        DesktopRuntimeLaunchSnapshot(
                            statusLabel: "Launching bridge",
                            detail: "Desktop shell launched bridge-server and is waiting for health.",
                            isLaunching: true
                        )
                    )
                ]
            )
        )

        await viewModel.refreshRuntimeState()

        XCTAssertEqual(viewModel.shellState, .starting)
        XCTAssertEqual(viewModel.supervisorStatusLabel, "Launching bridge")
        XCTAssertEqual(viewModel.bridgeRuntimeLabel, "Launching bridge")
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testPairingViewModelSurfacesRuntimeSupervisorLaunchFailure() async {
        let client = StubShellBridgeClient(
            healthResults: [],
            threadResults: [],
            pairingResults: []
        )
        let viewModel = PairingEntryViewModel(
            bridgeClient: client,
            runtimeSupervisor: StubDesktopRuntimeSupervisor(
                prepareResults: [
                    .failure(
                        DesktopRuntimeSupervisorError.launchFailed("missing helper binary")
                    )
                ]
            )
        )

        await viewModel.refreshRuntimeState()

        XCTAssertEqual(viewModel.shellState, .degraded)
        XCTAssertEqual(viewModel.bridgeRuntimeLabel, "Unavailable")
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.runtimeDetail.contains("missing helper binary"))
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

    @MainActor
    private func waitUntil(
        timeoutSeconds: TimeInterval = 1.0,
        pollNanoseconds: UInt64 = 5_000_000,
        condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if condition() {
                return true
            }

            try? await Task.sleep(nanoseconds: pollNanoseconds)
        }

        return condition()
    }
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

private final class StubDesktopRuntimeSupervisor: DesktopRuntimeSupervisorClient {
    private let store: StubDesktopRuntimeSupervisorStore
    private(set) var shutdownBridgeCallCount = 0

    init(
        prepareResults: [Result<DesktopRuntimeLaunchSnapshot, Error>] = [
            .success(
                DesktopRuntimeLaunchSnapshot(
                    statusLabel: "Attached to existing bridge",
                    detail: "Stub desktop runtime supervisor is ready.",
                    isLaunching: false
                )
            )
        ],
        restartResults: [Result<DesktopRuntimeLaunchSnapshot, Error>] = []
    ) {
        self.store = StubDesktopRuntimeSupervisorStore(
            prepareResults: prepareResults,
            restartResults: restartResults
        )
    }

    func prepareBridgeForConnection() async throws -> DesktopRuntimeLaunchSnapshot {
        try await store.nextPrepare()
    }

    func restartBridge() async throws -> DesktopRuntimeLaunchSnapshot {
        try await store.nextRestart()
    }

    func shutdownBridgeIfManaged() {
        shutdownBridgeCallCount += 1
    }
}

private actor StubDesktopRuntimeSupervisorStore {
    private var prepareResults: [Result<DesktopRuntimeLaunchSnapshot, Error>]
    private var restartResults: [Result<DesktopRuntimeLaunchSnapshot, Error>]

    init(
        prepareResults: [Result<DesktopRuntimeLaunchSnapshot, Error>],
        restartResults: [Result<DesktopRuntimeLaunchSnapshot, Error>]
    ) {
        self.prepareResults = prepareResults
        self.restartResults = restartResults
    }

    func nextPrepare() throws -> DesktopRuntimeLaunchSnapshot {
        guard !prepareResults.isEmpty else {
            throw StubError.missingRuntimePrepareResult
        }
        if prepareResults.count == 1 {
            return try prepareResults[0].get()
        }
        return try prepareResults.removeFirst().get()
    }

    func nextRestart() throws -> DesktopRuntimeLaunchSnapshot {
        guard !restartResults.isEmpty else {
            throw StubError.missingRuntimeRestartResult
        }
        if restartResults.count == 1 {
            return try restartResults[0].get()
        }
        return try restartResults.removeFirst().get()
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
    case missingRuntimePrepareResult
    case missingRuntimeRestartResult

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
        case .missingRuntimePrepareResult:
            return "missing runtime supervisor prepare result"
        case .missingRuntimeRestartResult:
            return "missing runtime supervisor restart result"
        }
    }
}
