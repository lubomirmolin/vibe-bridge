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
        guard trustStatus?.trustedPhone != nil else {
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
        filter.setValue("Q", forKey: "inputCorrectionLevel")

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
