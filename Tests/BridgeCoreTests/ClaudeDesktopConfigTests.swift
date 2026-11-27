import Testing
import Foundation
@testable import BridgeCore

@Suite("Claude Desktop configuration library")
struct ClaudeDesktopConfigTests {

    /// A throwaway config library. Each test gets its own directory so they can
    /// run in parallel without fighting over `_meta.json`.
    ///
    /// The library sits inside a fake `Claude-3p` directory, because Claude
    /// Desktop's own settings file — the one holding the deployment-mode pin —
    /// lives next to the library, and tests that trigger writes to it must not
    /// park files in the shared temp directory.
    func makeConfig(
        entries: [(id: String, name: String)],
        applied: String?,
        bodies: [String: String] = [:],
        settingsBody: String? = nil
    ) throws -> ClaudeDesktopConfig {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cb-tests-\(UUID().uuidString)")
        let dir = base.appendingPathComponent("configLibrary")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        if let settingsBody {
            try Data(settingsBody.utf8)
                .write(to: base.appendingPathComponent("claude_desktop_config.json"))
        }

        for entry in entries {
            let body = bodies[entry.id]
                ?? #"{"inferenceGatewayBaseUrl":"http://example.invalid/\#(entry.name)"}"#
            try Data(body.utf8).write(to: dir.appendingPathComponent("\(entry.id).json"))
        }

        var meta = ClaudeDesktopConfig.Meta()
        meta.appliedId = applied
        meta.entries = entries.map { .init(id: $0.id, name: $0.name) }
        let enc = JSONEncoder()
        try enc.encode(meta).write(to: dir.appendingPathComponent("_meta.json"))

        return ClaudeDesktopConfig(configDirectory: dir)
    }

    @Test("the bridge's own entry is not offered as somewhere to restore to")
    func excludesOwnEntry() throws {
        let config = try makeConfig(
            entries: [("default-id", "Default"), ("bridge-id", "Claude Bridge")],
            applied: "bridge-id"
        )
        #expect(config.status().restorableEntries.map(\.name) == ["Default"])
    }




    @Test("switching to a named entry rewrites only appliedId")
    func applyEntryLeavesEntriesUntouched() throws {
        let config = try makeConfig(
            entries: [("default-id", "Default"), ("bridge-id", "Claude Bridge")],
            applied: "bridge-id"
        )
        let before = try config.readEntry("default-id")

        try config.applyEntry(id: "default-id")

        #expect(try config.readMeta().appliedId == "default-id")
        #expect(try config.readEntry("default-id") == before)
        #expect(try config.readMeta().entries.count == 2)
    }

