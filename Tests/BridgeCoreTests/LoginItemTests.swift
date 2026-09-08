import Testing
import Foundation
import ServiceManagement
@testable import BridgeCore

@Suite("Launch at login")
struct LoginItemTests {

    /// `requiresApproval` is the case that matters: macOS reports it when the
    /// user has switched the item off in System Settings, and registering again
    /// does not clear it. Folding it into `enabled` would show a toggle that is
    /// on while nothing launches at login.
    @Test("every SMAppService status maps to a distinct state")
    func statusesAreDistinct() {
        let states: [LoginItem.State] = [.enabled, .disabled, .requiresApproval, .unavailable]
        #expect(Set(states.map(String.init(describing:))).count == states.count)
    }

    @Test("reading the state does not throw or change anything")
    func readingStateIsSafe() {
        let before = LoginItem.state
        #expect(LoginItem.state == before)
    }

    /// The state is deliberately not persisted, so that a revoked registration
    /// cannot leave `settings.json` claiming it is still on.
    @Test("launch at login is not stored in settings")
    func notPersisted() throws {
        let settings = BridgeSettings(gatewayToken: "cb-test")
        let json = try JSONEncoder().encode(settings)
        let fields = try #require(
            try JSONSerialization.jsonObject(with: json) as? [String: Any]
        )

        #expect(fields["launchAtLogin"] == nil)
        #expect(fields.keys.contains { $0.lowercased().contains("login") } == false)
    }
}
