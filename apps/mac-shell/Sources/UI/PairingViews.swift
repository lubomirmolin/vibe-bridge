import AppKit
import Foundation
import SwiftUI

private enum PairingEntryLayout {
    static let panelMinWidth: CGFloat = 460
    static let panelMaxWidth: CGFloat = 540
    static let panelMinHeight: CGFloat = 480
    static let panelMaxHeight: CGFloat = 800
    static let qrDimension: CGFloat = 260
    static let qrWindowDimension: CGFloat = 520
}

enum PairingWindowID {
    static let qrCode = "pairing-qr-window"
}

struct PairingEntryView: View {
    @ObservedObject var viewModel: PairingEntryViewModel
    @ObservedObject var updateViewModel: UpdateCheckViewModel
    @Environment(\.openWindow) private var openWindow
    @State private var showUpdateCard = false

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            Divider()

            ScrollView {
                VStack(spacing: 24) {
                    bridgeAndDevicesCard
                    qrSection
                    speechCard

                    if showUpdateCard {
                        updateCard
                    }

                    if let errorMessage = viewModel.errorMessage {
                        errorMessageView(errorMessage)
                    }
                }
                .padding(24)
            }

            Divider()

            bottomBar
        }
        .frame(
            minWidth: PairingEntryLayout.panelMinWidth,
            maxWidth: PairingEntryLayout.panelMaxWidth,
            minHeight: PairingEntryLayout.panelMinHeight,
            maxHeight: PairingEntryLayout.panelMaxHeight
        )
    }

    private var headerBar: some View {
        HStack(spacing: 10) {
            Image("StatusBarIcon")
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 18, height: 18)
                .foregroundStyle(.tint)

            Text("Vibe Bridge Companion")
                .font(.headline)
                .fontWeight(.semibold)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            if viewModel.isLoadingPairing
                || viewModel.isRefreshingRuntime
                || viewModel.isRevokingTrust
                || viewModel.isRestartingRuntime
                || viewModel.isUpdatingNetworkSettings
            {
                ProgressView()
                    .controlSize(.small)
                    .padding(.trailing, 8)
            }

            Spacer()

            Button {
                withAnimation { showUpdateCard.toggle() }
            } label: {
                if showUpdateCard {
                    Label("Hide Updates", systemImage: "chevron.up")
                } else {
                    Label("Updates", systemImage: "arrow.down.circle")
                }
            }

            Button {
                Task { await viewModel.restartLocalRuntime() }
            } label: {
                Text(viewModel.isRestartingRuntime ? "Restarting…" : "Restart Runtime")
            }
            .disabled(viewModel.isRefreshingRuntime || viewModel.isRestartingRuntime)

            Button {
                viewModel.stopBridgeExplicitly()
                NSApplication.shared.terminate(nil)
            } label: {
                Text("Quit")
            }
        }
        .padding(16)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var bridgeAndDevicesCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: shellStateIcon)
                    .font(.system(size: 16))
                    .foregroundStyle(shellStateColor)
                    .frame(width: 20)

                Text(viewModel.shellState.displayName)
                    .font(.body.weight(.medium))

                Spacer()

                if viewModel.runningThreadCount > 0 {
                    Text("\(viewModel.runningThreadCount) thread\(viewModel.runningThreadCount == 1 ? "" : "s")")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 16)

            if viewModel.shellState == .degraded {
                Divider().padding(.leading, 44)
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                    Text(viewModel.runtimeDetail)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 16)
            }

            Divider().padding(.leading, 44)

            if viewModel.trustedDevices.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "plus.viewfinder")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                        .frame(width: 20)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("No paired devices")
                            .font(.body)
                        Text("Generate a QR code below to pair the first device.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(viewModel.trustedDevices.enumerated()), id: \.element.id) { index, device in
                        trustedDeviceRow(
                            device: device,
                            session: viewModel.trustedSessions.first(where: { $0.deviceID == device.deviceID })
                        )

                        if index < viewModel.trustedDevices.count - 1 {
                            Divider().padding(.leading, 44)
                        }
                    }
                }

                Divider().padding(.leading, 44)

                HStack {
                    Button(role: .destructive) {
                        Task { await viewModel.revokeTrustedDeviceFromDesktop() }
                    } label: {
                        Text(viewModel.isRevokingTrust ? "Removing…" : "Remove All Devices")
                    }
                    .disabled(viewModel.isRevokingTrust || viewModel.isRefreshingRuntime)

                    Spacer()
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }

    private func trustedDeviceRow(
        device: BridgeTrustedDeviceDTO,
        session: BridgeTrustedSessionDTO?
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "iphone.gen3")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 6) {
                Text(device.deviceName)
                    .font(.body)

                Text(device.deviceID)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)

                Text(
                    "Paired \(DateFormatter.pairingExpiry.string(from: Date(timeIntervalSince1970: TimeInterval(device.pairedAtEpochSeconds))))"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)

                if let session {
                    Text("Session \(session.sessionID)")
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            Button(role: .destructive) {
                Task { await viewModel.revokeTrustedDeviceFromDesktop(phoneID: device.deviceID) }
            } label: {
                Text(viewModel.isRevokingTrust ? "Removing…" : "Remove")
            }
            .disabled(viewModel.isRevokingTrust || viewModel.isRefreshingRuntime)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var qrSection: some View {
        switch viewModel.shellState {
        case .starting:
            infoBox(
                icon: "hourglass",
                title: "Starting Up",
                message: "Desktop app is starting the local bridge and Codex runtime. Pairing will unlock automatically once the stack reports healthy."
            )

        case .unpaired, .pairedIdle, .pairedActive:
            if let qrImage = viewModel.qrImage,
               let response = viewModel.pairingSession
            {
                VStack(spacing: 20) {
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
                            .padding(16)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .shadow(color: Color.black.opacity(0.1), radius: 10, x: 0, y: 4)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(Color.black.opacity(0.05), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Click to open large pairing window")

                    VStack(spacing: 8) {
                        Text(viewModel.hasTrustedDevices ? "Add Another Device" : "Ready to Pair")
                            .font(.headline)
                        Text(
                            viewModel.hasTrustedDevices
                                ? "Scan this QR code using the Codex mobile app to add another trusted device."
                                : "Scan this QR code using the Codex mobile app."
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    }

                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                        Text("Expires: \(DateFormatter.pairingExpiry.string(from: Date(timeIntervalSince1970: TimeInterval(response.pairingSession.expiresAtEpochSeconds))))")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(Capsule())

                    Button {
                        Task { await viewModel.refreshPairingSession() }
                    } label: {
                        Text(
                            viewModel.isLoadingPairing
                                ? "Generating…"
                                : (viewModel.hasTrustedDevices ? "Add Device QR" : "Refresh QR")
                        )
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(viewModel.isLoadingPairing || !viewModel.shouldShowPairingQR)
                    .buttonStyle(.borderedProminent)
                }
                .padding(.vertical, 8)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)

                    Text(viewModel.hasTrustedDevices ? "Add Another Device" : "Ready to Generate QR")
                        .font(.headline)

                    Text(
                        viewModel.hasTrustedDevices
                            ? "Existing devices stay connected. Click below to generate a fresh pairing code."
                            : "Bridge is reachable but no pairing QR is cached yet. Click below to begin."
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                    Button {
                        Task { await viewModel.refreshPairingSession() }
                    } label: {
                        Text(
                            viewModel.isLoadingPairing
                                ? "Generating…"
                                : (viewModel.hasTrustedDevices ? "Add Device QR" : "Generate QR")
                        )
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(viewModel.isLoadingPairing || !viewModel.shouldShowPairingQR)
                    .buttonStyle(.borderedProminent)
                }
                .padding(24)
                .frame(maxWidth: .infinity)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )
            }

        case .degraded:
            infoBox(
                icon: "exclamationmark.triangle.fill",
                iconColor: .red,
                title: "Bridge Degraded",
                message: "Supervision is retrying automatically and will recover when bridge health returns."
            )
        }
    }

    private var speechCard: some View {
        VStack(spacing: 0) {
            statusRow(
                icon: "waveform.badge.mic",
                iconColor: .secondary,
                label: "Speech",
                value: viewModel.speechModelStateLabel
            )
            Divider().padding(.leading, 44)
            HStack(spacing: 12) {
                Image(systemName: "internaldrive")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Parakeet v3")
                        .font(.body)
                    Text(viewModel.speechModelDetail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer()
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 16)

            if let progress = viewModel.speechDownloadProgress,
               viewModel.speechModelStateLabel == "Installing"
            {
                Divider().padding(.leading, 44)
                HStack(spacing: 12) {
                    ProgressView(value: Double(progress), total: 100)
                        .progressViewStyle(.linear)
                    Text("\(progress)%")
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
            }

            Divider().padding(.leading, 44)
            HStack {
                Button {
                    Task { await viewModel.ensureSpeechModelOnDesktop() }
                } label: {
                    Text(viewModel.isInstallingSpeechModel ? "Downloading…" : "Download Parakeet")
                }
                .disabled(!viewModel.canInstallSpeechModel)

                Button(role: .destructive) {
                    Task { await viewModel.removeSpeechModelFromDesktop() }
                } label: {
                    Text(viewModel.isRemovingSpeechModel ? "Removing…" : "Remove Parakeet")
                }
                .disabled(!viewModel.canRemoveSpeechModel)

                Spacer()
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
        }
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }

    private var updateCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Updates")
                    .font(.headline)
                Spacer()
                Button(updateViewModel.isChecking ? "Checking…" : "Check for Updates") {
                    updateViewModel.checkForUpdates()
                }
                .buttonStyle(.borderedProminent)
                .disabled(updateViewModel.isChecking || updateViewModel.isInstalling)
            }

            Text("User-initiated updater only. No background auto-update daemon.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(updateViewModel.stateMessage)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let latestVersion = updateViewModel.latestVersion {
                Text("Latest release: \(latestVersion)")
                    .font(.subheadline.weight(.semibold))
            }

            if let notes = updateViewModel.releaseNotes, !notes.isEmpty {
                ScrollView {
                    Text(notes)
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(NSColor.windowBackgroundColor).opacity(0.4))
                )
            }

            HStack {
                if updateViewModel.canInstall {
                    Button("Download & Install Update") {
                        updateViewModel.installUpdate()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(updateViewModel.isInstalling)
                }

                if updateViewModel.showOpenReleasesFallback {
                    Button("Open Releases Page") {
                        updateViewModel.openReleasesPage()
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()
            }
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private func statusRow(icon: String, iconColor: Color, label: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(iconColor)
                .frame(width: 20)

            Text(label)
                .font(.body)
                .foregroundStyle(.primary)

            Spacer()

            Text(value)
                .font(.body.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
    }

    private var shellStateIcon: String {
        switch viewModel.shellState {
        case .starting: return "arrow.triangle.2.circlepath"
        case .unpaired: return "lock.open"
        case .pairedIdle: return "lock"
        case .pairedActive: return "lock.fill"
        case .degraded: return "exclamationmark.triangle"
        }
    }

    private var shellStateColor: Color {
        switch viewModel.shellState {
        case .starting: return .orange
        case .unpaired: return .blue
        case .pairedIdle: return .green
        case .pairedActive: return .green
        case .degraded: return .red
        }
    }

    private func errorMessageView(_ message: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .font(.title3)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.red.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.red.opacity(0.3), lineWidth: 1)
        )
    }

    private func infoBox(icon: String, iconColor: Color = .secondary, title: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundStyle(iconColor)

            Text(title)
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }
}

struct PairingQRCodeWindowView: View {
    @ObservedObject var viewModel: PairingEntryViewModel

    var body: some View {
        Group {
            if let qrImage = viewModel.qrImage,
               let response = viewModel.pairingSession,
               viewModel.shellState == .unpaired
            {
                VStack(spacing: 0) {
                    VStack(spacing: 8) {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.system(size: 48, weight: .light))
                            .foregroundStyle(.tint)
                            .padding(.bottom, 8)

                        Text("Pairing QR")
                            .font(.system(size: 32, weight: .semibold, design: .rounded))

                        Text("Scan this code from the mobile app to securely pair your device.")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .padding(.top, 48)
                    .padding(.bottom, 32)

                    Image(nsImage: qrImage)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .frame(
                            width: PairingEntryLayout.qrWindowDimension,
                            height: PairingEntryLayout.qrWindowDimension
                        )
                        .padding(24)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .shadow(color: Color.black.opacity(0.15), radius: 20, x: 0, y: 10)
                        .padding(.bottom, 40)

                    HStack(spacing: 40) {
                        qrMetadataItem(
                            icon: "number.circle",
                            label: "Session ID",
                            value: response.pairingSession.sessionID
                        )

                        qrMetadataItem(
                            icon: "server.rack",
                            label: "Bridge ID",
                            value: response.bridgeIdentity.bridgeID
                        )

                        qrMetadataItem(
                            icon: "clock",
                            label: "Expires At",
                            value: DateFormatter.pairingExpiry.string(
                                from: Date(
                                    timeIntervalSince1970: TimeInterval(
                                        response.pairingSession.expiresAtEpochSeconds
                                    )
                                )
                            )
                        )
                    }
                    .padding(24)
                    .background(Color(NSColor.controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
                    .padding(.horizontal, 48)
                    .padding(.bottom, 48)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(NSColor.windowBackgroundColor))
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "qrcode.slash")
                        .font(.system(size: 48))
                        .foregroundStyle(.tertiary)

                    Text("No Pairing Session")
                        .font(.title)
                        .fontWeight(.semibold)

                    Text("No active pairing QR is available right now.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)

                    Text("Refresh the pairing session from the menu bar app and try again.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(NSColor.windowBackgroundColor))
            }
        }
    }

    private func qrMetadataItem(icon: String, label: String, value: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.secondary)

            Text(label)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)

            Text(value)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 160)
        }
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
