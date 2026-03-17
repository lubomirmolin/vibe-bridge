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
}
