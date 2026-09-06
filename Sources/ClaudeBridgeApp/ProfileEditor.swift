import BridgeCore
import SwiftUI

/// Edits one profile: where the backend is, and which of its models to expose.
struct ProfileEditor: View {
    @Bindable var state: AppState
    @Binding var profile: Profile

    @State private var apiKey: String = ""
    @State private var health: HealthChecker.Health = .unknown
    @State private var discovering = false
    @State private var discoveryResult: String?

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
                ModelTable(profile: $profile)
            } header: {
                HStack {
                    Text("Models")
                    Spacer()
                    if let discoveryResult {
                        Text(discoveryResult)
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
                    Button {
                        profile.models.append(ModelMapping(upstreamID: ""))
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
            } footer: {
                Text("""
                    Tier decides which Claude family a model stands in for, which is how a \
                    non-Claude model ID reaches Claude Desktop's picker at all — and which \
                    work Claude Desktop routes to it. Sub-agents go to Haiku; the main \
                    conversation goes to whichever tier you pick in the app.
                    """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task(id: profile.id) {
            apiKey = profile.backend.keychainAccount.flatMap { Keychain.get(account: $0) } ?? ""
            await test()
        }
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
        try? Keychain.set(apiKey, account: account)
    }

    private func test() async {
        health = .checking
        health = await state.health(of: profile)
    }

    private func discover() async {
        discovering = true
        discoveryResult = nil
        let added = await state.discoverModels(for: profile.id)
        discovering = false
        discoveryResult = added == 0
            ? "Nothing new"
            : "Added \(added) model\(added == 1 ? "" : "s")"
        await test()
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
                    ModelRow(model: $model, profile: $profile)
                    Divider()
                }
            }
        }
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

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $model.enabled)
                .labelsHidden()
                .frame(width: 26)

            TextField("model-id", text: $model.upstreamID)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
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
