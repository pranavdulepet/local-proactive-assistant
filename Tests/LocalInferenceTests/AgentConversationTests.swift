import Foundation
import Testing
@testable import LocalInference

struct AgentConversationTests {
    @Test func assistantCallsMustBePairedWithExactlyOneToolResult() throws {
        let call = AgentToolCall(id: "read-1", call: ContextToolCall(tool: .messages, person: "Asmitha Sathya", direction: "inbound", limit: 1))
        let user = AgentMessage(role: .user, content: "What did she say last?")
        let assistant = AgentMessage(role: .assistant, content: "", toolCalls: [call])
        let tool = AgentMessage(role: .tool, content: "Her last message", toolCallID: call.id)
        try AgentRequest(messages: [user, assistant, tool], availableTools: [.messages]).validate()
        #expect(throws: Error.self) { try AgentRequest(messages: [user, assistant], availableTools: [.messages]).validate() }
        #expect(throws: Error.self) { try AgentRequest(messages: [user, tool], availableTools: [.messages]).validate() }
        #expect(throws: Error.self) { try AgentRequest(messages: [user, assistant, tool, tool], availableTools: [.messages]).validate() }
        #expect(throws: Error.self) { try AgentRequest(messages: [user, assistant, AgentMessage(role: .user, content: "Next")], availableTools: [.messages]).validate() }
    }

    @Test func nativeCatalogDecodesSpecificSourceFiltersAndDateRanges() throws {
        let messages = try AgentToolCatalog.decode(name: "messages", arguments: ["person": "Asmitha Sathya", "direction": "inbound", "limit": 1, "offset": 2])
        #expect(messages.person == "Asmitha Sathya")
        #expect(messages.direction == "inbound")
        #expect(messages.limit == 1)
        let calendar = try AgentToolCatalog.decode(name: "calendar", arguments: ["from": "2026-10-07", "to": "2026-10-08"])
        #expect(calendar.from == "2026-10-07")
        #expect(calendar.to == "2026-10-08")
        let mail = try AgentToolCatalog.decode(name: "mailInbox", arguments: ["query": "Archive invoice", "offset": 100, "limit": 3])
        #expect(mail.offset == 100)
        let encoded = try AgentToolCatalog.arguments(for: messages)
        #expect(encoded["tool"] == nil)
        #expect(encoded["person"] as? String == "Asmitha Sathya")
    }

    @Test func functionArgumentsCannotSmuggleWritesOrUnknownKeys() throws {
        for name in ["sendMessage", "shell", "writeFile", "purchase"] {
            #expect(throws: Error.self) { try AgentToolCatalog.decode(name: name, arguments: [:]) }
        }
        #expect(throws: Error.self) { try AgentToolCatalog.decode(name: "messages", arguments: ["person": "Maya", "recipient": "other"]) }
        #expect(throws: Error.self) { try AgentToolCatalog.decode(name: "deviceInfo", arguments: ["query": "passwords"]) }
        #expect(throws: Error.self) { try AgentToolCatalog.decode(name: "readFile", arguments: ["path": "../secret"]) }
    }

    @Test func sourceSpecificSchemaKeepsCalendarRequiredAndMailPaginationBounded() throws {
        let definitions = AgentToolCatalog.definitions(for: [.calendar, .mailInbox])
        let calendar = try #require(definitions[0]["function"] as? [String: Any])
        let parameters = try #require(calendar["parameters"] as? [String: Any])
        #expect(parameters["required"] as? [String] == ["from", "to"])
        let mail = try #require(definitions[1]["function"] as? [String: Any])
        let mailParameters = try #require(mail["parameters"] as? [String: Any])
        let properties = try #require(mailParameters["properties"] as? [String: Any])
        #expect((properties["offset"] as? [String: Any])?["maximum"] as? Int == 5_000)
    }
}
