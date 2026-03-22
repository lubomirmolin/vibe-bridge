import FluidAudio
import Foundation

private let provider = "fluid_audio"
private let modelID = "parakeet-tdt-0.6b-v3-coreml"

struct HelperRequest: Decodable {
    let id: String
    let command: String
    let filePath: String?

    enum CodingKeys: String, CodingKey {
        case id
        case command
        case filePath = "file_path"
    }
}

struct HelperStatusPayload: Encodable {
    let provider: String
    let modelID: String
    let state: String
    let lastError: String?
    let installedBytes: UInt64?

    enum CodingKeys: String, CodingKey {
        case provider
        case modelID = "model_id"
        case state
        case lastError = "last_error"
        case installedBytes = "installed_bytes"
    }
}

struct HelperTranscriptionPayload: Encodable {
    let text: String
    let durationMS: UInt64

    enum CodingKeys: String, CodingKey {
        case text
        case durationMS = "duration_ms"
    }
}

enum HelperEnvelope: Encodable {
    case progress(id: String, progress: UInt8)
    case response(id: String, ok: Bool, payload: AnyEncodable?, errorCode: String?, message: String?)

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .progress(id, progress):
            try container.encode("progress", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(progress, forKey: .progress)
        case let .response(id, ok, payload, errorCode, message):
            try container.encode("response", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(ok, forKey: .ok)
            try container.encodeIfPresent(payload, forKey: .payload)
            try container.encodeIfPresent(errorCode, forKey: .errorCode)
            try container.encodeIfPresent(message, forKey: .message)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case id
        case ok
        case payload
        case errorCode = "error_code"
        case message
        case progress
    }
}

struct AnyEncodable: Encodable {
    private let encodeImpl: (Encoder) throws -> Void

    init<T: Encodable>(_ wrapped: T) {
        self.encodeImpl = wrapped.encode
    }

    func encode(to encoder: Encoder) throws {
        try encodeImpl(encoder)
    }
}

struct HelperFailure: Error {
    let code: String
    let message: String
}

actor ProtocolWriter {
    private let encoder = JSONEncoder()

    init() {
        encoder.outputFormatting = [.withoutEscapingSlashes]
    }

    func send(_ envelope: HelperEnvelope) async {
        guard let data = try? encoder.encode(envelope) else {
            return
        }

        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

actor SpeechHelperService {
    private let fileManager: FileManager
    private let modelRoot: URL
    private var asrManager: AsrManager?
    private var lastError: String?

    init(
        fileManager: FileManager = .default,
        modelRoot: URL? = nil
    ) {
        self.fileManager = fileManager
        self.modelRoot = modelRoot ?? Self.resolveModelRoot()
    }

    func status() -> HelperStatusPayload {
        guard Self.isSupported else {
            return HelperStatusPayload(
                provider: provider,
                modelID: modelID,
                state: "unsupported",
                lastError: "Parakeet transcription requires Apple Silicon.",
                installedBytes: nil
            )
        }

        let installed = AsrModels.modelsExist(at: modelRoot, version: .v3)
        return HelperStatusPayload(
            provider: provider,
            modelID: modelID,
            state: installed ? "ready" : "not_installed",
            lastError: lastError,
            installedBytes: installed ? Self.directorySize(at: modelRoot) : nil
        )
    }

    func ensureModel(progress: @escaping @Sendable (UInt8) -> Void) async throws -> HelperStatusPayload {
        guard Self.isSupported else {
            throw HelperFailure(
                code: "speech_unsupported",
                message: "Parakeet transcription requires Apple Silicon."
            )
        }

        do {
            let models = try await AsrModels.downloadAndLoad(
                to: modelRoot,
                version: .v3,
                progressHandler: { downloadProgress in
                    let clamped = UInt8(max(0, min(100, Int(downloadProgress.fractionCompleted * 100))))
                    progress(clamped)
                }
            )
            let manager = AsrManager()
            try await manager.initialize(models: models)
            asrManager = manager
            lastError = nil
            return status()
        } catch {
            let message = error.localizedDescription
            lastError = message
            throw HelperFailure(code: "speech_install_failed", message: message)
        }
    }

    func removeModel() throws -> HelperStatusPayload {
        guard Self.isSupported else {
            throw HelperFailure(
                code: "speech_unsupported",
                message: "Parakeet transcription requires Apple Silicon."
            )
        }

        do {
            if fileManager.fileExists(atPath: modelRoot.path) {
                try fileManager.removeItem(at: modelRoot)
            }
            asrManager = nil
            lastError = nil
            return status()
        } catch {
            let message = error.localizedDescription
            lastError = message
            throw HelperFailure(code: "speech_install_failed", message: message)
        }
    }

    func transcribe(filePath: String) async throws -> HelperTranscriptionPayload {
        guard Self.isSupported else {
            throw HelperFailure(
                code: "speech_unsupported",
                message: "Parakeet transcription requires Apple Silicon."
            )
        }
        guard AsrModels.modelsExist(at: modelRoot, version: .v3) else {
            throw HelperFailure(
                code: "speech_not_installed",
                message: "Parakeet is not installed."
            )
        }

        do {
            let manager = try await loadManager()
            let result = try await manager.transcribe(
                URL(fileURLWithPath: filePath),
                source: .microphone
            )
            lastError = nil
            return HelperTranscriptionPayload(
                text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
                durationMS: UInt64((result.duration * 1000).rounded())
            )
        } catch {
            let message = error.localizedDescription
            lastError = message
            throw HelperFailure(code: "speech_transcription_failed", message: message)
        }
    }

    private func loadManager() async throws -> AsrManager {
        if let asrManager {
            return asrManager
        }

        do {
            let models = try await AsrModels.load(from: modelRoot, version: .v3)
            let manager = AsrManager()
            try await manager.initialize(models: models)
            asrManager = manager
            return manager
        } catch {
            throw HelperFailure(
                code: "speech_transcription_failed",
                message: error.localizedDescription
            )
        }
    }

    private static var isSupported: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }

    private static func resolveModelRoot() -> URL {
        if let explicitRoot = ProcessInfo.processInfo.environment["CODEX_MOBILE_COMPANION_SPEECH_MODEL_ROOT"],
           !explicitRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: explicitRoot, isDirectory: true)
        }

        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return support
            .appendingPathComponent("CodexMobileCompanion", isDirectory: true)
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(modelID, isDirectory: true)
    }

