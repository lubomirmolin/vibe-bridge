import AppKit
import Foundation

struct UpdateRepositorySettings {
    let owner: String
    let repo: String
    let bundleIdentifier: String
    let appName: String

    var releasesPageURL: URL {
        URL(string: "https://github.com/\(owner)/\(repo)/releases")!
    }

    static func fromBundle(_ bundle: Bundle) -> UpdateRepositorySettings {
        UpdateRepositorySettings(
            owner: "lubomirmolin",
            repo: "vibe-bridge",
            bundleIdentifier: bundle.bundleIdentifier ?? "com.codex.mobile.companion.shell",
            appName: (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? "CodexMobileCompanion"
        )
    }
}

@MainActor
final class UpdateCheckViewModel: ObservableObject {
    @Published private(set) var state: InAppUpdaterState = .idle
    @Published private(set) var latestVersion: String?
    @Published private(set) var releaseNotes: String?

    private let repository: UpdateRepositorySettings
    private let currentVersionProvider: () -> String
    private var latestCheckResult: UpdateCheckResult?
    private var stateMachine = InAppUpdaterStateMachine()

    init(
        repository: UpdateRepositorySettings = .fromBundle(.main),
        currentVersionProvider: @escaping () -> String = {
            (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
        }
    ) {
        self.repository = repository
        self.currentVersionProvider = currentVersionProvider
    }

    var isChecking: Bool {
        if case .checking = state { return true }
        return false
    }

    var isInstalling: Bool {
        switch state {
        case .downloading, .installing, .relaunching:
            return true
        default:
            return false
        }
    }

    var canInstall: Bool {
        if case .updateAvailable = state {
            return latestCheckResult?.isUpdateAvailable == true
                && latestCheckResult?.preferredAsset != nil
        }
        return false
    }

    var stateMessage: String {
        switch state {
        case .idle:
            return "Manual update checks only."
        case .checking:
            return "Checking GitHub releases…"
        case .updateAvailable(let latestVersion):
            return "Update available: \(latestVersion)."
        case .upToDate(let currentVersion):
            return "You're up to date (\(currentVersion))."
        case .downloading(let progress):
            if let progress {
                return "Downloading update: \(Int((progress * 100).rounded()))%"
            }
            return "Downloading update…"
        case .installing:
            return "Preparing installation…"
        case .relaunching:
            return "Installing and relaunching…"
        case .failed(let reason):
            return reason
        }
    }

    var showOpenReleasesFallback: Bool {
        if case .failed = state { return true }
        if case .updateAvailable = state {
            return latestCheckResult?.preferredAsset == nil
        }
        return false
    }

    func checkForUpdates() {
        guard !isChecking, !isInstalling else { return }
        transition(.startChecking)

        Task {
            do {
                let updater = makeUpdater()
                let result = try await updater.checkForUpdates(currentVersion: currentVersionProvider())

                if result.isUpdateAvailable {
                    latestCheckResult = result
                    latestVersion = result.latestVersion.description
                    releaseNotes = result.release.body?.trimmingCharacters(in: .whitespacesAndNewlines)
                    transition(.setUpdateAvailable(latestVersion: result.latestVersion.description))
                } else {
                    latestCheckResult = nil
                    latestVersion = nil
                    releaseNotes = nil
                    transition(.setUpToDate(currentVersion: result.currentVersion.description))
                }
            } catch {
                latestCheckResult = nil
                latestVersion = nil
                releaseNotes = nil
                transition(.fail(checkErrorMessage(for: error)))
            }
        }
    }

    func installUpdate() {
        guard !isInstalling,
              let latestCheckResult,
              latestCheckResult.isUpdateAvailable else {
            return
        }

        Task {
            do {
                let updater = makeUpdater()
                _ = try await updater.prepareAndLaunchInstall(
                    from: latestCheckResult,
                    currentAppBundleURL: Bundle.main.bundleURL
                ) { [weak self] stage in
                    Task { @MainActor [weak self] in
                        self?.consumeInstallProgress(stage)
                    }
                }

                transition(.setRelaunching)
                NSApplication.shared.terminate(nil)
            } catch {
                transition(.fail(error.localizedDescription))
            }
        }
    }

    func openReleasesPage() {
        makeUpdater().openReleasesPage()
    }

    private func consumeInstallProgress(_ stage: InAppUpdaterInstallProgress) {
        switch stage {
        case .downloading(let fraction):
            transition(.setDownloadProgress(fraction))
        case .installing:
            transition(.startInstalling)
        case .relaunching:
            transition(.setRelaunching)
        }
    }

    private func transition(_ event: InAppUpdaterEvent) {
        stateMachine.apply(event)
        state = stateMachine.state
    }

    private func makeUpdater() -> GitHubInAppUpdater {
        GitHubInAppUpdater(
            configuration: UpdateRepositoryConfiguration(
                owner: repository.owner,
                repo: repository.repo,
                appName: repository.appName,
                bundleIdentifier: repository.bundleIdentifier,
                releasesPageURL: repository.releasesPageURL
            )
        )
    }

    private func checkErrorMessage(for error: Error) -> String {
        switch error {
        case GitHubReleaseClientError.notFoundLatestRelease:
            return "No published versioned release exists yet. You can still open the Releases page directly."
        default:
            return "Update check failed: \(error.localizedDescription)"
        }
    }
}
