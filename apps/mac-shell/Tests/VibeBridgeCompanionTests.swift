import XCTest
@testable import VibeBridgeCompanion

final class VibeBridgeCompanionTests: XCTestCase {
    func testShellScaffoldBuilds() {
        XCTAssertTrue(true)
    }

    func testThreadSummaryDecodesSharedFixtureShape() throws {
        let json = """
        {
          "contract_version": "2026-03-29",
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
          "contract_version": "2026-03-29",
          "bridge_identity": {
            "bridge_id": "bridge-74dbf8ad31e2af1b",
            "display_name": "Vibe Bridge Companion",
            "api_base_url": "http://127.0.0.1:3110"
          },
          "bridge_api_routes": [
            {
              "id": "local_network",
              "kind": "local_network",
              "base_url": "http://192.168.1.10:3110",
              "reachable": true,
              "is_preferred": true
            }
          ],
          "pairing_session": {
            "session_id": "pairing-session-1",
            "pairing_token": "ptk-aabbccdd",
            "issued_at_epoch_seconds": 1,
            "expires_at_epoch_seconds": 301
          },
          "qr_payload": "{\\"v\\":\\"2026-03-29\\",\\"b\\":\\"bridge-74dbf8ad31e2af1b\\",\\"u\\":\\"http://192.168.1.10:3110\\",\\"r\\":[\\"http://192.168.1.10:3110\\"],\\"s\\":\\"pairing-session-1\\",\\"t\\":\\"ptk-aabbccdd\\"}"
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
        XCTAssertEqual(decoded.bridgeAPIRoutes.first?.baseURL, "http://192.168.1.10:3110")
    }

    func testBridgeTrustStatusDecodesMultiDevicePayloadWithLegacyFallback() throws {
        let json = """
        {
          "trusted_devices": [
            {
              "phone_id": "phone-1",
              "phone_name": "Primary Phone",
              "paired_at_epoch_seconds": 100
            },
            {
              "device_id": "phone-2",
              "device_name": "Backup Phone",
              "paired_at_epoch_seconds": 200
            }
          ],
          "trusted_sessions": [
            {
              "phone_id": "phone-1",
              "session_id": "pairing-session-42",
              "finalized_at_epoch_seconds": 120
            },
            {
              "device_id": "phone-2",
              "session_id": "pairing-session-43",
              "finalized_at_epoch_seconds": 220
            }
          ]
        }
        """

        let decoded = try JSONDecoder().decode(
            BridgeTrustStatusDTO.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(decoded.trustedDevices.count, 2)
        XCTAssertEqual(decoded.trustedDevices[0].deviceID, "phone-1")
        XCTAssertEqual(decoded.trustedDevices[1].deviceName, "Backup Phone")
        XCTAssertEqual(decoded.trustedSessions.count, 2)
        XCTAssertEqual(decoded.trustedSessions[1].sessionID, "pairing-session-43")
    }

    func testDesktopRuntimeSupervisorDefaultStateDirectoryUsesApplicationSupport() {
        let url = DesktopRuntimeSupervisor.defaultStateDirectoryURL()

        XCTAssertTrue(url.path.contains("/Library/Application Support/"))
        XCTAssertTrue(url.path.hasSuffix("/CodexMobileCompanion/bridge-core"))
    }

    func testBridgeSupervisorLogWriterPersistsTimestampedLines() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let logFileURL = tempDirectory.appendingPathComponent("bridge-supervisor.log")
        let fixedDate = Date(timeIntervalSince1970: 1_742_924_800)
        let writer = BridgeSupervisorLogWriter(
            fileManager: .default,
            logFileURL: logFileURL,
            now: { fixedDate }
        )

        writer.append("[supervisor] bridge helper launched")
        writer.append("[stderr] panic: listener failed")

        let contents = try String(contentsOf: logFileURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("[supervisor] bridge helper launched"))
        XCTAssertTrue(contents.contains("[stderr] panic: listener failed"))
        XCTAssertTrue(contents.contains("[202"))
    }

    func testBridgeTerminationSummaryIncludesSignalAndLogPath() {
        let summary = BridgeTerminationSummary.make(
            reason: .uncaughtSignal,
            status: 11,
            recentLogLines: [
                "[stdout] boot",
                "[stderr] thread 'main' panicked"
            ],
            logPath: "/tmp/bridge-supervisor.log"
        )

        XCTAssertTrue(summary.contains("crashed from signal 11"))
        XCTAssertTrue(summary.contains("[stderr] thread 'main' panicked"))
        XCTAssertTrue(summary.contains("/tmp/bridge-supervisor.log"))
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

    func testSemanticVersionOrdersPreReleaseBeforeStable() {
        XCTAssertLessThan(
            SemanticVersion(parsing: "1.2.3-beta.1")!,
            SemanticVersion(parsing: "1.2.3")!
        )
    }

    func testPreferredMacAssetPrefersZip() {
        let assets = [
            GitHubReleaseAsset(
                name: "codex-mobile-companion-macos-arm64-1.0.0.dmg",
                browserDownloadURL: URL(string: "https://github.com/lubomirmolin/vibe-bridge/releases/download/v1.0.0/codex-mobile-companion-macos-arm64-1.0.0.dmg")!
            ),
            GitHubReleaseAsset(
                name: "codex-mobile-companion-macos-arm64-1.0.0.zip",
                browserDownloadURL: URL(string: "https://github.com/lubomirmolin/vibe-bridge/releases/download/v1.0.0/codex-mobile-companion-macos-arm64-1.0.0.zip")!
            )
        ]

        XCTAssertEqual(
            GitHubReleaseUpdateChecker.preferredMacAsset(from: assets)?.name,
            "codex-mobile-companion-macos-arm64-1.0.0.zip"
        )
    }

    func testChecksumManifestParsesNamedAssetDigest() throws {
        let manifest = """
        1111111111111111111111111111111111111111111111111111111111111111  codex-mobile-companion-linux-x86_64-1.0.0.tar.gz
        2222222222222222222222222222222222222222222222222222222222222222  codex-mobile-companion-macos-arm64-1.0.0.zip
        """

        let digest = try GitHubInAppUpdater.parseDigestManifest(
            data: Data(manifest.utf8),
            assetName: "codex-mobile-companion-macos-arm64-1.0.0.zip"
        )

        XCTAssertEqual(
            digest,
            "2222222222222222222222222222222222222222222222222222222222222222"
        )
    }

    func testChecksumManifestParsesDigestWhenManifestIncludesDistPrefix() throws {
        let manifest = """
        2222222222222222222222222222222222222222222222222222222222222222  dist/codex-mobile-companion-macos-arm64-1.0.0.zip
        """

        let digest = try GitHubInAppUpdater.parseDigestManifest(
            data: Data(manifest.utf8),
            assetName: "codex-mobile-companion-macos-arm64-1.0.0.zip"
        )

        XCTAssertEqual(
            digest,
            "2222222222222222222222222222222222222222222222222222222222222222"
        )
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

    func testBridgeBinaryPathResolverPrefersBundledSpeechHelper() {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let resourcesDirectory = tempDirectory.appendingPathComponent("Resources", isDirectory: true)
        let bundledBinary = resourcesDirectory
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("CodexSpeechHelper")

        try? FileManager.default.createDirectory(
            at: bundledBinary.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? Data("speech".utf8).write(to: bundledBinary)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: bundledBinary.path
        )

        let resolver = BridgeBinaryPathResolver(
            environment: [:],
            currentDirectoryURL: tempDirectory,
            bundleResourceURL: resourcesDirectory
        )

        XCTAssertEqual(resolver.resolveSpeechHelperBinaryURL()?.path, bundledBinary.path)
    }

    func testSpeechModelStatusDecodesSharedContractShape() throws {
        let json = """
        {
          "contract_version": "2026-03-29",
          "provider": "fluid_audio",
          "model_id": "parakeet-tdt-0.6b-v3-coreml",
          "state": "installing",
          "download_progress": 42,
          "last_error": null,
          "installed_bytes": 1024
        }
        """

        let decoded = try JSONDecoder().decode(
            SpeechModelStatusDTO.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(decoded.contractVersion, SharedContract.version)
        XCTAssertEqual(decoded.state, .installing)
        XCTAssertEqual(decoded.downloadProgress, 42)
        XCTAssertEqual(decoded.installedBytes, 1024)
    }

    func testBridgePortProcessRequiresCurrentShellOwnershipForManagedBridge() {
        let bridgeBinaryURL = URL(fileURLWithPath: "/tmp/VibeBridgeCompanion.app/Contents/Resources/bin/bridge-server")
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

        await viewModel.revokeTrustedDeviceFromDesktop(phoneID: "phone-1")

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

        await viewModel.revokeTrustedDeviceFromDesktop(phoneID: "phone-1")

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
                routes: sampleRoutes(pairingRouteReachable: pairingRouteReachable),
                message: pairingRouteMessage
            ),
            networkSettings: BridgeNetworkSettingsDTO(
                contractVersion: SharedContract.version,
                localNetworkPairingEnabled: false,
                routes: sampleRoutes(pairingRouteReachable: pairingRouteReachable),
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
            ),
            trustedDevices: [
                BridgeTrustedDeviceDTO(
                    deviceID: "phone-1",
                    deviceName: "Primary Phone",
                    pairedAtEpochSeconds: 100
                )
            ],
            trustedSessions: [
                BridgeTrustedSessionDTO(
                    deviceID: "phone-1",
                    sessionID: "pairing-session-42",
                    finalizedAtEpochSeconds: 120
                )
            ]
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
            displayName: "Vibe Bridge Companion",
            apiBaseURL: "http://127.0.0.1:3110"
        ),
        bridgeAPIRoutes: [
            BridgeAPIRouteDTO(
                id: "local_network",
                kind: .localNetwork,
                baseURL: "http://192.168.1.10:3110",
                reachable: true,
                isPreferred: true
            )
        ],
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

    private static func sampleRoutes(pairingRouteReachable: Bool) -> [BridgeAPIRouteDTO] {
        [
            BridgeAPIRouteDTO(
                id: "tailscale",
                kind: .tailscale,
                baseURL: "https://bridge.ts.net",
                reachable: pairingRouteReachable,
                isPreferred: pairingRouteReachable
            )
        ]
    }

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
        networkSettingsResults: [Result<BridgeNetworkSettingsDTO, Error>] = [
            .success(
                BridgeNetworkSettingsDTO(
                    contractVersion: SharedContract.version,
                    localNetworkPairingEnabled: false,
                    routes: [],
                    message: nil
                )
            )
        ],
        networkSettingsMutationResults: [Result<BridgeNetworkSettingsDTO, Error>] = [],
        speechResults: [Result<SpeechModelStatusDTO, Error>] = [
            .success(
                SpeechModelStatusDTO(
                    contractVersion: SharedContract.version,
                    provider: "fluid_audio",
                    modelID: "parakeet-tdt-0.6b-v3-coreml",
                    state: .notInstalled,
                    downloadProgress: nil,
                    lastError: nil,
                    installedBytes: nil
                )
            )
        ],
        speechEnsureResults: [Result<SpeechModelMutationAcceptedDTO, Error>] = [],
        speechRemoveResults: [Result<SpeechModelMutationAcceptedDTO, Error>] = [],
        revokeResults: [Result<PairingRevokeResponseDTO, Error>] = []
    ) {
        self.store = StubShellBridgeResponseStore(
            healthResults: healthResults,
            threadResults: threadResults,
            pairingResults: pairingResults,
            networkSettingsResults: networkSettingsResults,
            networkSettingsMutationResults: networkSettingsMutationResults,
            speechResults: speechResults,
            speechEnsureResults: speechEnsureResults,
            speechRemoveResults: speechRemoveResults,
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

    func fetchNetworkSettings() async throws -> BridgeNetworkSettingsDTO {
        try await store.nextNetworkSettings()
    }

    func setLocalNetworkPairingEnabled(_ enabled: Bool) async throws -> BridgeNetworkSettingsDTO {
        try await store.nextNetworkSettingsMutation(enabled: enabled)
    }

    func fetchSpeechModelStatus() async throws -> SpeechModelStatusDTO {
        try await store.nextSpeechStatus()
    }

    func ensureSpeechModel() async throws -> SpeechModelMutationAcceptedDTO {
        try await store.nextSpeechEnsure()
    }

    func removeSpeechModel() async throws -> SpeechModelMutationAcceptedDTO {
        try await store.nextSpeechRemove()
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
    private(set) var stopBridgeCallCount = 0

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

    func stopManagedBridge() {
        stopBridgeCallCount += 1
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
    private var networkSettingsResults: [Result<BridgeNetworkSettingsDTO, Error>]
    private var networkSettingsMutationResults: [Result<BridgeNetworkSettingsDTO, Error>]
    private var speechResults: [Result<SpeechModelStatusDTO, Error>]
    private var speechEnsureResults: [Result<SpeechModelMutationAcceptedDTO, Error>]
    private var speechRemoveResults: [Result<SpeechModelMutationAcceptedDTO, Error>]
    private var revokeResults: [Result<PairingRevokeResponseDTO, Error>]
    private var recordedRevokedPhoneIDs: [String?] = []

    init(
        healthResults: [Result<BridgeHealthResponseDTO, Error>],
        threadResults: [Result<ThreadListResponseDTO, Error>],
        pairingResults: [Result<PairingSessionResponseDTO, Error>],
        networkSettingsResults: [Result<BridgeNetworkSettingsDTO, Error>],
        networkSettingsMutationResults: [Result<BridgeNetworkSettingsDTO, Error>],
        speechResults: [Result<SpeechModelStatusDTO, Error>],
        speechEnsureResults: [Result<SpeechModelMutationAcceptedDTO, Error>],
        speechRemoveResults: [Result<SpeechModelMutationAcceptedDTO, Error>],
        revokeResults: [Result<PairingRevokeResponseDTO, Error>]
    ) {
        self.healthResults = healthResults
        self.threadResults = threadResults
        self.pairingResults = pairingResults
        self.networkSettingsResults = networkSettingsResults
        self.networkSettingsMutationResults = networkSettingsMutationResults
        self.speechResults = speechResults
        self.speechEnsureResults = speechEnsureResults
        self.speechRemoveResults = speechRemoveResults
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

    func nextNetworkSettings() throws -> BridgeNetworkSettingsDTO {
        guard !networkSettingsResults.isEmpty else {
            throw StubError.missingNetworkSettingsResult
        }
        if networkSettingsResults.count == 1 {
            return try networkSettingsResults[0].get()
        }
        return try networkSettingsResults.removeFirst().get()
    }

    func nextNetworkSettingsMutation(enabled: Bool) throws -> BridgeNetworkSettingsDTO {
        if !networkSettingsMutationResults.isEmpty {
            if networkSettingsMutationResults.count == 1 {
                return try networkSettingsMutationResults[0].get()
            }
            return try networkSettingsMutationResults.removeFirst().get()
        }

        return BridgeNetworkSettingsDTO(
            contractVersion: SharedContract.version,
            localNetworkPairingEnabled: enabled,
            routes: [],
            message: nil
        )
    }

    func nextSpeechStatus() throws -> SpeechModelStatusDTO {
        guard !speechResults.isEmpty else {
            throw StubError.missingSpeechStatusResult
        }
        return try speechResults.removeFirst().get()
    }

    func nextSpeechEnsure() throws -> SpeechModelMutationAcceptedDTO {
        guard !speechEnsureResults.isEmpty else {
            throw StubError.missingSpeechEnsureResult
        }
        return try speechEnsureResults.removeFirst().get()
    }

    func nextSpeechRemove() throws -> SpeechModelMutationAcceptedDTO {
        guard !speechRemoveResults.isEmpty else {
            throw StubError.missingSpeechRemoveResult
        }
        return try speechRemoveResults.removeFirst().get()
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
    case missingNetworkSettingsResult
    case missingSpeechStatusResult
    case missingSpeechEnsureResult
    case missingSpeechRemoveResult
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
        case .missingNetworkSettingsResult:
            return "missing stub network settings result"
        case .missingSpeechStatusResult:
            return "missing stub speech status result"
        case .missingSpeechEnsureResult:
            return "missing stub speech install result"
        case .missingSpeechRemoveResult:
            return "missing stub speech remove result"
        case .missingRevokeResult:
            return "missing stub revoke result"
        case .missingRuntimePrepareResult:
            return "missing runtime supervisor prepare result"
        case .missingRuntimeRestartResult:
            return "missing runtime supervisor restart result"
        }
    }
}