    private static func directorySize(at url: URL) -> UInt64? {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            guard
                let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                values.isRegularFile == true,
                let size = values.fileSize
            else {
                continue
            }
            total += UInt64(size)
        }
        return total
    }
}

@main
enum CodexSpeechHelperMain {
    static func main() async {
        let service = SpeechHelperService()
        let writer = ProtocolWriter()
        let decoder = JSONDecoder()

        do {
            for try await line in FileHandle.standardInput.bytes.lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    continue
                }

                let request: HelperRequest
                do {
                    request = try decoder.decode(HelperRequest.self, from: Data(trimmed.utf8))
                } catch {
                    await writer.send(
                        .response(
                            id: "unknown",
                            ok: false,
                            payload: nil,
                            errorCode: "speech_helper_unavailable",
                            message: "Malformed helper request: \(error.localizedDescription)"
                        )
                    )
                    continue
                }

                do {
                    switch request.command {
                    case "get_status":
                        let payload = await service.status()
                        await writer.send(
                            .response(
                                id: request.id,
                                ok: true,
                                payload: AnyEncodable(payload),
                                errorCode: nil,
                                message: nil
                            )
                        )

                    case "ensure_model":
                        let payload = try await service.ensureModel { progress in
                            Task {
                                await writer.send(.progress(id: request.id, progress: progress))
                            }
                        }
                        await writer.send(
                            .response(
                                id: request.id,
                                ok: true,
                                payload: AnyEncodable(payload),
                                errorCode: nil,
                                message: nil
                            )
                        )

                    case "remove_model":
                        let payload = try await service.removeModel()
                        await writer.send(
                            .response(
                                id: request.id,
                                ok: true,
                                payload: AnyEncodable(payload),
                                errorCode: nil,
                                message: nil
                            )
                        )

                    case "transcribe_file":
                        guard let filePath = request.filePath,
                              !filePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        else {
                            throw HelperFailure(
                                code: "speech_invalid_audio",
                                message: "Missing file path for transcription request."
                            )
                        }
                        let payload = try await service.transcribe(filePath: filePath)
                        await writer.send(
                            .response(
                                id: request.id,
                                ok: true,
                                payload: AnyEncodable(payload),
                                errorCode: nil,
                                message: nil
                            )
                        )

                    default:
                        throw HelperFailure(
                            code: "speech_helper_unavailable",
                            message: "Unknown helper command \(request.command)."
                        )
                    }
                } catch let failure as HelperFailure {
                    await writer.send(
                        .response(
                            id: request.id,
                            ok: false,
                            payload: nil,
                            errorCode: failure.code,
                            message: failure.message
                        )
                    )
                } catch {
                    await writer.send(
                        .response(
                            id: request.id,
                            ok: false,
                            payload: nil,
                            errorCode: "speech_helper_unavailable",
                            message: error.localizedDescription
                        )
                    )
                }
            }
        } catch {
            fputs("speech helper input stream failed: \(error.localizedDescription)\n", stderr)
        }
    }
}
