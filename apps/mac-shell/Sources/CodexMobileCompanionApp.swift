import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import SwiftUI

@main
struct CodexMobileCompanionApp: App {
    @StateObject private var pairingViewModel = PairingEntryViewModel()

    var body: some Scene {
        MenuBarExtra("Codex Mobile Companion", systemImage: "iphone.gen3") {
            PairingEntryView(viewModel: pairingViewModel)
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

            Text("Desktop pairing entrypoint")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Group {
                metadataRow(label: "Shell state", value: "Unpaired")
                metadataRow(label: "Bridge", value: viewModel.bridgeStatus)
            }

            qrSection

            HStack(spacing: 12) {
                Button(viewModel.isLoading ? "Generating…" : "Generate Pairing QR") {
                    Task {
                        await viewModel.refreshPairingSession()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(viewModel.isLoading)

                if viewModel.isLoading {
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
        .frame(minWidth: 420, minHeight: 500)
        .task {
            await viewModel.refreshPairingSessionIfNeeded()
        }
    }

    @ViewBuilder
    private var qrSection: some View {
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
            Text("Generate a pairing session to display a scannable QR code.")
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
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
        }
    }
}

@MainActor
final class PairingEntryViewModel: ObservableObject {
    @Published private(set) var isLoading = false
    @Published private(set) var pairingSession: PairingSessionResponseDTO?
    @Published private(set) var qrImage: NSImage?
    @Published private(set) var errorMessage: String?

    private let pairingClient: PairingSessionClient

    var bridgeStatus: String {
        if pairingSession != nil {
            return "Connected"
        }
        return "Unavailable"
    }

    init(pairingClient: PairingSessionClient = BridgePairingClient()) {
        self.pairingClient = pairingClient
    }

    func refreshPairingSessionIfNeeded() async {
        guard pairingSession == nil, !isLoading else {
            return
        }
        await refreshPairingSession()
    }

    func refreshPairingSession() async {
        guard !isLoading else {
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let response = try await pairingClient.fetchPairingSession()
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
}

protocol PairingSessionClient {
    func fetchPairingSession() async throws -> PairingSessionResponseDTO
}

struct BridgePairingClient: PairingSessionClient {
    let endpoint: URL

    init(endpoint: URL = URL(string: "http://127.0.0.1:3110/pairing/session")!) {
        self.endpoint = endpoint
    }

    func fetchPairingSession() async throws -> PairingSessionResponseDTO {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BridgePairingClientError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? "<no body>"
            throw BridgePairingClientError.unexpectedStatus(httpResponse.statusCode, bodyText)
        }

        do {
            return try JSONDecoder().decode(PairingSessionResponseDTO.self, from: data)
        } catch {
            throw BridgePairingClientError.decodingFailure(error)
        }
    }
}

enum BridgePairingClientError: LocalizedError {
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
            return "failed to decode pairing payload: \(error.localizedDescription)"
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
