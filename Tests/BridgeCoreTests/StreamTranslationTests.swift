import Testing
import Foundation
@testable import BridgeCore

@Suite("OpenAI to Anthropic stream translation")
struct StreamTranslationTests {

    /// Feeds raw OpenAI chunk objects through and returns the Anthropic events.
    func run(_ chunks: [JSONValue], reasoning: ReasoningMode = .drop) -> [SSEEvent] {
        var translator = OpenAIStreamTranslator(
            requestModel: "qwen3:8b", reasoning: reasoning, estimatedInputTokens: 42
        )
        var out: [SSEEvent] = []
        for chunk in chunks {
            out += translator.ingest(SSEEvent(name: nil, data: chunk.compactString))
        }
        out += translator.finish()
        return out
    }

    func names(_ events: [SSEEvent]) -> [String] { events.compactMap(\.name) }

    func json(_ event: SSEEvent) -> JSONValue { JSONValue.lenient(event.data)! }

    static func textChunk(_ text: String) -> JSONValue {
        ["id": "chatcmpl-1", "choices": [["index": 0, "delta": ["content": .string(text)]]]]
    }

    @Test("a plain text response produces one well-formed block")
    func plainText() {
        let events = run([Self.textChunk("Hel"), Self.textChunk("lo"),
                          ["choices": [["index": 0, "delta": [:], "finish_reason": "stop"]]]])

        #expect(names(events) == [
            "message_start", "content_block_start",
            "content_block_delta", "content_block_delta",
            "content_block_stop", "message_delta", "message_stop",
        ])
        #expect(json(events[2])["delta"]?["text"]?.stringValue == "Hel")
        #expect(json(events[5])["delta"]?["stop_reason"]?.stringValue == "end_turn")
        // Claude Desktop needs a token count from the first event onwards.
        #expect(json(events[0])["message"]?["usage"]?["input_tokens"]?.intValue == 42)
    }

    @Test("tool calls open their own block and stream arguments as input_json_delta")
    func toolCalls() {
        let events = run([
            ["id": "chatcmpl-1", "choices": [["index": 0, "delta": ["tool_calls": [
                ["index": 0, "id": "call_1", "type": "function",
                 "function": ["name": "get_weather", "arguments": ""]],
            ]]]]],
            ["choices": [["index": 0, "delta": ["tool_calls": [
                ["index": 0, "function": ["arguments": "{\"city\":"]],
            ]]]]],
            ["choices": [["index": 0, "delta": ["tool_calls": [
                ["index": 0, "function": ["arguments": "\"Berlin\"}"]],
            ]]]]],
            ["choices": [["index": 0, "delta": [:], "finish_reason": "tool_calls"]]],
        ])

        let start = events.first { $0.name == "content_block_start" }!
        #expect(json(start)["content_block"]?["type"]?.stringValue == "tool_use")
        #expect(json(start)["content_block"]?["name"]?.stringValue == "get_weather")
        #expect(json(start)["content_block"]?["id"]?.stringValue == "call_1")

        let fragments = events
            .filter { $0.name == "content_block_delta" }
            .compactMap { json($0)["delta"]?["partial_json"]?.stringValue }
        #expect(fragments.joined() == "{\"city\":\"Berlin\"}")

        let final = events.first { $0.name == "message_delta" }!
        #expect(json(final)["delta"]?["stop_reason"]?.stringValue == "tool_use")
    }

    @Test("text followed by a tool call yields two separately closed blocks")
    func textThenTool() {
        let events = run([
            Self.textChunk("Checking."),
            ["choices": [["index": 0, "delta": ["tool_calls": [
                ["index": 0, "id": "call_1", "function": ["name": "f", "arguments": "{}"]],
            ]]]]],
            ["choices": [["index": 0, "delta": [:], "finish_reason": "tool_calls"]]],
        ])

        #expect(names(events) == [
            "message_start",
            "content_block_start", "content_block_delta", "content_block_stop",
            "content_block_start", "content_block_delta", "content_block_stop",
            "message_delta", "message_stop",
        ])
        // Anthropic allows only one open block at a time, and indices must
        // advance rather than repeat.
        #expect(json(events[1])["index"]?.intValue == 0)
        #expect(json(events[4])["index"]?.intValue == 1)
    }

    @Test("two parallel tool calls get one block each")
    func parallelToolCalls() {
        let events = run([
            ["id": "c", "choices": [["delta": ["tool_calls": [
                ["index": 0, "id": "call_1", "function": ["name": "a", "arguments": "{}"]],
            ]]]]],
            ["choices": [["delta": ["tool_calls": [
                ["index": 1, "id": "call_2", "function": ["name": "b", "arguments": "{}"]],
            ]]]]],
            ["choices": [["delta": [:], "finish_reason": "tool_calls"]]],
        ])
        let starts = events.filter { $0.name == "content_block_start" }
        #expect(starts.count == 2)
        #expect(json(starts[0])["content_block"]?["name"]?.stringValue == "a")
        #expect(json(starts[1])["content_block"]?["name"]?.stringValue == "b")
        #expect(json(starts[1])["index"]?.intValue == 1)
    }

    @Test("the trailing usage-only chunk supplies real token counts")
    func usageTrailer() {
        let events = run([
            Self.textChunk("hi"),
            ["choices": [["delta": [:], "finish_reason": "stop"]]],
            ["choices": [], "usage": ["prompt_tokens": 100, "completion_tokens": 7,
                                      "prompt_tokens_details": ["cached_tokens": 30]]],
        ])
        let usage = json(events.first { $0.name == "message_delta" }!)["usage"]!
        // OpenAI counts cached tokens inside prompt_tokens; Anthropic keeps
        // them in a separate bucket.
        #expect(usage["input_tokens"]?.intValue == 70)
        #expect(usage["cache_read_input_tokens"]?.intValue == 30)
        #expect(usage["output_tokens"]?.intValue == 7)
    }

    @Test("[DONE] closes the stream and later chunks are ignored")
    func doneTerminates() {
        var translator = OpenAIStreamTranslator(requestModel: "m", reasoning: .drop, estimatedInputTokens: 1)
        _ = translator.ingest(SSEEvent(name: nil, data: Self.textChunk("hi").compactString))
        let closing = translator.ingest(SSEEvent(name: nil, data: "[DONE]"))
        #expect(names(closing).contains("message_stop"))
        #expect(translator.ingest(SSEEvent(name: nil, data: Self.textChunk("x").compactString)).isEmpty)
        #expect(translator.finish().isEmpty)
    }

    @Test("reasoning is discarded by default and shown as text when asked")
    func reasoningModes() {
        let chunk: JSONValue = ["id": "c", "choices": [["delta": ["reasoning_content": "thinking…"]]]]

        let dropped = run([chunk, Self.textChunk("answer")])
        let droppedText = dropped
            .filter { $0.name == "content_block_delta" }
            .compactMap { json($0)["delta"]?["text"]?.stringValue }
        #expect(droppedText == ["answer"])

        let shown = run([chunk, Self.textChunk("answer")], reasoning: .asText)
        let shownText = shown
            .filter { $0.name == "content_block_delta" }
            .compactMap { json($0)["delta"]?["text"]?.stringValue }
        #expect(shownText == ["thinking…", "answer"])
    }

    @Test("a mid-stream failure is reported as an in-stream error event")
    func midStreamFailure() {
        var translator = OpenAIStreamTranslator(requestModel: "m", reasoning: .drop, estimatedInputTokens: 1)
        _ = translator.ingest(SSEEvent(name: nil, data: Self.textChunk("partial").compactString))
        let failure = translator.fail(type: "api_error", message: "connection reset")
        #expect(failure.count == 1)
        #expect(failure[0].name == "error")
        #expect(json(failure[0])["error"]?["message"]?.stringValue == "connection reset")
    }

    @Test("a response with no content at all still closes cleanly")
    func emptyResponse() {
        let events = run([["choices": [["delta": [:], "finish_reason": "stop"]]]])
        #expect(names(events) == ["message_start", "message_delta", "message_stop"])
    }
}

