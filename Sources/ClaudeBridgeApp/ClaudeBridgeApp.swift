import AppKit
import BridgeCore
import SwiftUI

@main
struct ClaudeBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var state = AppState()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            MenuContent(state: state)
        } label: {
            // The icon carries the status so the common case — "is it working?"
            // — needs no click.
            Image(systemName: state.connectionState.symbolName)
                .accessibilityLabel("Claude Bridge: \(state.statusSummary)")
        }
        .menuBarExtraStyle(.menu)

        Window("Claude Bridge Settings", id: WindowID.settings) {
            SettingsView(state: state)
                .frame(minWidth: 780, minHeight: 520)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 860, height: 600)

        Window("Request Log", id: WindowID.log) {
            LogView(state: state)
                .frame(minWidth: 720, minHeight: 420)
        }
        .defaultSize(width: 900, height: 560)
    }
}

enum WindowID {
    static let settings = "settings"
    static let log = "log"
}

/// The app has no dock icon and no main window; it lives in the menu bar.
/// `LSUIElement` in the bundle's Info.plist is what actually sets this, but a
/// bare SwiftPM binary run from a terminal has no bundle, so it is also done
/// here at launch.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
