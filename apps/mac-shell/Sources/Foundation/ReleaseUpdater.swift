import AppKit
import CryptoKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct SemanticVersion: Comparable, Hashable, CustomStringConvertible, Sendable {
    let major: Int
    let minor: Int
    let patch: Int
    let preReleaseIdentifiers: [String]

    init(major: Int, minor: Int, patch: Int, preReleaseIdentifiers: [String] = []) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.preReleaseIdentifiers = preReleaseIdentifiers
    }

    init?(parsing rawValue: String) {
        var candidate = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return nil }

        if candidate.hasPrefix("v") || candidate.hasPrefix("V") {
            candidate.removeFirst()
        }

        if let plusIndex = candidate.firstIndex(of: "+") {
            candidate = String(candidate[..<plusIndex])
        }

        let parts = candidate.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numberComponents = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(numberComponents.count),
              let major = Int(numberComponents[0]) else {
            return nil
        }

        let minor = numberComponents.count > 1 ? Int(numberComponents[1]) : 0
        let patch = numberComponents.count > 2 ? Int(numberComponents[2]) : 0
        guard let minor, let patch else { return nil }

        let preReleaseIdentifiers: [String]
        if parts.count > 1 {
            preReleaseIdentifiers = parts[1]
                .split(separator: ".", omittingEmptySubsequences: false)
                .map(String.init)
        } else {
            preReleaseIdentifiers = []
        }

        self.init(
            major: major,
            minor: minor,
            patch: patch,
            preReleaseIdentifiers: preReleaseIdentifiers
        )
    }

    var description: String {
        var output = "\(major).\(minor).\(patch)"
        if !preReleaseIdentifiers.isEmpty {
            output += "-\(preReleaseIdentifiers.joined(separator: "."))"
        }
        return output
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        switch (lhs.preReleaseIdentifiers.isEmpty, rhs.preReleaseIdentifiers.isEmpty) {
        case (true, true):
            return false
        case (true, false):
            return false
        case (false, true):
            return true
        case (false, false):
            return comparePreRelease(lhs.preReleaseIdentifiers, rhs.preReleaseIdentifiers) == .orderedAscending
        }
    }

    private static func comparePreRelease(_ lhs: [String], _ rhs: [String]) -> ComparisonResult {
        let count = max(lhs.count, rhs.count)
        for index in 0..<count {
            let left = index < lhs.count ? lhs[index] : nil
            let right = index < rhs.count ? rhs[index] : nil

            switch (left, right) {
            case (nil, nil):
                return .orderedSame
            case (nil, _):
                return .orderedAscending
            case (_, nil):
                return .orderedDescending
            case let (left?, right?):
                if left == right {
                    continue
                }

                let leftNumeric = Int(left)
                let rightNumeric = Int(right)

                switch (leftNumeric, rightNumeric) {
                case let (leftNumeric?, rightNumeric?):
                    if leftNumeric < rightNumeric { return .orderedAscending }
                    if leftNumeric > rightNumeric { return .orderedDescending }
                case (_?, nil):
                    return .orderedAscending
                case (nil, _?):
                    return .orderedDescending
                case (nil, nil):
                    let comparison = left.compare(right, options: .numeric)
                    if comparison != .orderedSame {
                        return comparison
                    }
                }
            }
        }

        return .orderedSame
    }
}

struct GitHubReleaseAsset: Decodable, Hashable, Sendable {
    let name: String
    let browserDownloadURL: URL

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

struct GitHubRelease: Decodable, Sendable {
    let tagName: String
    let body: String?
    let htmlURL: URL
    let assets: [GitHubReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case body
        case htmlURL = "html_url"
        case assets
    }

    var semanticVersion: SemanticVersion? {
        SemanticVersion(parsing: tagName)
    }
}

struct UpdateCheckResult: Sendable {
    let currentVersion: SemanticVersion
    let latestVersion: SemanticVersion
    let release: GitHubRelease
    let preferredAsset: GitHubReleaseAsset?

