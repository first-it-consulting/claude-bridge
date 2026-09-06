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

    @Test("a blank row is cleared rather than reported as stale")
    func ignoresBlankRows() {
        let result = ModelCatalog.reconcile(
            existing: [ModelMapping(upstreamID: "")],
            discovered: discovered("a:1")
        )
        #expect(result.unavailable.isEmpty)
        #expect(result.removed.isEmpty)
        #expect(!result.models.contains { $0.upstreamID.isEmpty })
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

@Suite("One model backing several tiers")
struct SharedModelTests {

    /// A machine with limited VRAM keeps one model loaded and wants every tier
    /// to route to it.
    func sharedProfile() -> Profile {
        Profile(name: "p", models: [
            ModelMapping(upstreamID: "qwen3-coder-next:latest", tier: .sonnet, isFamilyDefault: true),
            ModelMapping(upstreamID: "qwen3-coder-next:latest", tier: .haiku, isFamilyDefault: true),
            ModelMapping(upstreamID: "qwen3-coder-next:latest", tier: .opus, isFamilyDefault: true),
        ])
    }

    /// The pattern Claude Desktop accepts unconditionally, from its own
    /// source: `^(sonnet|opus|haiku|fable|mythos)(-[\d.]+)?$`.
    static func isTierAlias(_ id: String) -> Bool {
        id.wholeMatch(of: /^(sonnet|opus|haiku|fable|mythos)(-[\d.]+)?$/) != nil
    }

    /// The vendor denylist Claude Desktop applies to every other id. Any of
    /// these substrings and the model never reaches the picker, whatever its
    /// anthropic_family_tier says.
    static let vendorDenylist = ["qwen", "llama", "gemma", "gpt", "mistral", "deepseek", "glm"]

    @Test("advertised ids are tier aliases, which is the only form the picker accepts")
    func advertisedIDsPassClaudeDesktopFilter() {
        let served = sharedProfile().servedModels
        let ids = served.map(\.advertisedID)
        #expect(Set(ids).count == ids.count)

        for id in ids {
            #expect(Self.isTierAlias(id), "\(id) would be rejected by the picker")
            let lower = id.lowercased()
            #expect(!Self.vendorDenylist.contains { lower.contains($0) })
        }
    }

    @Test("the real model name still reaches the picker as the display name")
    func displayNameCarriesTheRealModel() {
        let data = ModelCatalog.modelsResponse(for: sharedProfile())["data"]!.arrayValue!
        for entry in data {
            #expect(entry["display_name"]?.stringValue == "qwen3-coder-next:latest")
        }
    }

    @Test("several models in one tier get numbered ids")
    func numberedWithinTier() {
        let profile = Profile(name: "p", models: [
            ModelMapping(upstreamID: "a", tier: .sonnet),
            ModelMapping(upstreamID: "b", tier: .sonnet),
            ModelMapping(upstreamID: "c", tier: .sonnet),
        ])
        #expect(profile.servedModels.map(\.advertisedID) == ["sonnet", "sonnet-2", "sonnet-3"])
        for entry in profile.servedModels {
            #expect(Self.isTierAlias(entry.advertisedID))
        }
    }

    @Test("every tier is served and flagged as its own default")
    func perTierDefaults() {
        let data = ModelCatalog.modelsResponse(for: sharedProfile())["data"]!.arrayValue!
        let defaults = data.filter { $0["is_family_default"]?.boolValue == true }
        #expect(Set(defaults.compactMap { $0["anthropic_family_tier"]?.stringValue })
                == ["sonnet", "haiku", "opus"])
    }

    @Test("an aliased id resolves back to the real model name")
    func aliasResolvesToUpstream() async {
        let router = BridgeRouter(
            profile: sharedProfile(), apiKey: nil, token: "", log: RequestLog()
        )
        let haiku = await router.resolveModel(requested: "haiku")
        #expect(haiku?.upstreamID == "qwen3-coder-next:latest")
        #expect(haiku?.tier == .haiku)

        let opus = await router.resolveModel(requested: "opus")
        #expect(opus?.tier == .opus)

        // Claude Desktop also sends the real name back in some flows.
        let plain = await router.resolveModel(requested: "qwen3-coder-next:latest")
        #expect(plain?.tier == .sonnet)
    }

    @Test("an explicit label wins over the model name")
    func explicitLabel() {
        let profile = Profile(name: "p", models: [
            ModelMapping(upstreamID: "m", tier: .sonnet),
            ModelMapping(upstreamID: "m", displayName: "Fast lane", tier: .haiku),
        ])
        #expect(profile.servedModels[1].displayName == "Fast lane")
    }

    @Test("a numbered alias resolves to the right model")
    func numberedAliasResolves() async {
        let profile = Profile(name: "p", models: [
            ModelMapping(upstreamID: "first", tier: .sonnet),
            ModelMapping(upstreamID: "second", tier: .sonnet),
        ])
        let router = BridgeRouter(profile: profile, apiKey: nil, token: "", log: RequestLog())
        #expect(await router.resolveModel(requested: "sonnet-2")?.upstreamID == "second")
        #expect(await router.resolveModel(requested: "sonnet")?.upstreamID == "first")
    }
}

@Suite("Blank row cleanup")
struct BlankRowTests {
    @Test("rows left without an ID are cleared on reconciliation")
    func dropsBlankRows() {
        let existing = [
            ModelMapping(upstreamID: "a:1", origin: .discovered),
            ModelMapping(upstreamID: "", tier: .haiku, origin: .manual),
            ModelMapping(upstreamID: "   ", origin: .manual),
        ]
        let result = ModelCatalog.reconcile(
            existing: existing,
            discovered: [ModelCatalog.DiscoveredModel(id: "a:1")]
        )
        #expect(result.models.map(\.upstreamID) == ["a:1"])
        // Not reported as stale — they were never real entries.
        #expect(result.removed.isEmpty)
        #expect(result.unavailable.isEmpty)
    }
}
