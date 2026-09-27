import Foundation

public actor CursorStore {
    private let fileURL: URL?
    private var cursors: [String: Int64]

    public init() {
        fileURL = nil
        cursors = [:]
    }

    public init(fileURL: URL) throws {
        self.fileURL = fileURL

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            cursors = [:]
            return
        }

        let data = try Data(contentsOf: fileURL)
        cursors = try JSONDecoder().decode([String: Int64].self, from: data)
    }

    public func cursor(for chatID: TransportChatID) -> TransportCursor? {
        cursors[String(chatID.rawValue)].map(TransportCursor.init(rawValue:))
    }

    public func advance(
        chatID: TransportChatID,
        to cursor: TransportCursor
    ) throws {
        let key = String(chatID.rawValue)
        guard cursor.rawValue > (cursors[key] ?? .min) else { return }

        cursors[key] = cursor.rawValue
        try persist()
    }

    private func persist() throws {
        guard let fileURL else { return }

        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let data = try JSONEncoder().encode(cursors)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }
}
