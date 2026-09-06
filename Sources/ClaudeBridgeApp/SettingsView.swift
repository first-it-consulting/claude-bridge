import BridgeCore
import SwiftUI

struct SettingsView: View {
    @Bindable var state: AppState
    @State private var selection: UUID?
    @State private var showingGeneral = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Profiles") {
                    ForEach(state.settings.profiles) { profile in
                        ProfileRow(profile: profile, isActive: profile.id == state.activeProfile?.id)
                            .tag(profile.id)
                            .contextMenu {
                                Button("Make Active") { Task { await state.selectProfile(profile) } }
                                Button("Duplicate") { state.duplicate(profile: profile) }
                                Divider()
                                Button("Delete", role: .destructive) { delete(profile) }
                            }
                    }
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom) {
                sidebarFooter
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            if showingGeneral {
                GeneralSettingsView(state: state)
            } else if let selection, let index = state.settings.profiles.firstIndex(where: { $0.id == selection }) {
                ProfileEditor(state: state, profile: $state.settings.profiles[index])
                    .id(selection)
            } else {
                ContentUnavailableView(
                    "No Profile Selected",
                    systemImage: "server.rack",
                    description: Text("Pick a profile on the left, or add one to connect a provider.")
                )
            }
        }
        .onAppear {
            selection = selection ?? state.activeProfile?.id
            state.refreshClaudeStatus()
        }
        .onChange(of: selection) { _, new in
            if new != nil { showingGeneral = false }
        }
        .safeAreaInset(edge: .top) { statusBanner }
    }

    @ViewBuilder
    private var statusBanner: some View {
        if let notice = state.notice {
            HStack(spacing: 8) {
                Image(systemName: symbol(for: notice.kind))
                    .foregroundStyle(color(for: notice.kind))
                Text(notice.text)
                    .font(.callout)
                Spacer(minLength: 12)
                Button("Dismiss") { state.notice = nil }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(color(for: notice.kind).opacity(0.12))
        }
    }

    private var sidebarFooter: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(BackendPreset.all) { preset in
                    Button(preset.name) { add(preset) }
                }
            } label: {
                Label("Add Profile", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()

            Button {
                showingGeneral = true
                selection = nil
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help("General settings")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func add(_ preset: BackendPreset) {
        var profile = preset.makeProfile()
        // Keep names unique so the menu stays readable.
        let existing = Set(state.settings.profiles.map(\.name))
        if existing.contains(profile.name) {
            var n = 2
            while existing.contains("\(preset.name) \(n)") { n += 1 }
            profile.name = "\(preset.name) \(n)"
        }
        state.settings.profiles.append(profile)
        selection = profile.id
        showingGeneral = false
        Task { await state.discoverModels(for: profile.id) }
    }

    private func delete(_ profile: Profile) {
        let alert = NSAlert()
        alert.messageText = "Delete “\(profile.name)”?"
        alert.informativeText = "Its API key will be removed from your keychain. This cannot be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        if selection == profile.id { selection = nil }
        state.delete(profile: profile)
    }

    private func symbol(for kind: AppState.Notice.Kind) -> String {
        switch kind {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private func color(for kind: AppState.Notice.Kind) -> Color {
        switch kind {
        case .info: return .accentColor
        case .warning: return .orange
        case .error: return .red
        }
    }
}

private struct ProfileRow: View {
    let profile: Profile
    let isActive: Bool

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.name)
                Text("\(profile.enabledModels.count) model\(profile.enabledModels.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
                    .help("Active profile")
            }
        }
        .padding(.vertical, 2)
    }
}
