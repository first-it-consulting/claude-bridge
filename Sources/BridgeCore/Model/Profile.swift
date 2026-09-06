import Foundation

/// The Claude model families Claude Desktop knows about. A backend model is
/// advertised under one of these tiers so it survives Claude Desktop's
/// "is this recognisably a Claude model?" discovery filter.
public enum FamilyTier: String, Codable, CaseIterable, Sendable {
    case haiku, sonnet, opus

    public var displayName: String {
        switch self {
        case .haiku: return "Haiku"
        case .sonnet: return "Sonnet"
        case .opus: return "Opus"
        }
    }
}

/// Which wire protocol the upstream provider speaks.
public enum BackendKind: String, Codable, CaseIterable, Sendable {
    /// OpenAI `/chat/completions`. Ollama, LM Studio, llama.cpp, vLLM,
    /// OpenRouter, Groq, Together, and most everything else.
    case openai
    /// Anthropic `/v1/messages`. LiteLLM in passthrough, Portkey, Bedrock
    /// proxies, api.anthropic.com itself.
    case anthropic
}

/// How the upstream credential is presented.
public enum AuthScheme: String, Codable, CaseIterable, Sendable {
    case bearer      // Authorization: Bearer <key>
    case xApiKey     // x-api-key: <key>
    case none

    public var displayName: String {
        switch self {
        case .bearer: return "Bearer"
        case .xApiKey: return "x-api-key"
        case .none: return "None"
        }
    }
}

/// What to do with `reasoning_content` / `reasoning` deltas that reasoning
/// models (qwen3, gpt-oss, deepseek-r1) emit alongside their answer.
///
/// Anthropic `thinking` blocks carry a signature that Claude Desktop replays on
/// the next turn and an OpenAI backend cannot produce, so the default is to
/// drop reasoning rather than forge one.
public enum ReasoningMode: String, Codable, CaseIterable, Sendable {
    case drop
    case asText

    public var displayName: String {
        switch self {
        case .drop: return "Discard"
        case .asText: return "Show as text"
        }
    }
}

/// One upstream endpoint.
public struct Backend: Codable, Hashable, Sendable {
    public var kind: BackendKind
    /// Base URL including any version prefix the provider expects, e.g.
    /// `http://localhost:11434/v1`. The bridge appends `/chat/completions`
    /// or `/messages`.
    public var baseURL: String
    public var authScheme: AuthScheme
    /// Keychain account holding the API key. The key itself never touches disk.
    public var keychainAccount: String?
    public var extraHeaders: [String: String]
    public var reasoningMode: ReasoningMode
    /// Seconds to wait for the upstream response.
    public var requestTimeout: Double

    public init(
        kind: BackendKind = .openai,
        baseURL: String = "http://localhost:11434/v1",
        authScheme: AuthScheme = .none,
        keychainAccount: String? = nil,
        extraHeaders: [String: String] = [:],
        reasoningMode: ReasoningMode = .drop,
        requestTimeout: Double = 600
    ) {
        self.kind = kind
        self.baseURL = baseURL
        self.authScheme = authScheme
        self.keychainAccount = keychainAccount
        self.extraHeaders = extraHeaders
        self.reasoningMode = reasoningMode
        self.requestTimeout = requestTimeout
    }

    /// `baseURL` with any trailing slash removed.
    public var normalizedBase: String {
        var s = baseURL.trimmingCharacters(in: .whitespaces)
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    public func endpointURL(path: String) -> URL? {
        URL(string: normalizedBase + path)
    }
}

/// Where a model entry came from, which decides whether discovery may remove
/// it again.
public enum ModelOrigin: String, Codable, Sendable {
    /// Listed by the backend. Discovery owns it, so discovery may drop it when
    /// the backend stops listing it.
    case discovered
    /// Typed in by hand. Kept even when the backend does not advertise it —
    /// some backends serve models their `/v1/models` never mentions.
    case manual
}

/// One backend model, and how it should appear in Claude Desktop's picker.
public struct ModelMapping: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// The model ID the upstream expects, e.g. `qwen3-coder:30b`.
    public var upstreamID: String
    /// Label shown in Claude Desktop. Defaults to `upstreamID`.
    public var displayName: String?
    public var tier: FamilyTier
    /// Winner when several models claim the same tier.
    public var isFamilyDefault: Bool
    public var enabled: Bool
    /// Clamp for `max_tokens` when the backend has a smaller ceiling than the
    /// value Claude Desktop asks for. `nil` passes the request through.
    public var maxOutputTokens: Int?
    /// When false the bridge strips `tools` from the request instead of
    /// letting the backend reject it.
    public var supportsTools: Bool
    /// Optional so settings written before this existed still decode; those
    /// entries were all produced by discovery, so they are treated as such.
    public var origin: ModelOrigin?

    public init(
        id: UUID = UUID(),
        upstreamID: String,
        displayName: String? = nil,
        tier: FamilyTier = .sonnet,
        isFamilyDefault: Bool = false,
        enabled: Bool = true,
        maxOutputTokens: Int? = nil,
        supportsTools: Bool = true,
        origin: ModelOrigin? = nil
    ) {
        self.id = id
        self.upstreamID = upstreamID
        self.displayName = displayName
        self.tier = tier
        self.isFamilyDefault = isFamilyDefault
        self.enabled = enabled
        self.maxOutputTokens = maxOutputTokens
        self.supportsTools = supportsTools
        self.origin = origin
    }

    /// Whether discovery is allowed to remove this entry.
    public var isDiscoveryOwned: Bool { (origin ?? .discovered) == .discovered }

    public var label: String {
        if let name = displayName?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            return name
        }
        return upstreamID
    }
}

/// A named, switchable configuration: one backend plus its model list.
public struct Profile: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var backend: Backend
    public var models: [ModelMapping]
    /// Ask the backend for its model list and merge anything new in.
    public var autoDiscoverModels: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        backend: Backend = Backend(),
        models: [ModelMapping] = [],
        autoDiscoverModels: Bool = true
    ) {
        self.id = id
        self.name = name
        self.backend = backend
        self.models = models
        self.autoDiscoverModels = autoDiscoverModels
    }

    /// The models the bridge will actually serve.
    ///
    /// A row whose ID is still blank is one the user is part-way through
    /// adding. Serving it would advertise a model with an empty id to Claude
    /// Desktop and put a nameless entry in its picker.
    public var enabledModels: [ModelMapping] {
        models.filter { $0.enabled && !$0.upstreamID.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// The mapping Claude Desktop should land on when it opens the picker:
    /// the flagged family default, else the first enabled model.
    public var defaultModel: ModelMapping? {
        enabledModels.first(where: \.isFamilyDefault) ?? enabledModels.first
    }
}
