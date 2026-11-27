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

        claudeDesktopSection

        Divider()

        updateSection

        Divider()

        Button("About Claude Bridge") {
            AppInfo.showAboutPanel()
        }

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

    /// Installed and latest version, and a one-click way to the new one.
    @ViewBuilder
    private var updateSection: some View {
        Section("Updates") {
            if state.updateAvailable, let version = state.updateVersion {
                Button("Update to \(version)… (installed \(state.installedVersion))") {
                    state.installUpdate()
                }
            } else if state.updateChecking {
                Text("Checking for updates…")
            } else if state.updateError != nil {
                Text("Could not check for updates · \(state.installedVersion)")
            } else {
                Text("Up to date · \(state.installedVersion)")
            }
            // Not disabled while checking: clicking joins the running check
            // and still gets its answer in a dialog.
            Button("Check for Updates…") { state.checkForUpdates(announce: true) }
        }
    }

    /// One click per destination.
    ///
    /// Switching used to be three trips through the menu — pick the profile,
    /// point Claude Desktop at the bridge, then restart it — for what is really
    /// one decision. Profiles are listed here as destinations in their own
    /// right, and choosing one does all three.
    @ViewBuilder
    private var claudeDesktopSection: some View {
        Section("Claude Desktop Uses") {
            if !state.claudeStatus.configDirectoryExists {
                Text("Not set up for third-party inference")
            } else if state.claudeStatus.managedProfilePresent {
                Text("Managed by MDM — local config is ignored")
            } else {
                // Reachable again after the switch if the user later picks
                // Claude.ai in Claude Desktop's own mode chooser: our entry is
                // still applied, so every destination here looks ticked as
                // usual, while the app quietly stays on first-party models.
                if state.claudeStatus.deploymentModePinnedFirstParty,
                   state.claudeStatus.bridgeEntryApplied {
                    Text("Claude Desktop is pinned to its own models — pick a profile to lift it")
                }
                // A stopped bridge (or a bind that failed at launch) fails
                // every Claude Desktop request with a connection error, while
                // this menu stayed passive about it. Say it where the user
                // looks when "Claude Desktop shows nothing".
                if !state.serverRunning, state.claudeStatus.bridgeEntryApplied {
                    if let error = state.serverError {
                        Text("Bridge could not start: \(error)")
                    } else {
                        Text("Bridge is stopped — Claude Desktop's requests fail until it starts")
                    }
                }
                ForEach(Array(state.destinations.enumerated()), id: \.offset) { _, destination in
                    Toggle(isOn: binding(for: destination)) {
                        Text(ClaudeDestinationUI.label(for: destination))
                    }
                }
            }

            Button("Restart Claude Desktop") {
                confirmRestart()
            }
            .disabled(!state.claudeStatus.claudeDesktopInstalled)
        }
    }

    /// A menu item that behaves like a radio button: picking it switches, and
    /// picking the current one again does nothing rather than unsetting it.
    private func binding(for destination: AppState.Destination) -> Binding<Bool> {
        let isCurrent = state.isCurrent(destination)
        return Binding(
            get: { isCurrent },
            set: { picked in
                guard picked, !isCurrent else { return }
                ClaudeDestinationUI.confirmAndSwitch(state, to: destination)
            }
        )
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
