import Testing
import Foundation
@testable import BridgeCore

@Suite("Persisted settings")
struct BridgeSettingsTests {

    /// Synthesized `Codable` ignores default values for missing keys, so a
    /// non-optional addition makes every existing `settings.json` fail to
    /// decode and `ProfileStore.load()` fall back to starter profiles — losing
    /// the user's profiles without a word. Every new field must be optional,
    /// and this is the test that says so.
    @Test("settings written before a field existed still decode")
    func decodesSettingsWithoutNewerFields() throws {
        let json = """
        {
          "profiles": [],
          "port": 8788,
          "gatewayToken": "cb-test",
          "startServerAtLaunch": true,
          "logCapacity": 300
        }
        """

        let settings = try JSONDecoder().decode(BridgeSettings.self, from: Data(json.utf8))

        #expect(settings.port == 8788)
        #expect(settings.confirmClaudeRestart == nil)
        // nil means "ask", so an upgrade never silently starts closing the
        // user's app without warning.
        #expect(settings.shouldConfirmClaudeRestart)
    }

    @Test("suppressing the confirmation survives a save and load")
    func roundTripsSuppression() throws {
        var settings = BridgeSettings(gatewayToken: "cb-test")
        settings.confirmClaudeRestart = false

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(BridgeSettings.self, from: data)

        #expect(decoded.shouldConfirmClaudeRestart == false)
    }
}