    var isUpdateAvailable: Bool {
        latestVersion > currentVersion
    }
}

enum GitHubReleaseClientError: LocalizedError {
    case invalidResponse
    case notFoundLatestRelease(owner: String, repo: String)
    case unauthorizedOrForbidden(statusCode: Int)
    case rateLimited
    case httpError(statusCode: Int, body: String)
    case decodeFailed

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "GitHub API returned an invalid response."
        case .notFoundLatestRelease(let owner, let repo):
            return "No published release was found for \(owner)/\(repo)."
        case .unauthorizedOrForbidden(let statusCode):
            return "GitHub API request failed with status \(statusCode)."
        case .rateLimited:
            return "GitHub API rate limit reached."
        case .httpError(let statusCode, let body):
            return body.isEmpty
                ? "GitHub API request failed with status \(statusCode)."
                : "GitHub API request failed with status \(statusCode): \(body)"
        case .decodeFailed:
            return "Failed to parse the GitHub release payload."
        }
    }
}

struct GitHubReleaseClient: Sendable {
    private let session: URLSession
    private let decoder: JSONDecoder

    init(session: URLSession = .shared, decoder: JSONDecoder = JSONDecoder()) {
        self.session = session
        self.decoder = decoder
    }

    func fetchLatestRelease(owner: String, repo: String) async throws -> GitHubRelease {
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest") else {
            throw GitHubReleaseClientError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("VibeBridge-UpdateCheck", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GitHubReleaseClientError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            switch httpResponse.statusCode {
            case 401, 403:
                throw GitHubReleaseClientError.unauthorizedOrForbidden(statusCode: httpResponse.statusCode)
            case 404:
                throw GitHubReleaseClientError.notFoundLatestRelease(owner: owner, repo: repo)
            case 429:
                throw GitHubReleaseClientError.rateLimited
            default:
                let body = String(data: data, encoding: .utf8) ?? ""
                throw GitHubReleaseClientError.httpError(statusCode: httpResponse.statusCode, body: body)
            }
        }

        do {
            return try decoder.decode(GitHubRelease.self, from: data)
        } catch {
            throw GitHubReleaseClientError.decodeFailed
        }
    }
}

enum UpdateCheckError: LocalizedError {
    case invalidCurrentVersion(String)
    case invalidReleaseTag(String)

    var errorDescription: String? {
        switch self {
        case .invalidCurrentVersion(let value):
            return "Current app version is not semantic: \(value)"
        case .invalidReleaseTag(let value):
            return "Latest GitHub release tag is not semantic: \(value)"
        }
    }
}

enum InAppUpdaterState: Equatable, Sendable {
    case idle
    case checking
    case updateAvailable(latestVersion: String)
    case upToDate(currentVersion: String)
    case downloading(progress: Double?)
    case installing
    case relaunching
    case failed(reason: String)
}

enum InAppUpdaterEvent: Sendable {
    case startChecking
    case setUpdateAvailable(latestVersion: String)
    case setUpToDate(currentVersion: String)
    case setDownloadProgress(Double?)
    case startInstalling
    case setRelaunching
    case fail(String)
    case reset
}

struct InAppUpdaterStateMachine: Sendable {
    private(set) var state: InAppUpdaterState = .idle

    mutating func apply(_ event: InAppUpdaterEvent) {
        switch event {
        case .startChecking:
            state = .checking
        case .setUpdateAvailable(let latestVersion):
            state = .updateAvailable(latestVersion: latestVersion)
        case .setUpToDate(let currentVersion):
            state = .upToDate(currentVersion: currentVersion)
        case .setDownloadProgress(let progress):
            state = .downloading(progress: progress)
        case .startInstalling:
            state = .installing
        case .setRelaunching:
            state = .relaunching
        case .fail(let reason):
            state = .failed(reason: reason)
        case .reset:
            state = .idle
        }
    }
}

