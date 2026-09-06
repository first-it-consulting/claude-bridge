import BridgeCore
import SwiftUI

/// The menu that drops down from the status item.
///
/// Deliberately shallow: switch profile, see whether it works, get to the two
/// windows. Anything that edits configuration lives in Settings.
struct MenuContent: View {
    @Bindable var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Section(state.statusSummary) {
            Button(state.serverRunning ? "Stop Bridge" : "Start Bridge") {
                Task { await state.toggleServer() }
            }
            if state.serverRunning {
                Text("Listening on 127.0.0.1:\(String(state.settings.port))")
            }
        }

        Divider()

        if state.settings.profiles.isEmpty {
            Text("No profiles yet")
        } else {
            Section("Profile") {
                ForEach(state.settings.profiles) { profile in
                    Button {
                        Task { await state.selectProfile(profile) }
                    } label: {
                        // A leading checkmark is the menu idiom for the current
                        // choice; Toggle inside MenuBarExtra renders it for us.
                        Label(
                            profile.name,
                            systemImage: profile.id == state.activeProfile?.id ? "checkmark" : ""
                        )
                    }
                }
            }
        }

        Divider()

        claudeDesktopSection

        Divider()

        Button("Settings…") {
            openWindow(id: WindowID.settings)
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(",")

        Button("Request Log…") {
            openWindow(id: WindowID.log)
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("l")

        Divider()

        Button("Quit Claude Bridge") {
            Task {
                await state.onQuit()
                NSApp.terminate(nil)
            }
        }
        .keyboardShortcut("q")
    }

    @ViewBuilder
    private var claudeDesktopSection: some View {
        Section("Claude Desktop") {
            if !state.claudeStatus.configDirectoryExists {
                Text("Not set up for third-party inference")
            } else if state.claudeStatus.managedProfilePresent {
                Text("Managed by MDM — local config is ignored")
            } else if state.claudeStatus.bridgeEntryApplied {
                Text("Using Claude Bridge")
                Button("Restore Previous Configuration") {
                    state.disconnectClaudeDesktop()
                }
            } else {
                Text("Using: \(state.claudeStatus.appliedEntryName ?? "no configuration")")
                Button("Point Claude Desktop at the Bridge") {
                    state.connectClaudeDesktop()
                }
            }

            Button("Restart Claude Desktop") {
                confirmRestart()
            }
            .disabled(!state.claudeStatus.claudeDesktopInstalled)
        }
    }

    /// Restarting closes whatever the user has open in Claude Desktop, so it
    /// asks first rather than acting on a menu click.
    private func confirmRestart() {
        let alert = NSAlert()
        alert.messageText = "Restart Claude Desktop?"
        alert.informativeText = """
            Claude Desktop will quit and reopen. It reads its inference settings and \
            model list only at launch, so a restart is needed for changes to show up.
            """
        alert.addButton(withTitle: "Restart")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await state.restartClaudeDesktop() }
    }
}
