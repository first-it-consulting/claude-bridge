import Testing
import Foundation
@testable import BridgeCore

@Suite("Anthropic to OpenAI request translation")
struct RequestTranslationTests {

    func translate(_ json: JSONValue, stream: Bool = false, tools: Bool = true, cap: Int? = nil) -> JSONValue {
        OpenAIRequestTranslator.translate(
            anthropic: json,
            options: .init(model: "qwen3:8b", maxOutputTokens: cap, supportsTools: tools, stream: stream)
        )
    }

    @Test("system prompt becomes the leading system message")
    func systemPrompt() {
        let out = translate([
            "system": "You are helpful.",
            "messages": [["role": "user", "content": "hi"]],
            "max_tokens": 100,
        ])
        let messages = out["messages"]!.arrayValue!
        #expect(messages.count == 2)
        #expect(messages[0]["role"]?.stringValue == "system")
        #expect(messages[0]["content"]?.stringValue == "You are helpful.")
        #expect(messages[1]["role"]?.stringValue == "user")
        #expect(out["model"]?.stringValue == "qwen3:8b")
    }

    @Test("a system prompt given as blocks is joined")
    func systemBlocks() {
        let out = translate([
            "system": [
                ["type": "text", "text": "First."],
                ["type": "text", "text": "Second."],
            ],
            "messages": [["role": "user", "content": "hi"]],
        ])
        #expect(out["messages"]![0]!["content"]?.stringValue == "First.\nSecond.")
    }

    @Test("tool_use blocks become assistant tool_calls with stringified arguments")
    func toolUse() {
        let out = translate([
            "messages": [
                ["role": "user", "content": "weather?"],
                ["role": "assistant", "content": [
                    ["type": "text", "text": "Let me check."],
                    ["type": "tool_use", "id": "toolu_1", "name": "get_weather",
                     "input": ["city": "Berlin"]],
                ]],
            ],
        ])
        let assistant = out["messages"]![1]!
        #expect(assistant["content"]?.stringValue == "Let me check.")

        let call = assistant["tool_calls"]![0]!
        #expect(call["id"]?.stringValue == "toolu_1")
        #expect(call["type"]?.stringValue == "function")
        #expect(call["function"]?["name"]?.stringValue == "get_weather")
        // OpenAI wants arguments as a JSON string, not an object.
        let args = JSONValue.lenient(call["function"]!["arguments"]!.stringValue!)
        #expect(args?["city"]?.stringValue == "Berlin")
    }

    @Test("tool results become tool messages placed before any new user text")
    func toolResultOrdering() {
        let out = translate([
            "messages": [
                ["role": "assistant", "content": [
                    ["type": "tool_use", "id": "toolu_1", "name": "f", "input": [:]],
                ]],
                ["role": "user", "content": [
                    ["type": "tool_result", "tool_use_id": "toolu_1", "content": "18°C"],
                    ["type": "text", "text": "and tomorrow?"],
                ]],
            ],
        ])
        let messages = out["messages"]!.arrayValue!
        #expect(messages.count == 3)
        #expect(messages[0]["role"]?.stringValue == "assistant")
        // OpenAI requires the tool reply to directly answer the calling turn.
        #expect(messages[1]["role"]?.stringValue == "tool")
        #expect(messages[1]["tool_call_id"]?.stringValue == "toolu_1")
        #expect(messages[1]["content"]?.stringValue == "18°C")
        #expect(messages[2]["role"]?.stringValue == "user")
    }

    @Test("an errored tool result is marked as such in its text")
    func toolResultError() {
        let out = translate([
            "messages": [["role": "user", "content": [
                ["type": "tool_result", "tool_use_id": "t1", "content": "no such file", "is_error": true],
            ]]],
        ])
        #expect(out["messages"]![0]!["content"]?.stringValue == "Error: no such file")
    }

