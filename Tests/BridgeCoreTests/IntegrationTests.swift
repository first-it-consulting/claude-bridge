import Testing
import Foundation
@testable import BridgeCore

/// End-to-end tests against a real local backend.
///
/// Skipped unless `CLAUDE_BRIDGE_LIVE_BACKEND` names one, so `swift test` stays
/// green on a machine with no models installed. Point it at any
/// OpenAI-compatible server, e.g.
///
///     CLAUDE_BRIDGE_LIVE_BACKEND=http://localhost:11434/v1 \
///     CLAUDE_BRIDGE_LIVE_MODEL=qwen3-coder-next:latest swift test
@Suite("Live backend", .enabled(if: ProcessInfo.processInfo.environment["CLAUDE_BRIDGE_LIVE_BACKEND"] != nil))
struct IntegrationTests {

    static var baseURL: String { ProcessInfo.processInfo.environment["CLAUDE_BRIDGE_LIVE_BACKEND"]! }
    static var model: String { ProcessInfo.processInfo.environment["CLAUDE_BRIDGE_LIVE_MODEL"] ?? "qwen3:8b" }
    static let token = "test-token"

    /// Boots the bridge on a free port and tears it down afterwards.
    ///
    /// Cases run in parallel, so the port is searched for rather than fixed,
    /// starting from a random offset to keep two cases from racing for the
    /// same one.
    func withBridge<T>(_ body: (URL) async throws -> T) async throws -> T {
        let profile = Profile(
            name: "Live",
            backend: Backend(kind: .openai, baseURL: Self.baseURL, authScheme: .none),
            models: [ModelMapping(upstreamID: Self.model, tier: .sonnet, isFamilyDefault: true)]
        )
        let router = BridgeRouter(profile: profile, apiKey: nil, token: Self.token, log: RequestLog())
        let server = BridgeServer(router: router)

        var chosen: UInt16 = 0
        for candidate in stride(from: Int.random(in: 49_000...49_500), to: 49_900, by: 1) {
            let port = UInt16(candidate)
            guard BridgeServer.isPortAvailable(port) else { continue }
            do {
                try await server.start(port: port)
                chosen = port
                break
            } catch {
                continue
            }
        }
        #expect(chosen != 0, "no free port for the test bridge")

        do {
            let result = try await body(URL(string: "http://127.0.0.1:\(chosen)")!)
            await server.shutdown()
            return result
        } catch {
            await server.shutdown()
            throw error
        }
    }

    func request(_ base: URL, _ path: String, method: String = "GET", body: JSONValue? = nil) throws -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: 180)
        request.httpMethod = method
        request.setValue("Bearer \(Self.token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try body.encoded()
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    @Test("health needs no credential")
    func health() async throws {
        try await withBridge { base in
            let (data, response) = try await URLSession.shared.data(from: base.appendingPathComponent("health"))
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            #expect(try JSONValue.decode(data)["status"]?.stringValue == "ok")
        }
    }

    @Test("a wrong token is rejected")
    func authRejected() async throws {
        try await withBridge { base in
            var req = URLRequest(url: base.appendingPathComponent("v1/models"))
            req.setValue("Bearer wrong", forHTTPHeaderField: "Authorization")
            let (_, response) = try await URLSession.shared.data(for: req)
            #expect((response as? HTTPURLResponse)?.statusCode == 401)
        }
    }

    @Test("models are tagged so Claude Desktop's discovery filter accepts them")
    func models() async throws {
        try await withBridge { base in
            let (data, _) = try await URLSession.shared.data(for: try request(base, "v1/models"))
            let json = try JSONValue.decode(data)
            let first = json["data"]![0]!
            #expect(first["id"]?.stringValue == Self.model)
            #expect(first["anthropic_family_tier"]?.stringValue == "sonnet")
            #expect(first["is_family_default"]?.boolValue == true)
        }
    }

    @Test("a non-streamed message round-trips through a real model", .timeLimit(.minutes(3)))
    func messageRoundTrip() async throws {
        try await withBridge { base in
            let body: JSONValue = [
                "model": .string(Self.model),
                "max_tokens": 64,
                "messages": [["role": "user", "content": "Reply with exactly the word: pong"]],
            ]
            let (data, response) = try await URLSession.shared.data(
                for: try request(base, "v1/messages", method: "POST", body: body)
            )
            #expect((response as? HTTPURLResponse)?.statusCode == 200)

            let json = try JSONValue.decode(data)
            #expect(json["type"]?.stringValue == "message")
            #expect(json["role"]?.stringValue == "assistant")
            #expect(json["content"]?[0]?["type"]?.stringValue == "text")
            #expect(json["usage"]?["output_tokens"]?.intValue ?? 0 > 0)
        }
    }

    @Test("a streamed message produces a well-formed Anthropic event sequence", .timeLimit(.minutes(3)))
    func streamedMessage() async throws {
        try await withBridge { base in
            let body: JSONValue = [
                "model": .string(Self.model),
                "max_tokens": 64,
                "stream": true,
                "messages": [["role": "user", "content": "Count: one two three"]],
            ]
            let (bytes, response) = try await URLSession.shared.bytes(
                for: try request(base, "v1/messages", method: "POST", body: body)
            )
            #expect((response as? HTTPURLResponse)?.statusCode == 200)

            var names: [String] = []
            for try await event in SSEParser.events(from: bytes) {
                if let name = event.name { names.append(name) }
            }
            #expect(names.first == "message_start")
            #expect(names.last == "message_stop")
            #expect(names.contains("content_block_delta"))
            // Every opened block must be closed, or Claude Desktop's parser
            // stalls waiting for the rest.
            #expect(names.filter { $0 == "content_block_start" }.count
                    == names.filter { $0 == "content_block_stop" }.count)
        }
    }
}
