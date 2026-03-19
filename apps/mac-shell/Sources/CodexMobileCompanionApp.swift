import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Darwin
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
        .menuBarExtraStyle(.window)

        Window("Pairing QR", id: PairingWindowID.qrCode) {
            PairingQRCodeWindowView(viewModel: pairingViewModel)
        }
        .defaultSize(width: 640, height: 760)
        .windowResizability(.contentSize)
    }
}

enum ShellRuntimeState: Equatable {
    case starting
    case unpaired
    case pairedIdle
    case pairedActive
    case degraded

    var displayName: String {
        switch self {
        case .starting:
            return "Starting"
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

private enum PairingEntryLayout {
    static let panelMinWidth: CGFloat = 500
    static let panelMinHeight: CGFloat = 620
    static let qrDimension: CGFloat = 320
    static let qrWindowDimension: CGFloat = 520
}

private enum PairingWindowID {
    static let qrCode = "pairing-qr-window"
}

struct DesktopRuntimeLaunchSnapshot: Equatable {
    let statusLabel: String
    let detail: String
    let isLaunching: Bool
}

protocol DesktopRuntimeSupervisorClient: AnyObject {
    func prepareBridgeForConnection() async throws -> DesktopRuntimeLaunchSnapshot
    func restartBridge() async throws -> DesktopRuntimeLaunchSnapshot
}

private struct PairingEntryView: View {
    @ObservedObject var viewModel: PairingEntryViewModel
    @Environment(\.openWindow) private var openWindow

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
                metadataRow(label: "Supervisor", value: viewModel.supervisorStatusLabel)
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

                Button(viewModel.isRestartingRuntime ? "Restarting…" : "Restart Local Runtime") {
                    Task {
                        await viewModel.restartLocalRuntime()
                    }
                }
                .disabled(viewModel.isRefreshingRuntime || viewModel.isRestartingRuntime)

                if viewModel.canRevokeTrust {
                    Button(viewModel.isRevokingTrust ? "Revoking…" : "Unpair Trusted Phone") {
                        Task {
                            await viewModel.revokeTrustedPhoneFromDesktop()
                        }
                    }
                    .disabled(viewModel.isRevokingTrust || viewModel.isRefreshingRuntime)
                }

                if viewModel.isLoadingPairing
                    || viewModel.isRefreshingRuntime
                    || viewModel.isRevokingTrust
                    || viewModel.isRestartingRuntime
                {
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
        .frame(
            minWidth: PairingEntryLayout.panelMinWidth,
            minHeight: PairingEntryLayout.panelMinHeight
        )
    }

    @ViewBuilder
    private var qrSection: some View {
        switch viewModel.shellState {
        case .starting:
            Text("Desktop app is starting the local bridge and Codex runtime. Pairing will unlock automatically once the stack reports healthy.")
                .font(.body)
                .foregroundStyle(.secondary)
                .padding(.vertical, 24)

        case .unpaired:
            if let qrImage = viewModel.qrImage,
               let response = viewModel.pairingSession
            {
                VStack(alignment: .leading, spacing: 12) {
                    Button {
                        openWindow(id: PairingWindowID.qrCode)
                    } label: {
                        Image(nsImage: qrImage)
                            .resizable()
                            .interpolation(.none)
                            .scaledToFit()
                            .frame(
                                width: PairingEntryLayout.qrDimension,
                                height: PairingEntryLayout.qrDimension
                            )
                            .padding(8)
                            .background(.background)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Open a larger pairing QR window")

                    Button("Open large QR window") {
                        openWindow(id: PairingWindowID.qrCode)
                    }
                    .controlSize(.large)

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

private struct PairingQRCodeWindowView: View {
    @ObservedObject var viewModel: PairingEntryViewModel

    var body: some View {
        Group {
            if let qrImage = viewModel.qrImage,
               let response = viewModel.pairingSession,
               viewModel.shellState == .unpaired
            {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("Pairing QR")
                            .font(.largeTitle)
                            .fontWeight(.semibold)

                        Text("Scan this code from the mobile app.")
                            .font(.headline)
                            .foregroundStyle(.secondary)

                        Image(nsImage: qrImage)
                            .resizable()
                            .interpolation(.none)
                            .scaledToFit()
                            .frame(
                                width: PairingEntryLayout.qrWindowDimension,
                                height: PairingEntryLayout.qrWindowDimension
                            )
                            .padding(12)
                            .background(.background)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
                            )

                        VStack(alignment: .leading, spacing: 12) {
                            metadataRow(label: "Session ID", value: response.pairingSession.sessionID)
                            metadataRow(label: "Bridge ID", value: response.bridgeIdentity.bridgeID)
                            metadataRow(
                                label: "Expires",
                                value: DateFormatter.pairingExpiry.string(
                                    from: Date(
                                        timeIntervalSince1970: TimeInterval(
                                            response.pairingSession.expiresAtEpochSeconds
                                        )
                                    )
                                )
                            )
                        }
                    }
                    .padding(24)
                }
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Pairing QR")
                        .font(.title)
                        .fontWeight(.semibold)

                    Text("No active pairing QR is available right now. Refresh the pairing session from the menu bar app and try again.")
                        .foregroundStyle(.secondary)
                }
                .padding(24)
                .frame(minWidth: 420, minHeight: 220, alignment: .topLeading)
            }
        }
    }

    private func metadataRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body.monospaced())
                .textSelection(.enabled)
        }
    }
}

@MainActor
final class PairingEntryViewModel: ObservableObject {
    @Published private(set) var shellState: ShellRuntimeState = .degraded
    @Published private(set) var supervisorStatusLabel = "Not started"
    @Published private(set) var bridgeRuntimeLabel = "Unavailable"
    @Published private(set) var pairedDeviceLabel = "Not paired"
    @Published private(set) var activeSessionLabel = "No active session"
    @Published private(set) var runningThreadCount = 0
    @Published private(set) var runtimeDetail = "Waiting for bridge supervision…"

    @Published private(set) var isLoadingPairing = false
    @Published private(set) var isRefreshingRuntime = false
    @Published private(set) var isRestartingRuntime = false
    @Published private(set) var isRevokingTrust = false
    @Published private(set) var pairingSession: PairingSessionResponseDTO?
    @Published private(set) var qrImage: NSImage?
    @Published private(set) var errorMessage: String?

    private var trustedPhoneID: String?

    private let bridgeClient: ShellBridgeClient
    private let runtimeSupervisor: DesktopRuntimeSupervisorClient
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
        runtimeSupervisor: DesktopRuntimeSupervisorClient = DesktopRuntimeSupervisor(),
        startSupervisionOnInit: Bool = false,
        degradedPollIntervalNanoseconds: UInt64 = 2_000_000_000,
        healthyPollIntervalNanoseconds: UInt64 = 5_000_000_000
    ) {
        self.bridgeClient = bridgeClient
        self.runtimeSupervisor = runtimeSupervisor
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

        var launchSnapshot: DesktopRuntimeLaunchSnapshot?
        do {
            let resolvedLaunchSnapshot = try await runtimeSupervisor.prepareBridgeForConnection()
            launchSnapshot = resolvedLaunchSnapshot
            supervisorStatusLabel = resolvedLaunchSnapshot.statusLabel

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
            if let runtimeError = error as? DesktopRuntimeSupervisorError {
                applyDegradedState("Desktop runtime startup failed: \(runtimeError.localizedDescription)")
                return
            }

            if let launchSnapshot, launchSnapshot.isLaunching {
                applyStartingState(
                    bridgeLabel: launchSnapshot.statusLabel,
                    detail: launchSnapshot.detail
                )
                return
            }

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

    private func applyStartingState(
        bridgeLabel: String = "Starting local runtime…",
        detail: String
    ) {
        shellState = .starting
        bridgeRuntimeLabel = bridgeLabel
        runningThreadCount = 0
        pairedDeviceLabel = "Waiting for bridge"
        activeSessionLabel = "Waiting for bridge"
        trustedPhoneID = nil
        runtimeDetail = detail
        pairingSession = nil
        qrImage = nil
        errorMessage = nil
    }

    private func applyDegradedState(_ message: String) {
        shellState = .degraded
        bridgeRuntimeLabel = "Unavailable"
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

    func restartLocalRuntime() async {
        guard !isRestartingRuntime else {
            return
        }

        isRestartingRuntime = true
        defer { isRestartingRuntime = false }

        do {
            let snapshot = try await runtimeSupervisor.restartBridge()
            supervisorStatusLabel = snapshot.statusLabel
            applyStartingState(detail: snapshot.detail)
            await refreshRuntimeState()
        } catch {
            let message = error.localizedDescription
            applyDegradedState("Desktop runtime restart failed: \(message)")
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

enum DesktopRuntimeSupervisorError: LocalizedError {
    case bridgeBinaryNotFound([String])
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case let .bridgeBinaryNotFound(candidates):
            let candidateList = candidates.joined(separator: ", ")
            return "bridge-server binary was not found. Checked \(candidateList). Set CODEX_MOBILE_COMPANION_BRIDGE_BINARY or bundle the helper into the app."
        case let .launchFailed(message):
            return message
        }
    }
}

final class DesktopRuntimeSupervisor: DesktopRuntimeSupervisorClient {
    private let healthProbe: BridgeHealthProbe
    private let pathResolver: BridgeBinaryPathResolver
    private let portProcessInspector: BridgePortProcessInspecting
    private let processEnvironment: [String: String]
    private let bridgeHost: String
    private let bridgePort: Int
    private let adminPort: Int
    private let codexCommandOverride: String?
    private let currentProcessID: Int32

    private var managedProcess: Process?
    private var recentLogLines: [String] = []
    private var lastExitSummary: String?

    init(
        healthProbe: BridgeHealthProbe = HTTPBridgeHealthProbe(),
        pathResolver: BridgeBinaryPathResolver = BridgeBinaryPathResolver(),
        portProcessInspector: BridgePortProcessInspecting = BridgePortProcessInspector(),
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        bridgeHost: String = "127.0.0.1",
        bridgePort: Int = 3110,
        adminPort: Int = 3111,
        codexCommandOverride: String? = ProcessInfo.processInfo.environment["CODEX_MOBILE_COMPANION_CODEX_BINARY"],
        currentProcessID: Int32 = Int32(ProcessInfo.processInfo.processIdentifier)
    ) {
        self.healthProbe = healthProbe
        self.pathResolver = pathResolver
        self.portProcessInspector = portProcessInspector
        self.processEnvironment = processEnvironment
        self.bridgeHost = bridgeHost
        self.bridgePort = bridgePort
        self.adminPort = adminPort
        self.codexCommandOverride = codexCommandOverride
        self.currentProcessID = currentProcessID
    }

    func prepareBridgeForConnection() async throws -> DesktopRuntimeLaunchSnapshot {
        let bridgeBinaryURL = try? pathResolver.resolveBridgeBinaryURL()
        if await healthProbe.isReachable(host: bridgeHost, port: bridgePort) {
            if let managedProcess, managedProcess.isRunning {
                return DesktopRuntimeLaunchSnapshot(
                    statusLabel: "Managed locally",
                    detail: "Desktop shell owns the local bridge process.",
                    isLaunching: false
                )
            }

            if managedProcess != nil {
                self.managedProcess = nil
            }

            if let listener = portProcessInspector.listener(on: bridgePort),
               let bridgeBinaryURL,
               listener.isManagedBridge(matching: bridgeBinaryURL, ownedBy: currentProcessID)
            {
                return DesktopRuntimeLaunchSnapshot(
                    statusLabel: "Managed locally",
                    detail: "Desktop shell found an existing bundled bridge helper (pid \(listener.pid)).",
                    isLaunching: false
                )
            }

            if let listener = portProcessInspector.listener(on: bridgePort),
               let bridgeBinaryURL,
               listener.isManagedBridge(matching: bridgeBinaryURL)
            {
                try terminateBridgeListener(listener)
                return try startBridgeProcess()
            }

            return DesktopRuntimeLaunchSnapshot(
                statusLabel: "Attached to existing bridge",
                detail: "An existing bridge is already listening on \(bridgeHost):\(bridgePort).",
                isLaunching: false
            )
        }

        if let managedProcess {
            if managedProcess.isRunning {
                return DesktopRuntimeLaunchSnapshot(
                    statusLabel: "Launching bridge",
                    detail: "Desktop shell started bridge-server (pid \(managedProcess.processIdentifier)). Waiting for health on \(bridgeHost):\(bridgePort)…",
                    isLaunching: true
                )
            }

            let exitSummary = lastExitSummary
            self.managedProcess = nil
            let exitDetail = exitSummary ?? "bridge-server exited before reporting healthy"
            recentLogLines.removeAll()
            lastExitSummary = nil
            throw DesktopRuntimeSupervisorError.launchFailed(exitDetail)
        }

        return try startBridgeProcess()
    }

    func restartBridge() async throws -> DesktopRuntimeLaunchSnapshot {
        let externalBridgeReachable = await healthProbe.isReachable(host: bridgeHost, port: bridgePort)
        if managedProcess == nil && externalBridgeReachable {
            let bridgeBinaryURL = try? pathResolver.resolveBridgeBinaryURL()
            if let listener = portProcessInspector.listener(on: bridgePort),
               let bridgeBinaryURL,
               listener.isManagedBridge(matching: bridgeBinaryURL)
            {
                try terminateBridgeListener(listener)
            } else {
                throw DesktopRuntimeSupervisorError.launchFailed(
                    "desktop shell cannot restart the bridge because it is attached to an external process on \(bridgeHost):\(bridgePort)"
                )
            }
        }

        stopManagedProcess()
        return try startBridgeProcess()
    }

    private func startBridgeProcess() throws -> DesktopRuntimeLaunchSnapshot {
        let bridgeBinaryURL = try pathResolver.resolveBridgeBinaryURL()
        let process = Process()
        process.executableURL = bridgeBinaryURL
        process.arguments = bridgeArguments()
        process.environment = processEnvironment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        wirePipe(stdoutPipe, source: "stdout")
        wirePipe(stderrPipe, source: "stderr")

        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async { [weak self] in
                self?.handleTermination(process)
            }
        }

        do {
            try process.run()
        } catch {
            throw DesktopRuntimeSupervisorError.launchFailed(
                "failed to launch bridge-server at \(bridgeBinaryURL.path): \(error.localizedDescription)"
            )
        }

        managedProcess = process
        return DesktopRuntimeLaunchSnapshot(
            statusLabel: "Launching bridge",
            detail: "Desktop shell launched bridge-server (pid \(process.processIdentifier)). Waiting for health on \(bridgeHost):\(bridgePort)…",
            isLaunching: true
        )
    }

    private func bridgeArguments() -> [String] {
        var arguments = [
            "--host", bridgeHost,
            "--port", "\(bridgePort)",
            "--admin-port", "\(adminPort)",
            "--codex-mode", "auto",
        ]

        if let codexCommandOverride,
           !codexCommandOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            arguments.append(contentsOf: ["--codex-command", codexCommandOverride])
        } else if let resolvedCodexBinaryURL = pathResolver.resolveCodexBinaryURL() {
            arguments.append(contentsOf: ["--codex-command", resolvedCodexBinaryURL.path])
        }

        return arguments
    }

    private func terminateBridgeListener(_ listener: BridgePortProcess) throws {
        guard kill(listener.pid, SIGTERM) == 0 else {
            throw DesktopRuntimeSupervisorError.launchFailed(
                "failed to stop existing bundled bridge helper (pid \(listener.pid)): \(String(cString: strerror(errno)))"
            )
        }

        for _ in 0..<20 {
            if portProcessInspector.listener(on: bridgePort)?.pid != listener.pid {
                return
            }

            Thread.sleep(forTimeInterval: 0.1)
        }

        throw DesktopRuntimeSupervisorError.launchFailed(
            "timed out waiting for existing bundled bridge helper (pid \(listener.pid)) to stop"
        )
    }

    private func wirePipe(_ pipe: Pipe, source: String) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }

            let chunk = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { [weak self] in
                self?.appendLogLines(chunk, source: source)
            }
        }
    }

