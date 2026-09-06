import Foundation

/// Translates a non-streamed OpenAI `/chat/completions` response into an
/// Anthropic `message`.
public enum OpenAIResponseTranslator {

    public static func translate(
        openai res: JSONValue,
        requestModel: String,
        reasoning: ReasoningMode
    ) -> JSONValue {
        let choice = res["choices"]?[0]
        let message = choice?["message"]

        var content: [JSONValue] = []

        if reasoning == .asText, let thought = reasoningText(of: message), !thought.isEmpty {
            content.append(.object(["type": "text", "text": .string(thought)]))
        }

        if let text = message?["content"]?.stringValue, !text.isEmpty {
            content.append(.object(["type": "text", "text": .string(text)]))
        }

        for call in message?["tool_calls"]?.arrayValue ?? [] {
            guard let fn = call["function"] else { continue }
            let argumentsJSON = fn["arguments"]?.stringValue ?? "{}"
            content.append(.object([
                "type": "tool_use",
                "id": call["id"] ?? .string("toolu_" + String(UUID().uuidString.prefix(12))),
                "name": fn["name"] ?? .string(""),
                // A backend that truncates its own arguments string would
                // otherwise take the whole response down; an empty object at
                // least reaches the model as a malformed-call it can retry.
                "input": JSONValue.lenient(argumentsJSON) ?? .object([:]),
            ]))
        }

        // Anthropic requires at least one content block.
        if content.isEmpty {
            content.append(.object(["type": "text", "text": ""]))
        }

        let finish = choice?["finish_reason"]?.stringValue
        let hasToolUse = content.contains { $0["type"]?.stringValue == "tool_use" }

        return .object([
            "id": .string(anthropicMessageID(from: res["id"]?.stringValue)),
            "type": "message",
            "role": "assistant",
            "model": .string(requestModel),
            "content": .array(content),
            "stop_reason": .string(stopReason(finish: finish, hasToolUse: hasToolUse)),
            "stop_sequence": .null,
            "usage": usage(from: res["usage"]),
        ])
    }

    /// Reasoning models expose their scratchpad under several different keys
    /// depending on which server is in front of them.
    static func reasoningText(of message: JSONValue?) -> String? {
        guard let message else { return nil }
        for key in ["reasoning_content", "reasoning", "thinking"] {
            if let s = message[key]?.stringValue, !s.isEmpty { return s }
        }
        return nil
    }

    public static func stopReason(finish: String?, hasToolUse: Bool) -> String {
        if hasToolUse { return "tool_use" }
        switch finish {
        case "length": return "max_tokens"
        case "tool_calls", "function_call": return "tool_use"
        case "stop", "content_filter", nil: return "end_turn"
        default: return "end_turn"
        }
    }

    public static func usage(from openaiUsage: JSONValue?) -> JSONValue {
        let input = openaiUsage?["prompt_tokens"]?.intValue ?? 0
        let output = openaiUsage?["completion_tokens"]?.intValue ?? 0
        // OpenAI reports cached tokens as a *subset* of prompt_tokens, whereas
        // Anthropic reports them as a separate bucket alongside input_tokens.
        let cached = openaiUsage?["prompt_tokens_details"]?["cached_tokens"]?.intValue ?? 0

        return .object([
            "input_tokens": .number(Double(max(0, input - cached))),
            "output_tokens": .number(Double(output)),
            "cache_read_input_tokens": .number(Double(cached)),
            "cache_creation_input_tokens": 0,
        ])
    }

    static func anthropicMessageID(from openaiID: String?) -> String {
        guard let openaiID, !openaiID.isEmpty else {
            return "msg_" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24))
        }
        return "msg_" + openaiID.replacingOccurrences(of: "chatcmpl-", with: "")
    }
}
