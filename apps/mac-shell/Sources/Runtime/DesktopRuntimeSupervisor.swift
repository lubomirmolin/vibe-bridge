import Darwin
import Foundation

protocol DesktopRuntimeSupervisorClient: AnyObject {
    func prepareBridgeForConnection() async throws -> DesktopRuntimeLaunchSnapshot
    func restartBridge() async throws -> DesktopRuntimeLaunchSnapshot
}

enum DesktopRuntimeSupervisorError: LocalizedError {
    case bridgeBinaryNotFound([String])
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case let .bridgeBinaryNotFound(candidates):
            let candidateList = candidates.joined(separator: ", ")
            return "bridge-server binary was not found. Checked \(candidateList). Set CODEX_MOBILE_COMPANION_BRIDGE_BINARY or bundle the helper into the app."
        case let .launchFailed(message):
            return message
        }
    }
}

final class DesktopRuntimeSupervisor: DesktopRuntimeSupervisorClient {
    private let healthProbe: BridgeHealthProbe
    private let pathResolver: BridgeBinaryPathResolver
    private let portProcessInspector: BridgePortProcessInspecting
    private let processEnvironment: [String: String]
    private let fileManager: FileManager
    private let bridgeHost: String
    private let bridgePort: Int
    private let adminPort: Int
    private let codexCommandOverride: String?
    private let stateDirectoryURL: URL
    private let currentProcessID: Int32

    private var managedProcess: Process?
    private var recentLogLines: [String] = []
    private var lastExitSummary: String?

    init(
        healthProbe: BridgeHealthProbe = HTTPBridgeHealthProbe(),
        pathResolver: BridgeBinaryPathResolver = BridgeBinaryPathResolver(),
        portProcessInspector: BridgePortProcessInspecting = BridgePortProcessInspector(),
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        bridgeHost: String = "127.0.0.1",
        bridgePort: Int = 3110,
        adminPort: Int = 3111,
        codexCommandOverride: String? = ProcessInfo.processInfo.environment["CODEX_MOBILE_COMPANION_CODEX_BINARY"],
        stateDirectoryURL: URL = DesktopRuntimeSupervisor.defaultStateDirectoryURL(),
        currentProcessID: Int32 = Int32(ProcessInfo.processInfo.processIdentifier)
    ) {
        self.healthProbe = healthProbe
        self.pathResolver = pathResolver
        self.portProcessInspector = portProcessInspector
        self.processEnvironment = processEnvironment
        self.fileManager = fileManager
        self.bridgeHost = bridgeHost
        self.bridgePort = bridgePort
        self.adminPort = adminPort
        self.codexCommandOverride = codexCommandOverride
        self.stateDirectoryURL = stateDirectoryURL
        self.currentProcessID = currentProcessID
    }

    func prepareBridgeForConnection() async throws -> DesktopRuntimeLaunchSnapshot {
        let bridgeBinaryURL = try? pathResolver.resolveBridgeBinaryURL()
        if await healthProbe.isReachable(host: bridgeHost, port: bridgePort) {
            if let managedProcess, managedProcess.isRunning {
                return DesktopRuntimeLaunchSnapshot(
                    statusLabel: "Managed locally",
                    detail: "Desktop shell owns the local bridge process.",
                    isLaunching: false
                )
            }

            if managedProcess != nil {
                self.managedProcess = nil
            }

            if let listener = portProcessInspector.listener(on: bridgePort),
               let bridgeBinaryURL,
               listener.isManagedBridge(matching: bridgeBinaryURL, ownedBy: currentProcessID)
            {
                return DesktopRuntimeLaunchSnapshot(
                    statusLabel: "Managed locally",
                    detail: "Desktop shell found an existing bundled bridge helper (pid \(listener.pid)).",
                    isLaunching: false
                )
            }

            if let listener = portProcessInspector.listener(on: bridgePort),
               let bridgeBinaryURL,
               listener.isManagedBridge(matching: bridgeBinaryURL)
            {
                try terminateBridgeListener(listener)
                return try startBridgeProcess()
            }

            return DesktopRuntimeLaunchSnapshot(
                statusLabel: "Attached to existing bridge",
                detail: "An existing bridge is already listening on \(bridgeHost):\(bridgePort).",
                isLaunching: false
            )
        }

        if let managedProcess {
            if managedProcess.isRunning {
                return DesktopRuntimeLaunchSnapshot(
                    statusLabel: "Launching bridge",
                    detail: "Desktop shell started bridge-server (pid \(managedProcess.processIdentifier)). Waiting for health on \(bridgeHost):\(bridgePort)…",
                    isLaunching: true
                )
            }

            let exitSummary = lastExitSummary
            self.managedProcess = nil
            let exitDetail = exitSummary ?? "bridge-server exited before reporting healthy"
            recentLogLines.removeAll()
            lastExitSummary = nil
            throw DesktopRuntimeSupervisorError.launchFailed(exitDetail)
        }

        return try startBridgeProcess()
    }