    private func appendLogLines(_ chunk: String, source: String) {
        let lines = chunk
            .split(whereSeparator: \.isNewline)
            .map { "[\(source)] \($0)" }

        guard !lines.isEmpty else {
            return
        }

        recentLogLines.append(contentsOf: lines)
        if recentLogLines.count > 20 {
            recentLogLines.removeFirst(recentLogLines.count - 20)
        }
    }

    private func handleTermination(_ process: Process) {
        let summary = "bridge-server exited with status \(process.terminationStatus). \(recentLogTail())"
        lastExitSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)

        if managedProcess === process {
            managedProcess = nil
        }
    }

    private func stopManagedProcess() {
        guard let process = managedProcess else {
            recentLogLines.removeAll()
            lastExitSummary = nil
            return
        }

        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        managedProcess = nil
        recentLogLines.removeAll()
        lastExitSummary = nil
    }

    private func recentLogTail() -> String {
        guard !recentLogLines.isEmpty else {
            return ""
        }

        return "Recent logs: \(recentLogLines.suffix(4).joined(separator: " | "))"
    }
}

struct BridgeBinaryPathResolver {
    private let fileManager: FileManager
    private let environment: [String: String]
    private let currentDirectoryURL: URL
    private let bundleResourceURL: URL?

    init(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectoryURL: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
        bundleResourceURL: URL? = Bundle.main.resourceURL
    ) {
        self.fileManager = fileManager
        self.environment = environment
        self.currentDirectoryURL = currentDirectoryURL
        self.bundleResourceURL = bundleResourceURL
    }

