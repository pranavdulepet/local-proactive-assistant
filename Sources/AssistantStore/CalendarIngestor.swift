import AssistantCore
import CryptoKit
import Foundation

public struct CalendarIngestionSummary: Equatable, Sendable {
    public let scanned: Int
    public let indexed: Int
    public let cursor: Int64
    public let startDate: Date
    public let endDate: Date

    public init(
        scanned: Int,
        indexed: Int,
        cursor: Int64,
        startDate: Date,
        endDate: Date
    ) {
        self.scanned = scanned
        self.indexed = indexed
        self.cursor = cursor
        self.startDate = startDate
        self.endDate = endDate
    }
}

public struct CalendarIngestor: Sendable {
    private let source: any CalendarEventSource
    private let store: ObservationStore
    private let clock: @Sendable () -> Date

    public init(
        source: any CalendarEventSource,
        store: ObservationStore,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.source = source
        self.store = store
        self.clock = clock
    }

    public func run(from startDate: Date, to endDate: Date) async throws -> CalendarIngestionSummary {
        guard startDate < endDate else {
            throw ObservationStoreFailure("Calendar scan start must be before its end")
        }

        var authorization = await source.authorizationStatus()
        if authorization == .notDetermined {
            _ = try await source.requestFullAccess()
            authorization = await source.authorizationStatus()
        }
        guard authorization == .fullAccess else {
            throw ObservationStoreFailure(
                "Calendar full access is required; current status is \(authorization.rawValue)"
            )
        }

        let savedCursor = try await store.sourceCursor(for: .calendar)
        if let savedCursor, Int64(savedCursor) == nil {
            throw ObservationStoreFailure("Stored Calendar cursor is not an integer")
        }
        let previousRevision = savedCursor.flatMap(Int64.init) ?? 0
        let syncDate = clock()
        let currentMilliseconds = Int64(syncDate.timeIntervalSince1970 * 1_000)
        let revision = max(currentMilliseconds, previousRevision + 1)
        let records = try await source.events(from: startDate, to: endDate)
        let observations = try records.map { try Self.observation(for: $0, revision: revision) }
        let indexed = try await store.record(
            observations,
            advancing: .calendar,
            cursor: String(revision)
        )
        try await store.refreshCoverage(
            for: .calendar,
            status: .partial,
            limitations: [
                "Coverage is limited to the requested refresh window.",
                "Deleted events are not yet reconciled.",
            ],
            at: syncDate
        )

        return CalendarIngestionSummary(
            scanned: records.count,
            indexed: indexed,
            cursor: revision,
            startDate: startDate,
            endDate: endDate
        )
    }

    private static func observation(
        for event: CalendarEventRecord,
        revision: Int64
    ) throws -> Observation {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let digest = SHA256.hash(data: try encoder.encode(event))
        let versionHash = digest.map { String(format: "%02x", $0) }.joined()
        let startMilliseconds = Int64(event.startDate.timeIntervalSince1970 * 1_000)

        return Observation(
            source: .calendar,
            externalID: event.externalID,
            versionHash: versionHash,
            sourceRevision: revision,
            sourceTimestamp: event.startDate,
            sourceEndTimestamp: event.endDate,
            trust: .structuredSource,
            handles: PersonHandle.normalize(
                [event.organizer].compactMap { $0 } + event.attendees
            ),
            text: searchText(for: event),
            locator: "eventkit:\(event.calendarItemIdentifier):\(startMilliseconds)"
        )
    }

    private static func searchText(for event: CalendarEventRecord) -> String {
        let formatter = ISO8601DateFormatter()
        var lines = [
            event.title,
            "Start: \(formatter.string(from: event.startDate))",
            "End: \(formatter.string(from: event.endDate))",
            "Calendar: \(event.calendarTitle)",
            "Status: \(event.status.rawValue)",
            "All day: \(event.isAllDay ? "yes" : "no")",
        ]
        if let timeZoneIdentifier = event.timeZoneIdentifier {
            lines.append("Time zone: \(timeZoneIdentifier)")
        }
        if let location = event.location, !location.isEmpty {
            lines.append("Location: \(location)")
        }
        if let organizer = event.organizer, !organizer.isEmpty {
            lines.append("Organizer: \(organizer)")
        }
        if !event.attendees.isEmpty {
            lines.append("Attendees: \(event.attendees.joined(separator: ", "))")
        }
        if !event.recurrenceRules.isEmpty {
            lines.append("Recurrence: \(event.recurrenceRules.joined(separator: "; "))")
        }
        if let notes = event.notes, !notes.isEmpty {
            lines.append("Notes: \(notes)")
        }
        return lines.joined(separator: "\n")
    }
}