enum InAppUpdaterInstallProgress: Equatable, Sendable {
    case downloading(Double?)
    case installing
    case relaunching
}

enum UpdateAssetKind: String, Sendable {
    case zip
    case dmg
    case unsupported

    static func infer(from assetName: String) -> UpdateAssetKind {
        let lowered = assetName.lowercased()
        if lowered.hasSuffix(".zip") { return .zip }
        if lowered.hasSuffix(".dmg") { return .dmg }
        return .unsupported
    }
}

struct UpdateRepositoryConfiguration: Sendable {
    let owner: String
    let repo: String
    let appName: String
    let bundleIdentifier: String
    let releasesPageURL: URL
}

struct UpdaterHelperConfiguration: Sendable {
    let waitingForPID: Int32
    let assetURL: URL
    let assetKind: UpdateAssetKind
    let targetAppURL: URL
    let expectedBundleIdentifier: String
    let appName: String
}

struct UpdaterHelperInvocation: Sendable, Equatable {
    let executableURL: URL
    let arguments: [String]
}

enum InAppUpdaterError: LocalizedError {
    case noUpdateAvailable
    case missingInstallableAsset
    case missingChecksumsAsset
    case unsupportedAsset(name: String)
    case untrustedAssetURL(URL)
    case downloadFailed(String)
    case digestFetchFailed(String)
    case missingDigest(assetName: String)
    case invalidDigestFormat(source: String)
    case digestMismatch(expected: String, actual: String)
    case destinationNotWritable(path: String)
    case helperLaunchFailed(String)

    var errorDescription: String? {
        switch self {
        case .noUpdateAvailable:
            return "No newer release is available."
        case .missingInstallableAsset:
            return "Latest release has no installable macOS asset."
        case .missingChecksumsAsset:
            return "Latest release is missing SHA256SUMS."
        case .unsupportedAsset(let name):
            return "Updater does not support this release asset format: \(name)."
        case .untrustedAssetURL(let url):
            return "Refusing to download update from untrusted URL: \(url.absoluteString)"
        case .downloadFailed(let message):
            return "Failed to download update asset: \(message)"
        case .digestFetchFailed(let message):
            return "Failed to fetch release checksum: \(message)"
        case .missingDigest(let assetName):
            return "Update verification failed: \(assetName) is missing from SHA256SUMS."
        case .invalidDigestFormat(let source):
            return "Update verification failed: could not parse a SHA-256 checksum from \(source)."
        case .digestMismatch:
            return "Update verification failed: downloaded checksum does not match expected SHA-256."
        case .destinationNotWritable(let path):
            return "Cannot write to \(path). Move the app to a writable Applications folder or update manually."
        case .helperLaunchFailed(let message):
            return "Failed to launch updater helper: \(message)"
        }
    }
}

struct GitHubReleaseUpdateChecker: Sendable {
    let owner: String
    let repo: String
    let client: GitHubReleaseClient

    init(owner: String, repo: String, client: GitHubReleaseClient = GitHubReleaseClient()) {
        self.owner = owner
        self.repo = repo
        self.client = client
    }

    func checkForUpdate(currentVersionString: String) async throws -> UpdateCheckResult {
        guard let currentVersion = SemanticVersion(parsing: currentVersionString) else {
            throw UpdateCheckError.invalidCurrentVersion(currentVersionString)
        }

        let release = try await client.fetchLatestRelease(owner: owner, repo: repo)
        guard let latestVersion = release.semanticVersion else {
            throw UpdateCheckError.invalidReleaseTag(release.tagName)
        }

        let preferredAsset = Self.preferredMacAsset(from: release.assets)
        return UpdateCheckResult(
            currentVersion: currentVersion,
            latestVersion: latestVersion,
            release: release,
            preferredAsset: preferredAsset
        )
    }

