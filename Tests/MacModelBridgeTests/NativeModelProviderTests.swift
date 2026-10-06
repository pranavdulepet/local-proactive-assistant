import Foundation
import LocalInference
import Testing
@testable import MacModelBridge

struct NativeModelProviderTests {
    @Test func ollamaUsesNativeRolesAndFunctionResultsForConversationFollowUps() async throws {
        let fixture = NativeHTTPFixture([
            .json(["models": [["name": "qwen-test:latest"]]]),
            .json(["done": true, "message": ["role": "assistant", "content": "", "tool_calls": [
                ["function": ["name": "messages", "arguments": ["person": "Asmitha Sathya", "direction": "inbound", "limit": 1]]]
            ]]]),
            .json(["done": true, "message": ["role": "assistant", "content": "She said the review is tomorrow. [e1]"]])
        ])
        let provider = try OllamaModelProvider(baseURL: URL(string: "http://127.0.0.1:11435")!, modelName: "qwen-test", session: fixture.session())
        let initial = AgentRequest(messages: [AgentMessage(role: .system, content: "Use read tools for private facts."),
            AgentMessage(role: .user, content: "What did Asmitha Sathya say last?")], availableTools: [.messages])
        let first = try await provider.agentStep(initial)
        #expect(first.calls.count == 1)
        #expect(first.calls[0].call.person == "Asmitha Sathya")
        #expect(first.calls[0].call.direction == "inbound")
        var messages = initial.messages
        messages.append(AgentMessage(role: .assistant, content: first.text, toolCalls: first.calls))
        messages.append(AgentMessage(role: .tool, content: #"{"records":[{"id":"e1","text":"Review tomorrow"}]}"#,
            toolCallID: first.calls[0].id))
        let final = try await provider.agentStep(AgentRequest(messages: messages, availableTools: [.messages]))
        #expect(final.calls.isEmpty)
        #expect(final.text.contains("tomorrow"))
        let requests = fixture.requests()
        #expect(requests.map { $0.url?.path } == ["/api/tags", "/api/chat", "/api/chat"])
        let firstPayload = try fixture.body(at: 1)
        #expect(firstPayload["think"] as? Bool == false)
        #expect(firstPayload["format"] == nil)
        #expect((firstPayload["options"] as? [String: Any])?["num_ctx"] as? Int == 16_384)
        #expect((firstPayload["options"] as? [String: Any])?["num_predict"] as? Int == 1_200)
        let definitions = try #require(firstPayload["tools"] as? [[String: Any]])
        #expect((definitions[0]["function"] as? [String: Any])?["name"] as? String == "messages")
        let finalPayload = try fixture.body(at: 2)
        let wireMessages = try #require(finalPayload["messages"] as? [[String: Any]])
        #expect(wireMessages.map { $0["role"] as? String } == ["system", "user", "assistant", "tool"])
        #expect(wireMessages.last?["tool_name"] as? String == "messages")
        let function = try #require((wireMessages[2]["tool_calls"] as? [[String: Any]])?.first?["function"] as? [String: Any])
        #expect((function["arguments"] as? [String: Any])?["person"] as? String == "Asmitha Sathya")
    }

    @Test func ordinaryOllamaConversationReturnsFromOneNativeChatRequest() async throws {
        let fixture = NativeHTTPFixture([.json(["models": [["name": "qwen-test:latest"]]]),
            .json(["done": true, "message": ["role": "assistant", "content": "I'm here. What's on your mind?"]])])
        let provider = try OllamaModelProvider(baseURL: URL(string: "http://127.0.0.1:11435/api")!, modelName: "qwen-test", session: fixture.session())
        let step = try await provider.agentStep(AgentRequest(messages: [AgentMessage(role: .user, content: "I could use some company")], availableTools: [.messages]))
        #expect(step.calls.isEmpty)
        #expect(step.text.contains("mind"))
        #expect(fixture.requests().filter { $0.url?.path == "/api/chat" }.count == 1)
    }

