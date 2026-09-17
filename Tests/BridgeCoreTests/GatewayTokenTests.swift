import Testing
import Foundation
@testable import BridgeCore

/// Collects what the router writes, so auth can be tested without a socket.
actor CollectingSink: ResponseSink {
    private(set) var status: Int?
    private(set) var body = ""

    func begin(status: Int, headers: [(String, String)]) async { self.status = status }
    func write(_ text: String) async { body += text }
    func finish() async {}
}

@Suite("Gateway token")
struct GatewayTokenTests {

    static func router(token: String) -> BridgeRouter {
        let profile = Profile(
            name: "Test",
            backend: Backend(kind: .openai, baseURL: "http://127.0.0.1:1", authScheme: .none),
            models: [ModelMapping(upstreamID: "test-model", tier: .sonnet, isFamilyDefault: true)]
        )
        return BridgeRouter(profile: profile, apiKey: nil, token: token, log: RequestLog())
    }

    static func get(_ path: String, token: String, presenting: String?) async -> CollectingSink {
        let sink = CollectingSink()
        var headers: [String: String] = [:]
        if let presenting { headers["Authorization"] = "Bearer \(presenting)" }
        await router(token: token).handle(
            BridgeRequest(method: "GET", path: path, headers: headers, body: Data()),
            sink: sink
        )
        return sink
    }

    /// An empty token used to wave every request through. On a loopback port
    /// any process on the machine can reach, that turned a hand-edited or
    /// truncated `settings.json` into an open relay to the user's paid
    /// provider, with nothing said about it. Refusing is the only safe reading
    /// of "no token configured".
    @Test("an empty token rejects rather than disabling authentication")
    func emptyTokenRejects() async throws {
        let sink = await Self.get("/v1/models", token: "", presenting: nil)
        #expect(await sink.status == 401)
    }

    /// Presenting the empty string must not satisfy an empty token either —
    /// a constant-time comparison of "" against "" is perfectly equal.
    @Test("an empty token is not satisfied by presenting nothing")
    func emptyTokenNotSatisfiedByEmptyCredential() async throws {
        let sink = await Self.get("/v1/models", token: "", presenting: "")
        #expect(await sink.status == 401)
    }

    /// `/health` is how the app and the docs check the bridge is up, and it
    /// discloses nothing, so it stays open even with no usable token.
    @Test("health still answers when no token is configured")
    func healthStaysOpen() async throws {
        let sink = await Self.get("/health", token: "", presenting: nil)
        #expect(await sink.status == 200)
    }

    @Test("a settings file with an empty token is repaired on load")
    func loadRepairsEmptyToken() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-\(UUID().uuidString)")
            .appendingPathComponent("settings.json")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let json = """
        {
          "profiles": [],
          "port": 8788,
          "gatewayToken": "",
          "startServerAtLaunch": true,
          "logCapacity": 300
        }
        """
        try Data(json.utf8).write(to: url)

        let loaded = ProfileStore(fileURL: url).load()

        #expect(!loaded.gatewayToken.isEmpty)
        #expect(loaded.gatewayToken.hasPrefix("cb-"))
        // The rest of the file is kept; this is a repair, not a reset.
        #expect(loaded.port == 8788)
    }
}
