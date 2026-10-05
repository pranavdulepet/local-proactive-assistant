import Foundation
import LocalInference
import Testing
@testable import AssistantStore

struct ConversationHistoryDurabilityTests {
    @Test func longUnicodeTurnsRemainUsableForFollowUpWithoutSplittingCharacters() async throws {
        let history = ConversationHistory()
        let user = String(repeating: "会議の予定🙂", count: 140)
        let answer = String(repeating: "Tomorrow's review covers the launch plan. ", count: 60)
        try await history.append(user: user, assistant: answer, sourceID: "long-turn")
        let recent = await history.recent()
        #expect(recent.count == 2)
        #expect(recent[0].text.utf8.count > 512)
        #expect(recent[0].text.utf8.count <= 2_048)
        #expect(user.hasPrefix(recent[0].text))
        #expect(answer.hasPrefix(recent[1].text))
        #expect(recent[1].text.utf8.count > 512)
        #expect(recent[1].text.utf8.count <= 2_048)
        #expect(await history.lastUserMessage() == recent[0].text)
        try await history.append(user: "What about the review?", assistant: "The review is tomorrow.")
        #expect(await history.recent().prefix(2).map(\.text) == recent.map(\.text))
    }

    @Test func legacyTranscriptRemainsReadableAndSourceDedupSurvivesRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("history.json")
        try JSONEncoder().encode([ChatTurn(role: .user, text: "legacy question"),
                                  ChatTurn(role: .assistant, text: "legacy answer")]).write(to: file)
        let history = try ConversationHistory(fileURL: file)
        #expect(await history.recent().count == 2)
        try await history.append(user: "new question", assistant: "new answer", sourceID: "guid-1")
        try await history.append(user: "duplicate question", assistant: "duplicate answer", sourceID: "guid-1")
        #expect(await history.recent().count == 4)
        let restarted = try ConversationHistory(fileURL: file)
        try await restarted.append(user: "duplicate question", assistant: "duplicate answer", sourceID: "guid-1")
        #expect(await restarted.recent().map(\.text) == ["legacy question", "legacy answer", "new question", "new answer"])
    }

    @Test func failedTranscriptWritesRollbackAppendDedupAndClear() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = directory.appendingPathComponent("state")
        let saved = directory.appendingPathComponent("saved")
        let file = state.appendingPathComponent("history.json")
        let history = try ConversationHistory(fileURL: file)
        try await history.append(user: "saved question", assistant: "saved answer", sourceID: "first")
        let previous = await history.recent()
        try FileManager.default.moveItem(at: state, to: saved)
        try Data("block directory creation".utf8).write(to: state)
        await #expect(throws: (any Error).self) {
            try await history.append(user: "retry question", assistant: "retry answer", sourceID: "retry")
        }
        #expect(await history.recent() == previous)
        await #expect(throws: (any Error).self) { try await history.clear() }
        #expect(await history.recent() == previous)
        try FileManager.default.removeItem(at: state)
        try FileManager.default.moveItem(at: saved, to: state)
        try await history.append(user: "retry question", assistant: "retry answer", sourceID: "retry")
        #expect(await history.recent().count == 4)
        try await history.clear()
        let restarted = try ConversationHistory(fileURL: file)
        #expect(await restarted.recent().isEmpty)
        try await restarted.append(user: "fresh question", assistant: "fresh answer", sourceID: "first")
        #expect(await restarted.recent().count == 2)
    }
}
