import BridgeCore
import SwiftUI

struct GeneralSettingsView: View {
    @Bindable var state: AppState
    @State private var portText = ""
    @State private var portError: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(state.serverRunning ? Color.green : Color.secondary)
                            .frame(width: 8, height: 8)
                        Text(state.serverRunning
                             ? "Listening on 127.0.0.1:\(String(state.settings.port))"
                             : (state.serverError ?? "Stopped"))
                        Spacer()
                        Button(state.serverRunning ? "Stop" : "Start") {
                            Task { await state.toggleServer() }
                        }
                    }
                }

                HStack {
                    TextField("Port", text: $portText)
                        .frame(width: 90)
                    Button("Apply") { applyPort() }
                        .disabled(UInt16(portText) == nil || UInt16(portText) == state.settings.port)
                    Spacer()
                }
                if let portError {
                    Text(portError).font(.caption).foregroundStyle(.red)
                }

                Toggle("Start the bridge when Claude Bridge launches", isOn: $state.settings.startServerAtLaunch)

                LabeledContent("Gateway token") {
                    HStack {
                        Text(String(repeating: "•", count: 12) + String(state.settings.gatewayToken.suffix(4)))
                            .font(.system(.body, design: .monospaced))
                        Spacer()
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(state.settings.gatewayToken, forType: .string)
                        }
                        Button("Regenerate") { regenerateToken() }
                    }
                }
            } header: {
                Text("Bridge")
            } footer: {
                Text("""
                    The bridge listens on loopback only. The token stops other software on \
                    this Mac from using it as an open relay to your providers.
                    """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Third-party config") {
                    Text(state.claudeStatus.configDirectoryExists ? "Found" : "Not set up")
                        .foregroundStyle(state.claudeStatus.configDirectoryExists ? .primary : .secondary)
                }

                if !state.claudeStatus.configDirectoryExists {
                    Text("""
                        In Claude Desktop, open Help ▸ Troubleshooting ▸ Enable Developer Mode, then \
                        Developer ▸ Configure Third-Party Inference once. That creates the folder \
                        Claude Bridge writes to.
                        """)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }

                if state.claudeStatus.managedProfilePresent {
                    Label("""
                        An MDM configuration profile is installed for Claude Desktop. It overrides \
                        anything written here, so the bridge will not be used.
                        """, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                }

                LabeledContent("Currently pointed at") {
                    Text(state.destinations.first(where: state.isCurrent)
                        .map(ClaudeDestinationUI.label) ?? "Nothing")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Menu {
                        ForEach(Array(state.destinations.enumerated()), id: \.offset) { _, destination in
                            Button(ClaudeDestinationUI.label(for: destination)) {
                                ClaudeDestinationUI.confirmAndSwitch(state, to: destination)
                            }
                        }
                    } label: {
                        Text("Switch…")
                    }
                    .fixedSize()
                    .disabled(!state.claudeStatus.configDirectoryExists)

                    Spacer()
                    Button("Refresh") { state.refreshClaudeStatus() }
                }
            } header: {
                Text("Claude Desktop")
            } footer: {
                Text("""
                    Claude Desktop reads its inference settings and model list once, at launch, \
                    so switching restarts it. Profiles are listed here too: choosing one points \
                    Claude Desktop at the bridge and selects that backend in a single step.
                    """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Logging") {
                Toggle("Record request and response bodies", isOn: $state.captureBodies)
                    .help("Useful when a backend rejects a request. Bodies stay in memory and are never written to disk.")
                Stepper(
                    "Keep \(state.settings.logCapacity) requests",
                    value: $state.settings.logCapacity,
                    in: 50...2000,
                    step: 50
                )
            }
        }
        .formStyle(.grouped)
        .onAppear {
            portText = String(state.settings.port)
            state.refreshClaudeStatus()
        }
    }

    private func applyPort() {
        guard let port = UInt16(portText), port >= 1024 else {
            portError = "Pick a port between 1024 and 65535."
            return
        }
        guard port == state.settings.port || BridgeServer.isPortAvailable(port) else {
            portError = "Something else is already listening on port \(port)."
            return
        }
        portError = nil
        Task { await state.applyPortChange(to: port) }
    }

    private func regenerateToken() {
        state.settings.gatewayToken = BridgeSettings.generateToken()
        // The old token is baked into Claude Desktop's config, so rewrite it or
        // every request starts failing with a 401.
        if state.claudeStatus.bridgeEntryApplied {
            state.connectClaudeDesktop(announce: false)
            state.notice = AppState.Notice(
                kind: .info,
                text: "New token written to Claude Desktop's config. Restart Claude Desktop to pick it up."
            )
        }
    }
}