@Suite("SSE parsing")
struct SSEParserTests {

    @Test("events split across reads are reassembled")
    func splitAcrossReads() {
        var parser = SSEParser()
        #expect(parser.consume("data: {\"a\"").isEmpty)
        #expect(parser.consume(":1}\n").isEmpty)
        let events = parser.consume("\n")
        #expect(events.count == 1)
        #expect(events[0].data == "{\"a\":1}")
    }

    @Test("event names and CRLF line endings are handled")
    func namedEventsAndCRLF() {
        var parser = SSEParser()
        let events = parser.consume("event: message_start\r\ndata: {}\r\n\r\n")
        #expect(events == [SSEEvent(name: "message_start", data: "{}")])
    }

    @Test("comment keep-alives produce no events")
    func keepAliveComments() {
        var parser = SSEParser()
        #expect(parser.consume(": keep-alive\n\n").isEmpty)
    }

    @Test("multi-line data fields are joined with newlines")
    func multiLineData() {
        var parser = SSEParser()
        let events = parser.consume("data: line one\ndata: line two\n\n")
        #expect(events[0].data == "line one\nline two")
    }

    @Test("a final event without its blank line is flushed")
    func flushTrailing() {
        var parser = SSEParser()
        #expect(parser.consume("data: {\"x\":1}\n").isEmpty)
        #expect(parser.flush()[0].data == "{\"x\":1}")
    }
}