    func resolveBridgeBinaryURL() throws -> URL {
        let candidates = bridgeBinaryCandidates()
        if let resolved = resolveExecutableURL(candidates: candidates) {
            return resolved
        }

        throw DesktopRuntimeSupervisorError.bridgeBinaryNotFound(candidates.map(\.path))
    }

    func resolveCodexBinaryURL() -> URL? {
        resolveExecutableURL(candidates: codexBinaryCandidates())
    }

    private func bridgeBinaryCandidates() -> [URL] {
        var candidates: [URL] = []

        if let explicitPath = environment["CODEX_MOBILE_COMPANION_BRIDGE_BINARY"],
           !explicitPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            candidates.append(URL(fileURLWithPath: explicitPath))
        }

        if let bundleResourceURL {
            candidates.append(bundleResourceURL.appending(path: "bridge-server"))
            candidates.append(bundleResourceURL.appending(path: "bin").appending(path: "bridge-server"))
        }

        let searchRoots = [currentDirectoryURL, bundleResourceURL].compactMap { $0 }
        for root in searchRoots {
            if let workspaceRoot = workspaceRoot(startingAt: root) {
                candidates.append(workspaceRoot.appending(path: "target").appending(path: "debug").appending(path: "bridge-server"))
                candidates.append(workspaceRoot.appending(path: "target").appending(path: "release").appending(path: "bridge-server"))
            }
        }

