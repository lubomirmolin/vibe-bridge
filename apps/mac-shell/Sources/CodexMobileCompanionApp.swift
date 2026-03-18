import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import SwiftUI

@main
struct CodexMobileCompanionApp: App {
    @StateObject private var pairingViewModel: PairingEntryViewModel

    init() {
        _pairingViewModel = StateObject(
            wrappedValue: PairingEntryViewModel(startSupervisionOnInit: true)
        )
    }

    var body: some Scene {
        MenuBarExtra("Codex Mobile Companion", systemImage: "iphone.gen3") {
            PairingEntryView(viewModel: pairingViewModel)
        }
    }
}

enum ShellRuntimeState: Equatable {
    case unpaired
    case pairedIdle
    case pairedActive
    case degraded

    var displayName: String {
        switch self {
        case .unpaired:
            return "Unpaired"
        case .pairedIdle:
            return "Paired (Idle)"
        case .pairedActive:
            return "Paired (Active)"
        case .degraded:
            return "Degraded"
        }
    }
}

private struct PairingEntryView: View {
    @ObservedObject var viewModel: PairingEntryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Codex Mobile Companion")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Desktop shell runtime supervision")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Group {
                metadataRow(label: "Shell state", value: viewModel.shellState.displayName)
                metadataRow(label: "Bridge", value: viewModel.bridgeRuntimeLabel)
                metadataRow(label: "Paired phone", value: viewModel.pairedDeviceLabel)
                metadataRow(label: "Active session", value: viewModel.activeSessionLabel)
                metadataRow(label: "Active threads", value: "\(viewModel.runningThreadCount)")
            }

            Text(viewModel.runtimeDetail)
                .font(.footnote)
                .foregroundStyle(viewModel.shellState == .degraded ? .red : .secondary)

            qrSection

            HStack(spacing: 12) {
                Button(viewModel.isLoadingPairing ? "Generating…" : "Refresh Pairing QR") {
                    Task {
                        await viewModel.refreshPairingSession()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(viewModel.isLoadingPairing || !viewModel.shouldShowPairingQR)

                Button("Retry Bridge Now") {
                    Task {
                        await viewModel.refreshRuntimeState()
                    }
                }
                .disabled(viewModel.isRefreshingRuntime)

                if viewModel.canRevokeTrust {
                    Button(viewModel.isRevokingTrust ? "Revoking…" : "Unpair Trusted Phone") {
                        Task {
                            await viewModel.revokeTrustedPhoneFromDesktop()
                        }
                    }
                    .disabled(viewModel.isRevokingTrust || viewModel.isRefreshingRuntime)
                }

                if viewModel.isLoadingPairing || viewModel.isRefreshingRuntime || viewModel.isRevokingTrust {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 520)
    }

    @ViewBuilder
    private var qrSection: some View {
        switch viewModel.shellState {
        case .unpaired:
            if let qrImage = viewModel.qrImage,
               let response = viewModel.pairingSession
            {
                VStack(alignment: .leading, spacing: 12) {
                    Image(nsImage: qrImage)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .frame(width: 240, height: 240)
                        .padding(8)
                        .background(.background)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
                        )

                    metadataRow(label: "Session ID", value: response.pairingSession.sessionID)
                    metadataRow(label: "Bridge ID", value: response.bridgeIdentity.bridgeID)
                    metadataRow(
                        label: "Expires",
                        value: DateFormatter.pairingExpiry.string(from: Date(timeIntervalSince1970: TimeInterval(response.pairingSession.expiresAtEpochSeconds)))
                    )
                }
            } else {
                Text("Bridge is reachable but no pairing QR is cached yet. Use “Refresh Pairing QR”.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 24)
            }

        case .pairedIdle, .pairedActive:
            Text("This Mac is already paired. Existing trusted phone sessions stay active without rescanning. Use “Unpair Trusted Phone” to revoke trust and require a fresh pairing flow.")
                .font(.body)
                .foregroundStyle(.secondary)
                .padding(.vertical, 24)

        case .degraded:
            Text("Bridge is degraded or restarting. Supervision is retrying automatically and will recover when bridge health returns.")
                .font(.body)
                .foregroundStyle(.secondary)
                .padding(.vertical, 24)
        }
    }

    private func metadataRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(label):")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
        }
    }
}

@MainActor
final class PairingEntryViewModel: ObservableObject {
    @Published private(set) var shellState: ShellRuntimeState = .degraded
    @Published private(set) var bridgeRuntimeLabel = "Unavailable"
    @Published private(set) var pairedDeviceLabel = "Not paired"
    @Published private(set) var activeSessionLabel = "No active session"
    @Published private(set) var runningThreadCount = 0
    @Published private(set) var runtimeDetail = "Waiting for bridge supervision…"

