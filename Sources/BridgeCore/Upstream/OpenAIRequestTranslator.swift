import Foundation

/// Translates an Anthropic Messages API request into an OpenAI
/// `/chat/completions` request.
///
/// The two shapes differ in three ways that matter:
///
/// 1. Anthropic carries the system prompt in a top-level `system` field;
///    OpenAI carries it as the first message.
/// 2. Anthropic puts tool results in *user* messages as `tool_result` blocks;
///    OpenAI needs a separate `tool` message per result, placed immediately
///    after the assistant turn that made the calls.
/// 3. Anthropic tool schemas live under `input_schema`; OpenAI nests them under
///    `function.parameters`.
public enum OpenAIRequestTranslator {

    public struct Options: Sendable {
        public var model: String
        public var maxOutputTokens: Int?
        public var supportsTools: Bool
        public var stream: Bool

        public init(model: String, maxOutputTokens: Int? = nil, supportsTools: Bool = true, stream: Bool) {
            self.model = model
            self.maxOutputTokens = maxOutputTokens
            self.supportsTools = supportsTools
            self.stream = stream
        }
    }

    public static func translate(anthropic req: JSONValue, options: Options) -> JSONValue {
        var out: [String: JSONValue] = [:]
        out["model"] = .string(options.model)

        var messages: [JSONValue] = []

        // System prompt: string or array of text blocks.
        if let system = req["system"], !system.isNull {
            let text = flattenText(system)
            if !text.isEmpty {
                messages.append(.object(["role": "system", "content": .string(text)]))
            }
        }

        for message in req["messages"]?.arrayValue ?? [] {
            messages.append(contentsOf: convertMessage(message))
        }
        out["messages"] = .array(messages)

        // max_tokens is required by Anthropic and optional for OpenAI; clamp it
        // when the operator says the backend cannot go that high.
        if let requested = req["max_tokens"]?.intValue {
            let value = options.maxOutputTokens.map { min($0, requested) } ?? requested
            out["max_tokens"] = .number(Double(value))
        } else if let cap = options.maxOutputTokens {
            out["max_tokens"] = .number(Double(cap))
        }

        for key in ["temperature", "top_p"] {
            if let v = req[key], !v.isNull { out[key] = v }
        }
        // `top_k` has no OpenAI equivalent and strict backends reject it.

        if let stops = req["stop_sequences"]?.arrayValue, !stops.isEmpty {
            out["stop"] = .array(stops)
        }

        if options.stream {
            out["stream"] = .bool(true)
            // Without this most backends omit usage entirely on streamed
            // responses, and Claude Desktop's usage panel stays empty.
            out["stream_options"] = .object(["include_usage": .bool(true)])
        }

        if options.supportsTools, let tools = req["tools"]?.arrayValue, !tools.isEmpty {
            let converted = tools.compactMap(convertTool)
            if !converted.isEmpty {
                out["tools"] = .array(converted)
                if let choice = req["tool_choice"], let mapped = convertToolChoice(choice) {
                    out["tool_choice"] = mapped
                }
            }
        }

        // Anthropic prompt-caching breakpoints are meaningless downstream and
        // make strict backends reject the content block outright.
        return JSONValue.object(out).removingKeyRecursively("cache_control")
    }

    // MARK: - Messages

    /// One Anthropic message can become several OpenAI messages: an assistant
    /// turn with tool calls stays one message, but a user turn carrying tool
    /// results becomes one `tool` message per result plus, if there is any
    /// other content, a trailing `user` message.
    static func convertMessage(_ message: JSONValue) -> [JSONValue] {
        let role = message["role"]?.stringValue ?? "user"
        guard let content = message["content"] else { return [] }

        // Plain string content is the common case for short user turns.
        if let text = content.stringValue {
            guard !text.isEmpty else { return [] }
            return [.object(["role": .string(role), "content": .string(text)])]
        }

        guard let blocks = content.arrayValue else { return [] }

        if role == "assistant" {
            return [convertAssistantMessage(blocks)]
        }
        return convertUserMessage(blocks)
    }

