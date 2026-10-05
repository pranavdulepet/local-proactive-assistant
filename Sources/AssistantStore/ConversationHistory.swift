import Foundation
import LocalInference

/// A small private transcript shared by the Mac's verified self-chat routes.
public actor ConversationHistory {
    private struct Snapshot: Codable {
        let schemaVersion: Int
        let turns: [ChatTurn]
        let sourceIDs: [String]
    }

    private let fileURL: URL?
    private var turns: [ChatTurn]
    private var sourceIDs: [String]

    public init() {
        fileURL = nil
        turns = []
        sourceIDs = []
    }

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            if let legacy = try? decoder.decode([ChatTurn].self, from: data) {
                turns = legacy
                sourceIDs = []
            } else {
                let snapshot = try decoder.decode(Snapshot.self, from: data)
                guard snapshot.schemaVersion == 1 else {
                    throw LocalModelFailure("Unsupported conversation history version.")
                }
                turns = snapshot.turns
                sourceIDs = Array(snapshot.sourceIDs.suffix(4_096))
            }
        } else {
            turns = []
            sourceIDs = []
        }
        turns = Array(turns.suffix(8))
    }

    public func recent() -> [ChatTurn] { turns }

    public func lastUserMessage() -> String? {
        turns.last(where: { $0.role == .user })?.text
    }

    public func append(user: String, assistant: String, sourceID: String? = nil) throws {
        if let sourceID, sourceIDs.contains(sourceID) { return }
        let previousTurns = turns
        let previousIDs = sourceIDs
        turns.append(ChatTurn(role: .user, text: EvidenceText.bounded(user, bytes: 2_048)))
        turns.append(ChatTurn(role: .assistant, text: EvidenceText.bounded(assistant, bytes: 2_048)))
        turns = Array(turns.suffix(8))
        if let sourceID { sourceIDs = Array((sourceIDs + [sourceID]).suffix(4_096)) }
        do { try persist() } catch {
            turns = previousTurns
            sourceIDs = previousIDs
            throw error
        }
    }

    private func persist() throws {
        guard let fileURL else { return }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let snapshot = Snapshot(schemaVersion: 1, turns: turns, sourceIDs: sourceIDs)
        try JSONEncoder().encode(snapshot).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    public func clear() throws {
        let previousTurns = turns
        let previousIDs = sourceIDs
        turns = []
        sourceIDs = []
        do { try persist() } catch {
            turns = previousTurns
            sourceIDs = previousIDs
            throw error
        }
    }
}
