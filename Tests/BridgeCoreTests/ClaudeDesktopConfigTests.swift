import Testing
import Foundation
@testable import BridgeCore

@Suite("Claude Desktop configuration library")
struct ClaudeDesktopConfigTests {

    /// A throwaway config library. Each test gets its own directory so they can
    /// run in parallel without fighting over `_meta.json`.
    func makeConfig(
        entries: [(id: String, name: String)],
        applied: String?,
        bodies: [String: String] = [:]
    ) throws -> ClaudeDesktopConfig {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cb-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

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
}
