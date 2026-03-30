import SwiftUI

@main
struct CodexMobileCompanionApp: App {
    @StateObject private var pairingViewModel: PairingEntryViewModel
    @StateObject private var updateViewModel: UpdateCheckViewModel

    init() {
        _pairingViewModel = StateObject(
            wrappedValue: PairingEntryViewModel(startSupervisionOnInit: true)
        )
        _updateViewModel = StateObject(
            wrappedValue: UpdateCheckViewModel()
        )
    }

    var body: some Scene {
        MenuBarExtra("Codex Mobile Companion", systemImage: "iphone.gen3") {
            PairingEntryView(
                viewModel: pairingViewModel,
                updateViewModel: updateViewModel
            )
        }
        .menuBarExtraStyle(.window)

        Window("Pairing QR", id: PairingWindowID.qrCode) {
            PairingQRCodeWindowView(viewModel: pairingViewModel)
        }
        .defaultSize(width: 640, height: 760)
        .windowResizability(.contentSize)
    }
}