    static func convertAssistantMessage(_ blocks: [JSONValue]) -> JSONValue {
        var text = ""
        var toolCalls: [JSONValue] = []

        for block in blocks {
            switch block["type"]?.stringValue {
            case "text":
                text += block["text"]?.stringValue ?? ""
            case "tool_use":
                let args = block["input"] ?? .object([:])
                toolCalls.append(.object([
                    "id": block["id"] ?? .string("call_" + String(UUID().uuidString.prefix(8))),
                    "type": "function",
                    "function": .object([
                        "name": block["name"] ?? .string(""),
                        // OpenAI wants arguments as a JSON *string*.
                        "arguments": .string(args.compactString),
                    ]),
                ]))
            default:
                // `thinking` and `redacted_thinking` are dropped: the signature
                // they carry is Anthropic-issued and no other backend can
                // validate or reproduce it.
                continue
            }
        }

        var msg: [String: JSONValue] = ["role": "assistant"]
        // An assistant turn that is only tool calls must still carry `content`;
        // several backends reject the message when the key is missing.
        msg["content"] = text.isEmpty ? .null : .string(text)
        if !toolCalls.isEmpty { msg["tool_calls"] = .array(toolCalls) }
        return .object(msg)
    }

    static func convertUserMessage(_ blocks: [JSONValue]) -> [JSONValue] {
        var toolMessages: [JSONValue] = []
        var parts: [JSONValue] = []

        for block in blocks {
            switch block["type"]?.stringValue {
            case "tool_result":
                let body = block["content"].map(flattenText) ?? ""
                let isError = block["is_error"]?.boolValue ?? false
                toolMessages.append(.object([
                    "role": "tool",
                    "tool_call_id": block["tool_use_id"] ?? .string(""),
                    "content": .string(isError ? "Error: " + body : body),
                ]))
            case "text":
                let t = block["text"]?.stringValue ?? ""
                if !t.isEmpty { parts.append(.object(["type": "text", "text": .string(t)])) }
            case "image":
                if let part = convertImage(block) { parts.append(part) }
            default:
                continue
            }
        }

        // Tool results first: OpenAI requires them to answer the immediately
        // preceding assistant tool_calls turn before any new user content.
        var result = toolMessages
        if !parts.isEmpty {
            // Collapse a pure-text array back to a plain string; a few backends
            // only accept the array form when an image is present.
            if parts.count == 1, let only = parts.first, only["type"]?.stringValue == "text" {
                result.append(.object(["role": "user", "content": only["text"] ?? .string("")]))
            } else {
                result.append(.object(["role": "user", "content": .array(parts)]))
            }
        }
        return result
    }

    static func convertImage(_ block: JSONValue) -> JSONValue? {
        guard let source = block["source"] else { return nil }
        switch source["type"]?.stringValue {
        case "base64":
            guard let media = source["media_type"]?.stringValue,
                  let data = source["data"]?.stringValue else { return nil }
            return .object([
                "type": "image_url",
                "image_url": .object(["url": .string("data:\(media);base64,\(data)")]),
            ])
        case "url":
            guard let url = source["url"]?.stringValue else { return nil }
            return .object(["type": "image_url", "image_url": .object(["url": .string(url)])])
        default:
            return nil
        }
    }

    // MARK: - Tools

    static func convertTool(_ tool: JSONValue) -> JSONValue? {
        guard let name = tool["name"]?.stringValue else { return nil }
        // Anthropic server-side tools (web_search, computer, text_editor) have
        // no `input_schema` and no OpenAI equivalent; skip rather than send a
        // function the backend cannot honour.
        guard let schema = tool["input_schema"], schema.objectValue != nil else { return nil }

        var function: [String: JSONValue] = ["name": .string(name), "parameters": schema]
        if let description = tool["description"], !description.isNull {
            function["description"] = description
        }
        return .object(["type": "function", "function": .object(function)])
    }

    static func convertToolChoice(_ choice: JSONValue) -> JSONValue? {
        switch choice["type"]?.stringValue {
        case "auto": return .string("auto")
        case "any": return .string("required")
        case "none": return .string("none")
        case "tool":
            guard let name = choice["name"]?.stringValue else { return .string("auto") }
            return .object([
                "type": "function",
                "function": .object(["name": .string(name)]),
            ])
        default:
            return nil
        }
    }

    // MARK: - Helpers

    /// Reduces a string, a block, or an array of blocks to plain text.
    static func flattenText(_ value: JSONValue) -> String {
        if let s = value.stringValue { return s }
        if let blocks = value.arrayValue {
            return blocks.map(flattenText).filter { !$0.isEmpty }.joined(separator: "\n")
        }
        if value.objectValue != nil {
            if let t = value["text"]?.stringValue { return t }
            // A tool_result whose content is a nested block array.
            if let c = value["content"] { return flattenText(c) }
        }
        return ""
    }
}
