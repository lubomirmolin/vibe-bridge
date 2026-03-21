import Foundation

protocol ShellBridgeClient {
    func fetchHealth() async throws -> BridgeHealthResponseDTO
    func fetchThreads() async throws -> ThreadListResponseDTO
    func fetchPairingSession() async throws -> PairingSessionResponseDTO
    func revokeTrust(phoneID: String?) async throws -> PairingRevokeResponseDTO
}

struct BridgeShellAPIClient: ShellBridgeClient {
    let apiBaseURL: URL

    init(apiBaseURL: URL = URL(string: "http://127.0.0.1:3110")!) {
        self.apiBaseURL = apiBaseURL
    }

    func fetchHealth() async throws -> BridgeHealthResponseDTO {
        let bootstrap: BridgeBootstrapDTO = try await fetch(path: "/bootstrap", method: "GET")
        let pairingRoute: BridgePairingRouteHealthDTO = try await fetch(path: "/pairing/route", method: "GET")
        let trust: BridgeTrustStatusDTO = try await fetch(path: "/pairing/trust", method: "GET")
        return BridgeHealthResponseDTO(
            status: bootstrap.bridge.status == "healthy" ? "ok" : "degraded",
            runtime: BridgeRuntimeSnapshotDTO(
                mode: "auto",
                state: bootstrap.codex.status == "healthy" ? "managed" : "degraded",
                endpoint: nil,
                pid: nil,
                detail: bootstrap.codex.message ?? "Bridge is running."
            ),
            pairingRoute: pairingRoute,
            trust: trust,
            api: BridgeAPISurfaceDTO(
                endpoints: [
                    "GET /healthz",
                    "GET /bootstrap",
                    "GET /pairing/session",
                    "POST /pairing/finalize",
                    "POST /pairing/handshake",
                    "POST /pairing/trust/revoke",
                    "GET /threads",
                    "GET /threads/:thread_id/snapshot",
                    "GET /threads/:thread_id/history",
                    "POST /threads/:thread_id/turns",
                    "POST /threads/:thread_id/interrupt",
                    "GET /events"
                ],
                seededThreadCount: bootstrap.threads.count
            )
        )
    }

    func fetchThreads() async throws -> ThreadListResponseDTO {
        let threads: [ThreadSummaryDTO] = try await fetch(path: "/threads", method: "GET")
        return ThreadListResponseDTO(
            contractVersion: threads.first?.contractVersion ?? SharedContract.version,
            threads: threads
        )
    }

    func fetchPairingSession() async throws -> PairingSessionResponseDTO {
        try await fetch(path: "/pairing/session", method: "GET")
    }

    func revokeTrust(phoneID: String?) async throws -> PairingRevokeResponseDTO {
        var components = URLComponents(
            url: apiBaseURL.appending(path: "/pairing/trust/revoke"),
            resolvingAgainstBaseURL: false
        )
        var queryItems = [URLQueryItem(name: "actor", value: "desktop-shell")]
        if let phoneID, !phoneID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            queryItems.append(URLQueryItem(name: "phone_id", value: phoneID))
        }
        components?.queryItems = queryItems

        guard let url = components?.url else {
            throw BridgeShellAPIClientError.invalidResponse
        }

        return try await fetch(url: url, method: "POST")
    }

    private func fetch<T: Decodable>(path: String, method: String) async throws -> T {
        let endpoint = apiBaseURL.appending(path: path)
        return try await fetch(url: endpoint, method: method)
    }

    private func fetch<T: Decodable>(url: URL, method: String) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BridgeShellAPIClientError.invalidResponse
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? "<no body>"
            throw BridgeShellAPIClientError.unexpectedStatus(httpResponse.statusCode, bodyText)
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw BridgeShellAPIClientError.decodingFailure(error)
        }
    }
}

enum BridgeShellAPIClientError: LocalizedError {
    case invalidResponse
    case unexpectedStatus(Int, String)
    case decodingFailure(Error)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "bridge returned an invalid response"
        case let .unexpectedStatus(statusCode, body):
            return "bridge returned HTTP \(statusCode): \(body)"
        case let .decodingFailure(error):
            return "failed to decode bridge payload: \(error.localizedDescription)"
        case let .unsupported(message):
            return message
        }
    }
}

private struct BridgeBootstrapDTO: Decodable {
    let contractVersion: String
    let bridge: BridgeServiceHealthDTO
    let codex: BridgeServiceHealthDTO
    let threads: [ThreadSummaryDTO]

    enum CodingKeys: String, CodingKey {
        case contractVersion = "contract_version"
        case bridge
        case codex
        case threads
    }
}

private struct BridgeServiceHealthDTO: Decodable {
    let status: String
    let message: String?
}
