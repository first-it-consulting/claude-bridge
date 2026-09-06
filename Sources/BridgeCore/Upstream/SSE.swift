import Foundation

/// One server-sent event.
public struct SSEEvent: Sendable, Equatable {
    public var name: String?
    public var data: String

    public init(name: String?, data: String) {
        self.name = name
        self.data = data
    }

    public init(name: String, json: JSONValue) {
        self.name = name
        self.data = json.compactString
    }

    /// Wire form, including the blank line that terminates the event.
    public var wireFormat: String {
        var s = ""
        if let name { s += "event: \(name)\n" }
        s += "data: \(data)\n\n"
        return s
    }
}

/// Incremental SSE parser.
///
/// Upstream bytes arrive in arbitrary chunks that rarely align with event
/// boundaries, so partial lines are held until the rest shows up.
public struct SSEParser: Sendable {
    private var buffer = ""

    public init() {}

    /// Feeds raw bytes in and returns whatever complete events they finished.
    public mutating func consume(_ text: String) -> [SSEEvent] {
        buffer += text
        var events: [SSEEvent] = []

        // Events are separated by a blank line; tolerate CRLF from proxies.
        buffer = buffer.replacingOccurrences(of: "\r\n", with: "\n")
        while let range = buffer.range(of: "\n\n") {
            let raw = String(buffer[buffer.startIndex..<range.lowerBound])
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            if let event = parse(block: raw) { events.append(event) }
        }
        return events
    }

    /// Emits a trailing event that arrived without its terminating blank line,
    /// which happens when a backend closes the connection abruptly.
    public mutating func flush() -> [SSEEvent] {
        let raw = buffer
        buffer = ""
        guard let event = parse(block: raw) else { return [] }
        return [event]
    }

    private func parse(block: String) -> SSEEvent? {
        var name: String?
        var dataLines: [String] = []

        for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
            // A leading colon marks a comment; some gateways use them as
            // keep-alives.
            if line.hasPrefix(":") { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let field = String(line[line.startIndex..<colon])
            var value = String(line[line.index(after: colon)...])
            if value.hasPrefix(" ") { value.removeFirst() }

            switch field {
            case "event": name = value
            case "data": dataLines.append(value)
            default: continue
            }
        }

        guard !dataLines.isEmpty else { return nil }
        return SSEEvent(name: name, data: dataLines.joined(separator: "\n"))
    }
}

public extension SSEParser {
    /// Reads an SSE response body byte by byte and yields complete events.
    ///
    /// Byte level on purpose. `AsyncLineSequence` drops empty lines, and the
    /// empty line is precisely what separates one SSE event from the next — so
    /// consuming a stream through `.lines` silently merges the whole response
    /// into a single event.
    static func events<Bytes: AsyncSequence & Sendable>(
        from bytes: Bytes
    ) -> AsyncThrowingStream<SSEEvent, Error> where Bytes.Element == UInt8 {
        AsyncThrowingStream { continuation in
            let task = Task {
                var parser = SSEParser()
                var pending = Data()
                do {
                    for try await byte in bytes {
                        pending.append(byte)
                        guard byte == 0x0A else { continue }
                        // A newline byte never appears inside a multi-byte
                        // UTF-8 sequence, so the buffer always decodes cleanly
                        // at this point.
                        guard let text = String(data: pending, encoding: .utf8) else { continue }
                        pending.removeAll(keepingCapacity: true)
                        for event in parser.consume(text) { continuation.yield(event) }
                    }
                    if let tail = String(data: pending, encoding: .utf8), !tail.isEmpty {
                        for event in parser.consume(tail) { continuation.yield(event) }
                    }
                    for event in parser.flush() { continuation.yield(event) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
