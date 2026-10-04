import Foundation
import LocalInference

/// A small private transcript shared by the Mac's verified self-chat routes.
public actor ConversationHistory {
    private let fileURL: URL?
    private var turns: [ChatTurn]

    public init(fileURL: URL? = nil) throws {
        self.fileURL = fileURL
        if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
            turns = try JSONDecoder().decode([ChatTurn].self, from: Data(contentsOf: fileURL))
        } else {
            turns = []
        }
        turns = Array(turns.suffix(8))
    }

    public func recent() -> [ChatTurn] { turns }

    public func lastUserMessage() -> String? {
        turns.last(where: { $0.role == .user })?.text
    }

    public func append(user: String, assistant: String) throws {
        turns.append(ChatTurn(role: .user, text: EvidenceText.bounded(user, bytes: 512)))
        turns.append(ChatTurn(role: .assistant, text: EvidenceText.bounded(assistant, bytes: 512)))
        turns = Array(turns.suffix(8))
        guard let fileURL else { return }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try JSONEncoder().encode(turns).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    public func clear() throws {
        turns = []
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }
}
