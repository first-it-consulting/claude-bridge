import Testing
import Foundation
@testable import BridgeCore

@Suite("Model reconciliation")
struct ModelCatalogTests {

    func discovered(_ ids: String...) -> [ModelCatalog.DiscoveredModel] {
        ids.map { ModelCatalog.DiscoveredModel(id: $0, suggestedTier: .sonnet) }
    }

    @Test("new models are appended")
    func addsNew() {
        let result = ModelCatalog.reconcile(existing: [], discovered: discovered("a:1", "b:2"))
        #expect(result.added == 2)
        #expect(result.models.map(\.upstreamID) == ["a:1", "b:2"])
        #expect(result.models.allSatisfy { $0.origin == .discovered })
        #expect(result.unavailable.isEmpty)
    }

    @Test("existing entries keep the tier and label the user gave them")
    func preservesMapping() {
        let existing = [ModelMapping(upstreamID: "a:1", displayName: "Fast", tier: .haiku)]
        let result = ModelCatalog.reconcile(existing: existing, discovered: discovered("a:1", "b:2"))

        let kept = result.models.first { $0.upstreamID == "a:1" }
        #expect(kept?.tier == .haiku)
        #expect(kept?.displayName == "Fast")
        #expect(result.added == 1)
    }

    @Test("models discovery added and the backend dropped are removed")
    func prunesDiscovered() {
        // The reported bug: a profile pointed at one backend, discovered, then
        // pointed back keeps the first backend's models forever and advertises
        // them to Claude Desktop.
        let existing = [
            ModelMapping(upstreamID: "qwen3-coder-next:latest", origin: .discovered),
            ModelMapping(upstreamID: "Ornith-1.5-35B-A3B-MLX", origin: .discovered),
        ]
        let result = ModelCatalog.reconcile(
            existing: existing,
            discovered: discovered("qwen3-coder-next:latest", "gemma4:31b-mlx")
        )
        #expect(result.removed == ["Ornith-1.5-35B-A3B-MLX"])
        #expect(!result.models.contains { $0.upstreamID == "Ornith-1.5-35B-A3B-MLX" })
        #expect(result.unavailable.isEmpty)
    }

    @Test("hand-added models are kept and only reported")
    func keepsManual() {
        // Some backends serve models their /v1/models never lists, so a typed
        // entry must survive a discovery pass that does not mention it.
        let existing = [ModelMapping(upstreamID: "private-model", origin: .manual)]
        let result = ModelCatalog.reconcile(existing: existing, discovered: discovered("a:1"))

        #expect(result.unavailable == ["private-model"])
        #expect(result.removed.isEmpty)
        #expect(result.models.contains { $0.upstreamID == "private-model" })
    }

    @Test("entries from settings written before origin existed are prunable")
    func legacyEntriesAreDiscoveryOwned() {
        // Every model in an older settings file was put there by discovery, so
        // treating an absent origin as manual would strand exactly the stale
        // entries this change exists to clear.
        let legacy = ModelMapping(upstreamID: "Ornith-1.5-35B-A3B-MLX")
        #expect(legacy.origin == nil)
        #expect(legacy.isDiscoveryOwned)

        let result = ModelCatalog.reconcile(existing: [legacy], discovered: discovered("a:1"))
        #expect(result.removed == ["Ornith-1.5-35B-A3B-MLX"])
    }

    @Test("a blank row being typed is neither pruned nor flagged")
    func ignoresBlankRows() {
        let result = ModelCatalog.reconcile(
            existing: [ModelMapping(upstreamID: "")],
            discovered: discovered("a:1")
        )
        #expect(result.unavailable.isEmpty)
        #expect(result.removed.isEmpty)
        #expect(result.models.contains { $0.upstreamID.isEmpty })
    }

    @Test("every populated tier ends up with exactly one default")
    func familyDefaults() {
        let models = ModelCatalog.withFamilyDefaults([
            ModelMapping(upstreamID: "a", tier: .sonnet),
            ModelMapping(upstreamID: "b", tier: .sonnet, isFamilyDefault: true),
            ModelMapping(upstreamID: "c", tier: .sonnet, isFamilyDefault: true),
            ModelMapping(upstreamID: "d", tier: .haiku),
        ])
        #expect(models.filter { $0.tier == .sonnet && $0.isFamilyDefault }.count == 1)
        // The first already-flagged entry wins, matching how Claude Desktop
        // resolves several defaults in one tier.
        #expect(models.first { $0.isFamilyDefault && $0.tier == .sonnet }?.upstreamID == "b")
        // A tier with no flag gets one, or that family has nothing to route to.
        #expect(models.first { $0.tier == .haiku }?.isFamilyDefault == true)
    }

    @Test("tier is guessed from parameter count when the name has no family")
    func tierInference() {
        #expect(ModelCatalog.inferTier(from: "qwen3-8b-instruct") == .haiku)
        #expect(ModelCatalog.inferTier(from: "gemma4:31b-mlx") == .sonnet)
        #expect(ModelCatalog.inferTier(from: "llama-3.1-70b") == .opus)
        #expect(ModelCatalog.inferTier(from: "some-claude-opus-thing") == .opus)
        #expect(ModelCatalog.inferTier(from: "mystery-model") == .sonnet)
    }
}

@Suite("Served model list")
struct ServedModelsTests {

    @Test("a half-typed row is not advertised to Claude Desktop")
    func skipsBlankRows() {
        let profile = Profile(name: "p", models: [
            ModelMapping(upstreamID: "qwen3:8b"),
            ModelMapping(upstreamID: "   "),
            ModelMapping(upstreamID: ""),
        ])
        #expect(profile.enabledModels.map(\.upstreamID) == ["qwen3:8b"])

        let response = ModelCatalog.modelsResponse(for: profile)
        #expect(response["data"]?.arrayValue?.count == 1)
    }

    @Test("disabled models are not served")
    func skipsDisabled() {
        let profile = Profile(name: "p", models: [
            ModelMapping(upstreamID: "a", enabled: false),
            ModelMapping(upstreamID: "b"),
        ])
        #expect(profile.enabledModels.map(\.upstreamID) == ["b"])
    }

    @Test("only one model per tier is flagged as the family default")
    func oneDefaultPerTier() {
        let profile = Profile(name: "p", models: [
            ModelMapping(upstreamID: "a", tier: .sonnet, isFamilyDefault: true),
            ModelMapping(upstreamID: "b", tier: .sonnet, isFamilyDefault: true),
        ])
        let flagged = ModelCatalog.modelsResponse(for: profile)["data"]?.arrayValue?
            .filter { $0["is_family_default"]?.boolValue == true }
        #expect(flagged?.count == 1)
    }
}
