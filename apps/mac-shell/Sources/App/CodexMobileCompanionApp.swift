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
