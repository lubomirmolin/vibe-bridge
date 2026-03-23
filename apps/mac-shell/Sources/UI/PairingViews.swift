import AppKit
import Foundation
import SwiftUI

private enum PairingEntryLayout {
    static let panelMinWidth: CGFloat = 460
    static let panelMaxWidth: CGFloat = 540
    static let panelMinHeight: CGFloat = 640
    static let panelMaxHeight: CGFloat = 800
    static let qrDimension: CGFloat = 260
    static let qrWindowDimension: CGFloat = 520
}

enum PairingWindowID {
    static let qrCode = "pairing-qr-window"
}

struct PairingEntryView: View {
    @ObservedObject var viewModel: PairingEntryViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 40, height: 40)
                    .foregroundStyle(.tint)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.accentColor.opacity(0.1))
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text("Codex Companion")
                        .font(.title2)
                        .fontWeight(.bold)

                    Text("Desktop shell runtime supervision")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(24)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            ScrollView {
                VStack(spacing: 24) {
                    statusCard
                    networkCard
                    speechCard
                    qrSection

                    if let errorMessage = viewModel.errorMessage {
                        errorMessageView(errorMessage)
                    }
                }
                .padding(24)
            }

            Divider()

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

                if viewModel.canRevokeTrust {
                    Button(role: .destructive) {
                        Task { await viewModel.revokeTrustedPhoneFromDesktop() }
                    } label: {
                        Text(viewModel.isRevokingTrust ? "Revoking…" : "Unpair Phone")
                    }
                    .disabled(viewModel.isRevokingTrust || viewModel.isRefreshingRuntime)
                }

                Button {
                    Task { await viewModel.restartLocalRuntime() }
                } label: {
                    Text(viewModel.isRestartingRuntime ? "Restarting…" : "Restart Runtime")
                }
                .disabled(viewModel.isRefreshingRuntime || viewModel.isRestartingRuntime)

                Button {
                    Task { await viewModel.refreshPairingSession() }
                } label: {
                    Text(viewModel.isLoadingPairing ? "Generating…" : "Refresh QR")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(viewModel.isLoadingPairing || !viewModel.shouldShowPairingQR)
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            HStack(spacing: 12) {
                Spacer()

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Text("Quit")
                }

                Button(role: .destructive) {
                    viewModel.stopBridgeExplicitly()
                    NSApplication.shared.terminate(nil)
                } label: {
                    Text("Quit + Stop Bridge")
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(
            minWidth: PairingEntryLayout.panelMinWidth,
            maxWidth: PairingEntryLayout.panelMaxWidth,
            minHeight: PairingEntryLayout.panelMinHeight,
            maxHeight: PairingEntryLayout.panelMaxHeight
        )
    }

    private var statusCard: some View {
        VStack(spacing: 0) {
            statusRow(
                icon: shellStateIcon,
                iconColor: shellStateColor,
                label: "Shell State",
                value: viewModel.shellState.displayName
            )
            Divider().padding(.leading, 44)
            statusRow(
                icon: "cpu",
                iconColor: .secondary,
                label: "Supervisor",
                value: viewModel.supervisorStatusLabel
            )
            Divider().padding(.leading, 44)
            statusRow(
                icon: "server.rack",
                iconColor: .secondary,
                label: "Bridge",
                value: viewModel.bridgeRuntimeLabel
            )
            Divider().padding(.leading, 44)
            statusRow(
                icon: "candybarphone",
                iconColor: .secondary,
                label: "Paired Phone",
                value: viewModel.pairedDeviceLabel
            )
            if viewModel.shellState == .pairedActive || viewModel.shellState == .pairedIdle {
                Divider().padding(.leading, 44)
                statusRow(
                    icon: "key",
                    iconColor: .secondary,
                    label: "Active Session",
                    value: viewModel.activeSessionLabel
                )
            }
            Divider().padding(.leading, 44)
            statusRow(
                icon: "point.3.connected.trianglepath.dotted",
                iconColor: .secondary,
                label: "Active Threads",
                value: "\(viewModel.runningThreadCount)"
            )
        }
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Text(viewModel.runtimeDetail)
                    .font(.footnote)
                    .foregroundStyle(viewModel.shellState == .degraded ? .red : .secondary)
                    .padding(.top, 8)
                    .padding(.horizontal, 4)
                Spacer()
            }
        }
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
               viewModel.speechModelStateLabel == "Installing" {
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

    private var networkCard: some View {
        VStack(spacing: 0) {
            statusRow(
                icon: "point.3.connected.trianglepath.dotted",
                iconColor: .secondary,
                label: "Pairing Routes",
                value: viewModel.routeSummaryLabel
            )
            Divider().padding(.leading, 44)
            HStack(spacing: 12) {
                Image(systemName: "network")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Enable Local Network Pairing")
                        .font(.body)
                    Text(
                        "Advertise an HTTP LAN route alongside Tailscale on trusted private networks."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Toggle(
                    "",
                    isOn: Binding(
                        get: { viewModel.localNetworkPairingEnabled },
                        set: { enabled in
                            Task { await viewModel.setLocalNetworkPairingEnabled(enabled) }
                        }
                    )
                )
                .labelsHidden()
                .disabled(viewModel.isUpdatingNetworkSettings || viewModel.isRefreshingRuntime)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 16)

            if !viewModel.pairingRoutes.isEmpty {
                Divider().padding(.leading, 44)
                VStack(spacing: 0) {
                    ForEach(Array(viewModel.pairingRoutes.enumerated()), id: \.offset) { _, route in
                        HStack(spacing: 12) {
                            Image(systemName: route.kind == .tailscale ? "lock.shield" : "wifi")
                                .font(.system(size: 16))
                                .foregroundStyle(route.reachable ? .green : .secondary)
                                .frame(width: 20)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(route.kind == .tailscale ? "Tailscale" : "Local Network")
                                    .font(.body)
                                Text(route.baseURL)
                                    .font(.footnote.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            Spacer()

                            Text(routeBadge(route))
                                .font(.caption.monospaced())
                                .foregroundStyle(route.reachable ? .green : .secondary)
                        }
                        .padding(.vertical, 12)
                        .padding(.horizontal, 16)

                        if route.id != viewModel.pairingRoutes.last?.id {
                            Divider().padding(.leading, 44)
                        }
                    }
                }
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }

    private func routeBadge(_ route: BridgeAPIRouteDTO) -> String {
        if route.isPreferred && route.reachable {
            return "primary"
        }
        if route.reachable {
            return "reachable"
        }
        return "offline"
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

        case .unpaired:
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
                        Text("Ready to Pair")
                            .font(.headline)
                        Text("Scan this QR code using the Codex mobile app.")
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
                }
                .padding(.vertical, 8)
            } else {
                infoBox(
                    icon: "qrcode.viewfinder",
                    title: "Ready to Generate QR",
                    message: "Bridge is reachable but no pairing QR is cached yet. Click \"Refresh QR\" below to begin."
                )
            }

        case .pairedIdle, .pairedActive:
            infoBox(
                icon: "checkmark.shield.fill",
                iconColor: .green,
                title: "Mac is Paired",
                message: "Existing trusted phone sessions stay active without rescanning. Use \"Unpair Phone\" to revoke trust and require a fresh pairing flow."
            )

        case .degraded:
            infoBox(
                icon: "exclamationmark.triangle.fill",
                iconColor: .red,
                title: "Bridge Degraded",
                message: "Supervision is retrying automatically and will recover when bridge health returns."
            )
        }
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
