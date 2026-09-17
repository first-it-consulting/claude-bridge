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
    public var startServerAtLaunch: Bool
    /// Number of requests kept in the log window.
    public var logCapacity: Int
    /// Whether switching where Claude Desktop points asks before restarting it.
    /// Optional so older `settings.json` files still decode; nil means ask.
    public var confirmClaudeRestart: Bool?

    public init(
        profiles: [Profile] = [],
        activeProfileID: UUID? = nil,
        port: UInt16 = 8788,
        gatewayToken: String = BridgeSettings.generateToken(),
        startServerAtLaunch: Bool = true,
        logCapacity: Int = 300,
        confirmClaudeRestart: Bool? = nil
    ) {
        self.profiles = profiles
        self.activeProfileID = activeProfileID
        self.port = port
        self.gatewayToken = gatewayToken
        self.startServerAtLaunch = startServerAtLaunch
        self.logCapacity = logCapacity
        self.confirmClaudeRestart = confirmClaudeRestart
    }

    /// A switch restarts Claude Desktop; this says whether to ask first.
    public var shouldConfirmClaudeRestart: Bool { confirmClaudeRestart ?? true }

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
        // The token is the bridge's only access control, so an empty one is a
        // broken settings file rather than a way to turn authentication off.
        // Repairing it here covers the app and the daemon alike; the server
        // rejects every request while it is empty, so the repair is what keeps
        // a truncated file from stopping the bridge working.
        guard settings.gatewayToken.isEmpty else { return settings }
        var repaired = settings
        repaired.gatewayToken = BridgeSettings.generateToken()
        return repaired
    }

    public func save(_ settings: BridgeSettings) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(settings).write(to: fileURL, options: .atomic)
        try FilePermissions.restrictToOwner(fileURL)
    }
}

/// Keeps the files holding the gateway token readable by their owner alone.
///
/// `~/Library` is `0700` on a stock macOS, so this is not what stands between
/// the token and another local user — it is there for the machine whose owner
/// has loosened those directories, and so the guarantee does not depend on a
/// permission this code never set.
enum FilePermissions {

    /// Sets `0600`, after the write rather than before.
    ///
    /// `Data.write(options: .atomic)` replaces the file through a rename and
    /// carries the old file's mode across, so a mode applied at creation is not
    /// enough on its own — a file that predates this code would keep `0644`
    /// through every later save.
    static func restrictToOwner(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path
        )
    }
}
