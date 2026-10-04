import AssistantCore
import Foundation

/// Durable, deduplicated model turns. The inbound cursor advances only after enqueue succeeds.
public actor ConversationInbox {
    public enum State: String, Codable, Equatable, Sendable {
        case queued, generating, sending, submitted, uncertain, failed
    }

    public struct Turn: Codable, Sendable {
        public let id: String
        public let question: String
        public let chatID: TransportChatID
        public let acceptedAt: Date
        public var state: State
    }

    public enum EnqueueResult: Equatable, Sendable { case accepted, duplicate, full }

    private let fileURL: URL?
    private var turns: [Turn]

    public init() {
        fileURL = nil
        turns = []
    }

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        let stored = FileManager.default.fileExists(atPath: fileURL.path)
            ? try JSONDecoder().decode([Turn].self, from: Data(contentsOf: fileURL))
            : []
        // Generation has no external effect and can resume. A send may have happened.
        turns = stored.map { turn in
            var recovered = turn
            if turn.state == .generating { recovered.state = .queued }
            if turn.state == .sending { recovered.state = .uncertain }
            return recovered
        }
    }

    public func enqueue(id: String, question: String, chatID: TransportChatID) throws -> EnqueueResult {
        if turns.contains(where: { $0.id == id }) { return .duplicate }
        let waiting = turns.filter { $0.state == .queued || $0.state == .generating }
        guard waiting.count < 16 else { return .full }
        turns.append(Turn(id: id, question: question, chatID: chatID, acceptedAt: Date(), state: .queued))
        do { try persist() } catch { turns.removeLast(); throw error }
        return .accepted
    }

    public func claim() throws -> Turn? {
        guard let index = turns.firstIndex(where: { $0.state == .queued }) else { return nil }
        turns[index].state = .generating
        do { try persist() } catch { turns[index].state = .queued; throw error }
        return turns[index]
    }

    public func mark(_ id: String, as state: State) throws {
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return }
        let previous = turns[index].state
        turns[index].state = state
        do { try persist() } catch { turns[index].state = previous; throw error }
    }

    public func hasQueued() -> Bool { turns.contains { $0.state == .queued } }

    public func counts() -> (queued: Int, uncertain: Int, failed: Int) {
        (turns.filter { $0.state == .queued || $0.state == .generating }.count,
         turns.filter { $0.state == .uncertain || $0.state == .sending }.count,
         turns.filter { $0.state == .failed }.count)
    }

    private func persist() throws {
        guard let fileURL else { return }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try JSONEncoder().encode(turns).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
