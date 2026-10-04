import AssistantCore
import Foundation
import Testing
@testable import AssistantStore

struct ConversationInboxTests {
    @Test func replaysGenerationButNeverRepeatsAnUncertainSend() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("inbox.json")
        let first = try ConversationInbox(fileURL: file)
        let chat = TransportChatID(rawValue: 954)
        #expect(try await first.enqueue(id: "954:guid-1", question: "hello", chatID: chat) == .accepted)
        #expect(try await first.enqueue(id: "954:guid-1", question: "hello", chatID: chat) == .duplicate)
        #expect(try await first.claim()?.id == "954:guid-1")

        let restarted = try ConversationInbox(fileURL: file)
        #expect(try await restarted.claim()?.id == "954:guid-1")
        try await restarted.mark("954:guid-1", as: .sending)

        let uncertain = try ConversationInbox(fileURL: file)
        #expect(try await uncertain.claim()?.id == nil)
        #expect(await uncertain.counts().uncertain == 1)
        #expect(try await uncertain.enqueue(id: "954:guid-1", question: "hello", chatID: chat) == .duplicate)
        #expect(try await uncertain.enqueue(id: "955:guid-2", question: "next", chatID: .init(rawValue: 955)) == .accepted)
        #expect(try await uncertain.claim()?.id == "955:guid-2")
    }
}
