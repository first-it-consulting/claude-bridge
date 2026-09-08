import AppKit
import BridgeCore
import SwiftUI

/// How a destination is named and chosen, shared by the menu bar and Settings.
///
/// Both surfaces offer the same switch, and when they each had their own
/// version they drifted: the menu grew a one-click switch that restarts Claude
/// Desktop while Settings still had buttons that changed the config and left the
/// user to work out that a restart was needed.
@MainActor
enum ClaudeDestinationUI {

    /// "oMLX (localhost:4000)" — the name the user gave it, plus where it
    /// actually goes, because the names alone are rarely distinguishing.
    /// Claude Desktop names its own first entry "Default" regardless of content.
    static func label(for destination: AppState.Destination) -> String {
        switch destination {
        case .anthropicModels:
            return "Anthropic's Models (claude.ai)"
        case .bridge(let profile):
            guard let url = URL(string: profile.backend.baseURL), let host = url.host else {
                return profile.name
            }
            guard let port = url.port else { return "\(profile.name) (\(host))" }
            return "\(profile.name) (\(host):\(port))"
        case .otherEntry(let entry):
            return entry.label
        }
    }

    /// Switches, asking first because restarting closes whatever the user has
    /// open in Claude Desktop.
    ///
    /// The prompt is suppressible, and skipped outright when Claude Desktop is
    /// not running, so the common case really is a single click.
    static func confirmAndSwitch(_ state: AppState, to destination: AppState.Destination) {
        guard state.settings.shouldConfirmClaudeRestart, state.claudeDesktopIsRunning else {
            Task { await state.switchClaudeDesktop(to: destination, restart: true) }
            return
        }

        let alert = NSAlert()
        alert.messageText = "Switch to \(destination.name)?"
        alert.informativeText = """
            Claude Desktop will quit and reopen. It reads its inference settings and \
            model list only at launch, so a restart is needed for the change to show up.
            """
        alert.addButton(withTitle: "Switch and Restart")
        alert.addButton(withTitle: "Switch Without Restarting")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        NSApp.activate(ignoringOtherApps: true)

        let choice = alert.runModal()
        guard choice != .alertThirdButtonReturn else { return }
        if alert.suppressionButton?.state == .on {
            state.settings.confirmClaudeRestart = false
        }
        let restart = choice == .alertFirstButtonReturn
        Task { await state.switchClaudeDesktop(to: destination, restart: restart) }
    }
}