    func restartBridge() async throws -> DesktopRuntimeLaunchSnapshot {
        let externalBridgeReachable = await healthProbe.isReachable(host: bridgeHost, port: bridgePort)
        if managedProcess == nil && externalBridgeReachable {
            let bridgeBinaryURL = try? pathResolver.resolveBridgeBinaryURL()
            if let listener = portProcessInspector.listener(on: bridgePort),
               let bridgeBinaryURL,
               listener.isManagedBridge(matching: bridgeBinaryURL)
            {
                try terminateBridgeListener(listener)
            } else {
                throw DesktopRuntimeSupervisorError.launchFailed(
                    "desktop shell cannot restart the bridge because it is attached to an external process on \(bridgeHost):\(bridgePort)"
                )
            }
        }

        stopManagedProcess()
        return try startBridgeProcess()
    }

    private func startBridgeProcess() throws -> DesktopRuntimeLaunchSnapshot {
        let bridgeBinaryURL = try pathResolver.resolveBridgeBinaryURL()
        let process = Process()
        process.executableURL = bridgeBinaryURL
        process.arguments = bridgeArguments()
        process.environment = processEnvironment
        process.currentDirectoryURL = stateDirectoryURL

        do {
            try fileManager.createDirectory(
                at: stateDirectoryURL,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            throw DesktopRuntimeSupervisorError.launchFailed(
                "failed to prepare bridge state directory at \(stateDirectoryURL.path): \(error.localizedDescription)"
            )
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        wirePipe(stdoutPipe, source: "stdout")
        wirePipe(stderrPipe, source: "stderr")

        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async { [weak self] in
                self?.handleTermination(process)
            }
        }

        do {
            try process.run()
        } catch {
            throw DesktopRuntimeSupervisorError.launchFailed(
                "failed to launch bridge-server at \(bridgeBinaryURL.path): \(error.localizedDescription)"
            )
        }

        managedProcess = process
        return DesktopRuntimeLaunchSnapshot(
            statusLabel: "Launching bridge",
            detail: "Desktop shell launched bridge-server (pid \(process.processIdentifier)). Waiting for health on \(bridgeHost):\(bridgePort)…",
            isLaunching: true
        )
    }

    private func bridgeArguments() -> [String] {
        var arguments = [
            "--host", bridgeHost,
            "--port", "\(bridgePort)",
            "--admin-port", "\(adminPort)",
            "--state-directory", stateDirectoryURL.path,
            "--codex-mode", "auto",
        ]

        if let codexCommandOverride,
           !codexCommandOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            arguments.append(contentsOf: ["--codex-command", codexCommandOverride])
        } else if let resolvedCodexBinaryURL = pathResolver.resolveCodexBinaryURL() {
            arguments.append(contentsOf: ["--codex-command", resolvedCodexBinaryURL.path])
        }

        return arguments
    }

    static func defaultStateDirectoryURL() -> URL {
        let applicationSupportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
        return applicationSupportDirectory
            .appending(path: "CodexMobileCompanion", directoryHint: .isDirectory)
            .appending(path: "bridge-core", directoryHint: .isDirectory)
    }

