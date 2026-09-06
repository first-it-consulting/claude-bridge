import Foundation

/// Known providers, so a new profile is two clicks rather than a URL hunt.
public struct BackendPreset: Sendable, Identifiable, Hashable {
    public var id: String { name }
    public var name: String
    public var baseURL: String
    public var kind: BackendKind
    public var authScheme: AuthScheme
    public var requiresKey: Bool
    /// Shown under the field when the URL usually needs editing.
    public var note: String?

    public static let all: [BackendPreset] = [
        .init(name: "Ollama", baseURL: "http://localhost:11434/v1",
              kind: .openai, authScheme: .none, requiresKey: false, note: nil),
        .init(name: "LM Studio", baseURL: "http://localhost:1234/v1",
              kind: .openai, authScheme: .none, requiresKey: false, note: nil),
        .init(name: "llama.cpp server", baseURL: "http://localhost:8080/v1",
              kind: .openai, authScheme: .none, requiresKey: false, note: nil),
        .init(name: "vLLM", baseURL: "http://localhost:8000/v1",
              kind: .openai, authScheme: .bearer, requiresKey: false, note: nil),
        .init(name: "LiteLLM (OpenAI routes)", baseURL: "http://localhost:4000/v1",
              kind: .openai, authScheme: .bearer, requiresKey: true, note: nil),
        .init(name: "LiteLLM (Anthropic passthrough)", baseURL: "http://localhost:4000",
              kind: .anthropic, authScheme: .bearer, requiresKey: true,
              note: "Use this when your LiteLLM routes already serve Claude models on /v1/messages."),
        .init(name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1",
              kind: .openai, authScheme: .bearer, requiresKey: true, note: nil),
        .init(name: "Groq", baseURL: "https://api.groq.com/openai/v1",
              kind: .openai, authScheme: .bearer, requiresKey: true, note: nil),
        .init(name: "Together AI", baseURL: "https://api.together.xyz/v1",
              kind: .openai, authScheme: .bearer, requiresKey: true, note: nil),
        .init(name: "Anthropic API", baseURL: "https://api.anthropic.com",
              kind: .anthropic, authScheme: .xApiKey, requiresKey: true, note: nil),
        .init(name: "Custom", baseURL: "http://localhost:8000/v1",
              kind: .openai, authScheme: .none, requiresKey: false, note: nil),
    ]

    public func makeProfile(named name: String? = nil) -> Profile {
        Profile(
            name: name ?? self.name,
            backend: Backend(
                kind: kind,
                baseURL: baseURL,
                authScheme: authScheme,
                keychainAccount: requiresKey ? UUID().uuidString : nil
            )
        )
    }

    /// What a fresh install starts with. Ollama is the common case and costs
    /// nothing to include even when it isn't installed — the health check just
    /// reports it as unreachable.
    public static func starterProfiles() -> [Profile] {
        [all[0].makeProfile(named: "Ollama (local)")]
    }
}
