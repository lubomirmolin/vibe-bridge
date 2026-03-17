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

    @MainActor
    func testPairingViewModelLoadsSessionAndCreatesQRCode() async {
        let viewModel = PairingEntryViewModel(
            pairingClient: StubPairingSessionClient(result: .success(Self.samplePairingResponse))
        )

        await viewModel.refreshPairingSession()

        XCTAssertEqual(viewModel.pairingSession?.pairingSession.sessionID, "pairing-session-42")
        XCTAssertNotNil(viewModel.qrImage)
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testPairingViewModelReportsBridgeFailure() async {
        let viewModel = PairingEntryViewModel(
            pairingClient: StubPairingSessionClient(result: .failure(StubError.bridgeUnavailable))
        )

        await viewModel.refreshPairingSession()

        XCTAssertNil(viewModel.pairingSession)
        XCTAssertNil(viewModel.qrImage)
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.bridgeStatus, "Unavailable")
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
            expiresAtEpochSeconds: 400
        ),
        qrPayload: "bridge-sample|pairing-session-42|ptk-42"
    )
}

private struct StubPairingSessionClient: PairingSessionClient {
    let result: Result<PairingSessionResponseDTO, Error>

    func fetchPairingSession() async throws -> PairingSessionResponseDTO {
        try result.get()
    }
}

private enum StubError: LocalizedError {
    case bridgeUnavailable

    var errorDescription: String? {
        switch self {
        case .bridgeUnavailable:
            return "bridge unavailable"
        }
    }
}
