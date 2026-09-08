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

    public enum State: Equatable {
        /// Registered, and macOS will launch the app at login.
        case enabled
        /// Not registered.
        case disabled
        /// Registered, but the user has switched it off in System Settings.
        /// Re-registering does not clear this; only the user can.
        case requiresApproval
        /// Login items are unavailable — the app is not in a state macOS will
        /// register, which for a development build usually means it is running
        /// somewhere `SMAppService` will not accept.
        case unavailable
    }

    public static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .notRegistered: return .disabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .unavailable
        @unknown default: return .unavailable
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
