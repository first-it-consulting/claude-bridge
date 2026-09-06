import Foundation

/// A request as it reaches the bridge, independent of the HTTP transport.
public struct BridgeRequest: Sendable {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, headers: [String: String], body: Data) {
        self.method = method
        self.path = path
        // Header names are case-insensitive on the wire; normalise once so
        // lookups do not have to care.
        self.headers = Dictionary(
            headers.map { ($0.key.lowercased(), $0.value) },
            uniquingKeysWith: { _, last in last }
        )
        self.body = body
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }
}

/// Where a response is written. Implemented by the NIO channel in production
/// and by a collector in tests.
public protocol ResponseSink: Sendable {
    func begin(status: Int, headers: [(String, String)]) async
    func write(_ text: String) async
    func finish() async
}

/// Routes and proxies requests. This is the whole of the bridge's behaviour;
/// everything else is configuration and chrome.
public actor BridgeRouter {

    private var profile: Profile
    private var apiKey: String?
    private var token: String
    private let log: RequestLog

    public init(profile: Profile, apiKey: String?, token: String, log: RequestLog) {
        self.profile = profile
        self.apiKey = apiKey
        self.token = token
        self.log = log
    }

    /// Swaps the active profile without dropping in-flight requests, which
    /// keep the profile they started with.
    public func update(profile: Profile, apiKey: String?, token: String) {
        self.profile = profile
        self.apiKey = apiKey
        self.token = token
    }

    public func handle(_ request: BridgeRequest, sink: ResponseSink) async {
        switch (request.method, request.path.split(separator: "?").first.map(String.init) ?? request.path) {
        case ("GET", "/health"), ("GET", "/"):
            await respondJSON(sink, status: 200, json: healthJSON())

        case ("GET", "/v1/models"):
            guard await requireAuth(request, sink: sink, path: "/v1/models") else { return }
            await respondJSON(sink, status: 200, json: ModelCatalog.modelsResponse(for: profile))

        case ("POST", "/v1/messages"):
            guard await requireAuth(request, sink: sink, path: "/v1/messages") else { return }
            await handleMessages(request, sink: sink)

        case ("POST", "/v1/messages/count_tokens"):
            guard await requireAuth(request, sink: sink, path: "/v1/messages/count_tokens") else { return }
            let estimate = Self.estimateInputTokens(body: (try? JSONValue.decode(request.body)) ?? .object([:]))
            await respondJSON(sink, status: 200, json: .object(["input_tokens": .number(Double(estimate))]))

        default:
            await respondError(sink, status: 404, type: "not_found_error",
                               message: "Claude Bridge does not serve \(request.method) \(request.path)")
        }
    }

    // MARK: - /v1/messages

    private func handleMessages(_ request: BridgeRequest, sink: ResponseSink) async {
        let started = Date()

        guard let body = try? JSONValue.decode(request.body) else {
            await respondError(sink, status: 400, type: "invalid_request_error",
                               message: "Request body is not valid JSON")
            return
        }

        let requestedModel = body["model"]?.stringValue ?? ""
        guard let mapping = resolveModel(requested: requestedModel) else {
            await respondError(
                sink, status: 400, type: "invalid_request_error",
                message: "No models are enabled in the “\(profile.name)” profile. Add one in Claude Bridge ▸ Settings."
            )
            return
        }

        let wantsStream = body["stream"]?.boolValue ?? false
        let captureBodies = await log.captureBodies

        let entry = LogEntry(
            method: "POST",
            path: "/v1/messages",
            profileName: profile.name,
            upstreamModel: mapping.upstreamID,
            upstreamURL: profile.backend.normalizedBase,
            streamed: wantsStream,
            outcome: .ok(status: 0),
            requestBody: captureBodies ? body.prettyString : nil
        )
        await log.append(entry)

        do {
            if wantsStream {
                try await proxyStreaming(body: body, mapping: mapping, sink: sink, logID: entry.id, started: started)
            } else {
                try await proxyBuffered(body: body, mapping: mapping, sink: sink, logID: entry.id, started: started)
            }
        } catch {
            let upstream = error as? UpstreamClient.UpstreamError
            let message = upstream?.message ?? error.localizedDescription
            await log.update(id: entry.id) { entry in
                entry.duration = Date().timeIntervalSince(started)
                entry.outcome = .failed(status: upstream?.status, message: message)
            }
            // If headers already went out this writes into a closed sink, which
            // is harmless; `proxyStreaming` reports mid-stream failures itself.
            await respondError(sink, status: upstream?.status ?? 502,
                               type: "api_error", message: message)
        }
    }

    private func proxyBuffered(
        body: JSONValue, mapping: ModelMapping, sink: ResponseSink,
        logID: UUID, started: Date
    ) async throws {
        let backend = profile.backend
        let (path, payload) = try translateRequest(body: body, mapping: mapping, stream: false)
        let (status, data) = try await UpstreamClient.send(
            backend: backend, path: path, body: payload, apiKey: apiKey
        )

        guard (200..<300).contains(status) else {
            throw UpstreamClient.UpstreamError(
                status: status,
                message: UpstreamClient.describeError(status: status, body: data)
            )
        }

        let upstreamJSON = try JSONValue.decode(data)
        let anthropic: JSONValue
        switch backend.kind {
        case .anthropic:
            anthropic = upstreamJSON
        case .openai:
            anthropic = OpenAIResponseTranslator.translate(
                openai: upstreamJSON,
                requestModel: mapping.upstreamID,
                reasoning: backend.reasoningMode
            )
        }

        let captureBodies = await log.captureBodies
        await log.update(id: logID) { entry in
            entry.duration = Date().timeIntervalSince(started)
            entry.outcome = .ok(status: status)
            entry.inputTokens = anthropic["usage"]?["input_tokens"]?.intValue
            entry.outputTokens = anthropic["usage"]?["output_tokens"]?.intValue
            if captureBodies { entry.responseBody = anthropic.prettyString }
        }
        await respondJSON(sink, status: 200, json: anthropic)
    }

    private func proxyStreaming(
        body: JSONValue, mapping: ModelMapping, sink: ResponseSink,
        logID: UUID, started: Date
    ) async throws {
        let backend = profile.backend
        let (path, payload) = try translateRequest(body: body, mapping: mapping, stream: true)
        let (status, events) = try await UpstreamClient.stream(
            backend: backend, path: path, body: payload, apiKey: apiKey
        )

        await sink.begin(status: 200, headers: [
            ("Content-Type", "text/event-stream; charset=utf-8"),
            ("Cache-Control", "no-cache"),
            // Claude Desktop reads this stream through whatever proxy the OS
            // has configured; buffering would defeat token-by-token rendering.
            ("X-Accel-Buffering", "no"),
        ])

        var inputTokens: Int?
        var outputTokens: Int?
        var transcript = ""
        let captureBodies = await log.captureBodies

        switch backend.kind {
        case .anthropic:
            // Already the right protocol: forward events verbatim so anything
            // the bridge does not model (new event types, betas) still works.
            for try await event in events {
                await sink.write(event.wireFormat)
                if captureBodies { transcript += event.wireFormat }
                if let json = JSONValue.lenient(event.data) {
                    inputTokens = json["message"]?["usage"]?["input_tokens"]?.intValue ?? inputTokens
                    outputTokens = json["usage"]?["output_tokens"]?.intValue ?? outputTokens
                }
            }
        case .openai:
            let estimate = Self.estimateInputTokens(body: body)
            var translator = OpenAIStreamTranslator(
                requestModel: mapping.upstreamID,
                reasoning: backend.reasoningMode,
                estimatedInputTokens: estimate
            )
            inputTokens = estimate
            do {
                for try await event in events {
                    for out in translator.ingest(event) {
                        await sink.write(out.wireFormat)
                        if captureBodies { transcript += out.wireFormat }
                    }
                }
                for out in translator.finish() {
                    await sink.write(out.wireFormat)
                    if captureBodies { transcript += out.wireFormat }
                    if let json = JSONValue.lenient(out.data), out.name == "message_delta" {
                        inputTokens = json["usage"]?["input_tokens"]?.intValue ?? inputTokens
                        outputTokens = json["usage"]?["output_tokens"]?.intValue ?? outputTokens
                    }
                }
            } catch {
                // The status line is long gone, so the only way to tell Claude
                // Desktop the generation failed is an in-stream error event.
                for out in translator.fail(type: "api_error", message: error.localizedDescription) {
                    await sink.write(out.wireFormat)
                }
                await sink.finish()
                throw error
            }
        }

        await sink.finish()

        // Snapshot before handing these to the log actor: the closure runs on
        // another isolation domain and cannot capture the mutable locals.
        let finalInput = inputTokens
        let finalOutput = outputTokens
        let finalTranscript = captureBodies ? transcript : nil
        let elapsed = Date().timeIntervalSince(started)
        await log.update(id: logID) { entry in
            entry.duration = elapsed
            entry.outcome = .ok(status: status)
            entry.inputTokens = finalInput
            entry.outputTokens = finalOutput
            entry.responseBody = finalTranscript
        }
    }

    /// Produces the upstream path and body for one request.
    private func translateRequest(
        body: JSONValue, mapping: ModelMapping, stream: Bool
    ) throws -> (path: String, body: Data) {
        switch profile.backend.kind {
        case .anthropic:
            // Passthrough. Only the model name is rewritten, so `cache_control`
            // breakpoints, betas, and thinking blocks reach the upstream intact
            // — which is what keeps prompt caching working.
            var out = body
            out["model"] = .string(mapping.upstreamID)
            if let cap = mapping.maxOutputTokens, let requested = body["max_tokens"]?.intValue {
                out["max_tokens"] = .number(Double(min(cap, requested)))
            }
            if !mapping.supportsTools {
                out["tools"] = nil
                out["tool_choice"] = nil
            }
            return ("/v1/messages", try out.encoded())

        case .openai:
            let translated = OpenAIRequestTranslator.translate(
                anthropic: body,
                options: .init(
                    model: mapping.upstreamID,
                    maxOutputTokens: mapping.maxOutputTokens,
                    supportsTools: mapping.supportsTools,
                    stream: stream
                )
            )
            return ("/chat/completions", try translated.encoded())
        }
    }

    // MARK: - Model resolution

    /// Maps the model Claude Desktop asked for onto one this profile serves.
    ///
    /// Claude Desktop remembers the model the user picked across launches, so
    /// after a profile switch it will ask for a model the new backend has never
    /// heard of. Falling back keeps that from being a dead end: an exact match
    /// wins, then anything in the same tier, then the profile's default.
    func resolveModel(requested: String) -> ModelMapping? {
        let served = profile.servedModels
        guard !served.isEmpty else { return nil }

        // Exact match on what was advertised. This is also what turns an alias
        // like "qwen3:8b#haiku" back into the real model name.
        if let entry = served.first(where: { $0.advertisedID == requested }) {
            return entry.mapping
        }
        if let entry = served.first(where: { $0.mapping.upstreamID == requested }) {
            return entry.mapping
        }

        let lower = requested.lowercased()
        if let tier = FamilyTier.allCases.first(where: { lower.contains($0.rawValue) }) {
            let inTier = served.filter { $0.mapping.tier == tier }
            if let preferred = inTier.first(where: { $0.mapping.isFamilyDefault }) ?? inTier.first {
                return preferred.mapping
            }
        }
        return profile.defaultModel
    }

    // MARK: - Auth

    private func requireAuth(_ request: BridgeRequest, sink: ResponseSink, path: String) async -> Bool {
        guard !token.isEmpty else { return true }

        let presented: String?
        if let bearer = request.header("authorization"), bearer.lowercased().hasPrefix("bearer ") {
            presented = String(bearer.dropFirst(7))
        } else {
            presented = request.header("x-api-key")
        }

        guard let presented, constantTimeEquals(presented, token) else {
            await log.append(LogEntry(
                method: request.method, path: path, profileName: profile.name,
                outcome: .failed(status: 401, message: "Rejected: wrong or missing gateway token")
            ))
            await respondError(sink, status: 401, type: "authentication_error",
                               message: "Invalid gateway token")
            return false
        }
        return true
    }

    /// Compares without leaking the answer through timing. Overkill for a
    /// loopback service, cheap enough to do anyway.
    private func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in x.indices { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    // MARK: - Responses

    private func healthJSON() -> JSONValue {
        .object([
            "status": "ok",
            "service": "claude-bridge",
            "profile": .string(profile.name),
            "backend": .string(profile.backend.normalizedBase),
            "backend_kind": .string(profile.backend.kind.rawValue),
            "models": .number(Double(profile.enabledModels.count)),
        ])
    }

    private func respondJSON(_ sink: ResponseSink, status: Int, json: JSONValue) async {
        let text = json.compactString
        await sink.begin(status: status, headers: [
            ("Content-Type", "application/json"),
            ("Content-Length", "\(text.utf8.count)"),
        ])
        await sink.write(text)
        await sink.finish()
    }

    private func respondError(_ sink: ResponseSink, status: Int, type: String, message: String) async {
        await respondJSON(sink, status: status, json: .object([
            "type": "error",
            "error": .object(["type": .string(type), "message": .string(message)]),
        ]))
    }

    // MARK: - Token estimation

    /// A rough input-token count for backends that report none.
    ///
    /// Four characters per token is the usual English approximation. It is only
    /// used to give Claude Desktop's context meter something to draw before the
    /// backend reports real numbers, so being off by a few percent is fine.
    public static func estimateInputTokens(body: JSONValue) -> Int {
        var characters = 0
        if let system = body["system"] {
            characters += OpenAIRequestTranslator.flattenText(system).count
        }
        for message in body["messages"]?.arrayValue ?? [] {
            if let content = message["content"] {
                characters += OpenAIRequestTranslator.flattenText(content).count
            }
        }
        // Tool schemas are part of the prompt and are often the bulk of it.
        if let tools = body["tools"] {
            characters += tools.compactString.count
        }
        return max(1, characters / 4)
    }
}
