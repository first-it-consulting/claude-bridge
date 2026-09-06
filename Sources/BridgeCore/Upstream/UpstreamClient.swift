import Foundation

/// Talks to the configured backend.
public enum UpstreamClient {

    public struct UpstreamError: LocalizedError {
        public var status: Int?
        public var message: String
        public var errorDescription: String? { message }

        public init(status: Int?, message: String) {
            self.status = status
            self.message = message
        }
    }

    /// Applies the backend credential and any operator-supplied headers.
    public static func applyAuth(to request: inout URLRequest, backend: Backend, apiKey: String?) {
        switch backend.authScheme {
        case .bearer:
            if let apiKey, !apiKey.isEmpty {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
        case .xApiKey:
            if let apiKey, !apiKey.isEmpty {
                request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            }
        case .none:
            break
        }
        for (name, value) in backend.extraHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        // Anthropic backends reject a request without a version header, and
        // Claude Desktop's own value is the one the upstream expects to see.
        if backend.kind == .anthropic, request.value(forHTTPHeaderField: "anthropic-version") == nil {
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
    }

    static func makeRequest(backend: Backend, path: String, body: Data, apiKey: String?) throws -> URLRequest {
        guard let url = backend.endpointURL(path: path) else {
            throw UpstreamError(status: nil, message: "Backend base URL is not a valid URL: \(backend.baseURL)")
        }
        var request = URLRequest(url: url, timeoutInterval: backend.requestTimeout)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &request, backend: backend, apiKey: apiKey)
        return request
    }

    // MARK: - Non-streamed

    public static func send(
        backend: Backend,
        path: String,
        body: Data,
        apiKey: String?
    ) async throws -> (status: Int, body: Data) {
        let request = try makeRequest(backend: backend, path: path, body: body, apiKey: apiKey)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 502
        return (status, data)
    }

    // MARK: - Streamed

    /// Opens a streamed upstream request and hands back its SSE events as they
    /// arrive.
    ///
    /// The stream is delivered as an `AsyncThrowingStream` rather than a
    /// callback so the caller can stop consuming — which cancels the upstream
    /// request — when Claude Desktop disconnects mid-generation.
    public static func stream(
        backend: Backend,
        path: String,
        body: Data,
        apiKey: String?
    ) async throws -> (status: Int, events: AsyncThrowingStream<SSEEvent, Error>) {
        let request = try makeRequest(backend: backend, path: path, body: body, apiKey: apiKey)
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 502

        guard (200..<300).contains(status) else {
            // An error response is a normal body, not a stream; drain it so the
            // caller can report what the backend actually said.
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > 64_000 { break }
            }
            throw UpstreamError(
                status: status,
                message: describeError(status: status, body: data)
            )
        }

        return (status, SSEParser.events(from: bytes))
    }

    /// Turns an upstream error body into something worth showing a user.
    /// Providers disagree on the shape, so the common ones are tried in turn
    /// before falling back to the raw text.
    public static func describeError(status: Int, body: Data) -> String {
        guard let json = try? JSONValue.decode(body) else {
            let text = String(data: body.prefix(500), encoding: .utf8) ?? ""
            return text.isEmpty ? "Upstream returned HTTP \(status)" : text
        }
        if let message = json["error"]?["message"]?.stringValue { return message }
        if let message = json["error"]?.stringValue { return message }
        if let message = json["message"]?.stringValue { return message }
        if let detail = json["detail"]?.stringValue { return detail }
        return "Upstream returned HTTP \(status)"
    }
}
