import Foundation

/// One proxied request, as shown in the log window.
public struct LogEntry: Identifiable, Sendable, Hashable {
    public enum Outcome: Sendable, Hashable {
        case ok(status: Int)
        case failed(status: Int?, message: String)

        public var isFailure: Bool { if case .failed = self { return true }; return false }
    }

    public let id = UUID()
    public var date: Date
    public var method: String
    public var path: String
    public var profileName: String
    public var upstreamModel: String?
    public var upstreamURL: String?
    public var streamed: Bool
    public var duration: TimeInterval?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var outcome: Outcome
    /// Request and response bodies, kept only when body capture is on.
    public var requestBody: String?
    public var responseBody: String?

    public init(
        date: Date = Date(),
        method: String,
        path: String,
        profileName: String,
        upstreamModel: String? = nil,
        upstreamURL: String? = nil,
        streamed: Bool = false,
        duration: TimeInterval? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        outcome: Outcome,
        requestBody: String? = nil,
        responseBody: String? = nil
    ) {
        self.date = date
        self.method = method
        self.path = path
        self.profileName = profileName
        self.upstreamModel = upstreamModel
        self.upstreamURL = upstreamURL
        self.streamed = streamed
        self.duration = duration
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.outcome = outcome
        self.requestBody = requestBody
        self.responseBody = responseBody
    }

    public var statusText: String {
        switch outcome {
        case .ok(let status): return "\(status)"
        case .failed(let status, _): return status.map(String.init) ?? "—"
        }
    }
}

/// A bounded, thread-safe ring of recent requests.
///
/// The server writes to this from NIO threads and the log window reads it on
/// the main actor, so it is an actor rather than a plain array.
public actor RequestLog {
    private var entries: [LogEntry] = []
    private var capacity: Int
    /// Bodies are useful when debugging a backend that rejects a request and
    /// a liability the rest of the time, so they are off unless asked for.
    public private(set) var captureBodies = false

    private var observers: [UUID: @Sendable ([LogEntry]) -> Void] = [:]

    public init(capacity: Int = 300) {
        self.capacity = capacity
    }

    public func setCapacity(_ value: Int) {
        capacity = max(10, value)
        trim()
    }

    public func setCaptureBodies(_ value: Bool) {
        captureBodies = value
    }

    public func append(_ entry: LogEntry) {
        entries.append(entry)
        trim()
        notify()
    }

    /// Replaces an in-flight entry once the response completes. Streamed
    /// requests are logged when they start so a hung request is visible while
    /// it hangs, then updated with the outcome.
    public func update(id: UUID, _ transform: @Sendable (inout LogEntry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        transform(&entries[index])
        notify()
    }

    public func all() -> [LogEntry] { entries.reversed() }

    public func clear() {
        entries.removeAll()
        notify()
    }

    /// Calls `handler` on every change until the returned token is cancelled.
    public func observe(_ handler: @escaping @Sendable ([LogEntry]) -> Void) -> UUID {
        let token = UUID()
        observers[token] = handler
        handler(entries.reversed())
        return token
    }

    public func cancelObservation(_ token: UUID) {
        observers[token] = nil
    }

    private func trim() {
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    private func notify() {
        let snapshot = entries.reversed().map { $0 }
        for handler in observers.values { handler(snapshot) }
    }
}
