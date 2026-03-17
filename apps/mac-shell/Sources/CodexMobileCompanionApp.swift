import SwiftUI

@main
struct CodexMobileCompanionApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

private struct ContentView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Codex Mobile Companion")
                .font(.title2)
                .fontWeight(.semibold)
            Text("macOS shell scaffold is ready.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(minWidth: 420, minHeight: 240)
    }
}
