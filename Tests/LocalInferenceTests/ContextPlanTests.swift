import Foundation
import Testing
@testable import LocalInference

struct ContextPlanTests {
    @Test func schemaDecoderRejectsUnknownToolsAndUnexpectedFields() throws {
        let request = ContextPlanRequest(message: "Find my document", history: [], availableTools: [.searchFiles])
        for json in [
            #"{"calls":[{"tool":"shell","query":"cat secrets"}]}"#,
            #"{"calls":[],"command":"rm -rf"}"#,
            #"{"calls":[{"tool":"searchFiles","query":"document","recipient":"other"}]}"#,
            #"{"calls":"searchFiles"}"#
        ] {
            #expect(throws: Error.self) { try ContextPlan.decodeJSON(Data(json.utf8), for: request) }
        }
        let valid = try ContextPlan.decodeJSON(
            Data(#"{"calls":[{"tool":"searchFiles","query":"document","path":null}]}"#.utf8), for: request
        )
        #expect(valid.calls == [ContextToolCall(tool: .searchFiles, query: "document")])
    }

    @Test func plannerCannotExceedBudgetOrRequestUnavailableOrRepeatedReads() throws {
        let prior = ContextToolCall(tool: .searchIndex, query: "calendar tomorrow")
        let request = ContextPlanRequest(message: "Any conflicts?", history: [], availableTools: [.searchIndex],
            executedCalls: [prior], remainingCalls: 1)
        let invalid = [
            ContextPlan(calls: [prior]),
            ContextPlan(calls: [ContextToolCall(tool: .mailInbox)]),
            ContextPlan(calls: [ContextToolCall(tool: .searchIndex, query: "calendar today"),
                ContextToolCall(tool: .searchIndex, query: "calendar next week")])
        ]
        for plan in invalid { #expect(throws: Error.self) { try plan.validate(for: request) } }
    }

    @Test func filePathsAndQueriesStayWithinReadContract() throws {
        for path in ["relative.txt", "/Users/owner/../secret", "/tmp/\0file", "/" + String(repeating: "a", count: 1_024)] {
            #expect(throws: Error.self) { try ContextToolCall(tool: .readFile, path: path).validate() }
        }
        #expect(throws: Error.self) { try ContextToolCall(tool: .readFile, query: "extra", path: "/tmp/document").validate() }
        #expect(throws: Error.self) { try ContextToolCall(tool: .searchFiles).validate() }
        #expect(throws: Error.self) { try ContextToolCall(tool: .searchIndex, query: String(repeating: "a", count: 257)).validate() }
        #expect(throws: Error.self) { try ContextToolCall(tool: .deviceInfo, query: "run anything").validate() }
        try ContextToolCall(tool: .readFile, path: "/Users/owner/Documents/notes.txt").validate()
    }

    @Test func planningRoundTripsThroughSandboxWorkerWire() throws {
        let request = ContextPlanRequest(message: "What needs my attention?", history: [], availableTools: [.mailInbox],
            createdAt: Date(timeIntervalSince1970: 10))
        let wire = ModelWireRequest(operation: .planContext, contextPlanRequest: request)
        let decoded = try JSONDecoder().decode(ModelWireRequest.self, from: JSONEncoder().encode(wire))
        #expect(decoded.operation == .planContext)
        #expect(decoded.contextPlanRequest == request)
        let plan = ContextPlan(calls: [ContextToolCall(tool: .mailInbox)])
        let response = try JSONDecoder().decode(ModelWireResponse.self,
            from: JSONEncoder().encode(ModelWireResponse(contextPlan: plan)))
        #expect(response.contextPlan == plan)
        let failure = try JSONDecoder().decode(ModelWireResponse.self,
            from: JSONEncoder().encode(ModelWireResponse(failure: "Invalid plan", failureKind: "contextPlan")))
        #expect(failure.failureKind == "contextPlan")
    }

    @Test func replyOrReadsContractIsBackwardCompatibleAndRejectsFalseReadClaims() throws {
        let request = ContextPlanRequest(message: "Done", history: [], availableTools: [.mailInbox])
        let legacy = try ContextPlan.decodeJSON(Data(#"{"calls":[]}"#.utf8), for: request)
        #expect(legacy.reply == nil)
        let direct = try ContextPlan.decodeJSON(Data(#"{"calls":[],"reply":"Thanks. What would you like to check?"}"#.utf8), for: request)
        #expect(direct.reply?.contains("Thanks") == true)
        for plan in [
            ContextPlan(calls: [], reply: "I checked the inbox and it works."),
            ContextPlan(calls: [], reply: "I sent the reminder."),
            ContextPlan(calls: [], reply: "Your meeting is at noon. [e1]"),
            ContextPlan(calls: [ContextToolCall(tool: .mailInbox)], reply: "I will check that.")
        ] {
            #expect(throws: Error.self) { try plan.validate(for: request) }
        }
    }

    @Test func finalReplyCannotInventCitationOrClaimFailedReadSucceeded() throws {
        let failed = ChatRequest(message: "Check it again", history: [],
            coverage: ["Mail read failed without an identified cause."],
            contextReads: [ContextReadStatus(tool: .mailInbox, outcome: .failed, recordCount: 0)])
        #expect(throws: Error.self) { try ChatReply(text: "I checked your inbox.").validate(for: failed) }
        #expect(throws: Error.self) { try ChatReply(text: "Your invoice is ready. [e77]").validate(for: failed) }
        try ChatReply(text: "I couldn't read the inbox this time.").validate(for: failed)
        try ChatReply(text: "I changed my mind about the wording.").validate(for: failed)
        try ChatReply(text: "I read your message. What would you like to do next?").validate(for: failed)
        try ChatReply(text: #"The phrase "I checked your email" describes a completed check."#).validate(for: failed)
        let empty = ChatRequest(message: "Any reminders?", history: [],
            contextReads: [ContextReadStatus(tool: .reminders, outcome: .empty, recordCount: 0)])
        try ChatReply(text: "I checked the supplied reminder snapshot; it has no items.").validate(for: empty)
    }

    @Test func completeOwnerMessageAndUsefulHistoryAreRetained() throws {
        let message = String(repeating: "a", count: 4_096)
        let turn = ChatTurn(role: .user, text: String(repeating: "b", count: 2_048))
        try ChatRequest(message: message, history: [turn]).validate()
        try ContextPlanRequest(message: message, history: [turn], availableTools: [.searchIndex]).validate()
        #expect(throws: Error.self) { try ChatRequest(message: message + "a", history: []).validate() }
        #expect(throws: Error.self) { try ChatRequest(message: "Question", history: [ChatTurn(role: .user, text: turn.text + "b")]).validate() }
    }
}