    @Published private(set) var isLoadingPairing = false
    @Published private(set) var isRefreshingRuntime = false
    @Published private(set) var isRevokingTrust = false
    @Published private(set) var pairingSession: PairingSessionResponseDTO?
    @Published private(set) var qrImage: NSImage?
    @Published private(set) var errorMessage: String?

    private var trustedPhoneID: String?

    private let bridgeClient: ShellBridgeClient
    private var supervisionTask: Task<Void, Never>?
    private let degradedPollIntervalNanoseconds: UInt64
    private let healthyPollIntervalNanoseconds: UInt64

    var bridgeStatus: String {
        shellState == .degraded ? "Unavailable" : "Connected"
    }

    var shouldShowPairingQR: Bool {
        shellState == .unpaired
    }

    var canRevokeTrust: Bool {
        shellState == .pairedIdle || shellState == .pairedActive
    }

    init(
        bridgeClient: ShellBridgeClient = BridgeShellAPIClient(),
        startSupervisionOnInit: Bool = false,
        degradedPollIntervalNanoseconds: UInt64 = 2_000_000_000,
        healthyPollIntervalNanoseconds: UInt64 = 5_000_000_000
    ) {
        self.bridgeClient = bridgeClient
        self.degradedPollIntervalNanoseconds = degradedPollIntervalNanoseconds
        self.healthyPollIntervalNanoseconds = healthyPollIntervalNanoseconds

        if startSupervisionOnInit {
            startRuntimeSupervision()
        }
    }

    deinit {
        supervisionTask?.cancel()
    }

    func startRuntimeSupervision() {
        guard supervisionTask == nil else {
            return
        }

        supervisionTask = Task { [weak self] in
            guard let self else {
                return
            }

            await self.refreshRuntimeState()

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: self.pollIntervalNanoseconds)
                await self.refreshRuntimeState()
            }
        }
    }

    func stopRuntimeSupervision() {
        supervisionTask?.cancel()
        supervisionTask = nil
    }

    func refreshRuntimeState() async {
        guard !isRefreshingRuntime else {
            return
        }

        isRefreshingRuntime = true
        defer { isRefreshingRuntime = false }

        do {
            let health = try await bridgeClient.fetchHealth()
            bridgeRuntimeLabel = "\(health.runtime.state) (\(health.runtime.mode))"
            runtimeDetail = health.runtime.detail

            switch ShellStateResolver.resolveRuntimeHealth(health) {
            case let .degraded(message):
                applyDegradedState(message)
                return

            case let .healthy(trustStatus):
                let threadsResponse = try await bridgeClient.fetchThreads()
                let runningCount = threadsResponse.threads.filter { $0.status == .running }.count
                runningThreadCount = runningCount
                applyHealthyState(trustStatus: trustStatus, runningThreadCount: runningCount)

                if shellState == .unpaired {
                    await refreshPairingSessionIfNeeded()
                }
            }
        } catch {
            applyDegradedState("Bridge supervision retrying: \(error.localizedDescription)")
        }
    }

    private var pollIntervalNanoseconds: UInt64 {
        shellState == .degraded
            ? degradedPollIntervalNanoseconds
            : healthyPollIntervalNanoseconds
    }

    private func applyHealthyState(
        trustStatus: BridgeTrustStatusDTO?,
        runningThreadCount: Int
    ) {
        shellState = ShellStateResolver.resolveShellState(
            trustStatus: trustStatus,
            runningThreadCount: runningThreadCount
        )

        if let trustedPhone = trustStatus?.trustedPhone {
            pairedDeviceLabel = "\(trustedPhone.phoneName) (\(trustedPhone.phoneID))"
            trustedPhoneID = trustedPhone.phoneID
        } else {
            pairedDeviceLabel = "Not paired"
            trustedPhoneID = nil
        }

        if let activeSession = trustStatus?.activeSession {
            activeSessionLabel = activeSession.sessionID
        } else {
            activeSessionLabel = "No active session"
        }

        errorMessage = nil

        if shellState != .unpaired {
            pairingSession = nil
            qrImage = nil
        }
    }

    private func applyDegradedState(_ message: String) {
        shellState = .degraded
        runningThreadCount = 0
        pairedDeviceLabel = "Unavailable"
        activeSessionLabel = "Unavailable"
        trustedPhoneID = nil
        runtimeDetail = message
        pairingSession = nil
        qrImage = nil
        errorMessage = message
    }

    func revokeTrustedPhoneFromDesktop() async {
        guard !isRevokingTrust else {
            return
        }

        isRevokingTrust = true
        defer { isRevokingTrust = false }

        do {
            let response = try await bridgeClient.revokeTrust(phoneID: trustedPhoneID)
            if response.revoked {
                errorMessage = nil
                runtimeDetail = "Desktop trust revoked. The phone must pair again before reconnecting."
                await refreshRuntimeState()
                if shellState == .unpaired {
                    await refreshPairingSessionIfNeeded()
                }
                return
            }

            errorMessage = "No trusted phone was available to revoke."
        } catch {
            errorMessage = "Failed to revoke trust from desktop shell: \(error.localizedDescription)"
        }
    }

    func refreshPairingSessionIfNeeded() async {
        guard shouldShowPairingQR, !isLoadingPairing else {
            return
        }

        if hasFreshPairingSession {
            return
        }

        await refreshPairingSession()
    }

    func refreshPairingSession() async {
        guard shouldShowPairingQR, !isLoadingPairing else {
            return
        }

        isLoadingPairing = true
        defer { isLoadingPairing = false }

        do {
            let response = try await bridgeClient.fetchPairingSession()
            guard let generatedQR = PairingQRCodeRenderer.makeImage(from: response.qrPayload) else {
                throw PairingViewModelError.invalidPayload
            }

            pairingSession = response
            qrImage = generatedQR
            errorMessage = nil
        } catch {
            pairingSession = nil
            qrImage = nil
            errorMessage = "Failed to generate pairing QR from bridge data: \(error.localizedDescription)"
        }
    }

    private var hasFreshPairingSession: Bool {
        guard let pairingSession else {
            return false
        }

        let now = UInt64(Date().timeIntervalSince1970)
        return pairingSession.pairingSession.expiresAtEpochSeconds > now + 15
    }
}

