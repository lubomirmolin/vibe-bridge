import Darwin
import Foundation

struct BridgeTerminationSummary {
    static func make(
        reason: Process.TerminationReason,
        status: Int32,
        recentLogLines: [String],
        logPath: String
    ) -> String {
        let baseMessage: String
        switch reason {
        case .exit:
            baseMessage = "bridge helper exited with status \(status)"
        case .uncaughtSignal:
            baseMessage = "bridge helper crashed from signal \(status)"
        @unknown default:
            baseMessage = "bridge helper terminated for an unknown reason (\(status))"
        }

        let tail = recentLogLines.suffix(4).joined(separator: " | ")
        if tail.isEmpty {
            return "\(baseMessage). Full log: \(logPath)"
        }

        return "\(baseMessage). Recent logs: \(tail). Full log: \(logPath)"
    }
}

final class BridgeSupervisorLogWriter {
    private let fileManager: FileManager
    let logFileURL: URL
    private let now: () -> Date
    private let lock = NSLock()
    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    init(
        fileManager: FileManager = .default,
        logFileURL: URL,
        now: @escaping () -> Date = Date.init
    ) {
        self.fileManager = fileManager
        self.logFileURL = logFileURL
        self.now = now
    }

    func append(_ line: String) {
        let entry = "[\(formatter.string(from: now()))] \(line)\n"
        guard let data = entry.data(using: .utf8) else {
            return
        }

        lock.lock()
        defer { lock.unlock() }

        do {
            try fileManager.createDirectory(
                at: logFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )

            if !fileManager.fileExists(atPath: logFileURL.path) {
                fileManager.createFile(atPath: logFileURL.path, contents: Data())
            }

            let handle = try FileHandle(forWritingTo: logFileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            fputs("bridge supervisor log write failed: \(error.localizedDescription)\n", stderr)
        }
    }
}

protocol DesktopRuntimeSupervisorClient: AnyObject {
    func prepareBridgeForConnection() async throws -> DesktopRuntimeLaunchSnapshot
    func restartBridge() async throws -> DesktopRuntimeLaunchSnapshot
    func shutdownBridgeIfManaged()
    func stopManagedBridge()
}

enum DesktopRuntimeSupervisorError: LocalizedError {
    case bridgeBinaryNotFound([String])
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case let .bridgeBinaryNotFound(candidates):
            let candidateList = candidates.joined(separator: ", ")
            return "bridge helper binary was not found. Checked \(candidateList). Set CODEX_MOBILE_COMPANION_BRIDGE_BINARY or bundle the helper into the app."
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
    private let logWriter: BridgeSupervisorLogWriter

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
        currentProcessID: Int32 = Int32(ProcessInfo.processInfo.processIdentifier),
        logWriter: BridgeSupervisorLogWriter? = nil
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
        self.logWriter = logWriter ?? BridgeSupervisorLogWriter(
            fileManager: fileManager,
            logFileURL: stateDirectoryURL.appending(path: "bridge-supervisor.log")
        )
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
                    detail: "Desktop shell started the bridge helper (pid \(managedProcess.processIdentifier)). Waiting for health on \(bridgeHost):\(bridgePort)…",
                    isLaunching: true
                )
            }

            let exitSummary = lastExitSummary
            self.managedProcess = nil
            let exitDetail = exitSummary ?? "bridge helper exited before reporting healthy"
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

    func shutdownBridgeIfManaged() {
        managedProcess = nil
    }

    func stopManagedBridge() {
        stopManagedProcess()

        guard let bridgeBinaryURL = try? pathResolver.resolveBridgeBinaryURL(),
              let listener = portProcessInspector.listener(on: bridgePort),
              listener.isManagedBridge(matching: bridgeBinaryURL, ownedBy: currentProcessID)
        else {
            return
        }

        try? terminateBridgeListener(listener)
    }

    deinit {
        managedProcess = nil
    }

    private func startBridgeProcess() throws -> DesktopRuntimeLaunchSnapshot {
        let bridgeBinaryURL = try pathResolver.resolveBridgeBinaryURL()
        let process = Process()
        process.executableURL = bridgeBinaryURL
        process.arguments = bridgeArguments()
        process.environment = bridgeProcessEnvironment()
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
        logWriter.append("[supervisor] launching bridge helper: \(bridgeBinaryURL.path) \(bridgeArguments().joined(separator: " "))")
        recentLogLines.removeAll()
        lastExitSummary = nil

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
            logWriter.append("[supervisor] failed to launch bridge helper at \(bridgeBinaryURL.path): \(error.localizedDescription)")
            throw DesktopRuntimeSupervisorError.launchFailed(
                "failed to launch bridge helper at \(bridgeBinaryURL.path): \(error.localizedDescription)"
            )
        }

        managedProcess = process
        logWriter.append(
            "[supervisor] bridge helper launched (pid \(process.processIdentifier)); waiting for health on \(bridgeHost):\(bridgePort)"
        )
        return DesktopRuntimeLaunchSnapshot(
            statusLabel: "Launching bridge",
            detail: "Desktop shell launched the bridge helper (pid \(process.processIdentifier)). Waiting for health on \(bridgeHost):\(bridgePort)…",
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

    private func bridgeProcessEnvironment() -> [String: String] {
        var environment = processEnvironment
        if let speechHelperURL = pathResolver.resolveSpeechHelperBinaryURL() {
            environment["CODEX_MOBILE_COMPANION_SPEECH_HELPER_BINARY"] = speechHelperURL.path
        }

        let homeDirectoryPath = environment["HOME"] ?? NSHomeDirectory()
        let extraPathEntries = [
            "\(homeDirectoryPath)/.bun/bin",
            "\(homeDirectoryPath)/.nvm/versions/node",
            "\(homeDirectoryPath)/.local/bin",
            "\(homeDirectoryPath)/.cargo/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ]

        var nvmNodeBins: [String] = []
        let nvmVersionsPath = "\(homeDirectoryPath)/.nvm/versions/node"
        if let entries = try? fileManager.contentsOfDirectory(atPath: nvmVersionsPath) {
            for entry in entries.sorted().reversed() {
                let binPath = "\(nvmVersionsPath)/\(entry)/bin"
                if fileManager.isExecutableFile(atPath: "\(binPath)/node") {
                    nvmNodeBins.append(binPath)
                }
            }
        }

        let existingPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let allEntries = extraPathEntries + nvmNodeBins + [existingPath]
        environment["PATH"] = allEntries.joined(separator: ":")

        return environment
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

        for line in lines {
            logWriter.append(line)
        }
    }

    private func handleTermination(_ process: Process) {
        let summary = BridgeTerminationSummary.make(
            reason: process.terminationReason,
            status: process.terminationStatus,
            recentLogLines: recentLogLines,
            logPath: logWriter.logFileURL.path
        )
        lastExitSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        logWriter.append("[supervisor] \(summary)")

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

        logWriter.append("[supervisor] stopping managed bridge helper (pid \(process.processIdentifier))")

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

    func resolveSpeechHelperBinaryURL() -> URL? {
        resolveExecutableURL(candidates: speechHelperBinaryCandidates())
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

    private func speechHelperBinaryCandidates() -> [URL] {
        var candidates: [URL] = []

        if let explicitPath = environment["CODEX_MOBILE_COMPANION_SPEECH_HELPER_BINARY"],
           !explicitPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            candidates.append(URL(fileURLWithPath: explicitPath))
        }

        if let bundleResourceURL {
            candidates.append(bundleResourceURL.appending(path: "CodexSpeechHelper"))
            candidates.append(bundleResourceURL.appending(path: "bin").appending(path: "CodexSpeechHelper"))
        }

        let searchRoots = [currentDirectoryURL, bundleResourceURL].compactMap { $0 }
        for root in searchRoots {
            if let workspaceRoot = workspaceRoot(startingAt: root) {
                candidates.append(workspaceRoot.appending(path: "apps").appending(path: "mac-shell").appending(path: ".build").appending(path: "debug").appending(path: "CodexSpeechHelper"))
                candidates.append(workspaceRoot.appending(path: "build").appending(path: "Debug").appending(path: "CodexSpeechHelper"))
            }
        }

        candidates.append(contentsOf: pathExecutableCandidates(named: "CodexSpeechHelper"))
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
        for path in ["/healthz", "/health"] {
            guard let url = URL(string: "http://\(host):\(port)\(path)") else {
                continue
            }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 1
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    continue
                }
                if (200 ..< 300).contains(httpResponse.statusCode) {
                    return true
                }
            } catch {
                continue
            }
        }

        return false
    }
}
