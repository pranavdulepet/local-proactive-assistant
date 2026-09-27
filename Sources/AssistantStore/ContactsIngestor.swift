import AssistantCore
import CryptoKit
import Foundation

public struct ContactsIngestionSummary: Equatable, Sendable {
    public let scanned: Int
    public let indexed: Int
    public let tombstoned: Int
    public let cursor: Int64
    public let authorization: ContactAuthorizationStatus

    public init(
        scanned: Int,
        indexed: Int,
        tombstoned: Int,
        cursor: Int64,
        authorization: ContactAuthorizationStatus
    ) {
        self.scanned = scanned
        self.indexed = indexed
        self.tombstoned = tombstoned
        self.cursor = cursor
        self.authorization = authorization
    }
}

public struct ContactsIngestor: Sendable {
    private let source: any ContactSource
    private let store: ObservationStore
    private let clock: @Sendable () -> Date

    public init(
        source: any ContactSource,
        store: ObservationStore,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.source = source
        self.store = store
        self.clock = clock
    }

    public func run() async throws -> ContactsIngestionSummary {
        var authorization = await source.authorizationStatus()
        if authorization == .notDetermined {
            _ = try await source.requestAccess()
            authorization = await source.authorizationStatus()
        }
        guard authorization == .authorized || authorization == .limited else {
            throw ObservationStoreFailure(
                "Contacts access is required; current status is \(authorization.rawValue)"
            )
        }

        let savedCursor = try await store.sourceCursor(for: .contacts)
        if let savedCursor, Int64(savedCursor) == nil {
            throw ObservationStoreFailure("Stored Contacts cursor is not an integer")
        }
        let previousRevision = savedCursor.flatMap(Int64.init) ?? 0
        let currentMilliseconds = Int64(clock().timeIntervalSince1970 * 1_000)
        let revision = max(currentMilliseconds, previousRevision + 1)
        let records = try await source.contacts()
        var observations = try records.map { try Self.observation(for: $0, revision: revision) }

        var removedIDs: [String] = []
        if authorization == .authorized {
            let previousIDs = try await store.currentExternalIDs(source: .contacts)
            let currentIDs = Set(records.map(\.externalID))
            removedIDs = previousIDs.subtracting(currentIDs).sorted()
            observations.append(contentsOf: removedIDs.map {
                Self.tombstone(for: $0, revision: revision)
            })
        }

        let inserted = try await store.record(
            observations,
            advancing: .contacts,
            cursor: String(revision)
        )
        return ContactsIngestionSummary(
            scanned: records.count,
            indexed: inserted - removedIDs.count,
            tombstoned: removedIDs.count,
            cursor: revision,
            authorization: authorization
        )
    }

    private static func observation(
        for contact: ContactRecord,
        revision: Int64
    ) throws -> Observation {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: try encoder.encode(contact))
        let versionHash = digest.map { String(format: "%02x", $0) }.joined()
        return Observation(
            source: .contacts,
            externalID: contact.externalID,
            versionHash: versionHash,
            sourceRevision: revision,
            trust: .structuredSource,
            text: searchText(for: contact),
            locator: "contacts:\(contact.externalID)"
        )
    }

    private static func tombstone(for externalID: String, revision: Int64) -> Observation {
        let versionInput = "contacts\u{1F}\(externalID)\u{1F}deleted\u{1F}\(revision)"
        let digest = SHA256.hash(data: Data(versionInput.utf8))
        let versionHash = digest.map { String(format: "%02x", $0) }.joined()
        return Observation(
            source: .contacts,
            externalID: externalID,
            versionHash: versionHash,
            sourceRevision: revision,
            trust: .structuredSource,
            text: "",
            locator: "contacts:\(externalID)",
            tombstone: true
        )
    }

    private static func searchText(for contact: ContactRecord) -> String {
        var lines = [contact.displayName]
        if let nickname = contact.nickname {
            lines.append("Nickname: \(nickname)")
        }
        if let organizationName = contact.organizationName {
            lines.append("Organization: \(organizationName)")
        }
        if let departmentName = contact.departmentName {
            lines.append("Department: \(departmentName)")
        }
        if let jobTitle = contact.jobTitle {
            lines.append("Job title: \(jobTitle)")
        }
        if !contact.phoneNumbers.isEmpty {
            lines.append("Phones: \(contact.phoneNumbers.joined(separator: ", "))")
        }
        if !contact.emailAddresses.isEmpty {
            lines.append("Emails: \(contact.emailAddresses.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }
}
