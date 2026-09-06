import AppKit
import Foundation

/// Reads and writes Claude Desktop's third-party inference configuration.
///
/// Claude Desktop on 3P keeps a small library of named configurations at
/// `~/Library/Application Support/Claude-3p/configLibrary/`: one `<uuid>.json`
/// per entry, plus a `_meta.json` naming them and recording which one is
/// applied. Pointing Claude Desktop at the bridge is a matter of writing one
/// entry and setting `appliedId` to it.
///
/// Two things this deliberately does not do: it never deletes or edits entries
/// it did not create, and it never touches the managed-preferences domain. When
/// an MDM profile is present it wins outright and anything written here is
/// ignored, so the caller is told rather than silently doing nothing.
public struct ClaudeDesktopConfig: Sendable {

    /// The name the bridge gives its own entry. Entries are matched by this
    /// name so a reinstall reuses the same slot instead of piling up.
    public static let entryName = "Claude Bridge"

    public enum ConfigError: LocalizedError {
        case noConfigDirectory
        case unreadableMeta(String)

        public var errorDescription: String? {
            switch self {
            case .noConfigDirectory:
                return "Claude Desktop's third-party config folder wasn't found. Enable Developer Mode in Claude Desktop (Help ▸ Troubleshooting) and open Developer ▸ Configure Third-Party Inference once, so the folder is created."
            case .unreadableMeta(let detail):
                return "Claude Desktop's config index could not be read: \(detail)"
            }
        }
    }

    /// What the bridge can tell the user about the current wiring.
    public struct Status: Sendable, Equatable {
        public var configDirectoryExists: Bool
        public var claudeDesktopInstalled: Bool
        public var bridgeEntryApplied: Bool
        /// Base URL recorded in the applied entry, whoever wrote it.
        public var appliedBaseURL: String?
        public var appliedEntryName: String?
        /// An MDM profile overrides everything written locally.
        public var managedProfilePresent: Bool
    }

    public var configDirectory: URL
    public var claudeAppURL: URL

    public init(
        configDirectory: URL = ClaudeDesktopConfig.defaultConfigDirectory,
        claudeAppURL: URL = URL(fileURLWithPath: "/Applications/Claude.app")
    ) {
        self.configDirectory = configDirectory
        self.claudeAppURL = claudeAppURL
    }

    public static var defaultConfigDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude-3p/configLibrary")
    }

    /// `/Library/Managed Preferences/<user>/com.anthropic.claudefordesktop.plist`
    /// — present only on MDM-managed machines.
    public static var managedProfileURL: URL {
        URL(fileURLWithPath: "/Library/Managed Preferences")
            .appendingPathComponent(NSUserName())
            .appendingPathComponent("com.anthropic.claudefordesktop.plist")
    }

    // MARK: - Reading

    private var metaURL: URL { configDirectory.appendingPathComponent("_meta.json") }
    private func entryURL(_ id: String) -> URL {
        configDirectory.appendingPathComponent("\(id).json")
    }

    public func status() -> Status {
        let fm = FileManager.default
        let meta = (try? readMeta()) ?? Meta()
        let applied = meta.appliedId.flatMap { id in
            meta.entries.first { $0.id == id }
        }
        let appliedConfig = meta.appliedId.flatMap { try? readEntry($0) }

        return Status(
            configDirectoryExists: fm.fileExists(atPath: configDirectory.path),
            claudeDesktopInstalled: fm.fileExists(atPath: claudeAppURL.path),
            bridgeEntryApplied: applied?.name == Self.entryName,
            appliedBaseURL: appliedConfig?["inferenceGatewayBaseUrl"]?.stringValue,
            appliedEntryName: applied?.name,
            managedProfilePresent: fm.fileExists(atPath: Self.managedProfileURL.path)
        )
    }

    // MARK: - Writing

    /// Writes the bridge's entry and makes it the applied one.
    ///
    /// - Returns: the id that was applied beforehand, so the caller can offer
    ///   to put it back.
    @discardableResult
    public func applyBridgeEntry(port: UInt16, apiKey: String) throws -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: configDirectory.path) else { throw ConfigError.noConfigDirectory }

        var meta = try readMeta()
        let previousAppliedId = meta.appliedId

        // Reuse our slot if it already exists, so switching back and forth does
        // not litter the library.
        let id = meta.entries.first { $0.name == Self.entryName }?.id ?? UUID().uuidString.lowercased()

        let config: JSONValue = .object([
            "inferenceProvider": "gateway",
            "inferenceGatewayBaseUrl": .string("http://127.0.0.1:\(port)"),
            "inferenceGatewayApiKey": .string(apiKey),
            "inferenceGatewayAuthScheme": "bearer",
            "inferenceCredentialKind": "static",
            // The bridge serves GET /v1/models and tags every entry with
            // `anthropic_family_tier`, which is what lets non-Claude model IDs
            // through Claude Desktop's discovery filter.
            "modelDiscoveryEnabled": true,
        ])
        try writeAtomically(try config.encoded(), to: entryURL(id))

        if !meta.entries.contains(where: { $0.id == id }) {
            meta.entries.append(Meta.Entry(id: id, name: Self.entryName))
        }
        meta.appliedId = id
        try writeMeta(meta)

        return previousAppliedId == id ? nil : previousAppliedId
    }

    /// Points Claude Desktop back at a previously applied entry. Entries the
    /// bridge did not create are left exactly as they were.
    public func restoreAppliedEntry(id: String?) throws {
        var meta = try readMeta()
        guard let id, meta.entries.contains(where: { $0.id == id }) else {
            // The entry is gone; leaving `appliedId` untouched is safer than
            // guessing at a replacement.
            return
        }
        meta.appliedId = id
        try writeMeta(meta)
    }

    // MARK: - Relaunching

    /// Quits Claude Desktop and starts it again.
    ///
    /// Needed after any config change: Claude Desktop reads the inference
    /// configuration and discovers the model list once, at launch. This closes
    /// the user's app, so callers must confirm before invoking it.
    public func restartClaudeDesktop() async throws {
        // `osascript quit` gives the app a chance to save state, unlike a
        // signal.
        let quit = Process()
        quit.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        quit.arguments = ["-e", "tell application \"Claude\" to quit"]
        try? quit.run()
        quit.waitUntilExit()

        // Wait for the process to actually go away before relaunching, or the
        // new instance attaches to the dying one.
        for _ in 0..<40 where isClaudeRunning() {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: claudeAppURL, configuration: config)
    }

    public func isClaudeRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.anthropic.claudefordesktop"
        }
    }

    // MARK: - _meta.json

    struct Meta: Codable {
        struct Entry: Codable, Equatable {
            var id: String
            var name: String
        }
        var appliedId: String?
        var entries: [Entry] = []
    }

    func readMeta() throws -> Meta {
        guard let data = try? Data(contentsOf: metaURL) else { return Meta() }
        do {
            return try JSONDecoder().decode(Meta.self, from: data)
        } catch {
            throw ConfigError.unreadableMeta(error.localizedDescription)
        }
    }

    func readEntry(_ id: String) throws -> JSONValue {
        try JSONValue.decode(try Data(contentsOf: entryURL(id)))
    }

    private func writeMeta(_ meta: Meta) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try writeAtomically(try enc.encode(meta), to: metaURL)
    }

    /// Writes via a temporary file and a rename. Claude Desktop may read these
    /// files at launch while the bridge is writing them, and a half-written
    /// `_meta.json` would leave the app with no usable configuration.
    private func writeAtomically(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }
}
