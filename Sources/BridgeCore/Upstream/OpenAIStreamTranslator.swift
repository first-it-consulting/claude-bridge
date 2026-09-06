import Foundation

/// Turns an OpenAI `/chat/completions` SSE stream into an Anthropic Messages
/// SSE stream.
///
/// Anthropic's protocol is stricter than OpenAI's: content arrives as numbered
/// blocks that must be opened and closed in order, and exactly one block may be
/// open at a time. OpenAI just emits deltas. This type holds the block
/// bookkeeping in between — opening a block lazily on the first delta that
/// needs it, and closing it when the stream switches to a different kind of
/// content.
public struct OpenAIStreamTranslator: Sendable {

    private enum OpenBlock: Equatable {
        case text
        /// `callIndex` is OpenAI's index within its `tool_calls` array, which
        /// is what identifies which call an argument fragment belongs to.
        case toolUse(callIndex: Int)
    }

    private let requestModel: String
    private let reasoning: ReasoningMode
    /// Claude Desktop shows a token count from the moment the stream opens, so
    /// `message_start` needs a number before the backend has reported one.
    private let estimatedInputTokens: Int

    private var messageID: String?
    private var started = false
    private var stopped = false
    private var nextBlockIndex = 0
    private var openBlock: OpenBlock?
    private var openBlockIndex = 0
    private var emittedToolUse = false
    private var finishReason: String?
    private var finalUsage: JSONValue?
    private var outputTokenEstimate = 0

    public init(requestModel: String, reasoning: ReasoningMode, estimatedInputTokens: Int) {
        self.requestModel = requestModel
        self.reasoning = reasoning
        self.estimatedInputTokens = estimatedInputTokens
    }

    // MARK: - Ingest

    /// Consumes one upstream SSE event and returns the Anthropic events it
    /// produces. Returns an empty array for events that carry no new content.
    public mutating func ingest(_ event: SSEEvent) -> [SSEEvent] {
        guard !stopped else { return [] }

        // OpenAI terminates with a literal `data: [DONE]`.
        if event.data.trimmingCharacters(in: .whitespaces) == "[DONE]" {
            return finish()
        }
        guard let chunk = JSONValue.lenient(event.data) else { return [] }

        var out: [SSEEvent] = []

        if let id = chunk["id"]?.stringValue, messageID == nil {
            messageID = OpenAIResponseTranslator.anthropicMessageID(from: id)
        }
        // A usage-only trailer chunk carries no choices.
        if let usage = chunk["usage"], !usage.isNull {
            finalUsage = usage
        }

        out.append(contentsOf: startIfNeeded())

        guard let choice = chunk["choices"]?[0] else { return out }
        if let reason = choice["finish_reason"]?.stringValue, !reason.isEmpty {
            finishReason = reason
        }

        guard let delta = choice["delta"] else { return out }

        if reasoning == .asText, let thought = reasoningDelta(delta), !thought.isEmpty {
            out.append(contentsOf: appendText(thought))
        }

        if let text = delta["content"]?.stringValue, !text.isEmpty {
            out.append(contentsOf: appendText(text))
        }

        for call in delta["tool_calls"]?.arrayValue ?? [] {
            out.append(contentsOf: appendToolCall(call))
        }

        return out
    }

    /// Closes out the stream. Safe to call more than once.
    public mutating func finish() -> [SSEEvent] {
        guard !stopped else { return [] }
        var out = startIfNeeded()
        out.append(contentsOf: closeOpenBlock())
        stopped = true

        let stop = OpenAIResponseTranslator.stopReason(finish: finishReason, hasToolUse: emittedToolUse)
        out.append(SSEEvent(name: "message_delta", json: .object([
            "type": "message_delta",
            "delta": .object(["stop_reason": .string(stop), "stop_sequence": .null]),
            "usage": finalUsage.map { OpenAIResponseTranslator.usage(from: $0) }
                ?? .object([
                    "input_tokens": .number(Double(estimatedInputTokens)),
                    "output_tokens": .number(Double(outputTokenEstimate)),
                ]),
        ])))
        out.append(SSEEvent(name: "message_stop", json: .object(["type": "message_stop"])))
        return out
    }