    static func preferredMacAsset(from assets: [GitHubReleaseAsset]) -> GitHubReleaseAsset? {
        let candidates = assets.filter { asset in
            let lowered = asset.name.lowercased()
            return lowered.hasPrefix("codex-mobile-companion-macos-")
                && (lowered.hasSuffix(".zip") || lowered.hasSuffix(".dmg"))
        }

        for suffix in [".zip", ".dmg"] {
            if let asset = candidates.first(where: { $0.name.lowercased().hasSuffix(suffix) }) {
                return asset
            }
        }

        return nil
    }
}

enum UpdaterHelperBuilder {
    static func arguments(for config: UpdaterHelperConfiguration) -> [String] {
        [
            "--pid", String(config.waitingForPID),
            "--asset", config.assetURL.path,
            "--asset-kind", config.assetKind.rawValue,
            "--target-app", config.targetAppURL.path,
            "--bundle-id", config.expectedBundleIdentifier,
            "--app-name", config.appName
        ]
    }

    static func scriptContents() -> String {
        #"""
#!/bin/bash
set -euo pipefail

PID=""
ASSET_PATH=""
ASSET_KIND=""
TARGET_APP=""
EXPECTED_BUNDLE_ID=""
APP_NAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pid)
      PID="$2"
      shift 2
      ;;
    --asset)
      ASSET_PATH="$2"
      shift 2
      ;;
    --asset-kind)
      ASSET_KIND="$2"
      shift 2
      ;;
    --target-app)
      TARGET_APP="$2"
      shift 2
      ;;
    --bundle-id)
      EXPECTED_BUNDLE_ID="$2"
      shift 2
      ;;
    --app-name)
      APP_NAME="$2"
      shift 2
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$PID" || -z "$ASSET_PATH" || -z "$ASSET_KIND" || -z "$TARGET_APP" || -z "$EXPECTED_BUNDLE_ID" || -z "$APP_NAME" ]]; then
  echo "Missing required updater arguments" >&2
  exit 2
fi

TARGET_PARENT="$(dirname "$TARGET_APP")"
if [[ ! -w "$TARGET_PARENT" ]]; then
  echo "No write permission to $TARGET_PARENT." >&2
  exit 3
fi

for _ in {1..900}; do
  if ! kill -0 "$PID" 2>/dev/null; then
    break
  fi
  sleep 0.2
done

if kill -0 "$PID" 2>/dev/null; then
  echo "Timed out waiting for app process $PID to exit" >&2
  exit 4
fi

WORK_DIR="$(mktemp -d /tmp/vibe-bridge-updater.XXXXXX)"
MOUNT_POINT=""
SOURCE_ROOT=""
SOURCE_APP=""
STAGING_APP="$TARGET_PARENT/.${APP_NAME}.incoming.$$"
BACKUP_APP="$TARGET_PARENT/.${APP_NAME}.backup.$$"

cleanup() {
  if [[ -n "$MOUNT_POINT" ]]; then
    hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK_DIR"
}

rollback_install() {
  if [[ -d "$BACKUP_APP" && ! -e "$TARGET_APP" ]]; then
    mv "$BACKUP_APP" "$TARGET_APP" || true
  fi
}

fail() {
  local message="$1"
  rollback_install
  echo "$message" >&2
  cleanup
  exit 5
}

case "$ASSET_KIND" in
  zip)
    SOURCE_ROOT="$WORK_DIR/unpacked"
    mkdir -p "$SOURCE_ROOT"
    ditto -x -k "$ASSET_PATH" "$SOURCE_ROOT" || fail "Failed to extract ZIP update payload"
    ;;
  dmg)
    SOURCE_ROOT="$WORK_DIR/mounted"
    attach_output="$(hdiutil attach "$ASSET_PATH" -nobrowse -readonly 2>/dev/null)" || fail "Failed to mount DMG update payload"
    MOUNT_POINT="$(echo "$attach_output" | sed -n 's|^.*\t||p' | tail -n 1)"
    if [[ -z "$MOUNT_POINT" || ! -d "$MOUNT_POINT" ]]; then
      fail "Mounted DMG has no mount point"
    fi
    SOURCE_ROOT="$MOUNT_POINT"
    ;;
  *)
    fail "Unsupported update asset format: $ASSET_KIND"
    ;;
