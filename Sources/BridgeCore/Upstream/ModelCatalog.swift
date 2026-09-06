import Foundation

/// Builds the `GET /v1/models` response the bridge serves to Claude Desktop,
/// and discovers what a backend actually offers.
///
/// Claude Desktop filters discovered models down to those whose IDs look like
/// Claude models, which would hide every local model. The documented way out is
/// `anthropic_family_tier` on the model object: a model tagged with a tier name
/// passes the filter under that family, whatever it is called. The bridge tags
/// every model it serves, which is what lets `qwen3-coder:30b` appear in the
/// picker without pretending to be `claude-sonnet-5`.
public enum ModelCatalog {

    /// The response for `GET /v1/models`.
    public static func modelsResponse(for profile: Profile) -> JSONValue {
        let models = profile.enabledModels

        // Only one model per tier may be the family default; the first flagged
        // entry wins, matching how Claude Desktop resolves ties itself.
        var tierClaimed: Set<FamilyTier> = []

        let data: [JSONValue] = models.map { model in
            var isDefault = false
            if model.isFamilyDefault, !tierClaimed.contains(model.tier) {
                isDefault = true
                tierClaimed.insert(model.tier)
            }
            return .object([
                "id": .string(model.upstreamID),
                "type": "model",
                "display_name": .string(model.label),
                "created_at": .string(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 0))),
                "anthropic_family_tier": .string(model.tier.rawValue),
                "is_family_default": .bool(isDefault),
            ])
        }

        return .object([
            "data": .array(data),
            "has_more": false,
            "first_id": models.first.map { .string($0.upstreamID) } ?? .null,
            "last_id": models.last.map { .string($0.upstreamID) } ?? .null,
        ])
    }

    /// Asks a backend what it can serve.
    ///
    /// Both wire formats answer `GET /v1/models` with a list, but they disagree
    /// on the envelope: OpenAI wraps it in `data`, Anthropic in `data` as well
    /// but with `display_name`. Ollama's native `/api/tags` is checked as a
    /// fallback because its OpenAI-compatible route omits models that have
    /// never been loaded on some versions.
    public static func discover(backend: Backend, apiKey: String?) async throws -> [DiscoveredModel] {
        if let models = try? await fetchModelList(backend: backend, apiKey: apiKey), !models.isEmpty {
            return models
        }
        if let ollama = try? await fetchOllamaTags(backend: backend), !ollama.isEmpty {
            return ollama
        }
        return []
    }

    public struct DiscoveredModel: Sendable, Hashable, Identifiable {
        public var id: String
        public var displayName: String?
        /// A tier the backend asserted, if it happens to speak that dialect.
        public var suggestedTier: FamilyTier?

        public init(id: String, displayName: String? = nil, suggestedTier: FamilyTier? = nil) {
            self.id = id
            self.displayName = displayName
            self.suggestedTier = suggestedTier
        }
    }

    static func fetchModelList(backend: Backend, apiKey: String?) async throws -> [DiscoveredModel] {
        guard let url = backend.endpointURL(path: backend.kind == .anthropic ? "/v1/models" : "/models") else {
            return []
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        UpstreamClient.applyAuth(to: &request, backend: backend, apiKey: apiKey)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return []
        }
        let json = try JSONValue.decode(data)

        return (json["data"]?.arrayValue ?? []).compactMap { entry in
            guard let id = entry["id"]?.stringValue else { return nil }
            let tier = entry["anthropic_family_tier"]?.stringValue.flatMap(FamilyTier.init(rawValue:))
            return DiscoveredModel(
                id: id,
                displayName: entry["display_name"]?.stringValue,
                suggestedTier: tier ?? inferTier(from: id)
            )
        }
    }

    static func fetchOllamaTags(backend: Backend) async throws -> [DiscoveredModel] {
        // `/api/tags` sits at the server root, one level above the `/v1` the
        // OpenAI-compatible routes live under.
        var base = backend.normalizedBase
        if base.hasSuffix("/v1") { base.removeLast(3) }
        guard let url = URL(string: base + "/api/tags") else { return [] }

        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 10))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }

        let json = try JSONValue.decode(data)
        return (json["models"]?.arrayValue ?? []).compactMap { entry in
            guard let name = entry["name"]?.stringValue else { return nil }
            return DiscoveredModel(id: name, displayName: nil, suggestedTier: inferTier(from: name))
        }
    }

    /// The outcome of reconciling a configured list against a backend.
    public struct Reconciliation: Sendable, Equatable {
        public var models: [ModelMapping]
        public var added: Int
        /// Entries discovery had added before and the backend has stopped
        /// listing. Dropped, because discovery owns them.
        public var removed: [String]
        /// Hand-added entries the backend does not list. Kept and reported:
        /// some backends serve models their `/v1/models` never mentions.
        public var unavailable: [String]
    }

    /// Merges what a backend reports into a configured model list.
    ///
    /// Existing entries keep their tier, label, and flags, so re-running
    /// discovery never undoes the user's mapping.
    ///
    /// Entries discovery added itself and the backend no longer lists are
    /// dropped. That is what keeps a profile honest after its base URL changes:
    /// the previous backend's models would otherwise stay behind and be
    /// advertised to Claude Desktop, which would then ask this backend for a
    /// model it has never heard of. Hand-added entries are never dropped —
    /// some backends serve models their `/v1/models` never mentions — so those
    /// are only reported.
    public static func reconcile(
        existing: [ModelMapping],
        discovered: [DiscoveredModel]
    ) -> Reconciliation {
        let known = Set(existing.map(\.upstreamID))
        let served = Set(discovered.map(\.id))

        // A blank row is one the user is still typing, not a stale entry.
        func isStale(_ model: ModelMapping) -> Bool {
            !model.upstreamID.isEmpty && !served.contains(model.upstreamID)
        }

        let removed = existing.filter { isStale($0) && $0.isDiscoveryOwned }
        let unavailable = existing.filter { isStale($0) && !$0.isDiscoveryOwned }

        var models = existing.filter { !isStale($0) || !$0.isDiscoveryOwned }
        var added = 0
        for model in discovered where !known.contains(model.id) {
            models.append(ModelMapping(
                upstreamID: model.id,
                displayName: model.displayName,
                tier: model.suggestedTier ?? inferTier(from: model.id),
                origin: .discovered
            ))
            added += 1
        }

        return Reconciliation(
            models: withFamilyDefaults(models),
            added: added,
            removed: removed.map(\.upstreamID),
            unavailable: unavailable.map(\.upstreamID)
        )
    }

    /// Ensures every tier that has models has exactly one default.
    ///
    /// A tier with no default leaves Claude Desktop with nothing to route that
    /// family's work to — sub-agents in particular go to Haiku.
    public static func withFamilyDefaults(_ models: [ModelMapping]) -> [ModelMapping] {
        var models = models
        for tier in FamilyTier.allCases {
            let inTier = models.indices.filter { models[$0].tier == tier }
            guard !inTier.isEmpty else { continue }
            let defaults = inTier.filter { models[$0].isFamilyDefault }
            if defaults.isEmpty {
                models[inTier[0]].isFamilyDefault = true
            } else {
                // Keep only the first; several defaults in one tier is
                // ambiguous and Claude Desktop just takes the first anyway.
                for index in defaults.dropFirst() { models[index].isFamilyDefault = false }
            }
        }
        return models
    }

    /// A first guess at which Claude family a model should stand in for, based
    /// on its parameter count. Only a default — the point of the tier is to
    /// tell Claude Desktop which sub-agent work to route where, and the user
    /// knows their models better than a name pattern does.
    public static func inferTier(from id: String) -> FamilyTier {
        let lower = id.lowercased()
        if lower.contains("opus") { return .opus }
        if lower.contains("haiku") { return .haiku }
        if lower.contains("sonnet") { return .sonnet }

        // Match a parameter count like "30b", "7b", "235b-a22b".
        if let match = lower.range(of: #"(\d+(?:\.\d+)?)b"#, options: .regularExpression) {
            let digits = lower[match].dropLast()
            if let billions = Double(digits) {
                if billions >= 60 { return .opus }
                if billions <= 9 { return .haiku }
                return .sonnet
            }
        }
        return .sonnet
    }
}