enum RuntimeHealthResolution {
    case healthy(BridgeTrustStatusDTO?)
    case degraded(String)
}

struct ShellStateResolver {
    static func resolveRuntimeHealth(_ health: BridgeHealthResponseDTO) -> RuntimeHealthResolution {
        guard health.status == "ok" else {
            return .degraded("Bridge health endpoint reported status \(health.status).")
        }

        if !health.pairingRoute.reachable {
            return .degraded(
                health.pairingRoute.message ?? "Private pairing route is unavailable."
            )
        }

        if health.runtime.state == "degraded" {
            return .degraded(health.runtime.detail)
        }

        return .healthy(health.trust)
    }

    static func resolveShellState(
        trustStatus: BridgeTrustStatusDTO?,
        runningThreadCount: Int
    ) -> ShellRuntimeState {
        guard trustStatus?.trustedPhone != nil else {
            return .unpaired
        }

        return runningThreadCount > 0 ? .pairedActive : .pairedIdle
    }
}

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
        try await fetch(path: "/health", method: "GET")
    }

    func fetchThreads() async throws -> ThreadListResponseDTO {
        try await fetch(path: "/threads", method: "GET")
    }

    func fetchPairingSession() async throws -> PairingSessionResponseDTO {
        try await fetch(path: "/pairing/session", method: "POST")
    }

    func revokeTrust(phoneID: String?) async throws -> PairingRevokeResponseDTO {
        var components = URLComponents(url: apiBaseURL.appending(path: "/pairing/trust/revoke"), resolvingAgainstBaseURL: false)
        var queryItems: [URLQueryItem] = [URLQueryItem(name: "actor", value: "desktop-shell")]
        if let phoneID, !phoneID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            queryItems.append(URLQueryItem(name: "phone_id", value: phoneID))
        }
        components?.queryItems = queryItems

        guard let endpoint = components?.url else {
            throw BridgeShellAPIClientError.invalidResponse
        }

        return try await fetch(url: endpoint, method: "POST")
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

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "bridge returned an invalid response"
        case let .unexpectedStatus(statusCode, body):
            return "bridge returned HTTP \(statusCode): \(body)"
        case let .decodingFailure(error):
            return "failed to decode bridge payload: \(error.localizedDescription)"
        }
    }
}

enum PairingViewModelError: LocalizedError {
    case invalidPayload

    var errorDescription: String? {
        switch self {
        case .invalidPayload:
            return "bridge QR payload could not be rendered"
        }
    }
}

struct PairingQRCodeRenderer {
    static func makeImage(from payload: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("Q", forKey: "inputCorrectionLevel")

        guard let outputImage = filter.outputImage else {
            return nil
        }

        let targetDimension: CGFloat = 240
        let scaleX = targetDimension / outputImage.extent.width
        let scaleY = targetDimension / outputImage.extent.height
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        let representation = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}

private extension DateFormatter {
    static let pairingExpiry: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()
}
