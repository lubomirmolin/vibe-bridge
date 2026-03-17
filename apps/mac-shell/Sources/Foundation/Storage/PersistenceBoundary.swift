import Foundation

enum PersistenceScope {
    case threadsCache
    case timelineCache
    case securityAudit

    var fileName: String {
        switch self {
        case .threadsCache:
            return "threads-cache.sqlite"
        case .timelineCache:
            return "timeline-cache.sqlite"
        case .securityAudit:
            return "security-audit.sqlite"
        }
    }

    var storesSensitiveData: Bool {
        false
    }
}

struct PersistenceBoundary {
    let baseDirectory: URL

    var stateDirectory: URL {
        baseDirectory.appendingPathComponent("state", isDirectory: true)
    }

    func sqliteURL(for scope: PersistenceScope) -> URL {
        stateDirectory.appendingPathComponent(scope.fileName, isDirectory: false)
    }

    func requiresSecureStore(for scope: PersistenceScope) -> Bool {
        scope.storesSensitiveData
    }
}