        candidates.append(contentsOf: pathExecutableCandidates(named: "bridge-server"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/bridge-server"))
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/bridge-server"))

        return deduplicated(candidates)
    }

    private func codexBinaryCandidates() -> [URL] {
        var candidates: [URL] = []
        let homeDirectoryPath = environment["HOME"] ?? NSHomeDirectory()

        if let explicitPath = environment["CODEX_MOBILE_COMPANION_CODEX_BINARY"],
           !explicitPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            candidates.append(URL(fileURLWithPath: explicitPath))
        }

        candidates.append(contentsOf: pathExecutableCandidates(named: "codex"))
        candidates.append(URL(fileURLWithPath: homeDirectoryPath).appending(path: ".bun").appending(path: "bin").appending(path: "codex"))
        candidates.append(URL(fileURLWithPath: homeDirectoryPath).appending(path: ".cargo").appending(path: "bin").appending(path: "codex"))
        candidates.append(URL(fileURLWithPath: homeDirectoryPath).appending(path: ".local").appending(path: "bin").appending(path: "codex"))
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/codex"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/codex"))

        return deduplicated(candidates)
    }

    private func pathExecutableCandidates(named executableName: String) -> [URL] {
        guard let rawPath = environment["PATH"], !rawPath.isEmpty else {
            return []
        }

        return rawPath
            .split(separator: ":")
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: String($0), isDirectory: true).appending(path: executableName) }
    }

    private func resolveExecutableURL(candidates: [URL]) -> URL? {
        candidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) })
    }

    private func deduplicated(_ candidates: [URL]) -> [URL] {
        var uniqueCandidates: [URL] = []
        var seenPaths = Set<String>()
        for candidate in candidates where seenPaths.insert(candidate.path).inserted {
            uniqueCandidates.append(candidate)
        }
        return uniqueCandidates
    }

    private func workspaceRoot(startingAt startURL: URL) -> URL? {
        var currentURL = startURL.standardizedFileURL
        for _ in 0..<10 {
            let cargoURL = currentURL.appending(path: "Cargo.toml")
            let shellURL = currentURL.appending(path: "apps").appending(path: "mac-shell")
            if fileManager.fileExists(atPath: cargoURL.path) && fileManager.fileExists(atPath: shellURL.path) {
                return currentURL
            }

            let parentURL = currentURL.deletingLastPathComponent()
            if parentURL.path == currentURL.path {
                break
            }
            currentURL = parentURL
        }

        return nil
    }
}

