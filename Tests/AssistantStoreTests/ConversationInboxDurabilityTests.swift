import AssistantCore
import Foundation
import Testing
@testable import AssistantStore

struct ConversationInboxDurabilityTests {
    @Test func legacyInboxPrunesTerminalRecordsWithoutReplayingTheirRecentIDs() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("inbox.json")
        let chat = TransportChatID(rawValue: 954)
        var legacy: [ConversationInbox.Turn] = (0..<300).map {
            .init(id: "submitted-\($0)", question: "stored question", chatID: chat,
                  acceptedAt: Date(timeIntervalSince1970: Double($0)), state: .submitted)
        }
        legacy += (0..<300).map {
            .init(id: "uncertain-\($0)", question: "stored question", chatID: chat,
                  acceptedAt: Date(timeIntervalSince1970: Double($0 + 300)), state: .uncertain)
        }
        legacy.append(.init(id: "resume-generation", question: "resume me", chatID: chat,
                            acceptedAt: Date(), state: .generating))
        legacy.append(.init(id: "interrupted-send", question: "do not resend", chatID: chat,
                            acceptedAt: Date(), state: .sending))
        try JSONEncoder().encode(legacy).write(to: file)

        let inbox = try ConversationInbox(fileURL: file)
        #expect(await inbox.counts().uncertain == 256)
        #expect(try await inbox.enqueue(id: "submitted-0", question: "duplicate", chatID: chat) == .duplicate)
        #expect(try await inbox.enqueue(id: "uncertain-0", question: "duplicate", chatID: chat) == .duplicate)
        #expect(try await inbox.claim()?.id == "resume-generation")
        #expect(try await inbox.claim() == nil)
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let retained = try #require(object["turns"] as? [[String: Any]])
        #expect(retained.filter { $0["state"] as? String == "submitted" }.count == 256)
        #expect(retained.filter { $0["state"] as? String == "uncertain" }.count == 256)

        let restarted = try ConversationInbox(fileURL: file)
        #expect(try await restarted.enqueue(id: "submitted-0", question: "duplicate", chatID: chat) == .duplicate)
        #expect(try await restarted.claim()?.id == "resume-generation")
    }

    @Test func inboxDedupFileHasABoundedSizeAfterLegacyMigration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("inbox.json")
        let chat = TransportChatID(rawValue: 954)
        let legacy = (0..<4_500).map {
            ConversationInbox.Turn(id: "legacy-\($0)", question: "stored", chatID: chat,
                acceptedAt: Date(timeIntervalSince1970: Double($0)), state: .submitted)
        }
        try JSONEncoder().encode(legacy).write(to: file)
        let inbox = try ConversationInbox(fileURL: file)
        #expect(try await inbox.enqueue(id: "new", question: "fresh", chatID: chat) == .accepted)
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect((object["seenIDs"] as? [String])?.count == 4_096)
        #expect((object["turns"] as? [[String: Any]])?.count == 257)
        let restarted = try ConversationInbox(fileURL: file)
        #expect(try await restarted.enqueue(id: "legacy-4_499", question: "duplicate", chatID: chat) == .duplicate)
        #expect(try await restarted.claim()?.id == "new")
    }

    @Test func failedInboxWritesRestoreQueueAndDedupState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = directory.appendingPathComponent("state")
        let saved = directory.appendingPathComponent("saved")
        let inbox = try ConversationInbox(fileURL: state.appendingPathComponent("inbox.json"))
        let chat = TransportChatID(rawValue: 954)
        #expect(try await inbox.enqueue(id: "first", question: "first", chatID: chat) == .accepted)
        try FileManager.default.moveItem(at: state, to: saved)
        try Data("block directory creation".utf8).write(to: state)
        await #expect(throws: (any Error).self) { _ = try await inbox.claim() }
        await #expect(throws: (any Error).self) {
            _ = try await inbox.enqueue(id: "retry", question: "retry", chatID: chat)
        }
        #expect(await inbox.counts().queued == 1)
        try FileManager.default.removeItem(at: state)
        try FileManager.default.moveItem(at: saved, to: state)
        #expect(try await inbox.enqueue(id: "retry", question: "retry", chatID: chat) == .accepted)
        #expect(try await inbox.claim()?.id == "first")
        try FileManager.default.moveItem(at: state, to: saved)
        try Data("block directory creation".utf8).write(to: state)
        await #expect(throws: (any Error).self) { try await inbox.mark("first", as: .submitted) }
        #expect(await inbox.counts().queued == 2)
        try FileManager.default.removeItem(at: state)
        try FileManager.default.moveItem(at: saved, to: state)
        try await inbox.mark("first", as: .failed)
        #expect(await inbox.counts().failed == 1)
        #expect(try await inbox.claim()?.id == "retry")
    }
}