esac

SOURCE_APP="$(find "$SOURCE_ROOT" -maxdepth 4 -type d -name '*.app' | head -n 1)"
if [[ -z "$SOURCE_APP" || ! -d "$SOURCE_APP" ]]; then
  fail "Update payload did not contain an app bundle"
fi

ACTUAL_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$SOURCE_APP/Contents/Info.plist" 2>/dev/null || true)"
if [[ "$ACTUAL_BUNDLE_ID" != "$EXPECTED_BUNDLE_ID" ]]; then
  fail "Bundle identifier mismatch: expected $EXPECTED_BUNDLE_ID but found $ACTUAL_BUNDLE_ID"
fi

rm -rf "$STAGING_APP" "$BACKUP_APP"
ditto "$SOURCE_APP" "$STAGING_APP" || fail "Failed to stage updated app bundle"

if [[ -e "$TARGET_APP" ]]; then
  mv "$TARGET_APP" "$BACKUP_APP" || fail "Failed to backup existing app bundle"
fi

if ! mv "$STAGING_APP" "$TARGET_APP"; then
  fail "Failed to move updated app bundle into place"
fi

rm -rf "$BACKUP_APP"
xattr -dr com.apple.quarantine "$TARGET_APP" >/dev/null 2>&1 || true
open "$TARGET_APP" >/dev/null 2>&1 || fail "Updated app installed but relaunch failed"

