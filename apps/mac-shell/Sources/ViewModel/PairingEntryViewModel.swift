import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import SwiftUI

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

struct DesktopRuntimeLaunchSnapshot: Equatable {
    let statusLabel: String
    let detail: String
    let isLaunching: Bool
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
        guard trustStatus?.trustedDevices.isEmpty == false else {
            return .unpaired
        }

        return runningThreadCount > 0 ? .pairedActive : .pairedIdle
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
    private static let targetDimension: CGFloat = 260

    static func makeImage(from payload: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")

        guard let outputImage = filter.outputImage else {
            return nil
        }

        let scaleX = targetDimension / outputImage.extent.width
        let scaleY = targetDimension / outputImage.extent.height
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        let representation = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}

@MainActor
final class PairingEntryViewModel: ObservableObject {
    @Published private(set) var shellState: ShellRuntimeState = .degraded
    @Published private(set) var supervisorStatusLabel = "Not started"
    @Published private(set) var bridgeRuntimeLabel = "Unavailable"
    @Published private(set) var pairedDeviceLabel = "Not paired"
    @Published private(set) var activeSessionLabel = "No active session"
    @Published private(set) var trustedDevices: [BridgeTrustedDeviceDTO] = []
    @Published private(set) var trustedSessions: [BridgeTrustedSessionDTO] = []
    @Published private(set) var runningThreadCount = 0
    @Published private(set) var runtimeDetail = "Waiting for bridge supervision…"
    @Published private(set) var speechModelState: SpeechModelStateDTO = .unsupported
    @Published private(set) var speechModelStateLabel = "Unavailable"
    @Published private(set) var speechModelDetail = "Speech helper not detected."
    @Published private(set) var speechDownloadProgress: UInt8?
    @Published private(set) var isInstallingSpeechModel = false
    @Published private(set) var isRemovingSpeechModel = false
    @Published private(set) var localNetworkPairingEnabled = false
    @Published private(set) var pairingRoutes: [BridgeAPIRouteDTO] = []
    @Published private(set) var isUpdatingNetworkSettings = false

    @Published private(set) var isLoadingPairing = false
    @Published private(set) var isRefreshingRuntime = false
    @Published private(set) var isRestartingRuntime = false
    @Published private(set) var isRevokingTrust = false
    @Published private(set) var pairingSession: PairingSessionResponseDTO?
    @Published private(set) var qrImage: NSImage?
    @Published private(set) var errorMessage: String?

    private let bridgeClient: ShellBridgeClient
    private let runtimeSupervisor: DesktopRuntimeSupervisorClient
    private var supervisionTask: Task<Void, Never>?
    private var terminationObserver: NSObjectProtocol?
    private let degradedPollIntervalNanoseconds: UInt64
    private let healthyPollIntervalNanoseconds: UInt64

    var bridgeStatus: String {
        shellState == .degraded ? "Unavailable" : "Connected"
    }

    var shouldShowPairingQR: Bool {
        shellState != .starting && shellState != .degraded
    }

    var canRevokeTrust: Bool {
        !trustedDevices.isEmpty
    }

    var hasTrustedDevices: Bool {
        !trustedDevices.isEmpty
    }

    var canInstallSpeechModel: Bool {
        !isInstallingSpeechModel && !isRemovingSpeechModel &&
            speechModelState != .ready &&
            speechModelState != .unsupported &&
            shellState != .degraded
    }

    var canRemoveSpeechModel: Bool {
        !isInstallingSpeechModel && !isRemovingSpeechModel &&
            speechModelState == .ready
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
        self.terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.supervisionTask?.cancel()
                self?.supervisionTask = nil
                self?.runtimeSupervisor.shutdownBridgeIfManaged()
            }
        }

        if startSupervisionOnInit {
            startRuntimeSupervision()
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
        supervisionTask?.cancel()
        supervisionTask = nil
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
        runtimeSupervisor.shutdownBridgeIfManaged()
    }