    /// Emits a terminal `error` event for an upstream failure mid-stream.
    /// Once the response headers are out the only way to report a problem is
    /// inside the stream itself.
    public mutating func fail(type: String, message: String) -> [SSEEvent] {
        guard !stopped else { return [] }
        stopped = true
        return [SSEEvent(name: "error", json: .object([
            "type": "error",
            "error": .object(["type": .string(type), "message": .string(message)]),
        ]))]
    }

    public var hasStarted: Bool { started }

    // MARK: - Block bookkeeping

    private mutating func startIfNeeded() -> [SSEEvent] {
        guard !started else { return [] }
        started = true
        let id = messageID ?? ("msg_" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24)))
        messageID = id
        return [SSEEvent(name: "message_start", json: .object([
            "type": "message_start",
            "message": .object([
                "id": .string(id),
                "type": "message",
                "role": "assistant",
                "model": .string(requestModel),
                "content": .array([]),
                "stop_reason": .null,
                "stop_sequence": .null,
                "usage": .object([
                    "input_tokens": .number(Double(estimatedInputTokens)),
                    "output_tokens": 0,
                ]),
            ]),
        ]))]
    }

    private mutating func appendText(_ text: String) -> [SSEEvent] {
        var out: [SSEEvent] = []
        if openBlock != .text {
            out.append(contentsOf: closeOpenBlock())
            openBlockIndex = nextBlockIndex
            nextBlockIndex += 1
            openBlock = .text
            out.append(SSEEvent(name: "content_block_start", json: .object([
                "type": "content_block_start",
                "index": .number(Double(openBlockIndex)),
                "content_block": .object(["type": "text", "text": ""]),
            ])))
        }
        outputTokenEstimate += max(1, text.count / 4)
        out.append(SSEEvent(name: "content_block_delta", json: .object([
            "type": "content_block_delta",
            "index": .number(Double(openBlockIndex)),
            "delta": .object(["type": "text_delta", "text": .string(text)]),
        ])))
        return out
    }

    private mutating func appendToolCall(_ call: JSONValue) -> [SSEEvent] {
        // Backends that stream a single call sometimes omit `index`.
        let callIndex = call["index"]?.intValue ?? 0
        var out: [SSEEvent] = []

        if openBlock != .toolUse(callIndex: callIndex) {
            out.append(contentsOf: closeOpenBlock())
            openBlockIndex = nextBlockIndex
            nextBlockIndex += 1
            openBlock = .toolUse(callIndex: callIndex)
            emittedToolUse = true
            out.append(SSEEvent(name: "content_block_start", json: .object([
                "type": "content_block_start",
                "index": .number(Double(openBlockIndex)),
                "content_block": .object([
                    "type": "tool_use",
                    "id": call["id"] ?? .string("toolu_" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16))),
                    "name": call["function"]?["name"] ?? .string(""),
                    "input": .object([:]),
                ]),
            ])))
        }

        // The name can arrive on the opening fragment only, or be split across
        // fragments; argument text always streams in pieces.
        if let fragment = call["function"]?["arguments"]?.stringValue, !fragment.isEmpty {
            outputTokenEstimate += max(1, fragment.count / 4)
            out.append(SSEEvent(name: "content_block_delta", json: .object([
                "type": "content_block_delta",
                "index": .number(Double(openBlockIndex)),
                "delta": .object(["type": "input_json_delta", "partial_json": .string(fragment)]),
            ])))
        }
        return out
    }

    private mutating func closeOpenBlock() -> [SSEEvent] {
        guard openBlock != nil else { return [] }
        openBlock = nil
        return [SSEEvent(name: "content_block_stop", json: .object([
            "type": "content_block_stop",
            "index": .number(Double(openBlockIndex)),
        ]))]
    }

    private func reasoningDelta(_ delta: JSONValue) -> String? {
        for key in ["reasoning_content", "reasoning", "thinking"] {
            if let s = delta[key]?.stringValue, !s.isEmpty { return s }
        }
        return nil
    }
}
