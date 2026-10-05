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
    }
}