    @Test("images become data-URI image_url parts")
    func images() {
        let out = translate([
            "messages": [["role": "user", "content": [
                ["type": "text", "text": "what is this"],
                ["type": "image", "source": [
                    "type": "base64", "media_type": "image/png", "data": "AAAA",
                ]],
            ]]],
        ])
        let parts = out["messages"]![0]!["content"]!.arrayValue!
        #expect(parts.count == 2)
        #expect(parts[1]["image_url"]?["url"]?.stringValue == "data:image/png;base64,AAAA")
    }

    @Test("tool schemas move from input_schema to function.parameters")
    func toolSchemas() {
        let out = translate([
            "messages": [["role": "user", "content": "hi"]],
            "tools": [[
                "name": "get_weather",
                "description": "Look up weather",
                "input_schema": ["type": "object", "properties": ["city": ["type": "string"]]],
            ]],
            "tool_choice": ["type": "any"],
        ])
        let tool = out["tools"]![0]!
        #expect(tool["type"]?.stringValue == "function")
        #expect(tool["function"]?["name"]?.stringValue == "get_weather")
        #expect(tool["function"]?["parameters"]?["type"]?.stringValue == "object")
        #expect(out["tool_choice"]?.stringValue == "required")
    }

    @Test("server-side tools with no input_schema are skipped")
    func serverToolsSkipped() {
        let out = translate([
            "messages": [["role": "user", "content": "hi"]],
            "tools": [
                ["type": "web_search_20250305", "name": "web_search"],
                ["name": "ok", "input_schema": ["type": "object"]],
            ],
        ])
        #expect(out["tools"]!.arrayValue!.count == 1)
        #expect(out["tools"]![0]!["function"]?["name"]?.stringValue == "ok")
    }

    @Test("tools are dropped entirely when the model cannot use them")
    func toolsUnsupported() {
        let out = translate([
            "messages": [["role": "user", "content": "hi"]],
            "tools": [["name": "f", "input_schema": ["type": "object"]]],
        ], tools: false)
        #expect(out["tools"] == nil)
    }

    @Test("cache_control breakpoints are stripped everywhere")
    func cacheControlStripped() {
        let out = translate([
            "system": [["type": "text", "text": "sys", "cache_control": ["type": "ephemeral"]]],
            "messages": [["role": "user", "content": [
                ["type": "text", "text": "hi", "cache_control": ["type": "ephemeral"]],
            ]]],
            "tools": [["name": "f", "input_schema": ["type": "object"],
                       "cache_control": ["type": "ephemeral"]]],
        ])
        #expect(!out.compactString.contains("cache_control"))
    }

    @Test("max_tokens is clamped to the configured ceiling")
    func maxTokensClamped() {
        let out = translate(["messages": [["role": "user", "content": "hi"]], "max_tokens": 64000], cap: 4096)
        #expect(out["max_tokens"]?.intValue == 4096)

        let under = translate(["messages": [["role": "user", "content": "hi"]], "max_tokens": 512], cap: 4096)
        #expect(under["max_tokens"]?.intValue == 512)
    }

    @Test("streaming asks for usage, which most backends otherwise omit")
    func streamOptions() {
        let out = translate(["messages": [["role": "user", "content": "hi"]]], stream: true)
        #expect(out["stream"]?.boolValue == true)
        #expect(out["stream_options"]?["include_usage"]?.boolValue == true)
    }

    @Test("thinking blocks in history are dropped, not forwarded")
    func thinkingDropped() {
        let out = translate([
            "messages": [["role": "assistant", "content": [
                ["type": "thinking", "thinking": "hmm", "signature": "sig"],
                ["type": "text", "text": "Answer."],
            ]]],
        ])
        #expect(out["messages"]![0]!["content"]?.stringValue == "Answer.")
        #expect(!out.compactString.contains("signature"))
    }

    @Test("stop_sequences map to stop and top_k is dropped")
    func samplingParameters() {
        let out = translate([
            "messages": [["role": "user", "content": "hi"]],
            "stop_sequences": ["END"],
            "temperature": 0.5,
            "top_k": 40,
        ])
        #expect(out["stop"]?[0]?.stringValue == "END")
        #expect(out["temperature"]?.doubleValue == 0.5)
        #expect(out["top_k"] == nil)
    }
}