    @Test("switching to an entry that is not there is an error")
    func applyUnknownEntryThrows() throws {
        let config = try makeConfig(entries: [("bridge-id", "Claude Bridge")], applied: "bridge-id")

        #expect(throws: ClaudeDesktopConfig.ConfigError.self) {
            try config.applyEntry(id: "nope")
        }
    }

    @Test("switching to Anthropic's models leaves every entry in place")
    func anthropicModelsKeepsLibrary() throws {
        let config = try makeConfig(
            entries: [("default-id", "Default"), ("bridge-id", "Claude Bridge")],
            applied: "bridge-id"
        )
        let before = try config.readEntry("bridge-id")

        try config.applyAnthropicModels()

        let status = config.status()
        #expect(status.usingAnthropicModels)
        #expect(status.bridgeEntryApplied == false)
        // Nothing is deleted, so going back is one click.
        #expect(try config.readMeta().entries.count == 2)
        #expect(try config.readEntry("bridge-id") == before)
    }

    @Test("switching back to the bridge from Anthropic's models works")
    func returnsFromAnthropicModels() throws {
        let config = try makeConfig(entries: [("default-id", "Default")], applied: "default-id")
        try config.applyAnthropicModels()

        try config.applyBridgeEntry(port: 8788, apiKey: "cb-test")

        let status = config.status()
        #expect(status.bridgeEntryApplied)
        #expect(status.usingAnthropicModels == false)
    }

    /// Claude Desktop reads a configuration only when `appliedId` matches
    /// `/^[a-f0-9-]{36}$/`, so what counts as "no configuration" is its rule,
    /// not ours. Getting this wrong would silently strand the user on a
    /// third-party backend while the UI claimed otherwise.
    @Test(
        "an appliedId Claude Desktop would reject means Anthropic's models",
        arguments: [
            ("", true),
            ("2c1bd751-2f8e-41a9-ab70-c5dc437c0593", false),
            ("2C1BD751-2F8E-41A9-AB70-C5DC437C0593", true),   // uppercase is rejected
            ("2c1bd751-2f8e-41a9-ab70-c5dc437c059", true),    // 35 characters
            ("2c1bd751-2f8e-41a9-ab70-c5dc437c05933", true),  // 37 characters
            ("2c1bd751/2f8e/41a9/ab70/c5dc437c0593", true),   // right length, wrong alphabet
        ]
    )
    func appliedIDRule(id: String, meansAnthropic: Bool) throws {
        let config = try makeConfig(entries: [("bridge-id", "Claude Bridge")], applied: id)
        #expect(config.status().usingAnthropicModels == meansAnthropic)
    }

    /// "Default" is Claude Desktop's own bootstrap name and says nothing about
    /// where the entry points, which is exactly the confusion the label solves.
    @Test("entries are labelled with where they send inference")
    func entriesCarryTheirDestination() throws {
        let config = try makeConfig(
            entries: [("default-id", "Default"), ("bridge-id", "Claude Bridge")],
            applied: "bridge-id",
            bodies: ["default-id": #"{"inferenceGatewayBaseUrl":"http://localhost:4000","inferenceProvider":"gateway"}"#]
        )

        let entry = try #require(config.status().restorableEntries.first)
        #expect(entry.detail == "localhost:4000")
        #expect(entry.label == "Default (localhost:4000)")
    }

    @Test("an entry with no base URL falls back to its provider")
    func labelsProviderWithoutABaseURL() throws {
        let config = try makeConfig(
            entries: [("v-id", "Work")],
            applied: "v-id",
            bodies: ["v-id": #"{"inferenceProvider":"vertex"}"#]
        )

        #expect(config.status().restorableEntries.first?.label == "Work (vertex)")
    }

    @Test("an entry nobody has configured is shown by name alone")
    func labelsUnconfiguredEntryByName() throws {
        let config = try makeConfig(entries: [("new-id", "Default")], applied: "new-id", bodies: ["new-id": "{}"])

        let entry = try #require(config.status().restorableEntries.first)
        #expect(entry.detail == nil)
        #expect(entry.label == "Default")
    }

    @Test("applying the bridge entry records the entry it displaced")
    func applyBridgeEntryReturnsPrevious() throws {
        let config = try makeConfig(entries: [("default-id", "Default")], applied: "default-id")

        let previous = try config.applyBridgeEntry(port: 8788, apiKey: "cb-test")

        #expect(previous == "default-id")
        #expect(config.status().bridgeEntryApplied)
        // And the displaced entry is still there to go back to.
        #expect(config.status().restorableEntries.map(\.name) == ["Default"])
    }

    // MARK: - Deployment-mode pin

    /// The gate, from Claude Desktop's loader: while its persisted
    /// `deploymentMode` is `"1p"`, every launch resolves first-party and the
    /// applied library entry is never read — writing the entry and pointing
    /// `appliedId` at it looks like it worked and does nothing. This is the
    /// "restarts Claude Desktop but keeps the old models" failure, so the
    /// switch has to lift the pin and the tests below pin that down.

    @Test("applying the bridge entry lifts a first-party deployment-mode pin")
    func applyBridgeEntryLiftsThePin() throws {
        let config = try makeConfig(
            entries: [("bridge-id", "Claude Bridge")],
            applied: "bridge-id",
            settingsBody: #"{"deploymentMode":"1p","preferences":{"keepMe":true}}"#
        )

        try config.applyBridgeEntry(port: 8788, apiKey: "cb-test")

        #expect(config.readDeploymentMode() == .thirdParty)
        #expect(config.status().deploymentModePinnedFirstParty == false)
        // The same file holds the user's preferences; only the pin changed.
        let body = try JSONValue.decode(Data(contentsOf: config.deploymentModeURL))
        #expect(body["deploymentMode"]?.stringValue == "3p")
        #expect(body["preferences"]?["keepMe"]?.boolValue == true)
    }

    @Test("switching to Anthropic's models records the matching pin")
    func anthropicModelsSetsThePin() throws {
        let config = try makeConfig(
            entries: [("bridge-id", "Claude Bridge")],
            applied: "bridge-id",
            settingsBody: #"{"deploymentMode":"3p","preferences":{"keepMe":true}}"#
        )

        try config.applyAnthropicModels()

        #expect(config.readDeploymentMode() == .firstParty)
        let body = try JSONValue.decode(Data(contentsOf: config.deploymentModeURL))
        #expect(body["preferences"]?["keepMe"]?.boolValue == true)
    }

    @Test("applying an entry creates the settings file holding just the pin")
    func applyCreatesMissingSettingsFile() throws {
        let config = try makeConfig(entries: [("bridge-id", "Claude Bridge")], applied: nil)

        try config.applyBridgeEntry(port: 8788, apiKey: "cb-test")

        #expect(config.readDeploymentMode() == .thirdParty)
        let body = try JSONValue.decode(Data(contentsOf: config.deploymentModeURL))
        guard case .object(let fields) = body else { Issue.record("not an object"); return }
        #expect(fields.keys.map { $0 } == ["deploymentMode"])
    }

    @Test("a pin Claude Desktop would not honour is reported as no pin")
    func unhonouredValuesAreNoPin() throws {
        for body in [
            "{}",                                              // no key yet
            #"{"deploymentMode":"any"}"#,                      // chooser, not a pin
            #"{"deploymentMode":true}"#,                       // not a string
            "not json {{{",                                    // unreadable
        ] {
            let config = try makeConfig(
                entries: [("bridge-id", "Claude Bridge")],
                applied: "bridge-id",
                settingsBody: body
            )
            #expect(config.readDeploymentMode() == nil, "for \(body)")
            #expect(config.status().deploymentModePinnedFirstParty == false, "for \(body)")
        }
    }

    @Test("an unreadable settings file is left exactly as it was")
    func malformedSettingsFileSurvivesTheSwitch() throws {
        let config = try makeConfig(
            entries: [("bridge-id", "Claude Bridge")],
            applied: "default-id",
            settingsBody: "totally not json {{{"
        )
        let before = try Data(contentsOf: config.deploymentModeURL)

        // The switch still succeeds: an unreadable pin reads as "no
        // preference" to Claude Desktop, which honours the library anyway.
        try config.applyBridgeEntry(port: 8788, apiKey: "cb-test")

        #expect(config.status().bridgeEntryApplied)
        #expect(try Data(contentsOf: config.deploymentModeURL) == before)
    }

    @Test("a first-party pin next to an applied entry is reported, then lifted")
    func statusReportsTheStrandedState() throws {
        let config = try makeConfig(
            entries: [("bridge-id", "Claude Bridge")],
            applied: "bridge-id",
            settingsBody: #"{"deploymentMode":"1p"}"#
        )

        // Exactly the state that used to strand users: our entry applied,
        // Claude Desktop staying first-party under it.
        let stranded = config.status()
        #expect(stranded.bridgeEntryApplied)
        #expect(stranded.deploymentModePinnedFirstParty)

        try config.applyBridgeEntry(port: 8788, apiKey: "cb-test")
        #expect(config.status().deploymentModePinnedFirstParty == false)
    }
}