    private func terminateBridgeListener(_ listener: BridgePortProcess) throws {
        guard kill(listener.pid, SIGTERM) == 0 else {
            throw DesktopRuntimeSupervisorError.launchFailed(
                "failed to stop existing bundled bridge helper (pid \(listener.pid)): \(String(cString: strerror(errno)))"
            )
        }

        for _ in 0..<20 {
            if portProcessInspector.listener(on: bridgePort)?.pid != listener.pid {
                return
            }

            Thread.sleep(forTimeInterval: 0.1)
        }

        throw DesktopRuntimeSupervisorError.launchFailed(
            "timed out waiting for existing bundled bridge helper (pid \(listener.pid)) to stop"
        )
    }

    private func wirePipe(_ pipe: Pipe, source: String) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }

            let chunk = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { [weak self] in
                self?.appendLogLines(chunk, source: source)
            }
        }
    }

    private func appendLogLines(_ chunk: String, source: String) {
        let lines = chunk
            .split(whereSeparator: \.isNewline)
            .map { "[\(source)] \($0)" }

        guard !lines.isEmpty else {
            return
        }

        recentLogLines.append(contentsOf: lines)
        if recentLogLines.count > 20 {
            recentLogLines.removeFirst(recentLogLines.count - 20)
        }
    }

    private func handleTermination(_ process: Process) {
        let summary = "bridge-server exited with status \(process.terminationStatus). \(recentLogTail())"
        lastExitSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)

        if managedProcess === process {
            managedProcess = nil
        }
    }

    private func stopManagedProcess() {
        guard let process = managedProcess else {
            recentLogLines.removeAll()
            lastExitSummary = nil
            return
        }

        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        managedProcess = nil
        recentLogLines.removeAll()
        lastExitSummary = nil
    }

    private func recentLogTail() -> String {
        guard !recentLogLines.isEmpty else {
            return ""
        }

        return "Recent logs: \(recentLogLines.suffix(4).joined(separator: " | "))"
    }
}

struct BridgeBinaryPathResolver {
    private let fileManager: FileManager
    private let environment: [String: String]
    private let currentDirectoryURL: URL
    private let bundleResourceURL: URL?

    init(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectoryURL: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
        bundleResourceURL: URL? = Bundle.main.resourceURL
    ) {
        self.fileManager = fileManager
        self.environment = environment
        self.currentDirectoryURL = currentDirectoryURL
        self.bundleResourceURL = bundleResourceURL
    }

    func resolveBridgeBinaryURL() throws -> URL {
        let candidates = bridgeBinaryCandidates()
        if let resolved = resolveExecutableURL(candidates: candidates) {
            return resolved
        }

        throw DesktopRuntimeSupervisorError.bridgeBinaryNotFound(candidates.map(\.path))
    }

    func resolveCodexBinaryURL() -> URL? {
        resolveExecutableURL(candidates: codexBinaryCandidates())
    }

    private func bridgeBinaryCandidates() -> [URL] {
        var candidates: [URL] = []

        if let explicitPath = environment["CODEX_MOBILE_COMPANION_BRIDGE_BINARY"],
           !explicitPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            candidates.append(URL(fileURLWithPath: explicitPath))
        }

        if let bundleResourceURL {
            candidates.append(bundleResourceURL.appending(path: "bridge-server"))
            candidates.append(bundleResourceURL.appending(path: "bin").appending(path: "bridge-server"))
        }

        let searchRoots = [currentDirectoryURL, bundleResourceURL].compactMap { $0 }
        for root in searchRoots {
            if let workspaceRoot = workspaceRoot(startingAt: root) {
                candidates.append(workspaceRoot.appending(path: "target").appending(path: "debug").appending(path: "bridge-server"))
                candidates.append(workspaceRoot.appending(path: "target").appending(path: "release").appending(path: "bridge-server"))
            }
        }