    func stopBridgeExplicitly() {
        supervisionTask?.cancel()
        supervisionTask = nil
        runtimeSupervisor.stopManagedBridge()
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
                pairingRoutes = health.pairingRoute.routes
                localNetworkPairingEnabled = health.networkSettings.localNetworkPairingEnabled

                switch ShellStateResolver.resolveRuntimeHealth(health) {
            case let .degraded(message):
                applyDegradedState(message)
                return

            case let .healthy(trustStatus):
                let threadsResponse = try await bridgeClient.fetchThreads()
                let runningCount = threadsResponse.threads.filter { $0.status == .running }.count
                runningThreadCount = runningCount
                applyHealthyState(
                    trustStatus: trustStatus,
                    runningThreadCount: runningCount,
                    pairingRoute: health.pairingRoute
                )
                try? await refreshSpeechStatus()

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
        runningThreadCount: Int,
        pairingRoute: BridgePairingRouteHealthDTO
    ) {
        shellState = ShellStateResolver.resolveShellState(
            trustStatus: trustStatus,
            runningThreadCount: runningThreadCount
        )

        let trustedDevices = trustStatus?.trustedDevices ?? []
        self.trustedDevices = trustedDevices
        if let primaryDevice = trustedDevices.first {
            pairedDeviceLabel = trustedDevices.count > 1
                ? "\(trustedDevices.count) devices"
                : "\(primaryDevice.deviceName) (\(primaryDevice.deviceID))"
        } else {
            pairedDeviceLabel = "Not paired"
        }

        let trustedSessions = trustStatus?.trustedSessions ?? []
        self.trustedSessions = trustedSessions

        if let activeSession = trustedSessions.first {
            activeSessionLabel = trustedSessions.count > 1
                ? "\(trustedSessions.count) active sessions"
                : activeSession.sessionID
        } else {
            activeSessionLabel = "No active session"
        }

        errorMessage = nil
        runtimeDetail = pairingRoute.message ?? runtimeDetail
    }

    private func applyStartingState(
        bridgeLabel: String = "Starting local runtime…",
        detail: String
    ) {
        shellState = .starting
        bridgeRuntimeLabel = bridgeLabel
        runningThreadCount = 0
        trustedDevices = []
        trustedSessions = []
        pairedDeviceLabel = "Waiting for bridge"
        activeSessionLabel = "Waiting for bridge"
        runtimeDetail = detail
        speechModelStateLabel = "Starting"
        speechModelState = .busy
        speechModelDetail = "Waiting for bridge supervision…"
        speechDownloadProgress = nil
        pairingSession = nil
        qrImage = nil
        errorMessage = nil
    }

    private func applyDegradedState(_ message: String) {
        shellState = .degraded
        bridgeRuntimeLabel = "Unavailable"
        runningThreadCount = 0
        trustedDevices = []
        trustedSessions = []
        pairedDeviceLabel = "Unavailable"
        activeSessionLabel = "Unavailable"
        runtimeDetail = message
        speechModelStateLabel = "Unavailable"
        speechModelState = .unsupported
        speechModelDetail = "Speech status is unavailable while the bridge is degraded."
        speechDownloadProgress = nil
        pairingRoutes = []
        pairingSession = nil
        qrImage = nil
        errorMessage = message
    }

    func refreshSpeechStatus() async throws {
        let status = try await bridgeClient.fetchSpeechModelStatus()
        applySpeechStatus(status)
    }

    func ensureSpeechModelOnDesktop() async {
        guard !isInstallingSpeechModel else {
            return
        }

        isInstallingSpeechModel = true
        defer { isInstallingSpeechModel = false }

        do {
            _ = try await bridgeClient.ensureSpeechModel()
            try? await refreshSpeechStatus()
        } catch {
            speechModelState = .failed
            speechModelStateLabel = "Failed"
            speechModelDetail = error.localizedDescription
        }
    }

    func removeSpeechModelFromDesktop() async {
        guard !isRemovingSpeechModel else {
            return
        }

        isRemovingSpeechModel = true
        defer { isRemovingSpeechModel = false }

        do {
            _ = try await bridgeClient.removeSpeechModel()
            try? await refreshSpeechStatus()
        } catch {
            speechModelState = .failed
            speechModelStateLabel = "Failed"
            speechModelDetail = error.localizedDescription
        }
    }

    private func applySpeechStatus(_ status: SpeechModelStatusDTO) {
        speechModelState = status.state
        speechDownloadProgress = status.downloadProgress
        switch status.state {
        case .unsupported:
            speechModelStateLabel = "Unsupported"
        case .notInstalled:
            speechModelStateLabel = "Not Installed"
        case .installing:
            speechModelStateLabel = "Installing"
        case .ready:
            speechModelStateLabel = "Ready"
        case .busy:
            speechModelStateLabel = "Busy"
        case .failed:
            speechModelStateLabel = "Failed"
        }

        if let lastError = status.lastError, !lastError.isEmpty {
            speechModelDetail = lastError
        } else if let progress = status.downloadProgress, status.state == .installing {
            speechModelDetail = "Downloading Parakeet… \(progress)%"
        } else if let installedBytes = status.installedBytes, status.state == .ready {
            speechModelDetail = ByteCountFormatter.string(fromByteCount: Int64(installedBytes), countStyle: .file)
        } else if status.state == .notInstalled {
            speechModelDetail = "Parakeet can be downloaded on demand from Hugging Face."
        } else {
            speechModelDetail = "Speech runtime is managed by the local bridge."
        }
    }

    func revokeTrustedDeviceFromDesktop(phoneID: String? = nil) async {
        guard !isRevokingTrust else {
            return
        }

        isRevokingTrust = true
        defer { isRevokingTrust = false }

        do {
            let response = try await bridgeClient.revokeTrust(phoneID: phoneID)
            if response.revoked {
                errorMessage = nil
                runtimeDetail = phoneID == nil
                    ? "Desktop trust revoked. Devices must pair again before reconnecting."
                    : "Device removed from desktop trust."
                await refreshRuntimeState()
                if !hasTrustedDevices {
                    await refreshPairingSessionIfNeeded()
                }
                return
            }

            errorMessage = phoneID == nil
                ? "No trusted devices were available to revoke."
                : "The selected device was not available to revoke."
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

    func setLocalNetworkPairingEnabled(_ enabled: Bool) async {
        guard !isUpdatingNetworkSettings else {
            return
        }

        isUpdatingNetworkSettings = true
        defer { isUpdatingNetworkSettings = false }

        do {
            let settings = try await bridgeClient.setLocalNetworkPairingEnabled(enabled)
            localNetworkPairingEnabled = settings.localNetworkPairingEnabled
            pairingRoutes = settings.routes
            errorMessage = settings.message
            await refreshRuntimeState()
        } catch {
            errorMessage = "Failed to update network pairing setting: \(error.localizedDescription)"
        }
    }

    var routeSummaryLabel: String {
        let reachableCount = pairingRoutes.filter(\.reachable).count
        return "\(reachableCount)/\(pairingRoutes.count) reachable"
    }

    private var hasFreshPairingSession: Bool {
        guard let pairingSession else {
            return false
        }

        let now = UInt64(Date().timeIntervalSince1970)
        return pairingSession.pairingSession.expiresAtEpochSeconds > now + 15
    }
}
