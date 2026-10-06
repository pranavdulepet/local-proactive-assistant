import Foundation
import Darwin
import LocalInference

/// Last observed access, not a promise that a source is complete or still available.
public actor SourceAccessRegistry {
    public struct Entry: Codable, Equatable, Sendable {
        public let tool: ContextTool
        public let ready: Bool
        public let checkedAt: Date
        public let detail: String
    }

    private let fileURL: URL?
    private var entries: [Entry]

    public init(fileURL: URL? = nil) throws {
        self.fileURL = fileURL
        if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
            entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: fileURL))
        } else { entries = [] }
    }

    public func record(tool: ContextTool, ready: Bool, detail: String, at date: Date = Date()) throws {
        var descriptor: Int32 = -1
        if let fileURL {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            descriptor = open(fileURL.path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard descriptor >= 0, flock(descriptor, LOCK_EX) == 0 else {
                if descriptor >= 0 { close(descriptor) }
                throw LocalModelFailure("Source access status could not be updated.")
            }
        }
        defer { if descriptor >= 0 { flock(descriptor, LOCK_UN); close(descriptor) } }
        if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
            entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: fileURL))
        }
        if let latest = entries.first(where: { $0.tool == tool }), latest.checkedAt > date { return }
        let previous = entries
        entries.removeAll { $0.tool == tool }
        entries.append(Entry(tool: tool, ready: ready, checkedAt: date,
            detail: EvidenceText.bounded(detail, bytes: 512)))
        do { try persist() } catch { entries = previous; throw error }
    }

    public func snapshot() -> [Entry] {
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let latest = try? JSONDecoder().decode([Entry].self, from: data) { entries = latest }
        return entries.sorted { $0.tool.rawValue < $1.tool.rawValue }
    }

    public static func name(_ tool: ContextTool) -> String {
        switch tool {
        case .mailInbox: "Mail"
        case .notes: "Notes"
        case .reminders: "Reminders"
        case .searchFiles, .readFile: "Documents"
        case .searchIndex: "Personal index"
        case .messages: "Messages"
        case .calendar: "Calendar"
        case .contacts: "Contacts"
        case .photos: "Photos"
        case .deviceInfo: "Mac information"
        }
    }

    private func persist() throws {
        guard let fileURL else { return }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(entries).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
