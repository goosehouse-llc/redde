import Foundation
import Testing
@testable import Echo

struct SSEParserTests {
    @Test func splitsEventsAcrossChunks() {
        var parser = SSEParser()
        var events = parser.feed("event: response.output_text.delta\ndata: {\"del")
        #expect(events.isEmpty)
        events += parser.feed("ta\":\"Hi\"}\n\ndata: [DONE]\n\n")
        #expect(events == [
            SSEEvent(event: "response.output_text.delta", data: "{\"delta\":\"Hi\"}", id: nil),
            SSEEvent(event: nil, data: "[DONE]", id: nil),
        ])
    }

    @Test func joinsMultiLineDataAndIgnoresComments() {
        var parser = SSEParser()
        let events = parser.feed(": keepalive\ndata: a\ndata:b\n\n")
        #expect(events == [SSEEvent(event: nil, data: "a\nb", id: nil)])
    }

    @Test func flushesUnterminatedEventOnFinish() {
        var parser = SSEParser()
        #expect(parser.feed("data: tail").isEmpty)
        #expect(parser.finish() == SSEEvent(event: nil, data: "tail", id: nil))
    }

    @Test func decodesChatCompletionChunks() throws {
        let chunk = SSEEvent(event: nil, data: #"{"choices":[{"delta":{"content":"Hi"},"finish_reason":null}]}"#, id: nil)
        let (events, finished) = try ChatCompletionsTransport.decode(chunk)
        #expect(events == [.textDelta("Hi")])
        #expect(!finished)
        let done = try ChatCompletionsTransport.decode(SSEEvent(event: nil, data: "[DONE]", id: nil))
        #expect(done.finished)
        let usage = SSEEvent(event: nil, data: #"{"choices":[],"usage":{"prompt_tokens":19,"completion_tokens":6,"prompt_tokens_details":{"cached_tokens":7}}}"#, id: nil)
        #expect(try ChatCompletionsTransport.decode(usage).events == [.usage(TokenUsage(input: 19, output: 6, cached: 7, contextUsed: 25))])
    }

    /// llama.cpp's `return_progress` chunks (prefill percentage) surface as `.prefill` events.
    @Test func decodesPromptProgressChunks() throws {
        let progress = SSEEvent(event: nil, data: #"{"choices":[{"delta":{"content":null},"finish_reason":null}],"prompt_progress":{"total":9100,"cache":8412,"processed":4200,"time_ms":1250}}"#, id: nil)
        #expect(try ChatCompletionsTransport.decode(progress).events == [.prefill(processed: 4200, total: 9100, cached: 8412)])
    }

    /// The progress flag only goes to self-hosted endpoints; OpenAI rejects unknown arguments.
    @Test func progressFlagOnlyForSelfHostedEndpoints() {
        for host in ["http://localhost:8080", "http://192.168.1.5:8080", "http://100.101.102.103:11500",
                     "https://llm.tailnet-name.ts.net", "http://10.0.0.2", "http://172.20.0.1"] {
            #expect(ChatCompletionsTransport.isSelfHosted(URL(string: host)!), "\(host) should count as self-hosted")
        }
        for host in ["https://api.openai.com", "https://openrouter.ai", "https://172.15.0.1", "https://100.128.0.1"] {
            #expect(!ChatCompletionsTransport.isSelfHosted(URL(string: host)!), "\(host) should not")
        }
    }

    /// High effort on a self-hosted Qwen turns thinking on; anything else leaves the
    /// server default (off) alone, and nothing extra ever goes to a cloud endpoint.
    @Test func thinkingSwitchOnlyForHighEffortLocalQwen() {
        let local = URL(string: "http://100.101.102.103:11500")!
        let cloud = URL(string: "https://api.openai.com")!
        #expect(ChatCompletionsTransport.thinkingKwargs(model: "qwen36-35b-a3b", effort: "high", baseURL: local) == ["enable_thinking": true])
        #expect(ChatCompletionsTransport.thinkingKwargs(model: "Qwen3-8B", effort: "max", baseURL: local) == ["enable_thinking": true])
        #expect(ChatCompletionsTransport.thinkingKwargs(model: "qwen36-35b-a3b", effort: nil, baseURL: local) == nil)
        #expect(ChatCompletionsTransport.thinkingKwargs(model: "qwen36-35b-a3b", effort: "medium", baseURL: local) == nil)
        #expect(ChatCompletionsTransport.thinkingKwargs(model: "gemma4-26b-a4b", effort: "high", baseURL: local) == nil)
        #expect(ChatCompletionsTransport.thinkingKwargs(model: "qwen36-35b-a3b", effort: "high", baseURL: cloud) == nil)
    }
}

struct SessionsStreamTests {
    @Test func decodesLedgerEvents() throws {
        func ev(_ name: String, _ json: String) -> SSEEvent { SSEEvent(event: name, data: json, id: nil) }
        #expect(try HermesSessionsTransport.decode(ev("run.started", #"{"session_id":"abc","run_id":"r1"}"#)).events == [.sessionID("abc"), .runID("r1")])
        #expect(try HermesSessionsTransport.decode(ev("assistant.delta", #"{"message_id":"m","delta":"Hel"}"#)).events == [.textDelta("Hel")])
        #expect(try HermesSessionsTransport.decode(ev("tool.progress", #"{"tool_name":"_thinking","delta":"hmm"}"#)).events == [.reasoningDelta("hmm")])
        #expect(try HermesSessionsTransport.decode(ev("tool.started", #"{"tool_name":"memory","preview":"add"}"#)).events == [.toolStarted(name: "memory", preview: "add")])
        #expect(try HermesSessionsTransport.decode(ev("tool.failed", #"{"tool_name":"memory"}"#)).events == [.toolFinished(name: "memory", failed: true)])
        let done = try HermesSessionsTransport.decode(ev("run.completed", #"{"usage":{"input_tokens":50,"output_tokens":9}}"#))
        #expect(done.events == [.usage(TokenUsage(input: 50, output: 9, cached: nil))])
        #expect(!done.finished)
        #expect(try HermesSessionsTransport.decode(ev("done", "{}")).finished)
        #expect(throws: TransportError.self) { try HermesSessionsTransport.decode(ev("error", #"{"message":"boom"}"#)) }
    }
}

/// The API server only resolves `MEDIA:<path>` tags into inline images in the finished reply;
/// the deltas carry the bare tag. Redde used to drop `assistant.completed` on the floor and show
/// the tag as text, so an image the agent sent never appeared.
struct AssistantCompletedTests {
    private func ev(_ name: String, _ json: String) -> SSEEvent { SSEEvent(event: name, data: json, id: nil) }

    @Test func completedCarriesTheResolvedImage() throws {
        let image = "![image](data:image/jpeg;base64,/9j/4AAQSkZJRg==)"
        let json = #"{"message_id":"m","content":"Here it is \#(image)","completed":true}"#
        let out = try HermesSessionsTransport.decode(ev("assistant.completed", json))
        #expect(out.events == [.textFinal("Here it is \(image)")])
        #expect(out.finished == false)   // `done` ends the stream, not this
    }

    @Test func completedWithoutContentIsIgnored() throws {
        #expect(try HermesSessionsTransport.decode(ev("assistant.completed", #"{"message_id":"m"}"#)).events.isEmpty)
        #expect(try HermesSessionsTransport.decode(ev("assistant.completed", #"{"content":""}"#)).events.isEmpty)
    }

    @Test func deltasStillStreamTheRawTag() throws {
        // What the phone actually received before the fix, and still receives mid-stream.
        let out = try HermesSessionsTransport.decode(ev("assistant.delta", #"{"delta":"MEDIA:/tmp/snap.jpg"}"#))
        #expect(out.events == [.textDelta("MEDIA:/tmp/snap.jpg")])
    }
}

/// An approval bridge on the gateway surfaces approval-gated tool calls on the session stream;
/// the run id rides as the routing token for POST /v1/runs/{run_id}/approval.
struct SessionsApprovalTests {
    private func ev(_ name: String, _ json: String) -> SSEEvent { SSEEvent(event: name, data: json, id: nil) }

    @Test func approvalRequestBecomesAnInterrupt() throws {
        let json = #"{"request_id":"req1","command":"systemctl restart nginx","description":"Restart the web server","choices":["once","session","always","deny"],"run_id":"run_9","session_id":"s1"}"#
        let out = try HermesSessionsTransport.decode(ev("approval.request", json))
        let request = ApprovalRequest(id: "req1", command: "systemctl restart nginx",
                                      description: "Restart the web server",
                                      choices: ["once", "session", "always", "deny"])
        #expect(out.events == [.interrupt(.approval(request), runtimeSession: "run_9")])
        #expect(out.finished == false)
    }

    @Test func approvalWithoutARequestIDIsIgnored() throws {
        #expect(try HermesSessionsTransport.decode(ev("approval.request", #"{"command":"x"}"#)).events.isEmpty)
    }

    /// The model lock's post-run check compares the agent's normalized provider — bare "custom"
    /// for named custom endpoints — so the qualified slug must be sent as the bucket.
    @Test func lockProviderNormalizesCustomEndpoints() {
        #expect(HermesSessionsAPI.lockProvider("custom:gemma-4-26b-a4b-vision") == "custom")
        #expect(HermesSessionsAPI.lockProvider("custom") == "custom")
        #expect(HermesSessionsAPI.lockProvider("nous") == "nous")
        #expect(HermesSessionsAPI.lockProvider("") == nil)
        #expect(HermesSessionsAPI.lockProvider(nil) == nil)
    }
}
