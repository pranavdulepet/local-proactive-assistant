import Foundation
import Testing
@testable import AssistantCore

struct CursorStoreTests {
    @Test
    func persistsMonotonicCursorsPerChat() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("cursors.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstChat = TransportChatID(rawValue: 42)
        let secondChat = TransportChatID(rawValue: 84)
        let store = try CursorStore(fileURL: fileURL)

        try await store.advance(
            chatID: firstChat,
            to: TransportCursor(rawValue: 12)
        )
        try await store.advance(
            chatID: firstChat,
            to: TransportCursor(rawValue: 10)
        )
        try await store.advance(
            chatID: secondChat,
            to: TransportCursor(rawValue: 7)
        )

        let reloaded = try CursorStore(fileURL: fileURL)
        let firstCursor = await reloaded.cursor(for: firstChat)
        let secondCursor = await reloaded.cursor(for: secondChat)

        #expect(firstCursor == TransportCursor(rawValue: 12))
        #expect(secondCursor == TransportCursor(rawValue: 7))
    }
}
