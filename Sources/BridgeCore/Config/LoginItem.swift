import Foundation
import ServiceManagement

/// Whether macOS launches Claude Bridge when the user logs in.
///
/// This matters more than it does for most menu bar apps: Claude Desktop cannot
/// reach a bridge that is not running, and it reads its inference config and
/// model list only at launch. Open Claude Desktop first after a reboot and it
/// fails for the whole session — starting the bridge afterwards does not rescue
/// it, because Claude Desktop has already given up.
///
/// The state lives in the system, not in `settings.json`. macOS remembers the
/// registration itself, and the user can revoke it in System Settings ▸ General
/// ▸ Login Items without telling the app. Persisting a copy would let the two
/// disagree, and the UI would confidently report a setting macOS is ignoring —
/// so `status` is read every time rather than cached.
public enum LoginItem {

    public enum State: Equatable, Sendable {
        /// Registered, and macOS will launch the app at login.
        case enabled
        /// Not registered. `register()` is expected to work.
        case disabled
        /// Registered, but the user has switched it off in System Settings.
        /// Re-registering does not clear this; only the user can.
        case requiresApproval
    }

    /// Reported by macOS, mapped to what the UI can act on.
    ///
    /// `notFound` means "off", not "impossible". An app that has never been
    /// registered reports `notFound` rather than the `notRegistered` its name
    /// suggests, and `register()` then succeeds normally — including for an
    /// ad-hoc signed build. Reading it as "macOS will not accept this app"
    /// disabled the toggle in precisely the case where the user was trying to
    /// switch the feature on for the first time.
    ///
    /// Whether registration will work is therefore not predicted from `status`
    /// at all: the toggle stays live, and a `register()` that fails reports its
    /// own error.
    public static var state: State { state(for: SMAppService.mainApp.status) }

    /// Split out so the mapping can be tested without registering anything on
    /// the machine running the tests.
    public static func state(for status: SMAppService.Status) -> State {
        switch status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered, .notFound: return .disabled
        @unknown default: return .disabled
        }
    }

    /// Turns the login item on or off.
    ///
    /// - Note: macOS ties the registration to the app's code signature. Ad-hoc
    ///   signing gives the binary a new cdhash on every build, so a development
    ///   build can lose its registration or need approving again — the same
    ///   reason the keychain re-prompts. That is expected outside a signed
    ///   release, not a bug to chase.
    public static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    /// Opens the Login Items pane, for when only the user can clear the state.
    public static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
