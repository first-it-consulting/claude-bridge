import Testing
import Foundation
import ServiceManagement
@testable import BridgeCore

@Suite("Launch at login")
struct LoginItemTests {

    /// `notFound` means "off", not "impossible". macOS reports it for an app
    /// that has never been registered — `notRegistered` is not what you get —
    /// and `register()` then succeeds, ad-hoc signature included. Treating it
    /// as "unavailable" disabled the toggle in exactly the case where the user
    /// was switching the feature on for the first time, which is how this
    /// shipped broken.
    @Test(
        "a status that is not enabled or awaiting approval means simply off",
        arguments: [
            (SMAppService.Status.enabled, LoginItem.State.enabled),
            (.requiresApproval, .requiresApproval),
            (.notRegistered, .disabled),
            (.notFound, .disabled),
        ]
    )
    func mapsStatus(status: SMAppService.Status, expected: LoginItem.State) {
        #expect(LoginItem.state(for: status) == expected)
    }

    /// `requiresApproval` stays its own case: folding it into `enabled` would
    /// show a toggle that is on while nothing launches at login, and folding it
    /// into `disabled` would hide that only the user can clear it.
    @Test("approval is not mistaken for on or off")
    func approvalIsDistinct() {
        #expect(LoginItem.state(for: .requiresApproval) != .enabled)
        #expect(LoginItem.state(for: .requiresApproval) != .disabled)
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