struct BridgePortProcess: Equatable {
    let pid: Int32
    let parentPID: Int32?
    let command: String

    func isManagedBridge(matching bridgeBinaryURL: URL) -> Bool {
        command.hasPrefix(bridgeBinaryURL.path)
    }

    func isManagedBridge(matching bridgeBinaryURL: URL, ownedBy parentPID: Int32) -> Bool {
        isManagedBridge(matching: bridgeBinaryURL) && self.parentPID == parentPID
    }
}

protocol BridgePortProcessInspecting {
    func listener(on port: Int) -> BridgePortProcess?
}

struct BridgePortProcessInspector: BridgePortProcessInspecting {
    func listener(on port: Int) -> BridgePortProcess? {
        guard let pidString = run("/usr/sbin/lsof", arguments: ["-t", "-nP", "-iTCP:\(port)", "-sTCP:LISTEN"])?
            .split(whereSeparator: \.isNewline)
            .first
        else {
            return nil
        }

        let trimmedPID = pidString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = Int32(trimmedPID) else {
            return nil
        }

        guard let command = run("/bin/ps", arguments: ["-p", trimmedPID, "-o", "command="])?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty
        else {
            return nil
        }

        let parentPID = run("/bin/ps", arguments: ["-p", trimmedPID, "-o", "ppid="])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedParentPID = parentPID.flatMap(Int32.init)

        return BridgePortProcess(pid: pid, parentPID: parsedParentPID, command: command)
    }

    private func run(_ launchPath: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }
}

protocol BridgeHealthProbe {
    func isReachable(host: String, port: Int) async -> Bool
}

struct HTTPBridgeHealthProbe: BridgeHealthProbe {
    func isReachable(host: String, port: Int) async -> Bool {
        guard let url = URL(string: "http://\(host):\(port)/health") else {
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 1
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return false
            }
            return (200 ..< 300).contains(httpResponse.statusCode)
        } catch {
            return false
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

        let targetDimension = PairingEntryLayout.qrDimension
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
