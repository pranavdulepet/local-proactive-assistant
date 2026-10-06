import AssistantCore
import Foundation

/// Durable, deduplicated model turns. The inbound cursor advances only after enqueue succeeds.
/// Recent IDs survive completed-turn pruning; the separately persisted inbound cursor rejects older replay.
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
        public var outboundRequestID: UUID? = nil
    }

    public enum EnqueueResult: Equatable, Sendable { case accepted, duplicate, full }

    private struct Snapshot: Codable {
        let schemaVersion: Int
        let turns: [Turn]
        let seenIDs: [String]
    }

    private static let terminalLimit = 256
    private static let uncertainLimit = 256
    private static let dedupLimit = 4_096

    private let fileURL: URL?
    private var turns: [Turn]
    private var seenIDs: [String]

    public init() {
        fileURL = nil
        turns = []
        seenIDs = []
    }

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        let stored: [Turn]
        let previousIDs: [String]
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            if let legacy = try? decoder.decode([Turn].self, from: data) {
                stored = legacy
                previousIDs = legacy.map(\.id)
            } else {
                let snapshot = try decoder.decode(Snapshot.self, from: data)
                guard snapshot.schemaVersion == 1 else {
                    throw ConversationInboxFailure("Unsupported conversation inbox version.")
                }
                stored = snapshot.turns
                previousIDs = snapshot.seenIDs
            }
        } else {
            stored = []
            previousIDs = []
        }
        // Generation has no external effect and can resume. A send may have happened.
        let recovered = stored.map { turn in
            var recovered = turn
            if turn.state == .generating { recovered.state = .queued }
            if turn.state == .sending { recovered.state = .uncertain }
            return recovered
        }
        turns = Self.retained(recovered)
        seenIDs = Self.retainedIDs(previousIDs + stored.map(\.id))
    }

    public func enqueue(id: String, question: String, chatID: TransportChatID) throws -> EnqueueResult {
        if seenIDs.contains(id) || turns.contains(where: { $0.id == id }) { return .duplicate }
        let waiting = turns.filter { $0.state == .queued || $0.state == .generating }
        guard waiting.count < 16 else { return .full }
        let previousIDs = seenIDs
        turns.append(Turn(id: id, question: question, chatID: chatID, acceptedAt: Date(), state: .queued))
        seenIDs = Self.retainedIDs(seenIDs + [id])
        do { try persist() } catch {
            turns.removeLast()
            seenIDs = previousIDs
            throw error
        }
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
        let previous = turns
        turns[index].state = state
        turns = Self.retained(turns)
        do { try persist() } catch { turns = previous; throw error }
    }

    public func markSending(_ id: String, requestID: UUID) throws {
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return }
        let previous = turns[index]
        turns[index].outboundRequestID = requestID
        turns[index].state = .sending
        do { try persist() } catch { turns[index] = previous; throw error }
    }

    public func uncertainTurns() -> [Turn] {
        turns.filter { $0.state == .uncertain || $0.state == .sending }
    }

    public func reconcile(requestID: UUID) throws {
        guard let index = turns.firstIndex(where: {
            $0.outboundRequestID == requestID && ($0.state == .uncertain || $0.state == .sending)
        }) else { return }
        let previous = turns[index].state
        turns[index].state = .submitted
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
        let snapshot = Snapshot(schemaVersion: 1, turns: turns, seenIDs: seenIDs)
        try JSONEncoder().encode(snapshot).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private static func retained(_ stored: [Turn]) -> [Turn] {
        var terminal = 0
        var uncertain = 0
        return Array(stored.reversed().filter { turn in
            switch turn.state {
            case .submitted, .failed:
                terminal += 1
                return terminal <= terminalLimit
            case .uncertain:
                uncertain += 1
                return uncertain <= uncertainLimit
            case .queued, .generating, .sending:
                return true
            }
        }.reversed())
    }

    private static func retainedIDs(_ identifiers: [String]) -> [String] {
        var seen = Set<String>()
        return Array(identifiers.reversed().filter { seen.insert($0).inserted }
            .prefix(dedupLimit).reversed())
    }
}

private struct ConversationInboxFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