        candidates.append(contentsOf: pathExecutableCandidates(named: "bridge-server"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/bridge-server"))
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/bridge-server"))

        return deduplicated(candidates)
    }

    private func codexBinaryCandidates() -> [URL] {
        var candidates: [URL] = []
        let homeDirectoryPath = environment["HOME"] ?? NSHomeDirectory()

        if let explicitPath = environment["CODEX_MOBILE_COMPANION_CODEX_BINARY"],
           !explicitPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            candidates.append(URL(fileURLWithPath: explicitPath))
        }

        candidates.append(contentsOf: pathExecutableCandidates(named: "codex"))
        candidates.append(URL(fileURLWithPath: homeDirectoryPath).appending(path: ".bun").appending(path: "bin").appending(path: "codex"))
        candidates.append(URL(fileURLWithPath: homeDirectoryPath).appending(path: ".cargo").appending(path: "bin").appending(path: "codex"))
        candidates.append(URL(fileURLWithPath: homeDirectoryPath).appending(path: ".local").appending(path: "bin").appending(path: "codex"))
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/codex"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/codex"))

        return deduplicated(candidates)
    }

    private func pathExecutableCandidates(named executableName: String) -> [URL] {
        guard let rawPath = environment["PATH"], !rawPath.isEmpty else {
            return []
        }

        return rawPath
            .split(separator: ":")
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: String($0), isDirectory: true).appending(path: executableName) }
    }

    private func resolveExecutableURL(candidates: [URL]) -> URL? {
        candidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) })
    }

    private func deduplicated(_ candidates: [URL]) -> [URL] {
        var uniqueCandidates: [URL] = []
        var seenPaths = Set<String>()
        for candidate in candidates where seenPaths.insert(candidate.path).inserted {
            uniqueCandidates.append(candidate)
        }
        return uniqueCandidates
    }

    private func workspaceRoot(startingAt startURL: URL) -> URL? {
        var currentURL = startURL.standardizedFileURL
        for _ in 0..<10 {
            let cargoURL = currentURL.appending(path: "Cargo.toml")
            let shellURL = currentURL.appending(path: "apps").appending(path: "mac-shell")
            if fileManager.fileExists(atPath: cargoURL.path) && fileManager.fileExists(atPath: shellURL.path) {
                return currentURL
            }

            let parentURL = currentURL.deletingLastPathComponent()
            if parentURL.path == currentURL.path {
                break
            }
            currentURL = parentURL
        }

        return nil
    }
}

struct BridgePortProcess: Equatable {
    let pid: Int32
    let parentPID: Int32?
    let command: String

    func isManagedBridge(matching bridgeBinaryURL: URL) -> Bool {
        command.hasPrefix(bridgeBinaryURL.path)
    }

    func isManagedBridge(matching bridgeBinaryURL: URL, ownedBy parentPID: Int32) -> Bool {
        isManagedBridge(matching: bridgeBinaryURL) && self.parentPID == parentPID
    }
}

protocol BridgePortProcessInspecting {
    func listener(on port: Int) -> BridgePortProcess?
}

struct BridgePortProcessInspector: BridgePortProcessInspecting {
    func listener(on port: Int) -> BridgePortProcess? {
        guard let pidString = run("/usr/sbin/lsof", arguments: ["-t", "-nP", "-iTCP:\(port)", "-sTCP:LISTEN"])?
            .split(whereSeparator: \.isNewline)
            .first
        else {
            return nil
        }

        let trimmedPID = pidString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = Int32(trimmedPID) else {
            return nil
        }

        guard let command = run("/bin/ps", arguments: ["-p", trimmedPID, "-o", "command="])?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty
        else {
            return nil
        }

        let parentPID = run("/bin/ps", arguments: ["-p", trimmedPID, "-o", "ppid="])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedParentPID = parentPID.flatMap(Int32.init)

        return BridgePortProcess(pid: pid, parentPID: parsedParentPID, command: command)
    }

    private func run(_ launchPath: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }
}

protocol BridgeHealthProbe {
    func isReachable(host: String, port: Int) async -> Bool
}

struct HTTPBridgeHealthProbe: BridgeHealthProbe {
    func isReachable(host: String, port: Int) async -> Bool {
        guard let url = URL(string: "http://\(host):\(port)/health") else {
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 1
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return false
            }
            return (200 ..< 300).contains(httpResponse.statusCode)
        } catch {
            return false
        }
    }
}