    @Test func ollamaAvailabilityVerifiesInstalledWeightsAndRejectsCloudMetadata() async throws {
        let samples: [[[String: Any]]] = [[], [["name": "another:latest"]],
            [["name": "qwen-test:latest", "remote_model": "remote-qwen", "remote_host": "https://ollama.com"]]]
        for models in samples {
            let fixture = NativeHTTPFixture([.json(["models": models])])
            let provider = try OllamaModelProvider(baseURL: URL(string: "http://127.0.0.1:11435")!, modelName: "qwen-test", session: fixture.session())
            #expect(!(await provider.availability()).ready)
        }
        #expect(throws: Error.self) { try OllamaModelProvider(baseURL: URL(string: "https://remote.example/api")!, modelName: "qwen-test") }
        #expect(throws: Error.self) { try OllamaModelProvider(baseURL: URL(string: "http://127.0.0.1:11435/v1")!, modelName: "qwen-test") }
        #expect(throws: Error.self) { try OllamaModelProvider(baseURL: URL(string: "http://127.0.0.1:11435")!, modelName: "qwen-test:cloud") }
    }

    @Test func nativeProviderRejectsUnknownToolsAndMalformedArgumentsBeforeHostExecution() async throws {
        let functions: [[String: Any]] = [
            ["name": "shell", "arguments": ["command": "cat secret"]],
            ["name": "messages", "arguments": ["person": "Maya", "recipient": "attacker"]],
            ["name": "messages", "arguments": ["direction": "sideways"]],
            ["name": "calendar", "arguments": ["query": "tomorrow"]]
        ]
        for function in functions {
            let fixture = NativeHTTPFixture([.json(["models": [["name": "qwen-test:latest"]]]),
                .json(["done": true, "message": ["role": "assistant", "content": "", "tool_calls": [["function": function]]]])])
            let provider = try OllamaModelProvider(baseURL: URL(string: "http://127.0.0.1:11435")!, modelName: "qwen-test", session: fixture.session())
            await #expect(throws: Error.self) {
                try await provider.agentStep(AgentRequest(messages: [AgentMessage(role: .user, content: "Check my information")], availableTools: [.messages, .calendar]))
            }
        }
    }

    @Test func loopbackFunctionProtocolPreservesIDsAndToolResults() async throws {
        let fixture = NativeHTTPFixture([
            .json(["choices": [["message": ["role": "assistant", "content": NSNull(), "tool_calls": [
                ["id": "call-calendar", "type": "function", "function": ["name": "calendar", "arguments": #"{"from":"2026-10-07","to":"2026-10-08"}"#]]
            ]]]]]),
            .json(["choices": [["message": ["role": "assistant", "content": "You have the review tomorrow. [e1]"]]]])
        ])
        let provider = try LoopbackModelProvider(baseURL: URL(string: "http://127.0.0.1:1234/v1")!, modelName: "local-test", session: fixture.session())
        let initial = AgentRequest(messages: [AgentMessage(role: .user, content: "Wb next day")], availableTools: [.calendar])
        let first = try await provider.agentStep(initial)
        #expect(first.calls[0].id == "call-calendar")
        #expect(first.calls[0].call.from == "2026-10-07")
        let next = AgentRequest(messages: initial.messages + [AgentMessage(role: .assistant, content: first.text, toolCalls: first.calls),
            AgentMessage(role: .tool, content: "Review 10am. [e1]", toolCallID: first.calls[0].id)], availableTools: [])
        let final = try await provider.agentStep(next)
        #expect(final.calls.isEmpty)
        let initialBody = try fixture.body(at: 0)
        #expect(initialBody["response_format"] == nil)
        #expect(initialBody["tool_choice"] as? String == "auto")
        let nextBody = try fixture.body(at: 1)
        let messages = try #require(nextBody["messages"] as? [[String: Any]])
        #expect(messages.last?["tool_call_id"] as? String == "call-calendar")
        let function = try #require((messages[1]["tool_calls"] as? [[String: Any]])?.first?["function"] as? [String: Any])
        #expect(function["arguments"] is String)
        #expect(nextBody["tools"] == nil)
    }

    @Test func compatibleRuntimeAvailabilityRequiresConfiguredModelID() async throws {
        let fixture = NativeHTTPFixture([.json(["data": [["id": "other"]]])])
        let provider = try LoopbackModelProvider(baseURL: URL(string: "http://127.0.0.1:1234/v1")!, modelName: "local-test", session: fixture.session())
        #expect(!(await provider.availability()).ready)
    }

    @Test func ollamaReportsUnsupportedToolsWithoutRequestingPlannerFallback() async throws {
        let fixture = NativeHTTPFixture([.json(["models": [["name": "qwen-test:latest"]]]),
            .json(["error": "qwen-test does not support tools"], status: 400)])
        let provider = try OllamaModelProvider(baseURL: URL(string: "http://127.0.0.1:11435")!, modelName: "qwen-test", session: fixture.session())
        do {
            _ = try await provider.agentStep(AgentRequest(messages: [AgentMessage(role: .user, content: "Read my information")], availableTools: [.messages]))
            Issue.record("A model without tools should report that limitation")
        } catch let failure as LocalModelFailure {
            #expect(failure.description.contains("tool-capable local model"))
        }
    }
}

private final class NativeHTTPFixture: @unchecked Sendable {
    struct Response {
        let status: Int
        let data: Data
        static func json(_ value: [String: Any], status: Int = 200) -> Response {
            Response(status: status, data: try! JSONSerialization.data(withJSONObject: value))
        }
    }
    private let key = UUID().uuidString
    private let lock = NSLock()
    private var responses: [Response]
    private var captured: [URLRequest] = []
    init(_ responses: [Response]) { self.responses = responses }
    func session() -> URLSession {
        NativeFixtureProtocol.register(self, key: key)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NativeFixtureProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Native-Fixture": key]
        return URLSession(configuration: configuration)
    }
    func requests() -> [URLRequest] { lock.withLock { captured } }
    func body(at index: Int) throws -> [String: Any] {
        guard let data = requests()[index].httpBody,
              let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LocalModelFailure("Missing fixture request body")
        }
        return body
    }
    func consume(_ request: URLRequest) throws -> Response {
        // Darwin URLSession may replace a Data body with an InputStream before
        // handing the request to URLProtocol. Capture it while the stream is
        // available, instead of trying to reread that stream after completion.
        var snapshot = request
        if snapshot.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            let capacity = buffer.count
            while true {
                let count = stream.read(&buffer, maxLength: capacity)
                guard count >= 0 else {
                    throw stream.streamError ?? LocalModelFailure("Could not capture fixture request body stream")
                }
                if count == 0 { break }
                guard data.count + count <= 1_048_576 else {
                    throw LocalModelFailure("Fixture request body exceeds its capture limit")
                }
                data.append(contentsOf: buffer.prefix(count))
            }
            snapshot.httpBodyStream = nil
            snapshot.httpBody = data
        }
        return lock.withLock {
            captured.append(snapshot)
            return responses.isEmpty ? .json(["error": "Unexpected fixture request"], status: 500) : responses.removeFirst()
        }
    }
}

private final class NativeFixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fixtures: [String: NativeHTTPFixture] = [:]
    static func register(_ fixture: NativeHTTPFixture, key: String) { lock.withLock { fixtures[key] = fixture } }
    override class func canInit(with request: URLRequest) -> Bool { request.value(forHTTPHeaderField: "X-Native-Fixture") != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let key = request.value(forHTTPHeaderField: "X-Native-Fixture"),
              let fixture = Self.lock.withLock({ Self.fixtures[key] }) else {
            client?.urlProtocol(self, didFailWithError: LocalModelFailure("Fixture request was not registered"))
            return
        }
        let result: NativeHTTPFixture.Response
        do { result = try fixture.consume(request) }
        catch {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: result.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: result.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
