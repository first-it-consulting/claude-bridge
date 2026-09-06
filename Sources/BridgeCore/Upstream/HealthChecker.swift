import Foundation

/// Reachability probe for a backend.
public enum HealthChecker {

    public enum Health: Sendable, Equatable {
        case unknown
        case checking
        case reachable(modelCount: Int, latency: TimeInterval)
        case unreachable(String)

        public var isReachable: Bool { if case .reachable = self { return true }; return false }

        public var summary: String {
            switch self {
            case .unknown: return "Not checked"
            case .checking: return "Checking…"
            case .reachable(let count, let latency):
                let ms = Int(latency * 1000)
                return "\(count) model\(count == 1 ? "" : "s") · \(ms) ms"
            case .unreachable(let reason): return reason
            }
        }
    }

    /// Lists models as the probe: it proves the URL, the credential, and the
    /// route all work, which a bare TCP connect does not.
    public static func check(backend: Backend, apiKey: String?) async -> Health {
        let start = Date()
        do {
            let models = try await ModelCatalog.discover(backend: backend, apiKey: apiKey)
            let latency = Date().timeIntervalSince(start)
            if models.isEmpty {
                return .unreachable("Reachable, but it listed no models")
            }
            return .reachable(modelCount: models.count, latency: latency)
        } catch {
            return .unreachable(friendlyMessage(for: error))
        }
    }

    static func friendlyMessage(for error: Error) -> String {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return nsError.localizedDescription }
        switch nsError.code {
        case NSURLErrorCannotConnectToHost:
            return "Nothing is listening on that port"
        case NSURLErrorCannotFindHost:
            return "Host not found"
        case NSURLErrorTimedOut:
            return "Timed out"
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted:
            return "TLS failed — check the certificate"
        default:
            return nsError.localizedDescription
        }
    }
}
