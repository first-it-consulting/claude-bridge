import BridgeCore
import SwiftUI

/// Edits one profile: where the backend is, and which of its models to expose.
struct ProfileEditor: View {
    @Bindable var state: AppState
    @Binding var profile: Profile

    @State private var apiKey: String = ""
    @State private var health: HealthChecker.Health = .unknown
    @State private var discovering = false
    @State private var discovery: AppState.DiscoveryResult?

    var body: some View {
        Form {
            Section("Connection") {
                TextField("Name", text: $profile.name)

                Picker("API format", selection: $profile.backend.kind) {
                    Text("OpenAI-compatible").tag(BackendKind.openai)
                    Text("Anthropic-compatible").tag(BackendKind.anthropic)
                }
                .help("OpenAI backends are translated. Anthropic backends are passed through untouched, which preserves prompt caching.")

                TextField("Base URL", text: $profile.backend.baseURL)
                    .textContentType(.URL)
                    .autocorrectionDisabled()

                Text(pathHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Auth", selection: $profile.backend.authScheme) {
                    ForEach(AuthScheme.allCases, id: \.self) { scheme in
                        Text(scheme.displayName).tag(scheme)
                    }
                }

                if profile.backend.authScheme != .none {
                    SecureField("API key", text: $apiKey)
                        .onSubmit(saveKey)
                        .onChange(of: apiKey) { _, _ in saveKey() }
                } else if profile.backend.keychainAccount != nil {
                    // A leftover from when this profile did use a key. It is
                    // never read while auth is off, but it is still sitting in
                    // the keychain.
                    LabeledContent("Stored key") {
                        HStack {
                            Text("Unused — this backend needs no credential")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Forget") { state.forgetStoredKey(for: profile.id) }
                        }
                    }
                }

                Picker("Reasoning output", selection: $profile.backend.reasoningMode) {
                    ForEach(ReasoningMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .help("Reasoning models emit a scratchpad alongside their answer. Anthropic thinking blocks are signed and cannot be forged, so the scratchpad is either dropped or shown as ordinary text.")
                .disabled(profile.backend.kind == .anthropic)
            }

            Section {
                HStack(spacing: 10) {
                    Button("Test Connection") { Task { await test() } }
                    HealthBadge(health: health)
                    Spacer()
                }
            }

            Section {
                if let unavailable = discovery?.unavailable, !unavailable.isEmpty {
                    unavailableBanner(unavailable)
                }
                ModelTable(profile: $profile, served: state.servedModels(for: profile.id))
            } header: {
                HStack {
                    Text("Models")
                    Spacer()
                    if let summary = discoverySummary {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        Task { await discover() }
                    } label: {
                        if discovering {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Discover", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(discovering)
                    Menu {
                        let known = state.servedModels(for: profile.id) ?? []
                        if !known.isEmpty {
                            Section("Served by this backend") {
                                ForEach(known.sorted(), id: \.self) { id in
                                    Button(id) { addModel(id) }
                                }
                            }
                        }
                        Button("Custom…") { addModel("") }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .fixedSize()
                }
            } footer: {
                Text("""
                    Tier decides which Claude family a model stands in for. It is also what \
                    gets the model into Claude Desktop at all: models are advertised under \
                    their tier name, because Claude Desktop rejects ids containing a \
                    non-Anthropic vendor name. Your model's real name is what you see in \
                    the picker. Tier also decides the work it gets — sub-agents go to Haiku, \
                    the main conversation to whichever tier you select in Claude Desktop. \
                    The same model can back several tiers.
                    """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task(id: profile.id) {
            // Same reasoning as AppState.apiKey(for:): do not prompt for a
            // secret this profile has no use for.
            if profile.backend.authScheme != .none, let account = profile.backend.keychainAccount {
                apiKey = await Keychain.get(account: account) ?? ""
            } else {
                apiKey = ""
            }
            await test()
            await state.refreshServedModels(for: profile.id)
        }
        // Editing where the backend lives invalidates what it was known to
        // serve; keeping the old set would flag exactly the wrong rows.
        .onChange(of: profile.backend.baseURL) { _, _ in invalidateDiscovery() }
        .onChange(of: profile.backend.kind) { _, _ in invalidateDiscovery() }
    }

    private var pathHint: String {
        switch profile.backend.kind {
        case .openai:
            return "Requests go to \(profile.backend.normalizedBase)/chat/completions"
        case .anthropic:
            return "Requests go to \(profile.backend.normalizedBase)/v1/messages"
        }
    }

    private func saveKey() {
        // Give the profile a keychain slot the first time a key is entered.
        let account = profile.backend.keychainAccount ?? UUID().uuidString
        profile.backend.keychainAccount = account
        let secret = apiKey
        Task { try? await Keychain.set(secret, account: account) }
    }

    /// Appends a row.
    ///
    /// Marked manual so a later discovery pass does not prune a model this
    /// backend serves but never lists. The tier is a fresh guess from the name;
    /// pointing a second tier at an already-listed model is the common reason
    /// to add one by hand, and the user changes it in the row.
    private func addModel(_ id: String) {
        profile.models.append(ModelMapping(
            upstreamID: id,
            tier: id.isEmpty ? .sonnet : ModelCatalog.inferTier(from: id),
            origin: .manual
        ))
    }

    private func invalidateDiscovery() {
        discovery = nil
        state.invalidateDiscovery(for: profile.id)
    }

    private func test() async {
        health = .checking
        health = await state.health(of: profile)
    }

    private func discover() async {
        discovering = true
        discovery = nil
        discovery = await state.discoverModels(for: profile.id)
        discovering = false
        await test()
    }

    private var discoverySummary: String? {
        guard let discovery else { return nil }
        if discovery.failed { return "Backend listed no models" }
        var parts: [String] = []
        if discovery.added > 0 { parts.append("added \(discovery.added)") }
        if !discovery.removed.isEmpty { parts.append("removed \(discovery.removed.count)") }
        return parts.isEmpty ? "Up to date" : parts.joined(separator: ", ").capitalizedFirst
    }

    /// Models configured here that the backend does not serve.
    ///
    /// Almost always the result of pointing a profile at a different URL: the
    /// previous backend's models stay behind and get advertised to Claude
    /// Desktop, which then sends this backend a model ID it has never heard of.
    @ViewBuilder
    private func unavailableBanner(_ unavailable: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                "\(unavailable.count) model\(unavailable.count == 1 ? " you added is" : "s you added are") not served by this backend",
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.orange)

            Text(unavailable.prefix(6).joined(separator: ", ")
                 + (unavailable.count > 6 ? ", and \(unavailable.count - 6) more" : ""))
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Remove Them") {
                state.removeUnavailableModels(for: profile.id)
                discovery?.unavailable = []
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }
}

struct HealthBadge: View {
    let health: HealthChecker.Health

    var body: some View {
        HStack(spacing: 5) {
            switch health {
            case .checking:
                ProgressView().controlSize(.small)
            default:
                Circle().fill(color).frame(width: 8, height: 8)
            }
            Text(health.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var color: Color {
        switch health {
        case .reachable: return .green
        case .unreachable: return .red
        case .checking, .unknown: return .secondary
        }
    }
}

/// The model list. A table rather than a form because the interesting thing is
/// comparing tiers across models.
private struct ModelTable: View {
    @Binding var profile: Profile
    /// Model IDs the backend confirmed. `nil` when discovery has not run or
    /// the backend has no model endpoint, in which case nothing is flagged.
    var served: Set<String>?

    var body: some View {
        if profile.models.isEmpty {
            ContentUnavailableView {
                Label("No Models", systemImage: "cube")
            } description: {
                Text("Use Discover to list what this backend serves.")
            }
            .frame(height: 130)
        } else {
            VStack(spacing: 0) {
                header
                Divider()
                ForEach($profile.models) { $model in
                    ModelRow(
                        model: $model,
                        profile: $profile,
                        isUnavailable: isUnavailable(model),
                        choices: served ?? []
                    )
                    Divider()
                }
            }
        }
    }

    private func isUnavailable(_ model: ModelMapping) -> Bool {
        guard let served, !model.upstreamID.isEmpty else { return false }
        return !served.contains(model.upstreamID)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("On").frame(width: 26)
            Text("Model ID").frame(maxWidth: .infinity, alignment: .leading)
            Text("Shown as").frame(width: 130, alignment: .leading)
            Text("Tier").frame(width: 96, alignment: .leading)
            Text("Default").frame(width: 52)
            Spacer().frame(width: 22)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.vertical, 4)
    }
}

private struct ModelRow: View {
    @Binding var model: ModelMapping
    @Binding var profile: Profile
    var isUnavailable = false
    /// Model IDs the backend reported, offered as a dropdown on the ID field.
    var choices: Set<String> = []

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $model.enabled)
                .labelsHidden()
                .frame(width: 26)

            HStack(spacing: 4) {
                if isUnavailable {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help("This backend did not list this model")
                }
                TextField("model-id", text: $model.upstreamID)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                if !choices.isEmpty {
                    // Picking beats typing: these names are long, exact, and
                    // easy to get subtly wrong.
                    Menu {
                        ForEach(choices.sorted(), id: \.self) { id in
                            Button(id) { model.upstreamID = id }
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            TextField(model.upstreamID, text: Binding(
                get: { model.displayName ?? "" },
                set: { model.displayName = $0.isEmpty ? nil : $0 }
            ))
            .textFieldStyle(.plain)
            .foregroundStyle(.secondary)
            .frame(width: 130)

            Picker("", selection: $model.tier) {
                ForEach(FamilyTier.allCases, id: \.self) { tier in
                    Text(tier.displayName).tag(tier)
                }
            }
            .labelsHidden()
            .frame(width: 96)

            Toggle("", isOn: Binding(
                get: { model.isFamilyDefault },
                set: { isDefault in
                    // Only one default per tier, so setting this clears the
                    // others rather than leaving an ambiguous list.
                    if isDefault {
                        for index in profile.models.indices
                        where profile.models[index].tier == model.tier {
                            profile.models[index].isFamilyDefault = false
                        }
                    }
                    model.isFamilyDefault = isDefault
                }
            ))
            .labelsHidden()
            .frame(width: 52)
            .help("The model Claude Desktop uses for this tier")

            Button {
                profile.models.removeAll { $0.id == model.id }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .frame(width: 22)
        }
        .padding(.vertical, 3)
        .opacity(model.enabled ? 1 : 0.5)
    }
}

private extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
