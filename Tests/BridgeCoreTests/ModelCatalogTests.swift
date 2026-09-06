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

    @Test("models the backend does not list are reported, not deleted")
    func reportsStale() {
        // The reported bug: a profile pointed at one backend, discovered, then
        // pointed back at another keeps the first backend's models forever.
        let existing = [
            ModelMapping(upstreamID: "qwen3-coder-next:latest"),
            ModelMapping(upstreamID: "Ornith-1.5-35B-A3B-MLX"),
        ]
        let result = ModelCatalog.reconcile(
            existing: existing,
            discovered: discovered("qwen3-coder-next:latest", "gemma4:31b-mlx")
        )
        #expect(result.unavailable == ["Ornith-1.5-35B-A3B-MLX"])
        // Still present: removal is an explicit choice, because a backend with
        // no /v1/models endpoint lists nothing while its models work fine.
        #expect(result.models.contains { $0.upstreamID == "Ornith-1.5-35B-A3B-MLX" })
    }

    @Test("a blank row being typed is not treated as stale")
    func ignoresBlankRows() {
        let result = ModelCatalog.reconcile(
            existing: [ModelMapping(upstreamID: "")],
            discovered: discovered("a:1")
        )
        #expect(result.unavailable.isEmpty)
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
