import Foundation
import Security

/// Everything the bridge persists, in one file.
public struct BridgeSettings: Codable, Sendable {
    public var profiles: [Profile]
    public var activeProfileID: UUID?
    /// Loopback port the bridge listens on.
    public var port: UInt16
    /// Shared secret Claude Desktop must present. The bridge is bound to
    /// loopback, but any process on the machine can reach loopback, so a token
    /// still keeps other local software from using it as an open relay.
    public var gatewayToken: String
    /// Entry Claude Desktop had applied before the bridge took over, so
    /// disconnecting can put it back.
    public var previousClaudeEntryID: String?
    public var startServerAtLaunch: Bool
    /// Number of requests kept in the log window.
    public var logCapacity: Int

    public init(
        profiles: [Profile] = [],
        activeProfileID: UUID? = nil,
        port: UInt16 = 8788,
        gatewayToken: String = BridgeSettings.generateToken(),
        previousClaudeEntryID: String? = nil,
        startServerAtLaunch: Bool = true,
        logCapacity: Int = 300
    ) {
        self.profiles = profiles
        self.activeProfileID = activeProfileID
        self.port = port
        self.gatewayToken = gatewayToken
        self.previousClaudeEntryID = previousClaudeEntryID
        self.startServerAtLaunch = startServerAtLaunch
        self.logCapacity = logCapacity
    }

    public static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return "cb-" + Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "")
            .replacingOccurrences(of: "/", with: "")
            .replacingOccurrences(of: "=", with: "")
    }

    public var activeProfile: Profile? {
        guard let activeProfileID else { return profiles.first }
        return profiles.first { $0.id == activeProfileID } ?? profiles.first
    }
}
/// Loads and saves `BridgeSettings`.
public struct ProfileStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL = ProfileStore.defaultURL) {
        self.fileURL = fileURL
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClaudeBridge/settings.json")
    }

    public func load() -> BridgeSettings {
        guard let data = try? Data(contentsOf: fileURL),
              let settings = try? JSONDecoder().decode(BridgeSettings.self, from: data)
        else {
            // First run, or a settings file from a future version we cannot
            // read. Either way the presets are a working starting point, and
            // the existing file is left alone until the user saves.
            return BridgeSettings(profiles: BackendPreset.starterProfiles())
        }
        return settings
    }

    public func save(_ settings: BridgeSettings) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(settings).write(to: fileURL, options: .atomic)
    }
}