cleanup
exit 0
"""#
    }

    static func buildInvocation(
        config: UpdaterHelperConfiguration,
        fileManager: FileManager = .default
    ) throws -> UpdaterHelperInvocation {
        let scriptDirectory = fileManager.temporaryDirectory.appendingPathComponent("vibe-bridge-updater", isDirectory: true)
        try fileManager.createDirectory(
            at: scriptDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let scriptURL = scriptDirectory
            .appendingPathComponent("run-update-\(UUID().uuidString)")
            .appendingPathExtension("sh")

        try scriptContents().write(to: scriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

        return UpdaterHelperInvocation(
            executableURL: URL(fileURLWithPath: "/bin/bash"),
            arguments: [scriptURL.path] + arguments(for: config)
        )
    }
}

struct GitHubInAppUpdater: Sendable {
    let configuration: UpdateRepositoryConfiguration

    private let checker: GitHubReleaseUpdateChecker
    private let session: URLSession

    init(
        configuration: UpdateRepositoryConfiguration,
        checker: GitHubReleaseUpdateChecker? = nil,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.session = session
        self.checker = checker ?? GitHubReleaseUpdateChecker(
            owner: configuration.owner,
            repo: configuration.repo,
            client: GitHubReleaseClient(session: session)
        )
    }

    func checkForUpdates(currentVersion: String) async throws -> UpdateCheckResult {
        try await checker.checkForUpdate(currentVersionString: currentVersion)
    }

    @discardableResult
    func prepareAndLaunchInstall(
        from result: UpdateCheckResult,
        currentAppBundleURL: URL,
        waitingForPID: Int32 = ProcessInfo.processInfo.processIdentifier,
        progress: (@Sendable (InAppUpdaterInstallProgress) -> Void)? = nil
    ) async throws -> URL {
        guard result.isUpdateAvailable else {
            throw InAppUpdaterError.noUpdateAvailable
        }

        guard let asset = result.preferredAsset else {
            throw InAppUpdaterError.missingInstallableAsset
        }

        let assetKind = UpdateAssetKind.infer(from: asset.name)
        guard assetKind == .zip || assetKind == .dmg else {
            throw InAppUpdaterError.unsupportedAsset(name: asset.name)
        }

        guard Self.isTrustedReleaseAssetURL(asset.browserDownloadURL, owner: configuration.owner, repo: configuration.repo) else {
            throw InAppUpdaterError.untrustedAssetURL(asset.browserDownloadURL)
        }

        let checksumsAsset = result.release.assets.first(where: { $0.name == "SHA256SUMS" })
        guard let checksumsAsset else {
            throw InAppUpdaterError.missingChecksumsAsset
        }

        let targetAppURL = currentAppBundleURL.standardizedFileURL
        try ensureWritableDestination(targetAppURL: targetAppURL)

        progress?(.downloading(0))
        let downloadedAssetURL = try await downloadAsset(asset: asset) { fraction in
            progress?(.downloading(fraction))
        }

        let expectedDigest = try await resolveExpectedDigest(
            asset: asset,
            checksumsAsset: checksumsAsset
        )
        try verifyDownloadedAssetDigest(
            expectedDigest: expectedDigest,
            downloadedAssetURL: downloadedAssetURL
        )

        progress?(.installing)

        let helperConfig = UpdaterHelperConfiguration(
            waitingForPID: waitingForPID,
            assetURL: downloadedAssetURL,
            assetKind: assetKind,
            targetAppURL: targetAppURL,
            expectedBundleIdentifier: configuration.bundleIdentifier,
            appName: configuration.appName
        )

        let invocation = try UpdaterHelperBuilder.buildInvocation(config: helperConfig, fileManager: .default)
        try launchHelper(invocation)

        progress?(.relaunching)
        return targetAppURL
    }

    func openReleasesPage() {
        NSWorkspace.shared.open(configuration.releasesPageURL)
    }

    private static func isTrustedReleaseAssetURL(_ url: URL, owner: String, repo: String) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else {
            return false
        }

        if host == "github.com" {
            return url.path.contains("/\(owner)/\(repo)/releases/download/")
        }

        return host == "objects.githubusercontent.com"
            || host == "github-releases.githubusercontent.com"
            || host == "release-assets.githubusercontent.com"
    }

    private func ensureWritableDestination(targetAppURL: URL) throws {
        let parent = targetAppURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw InAppUpdaterError.destinationNotWritable(path: parent.path)
        }
    }

    private func launchHelper(_ invocation: UpdaterHelperInvocation) throws {
        let process = Process()
        process.executableURL = invocation.executableURL
        process.arguments = invocation.arguments

        do {
            try process.run()
        } catch {
            throw InAppUpdaterError.helperLaunchFailed(error.localizedDescription)
        }
    }

    private func downloadAsset(
        asset: GitHubReleaseAsset,
        progress: @escaping @Sendable (Double?) -> Void
    ) async throws -> URL {
        var request = URLRequest(url: asset.browserDownloadURL)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("VibeBridge-InAppUpdater", forHTTPHeaderField: "User-Agent")

        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw InAppUpdaterError.downloadFailed("Invalid HTTP response")
            }

            guard (200..<300).contains(http.statusCode) else {
                throw InAppUpdaterError.downloadFailed("HTTP \(http.statusCode)")
            }

            if let responseURL = http.url,
               !Self.isTrustedReleaseAssetURL(responseURL, owner: configuration.owner, repo: configuration.repo) {
                throw InAppUpdaterError.untrustedAssetURL(responseURL)
            }

            let fileManager = FileManager.default
            let destinationDir = fileManager.temporaryDirectory
                .appendingPathComponent("vibe-bridge-updater")
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fileManager.createDirectory(
                at: destinationDir,
                withIntermediateDirectories: true,
                attributes: nil
            )

            let destinationURL = destinationDir.appendingPathComponent(asset.name)
            fileManager.createFile(atPath: destinationURL.path, contents: nil)
            let output = try FileHandle(forWritingTo: destinationURL)
            defer {
                try? output.close()
            }

            let expectedLength = response.expectedContentLength > 0 ? response.expectedContentLength : nil
            var receivedBytes: Int64 = 0
            var buffer = Data()
            var iterator = bytes.makeAsyncIterator()

            while let byte = try await iterator.next() {
                buffer.append(byte)
                if buffer.count >= 64 * 1024 {
                    try output.write(contentsOf: buffer)
                    receivedBytes += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    if let expectedLength {
                        progress(min(1, Double(receivedBytes) / Double(expectedLength)))
                    } else {
                        progress(nil)
                    }
                }
            }

            if !buffer.isEmpty {
                try output.write(contentsOf: buffer)
                receivedBytes += Int64(buffer.count)
            }

            progress(expectedLength == nil ? 1 : min(1, Double(receivedBytes) / Double(expectedLength!)))
            return destinationURL
        } catch let error as InAppUpdaterError {
            throw error
        } catch {
            throw InAppUpdaterError.downloadFailed(error.localizedDescription)
        }
    }

    private func resolveExpectedDigest(
        asset: GitHubReleaseAsset,
        checksumsAsset: GitHubReleaseAsset
    ) async throws -> String {
        var request = URLRequest(url: checksumsAsset.browserDownloadURL)
        request.setValue("text/plain,application/octet-stream;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("VibeBridge-InAppUpdater", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw InAppUpdaterError.digestFetchFailed("Invalid HTTP response")
            }

            guard (200..<300).contains(http.statusCode) else {
                throw InAppUpdaterError.digestFetchFailed("HTTP \(http.statusCode)")
            }

            if let responseURL = http.url,
               !Self.isTrustedReleaseAssetURL(responseURL, owner: configuration.owner, repo: configuration.repo) {
                throw InAppUpdaterError.untrustedAssetURL(responseURL)
            }

            return try Self.parseDigestManifest(data: data, assetName: asset.name)
        } catch let error as InAppUpdaterError {
            throw error
        } catch {
            throw InAppUpdaterError.digestFetchFailed(error.localizedDescription)
        }
    }

    private func verifyDownloadedAssetDigest(
        expectedDigest: String,
        downloadedAssetURL: URL
    ) throws {
        let data = try Data(contentsOf: downloadedAssetURL)
        let actual = SHA256.hash(data: data).hexString
        guard actual == expectedDigest else {
            throw InAppUpdaterError.digestMismatch(expected: expectedDigest, actual: actual)
        }
    }

    static func parseDigestManifest(data: Data, assetName: String) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else {
            throw InAppUpdaterError.invalidDigestFormat(source: "SHA256SUMS")
        }

        let expectedNames = expectedManifestNames(for: assetName)
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(
                maxSplits: 2,
                omittingEmptySubsequences: true,
                whereSeparator: \.isWhitespace
            )
            guard let digestPart = parts.first else { continue }
            let digest = String(digestPart).lowercased()
            let remainder = String(trimmed.dropFirst(digestPart.count))
            let fileName = remainder.trimmingCharacters(in: CharacterSet.whitespaces)
                .replacingOccurrences(of: "*", with: "")
                .trimmingCharacters(in: CharacterSet.whitespaces)
            if expectedNames.contains(normalizeManifestFileName(fileName)) {
                guard digest.count == 64, digest.allSatisfy({ $0.isHexDigit }) else {
                    throw InAppUpdaterError.invalidDigestFormat(source: "SHA256SUMS")
                }
                return digest
            }
        }

        throw InAppUpdaterError.missingDigest(assetName: assetName)
    }

    private static func expectedManifestNames(for assetName: String) -> Set<String> {
        var names: Set<String> = [normalizeManifestFileName(assetName)]
        if let basename = assetName.split(separator: "/").last {
            names.insert(normalizeManifestFileName(String(basename)))
        }
        return names
    }

    private static func normalizeManifestFileName(_ rawValue: String) -> String {
        rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .last
            .map(String.init)?
            .lowercased() ?? rawValue.lowercased()
    }
}

private extension Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
