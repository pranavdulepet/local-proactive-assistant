import AssistantCore
import Foundation
import Testing
@testable import AssistantStore

struct CalendarIngestorTests {
    @Test
    func requestsAccessAndIndexesNormalizedEvents() async throws {
        let event = CalendarEventRecord(
            externalID: "event-1",
            calendarItemIdentifier: "local-1",
            title: "Project Cedar review",
            startDate: Date(timeIntervalSince1970: 1_800_000_000),
            endDate: Date(timeIntervalSince1970: 1_800_003_600),
            timeZoneIdentifier: "America/New_York",
            calendarTitle: "Work",
            location: "Room 4",
            organizer: "mailto:owner@example.com",
            attendees: ["mailto:teammate@example.com"],
            notes: "Bring the launch checklist",
            recurrenceRules: ["weekly"],
            status: .confirmed,
            lastModifiedDate: Date(timeIntervalSince1970: 1_799_000_000)
        )
        let source = FakeCalendarEventSource(
            authorization: .notDetermined,
            events: [event]
        )
        let store = try ObservationStore()
        let ingestor = CalendarIngestor(
            source: source,
            store: store,
            clock: { Date(timeIntervalSince1970: 1_900_000_000) }
        )
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let end = Date(timeIntervalSince1970: 1_910_000_000)

        let summary = try await ingestor.run(from: start, to: end)

        #expect(summary == CalendarIngestionSummary(
            scanned: 1,
            indexed: 1,
            cursor: 1_900_000_000_000,
            startDate: start,
            endDate: end
        ))
        #expect(await source.accessRequestCount() == 1)
        #expect(await source.requestedWindows() == [CalendarWindow(start: start, end: end)])
        #expect(try await store.sourceCursor(for: .calendar) == "1900000000000")

        let stored = try await store.current(source: .calendar, externalID: "event-1")
        #expect(stored?.trust == .structuredSource)
        #expect(stored?.locator == "eventkit:local-1:1800000000000")
        #expect(stored?.text.contains("Project Cedar review") == true)
        #expect(stored?.text.contains("Room 4") == true)
        #expect(stored?.text.contains("Bring the launch checklist") == true)
        #expect(stored?.handles == ["owner@example.com", "teammate@example.com"])
        #expect(try await store.search("Cedar", sources: [.calendar]).count == 1)
        #expect(try await store.sourceCoverage(for: .calendar)?.status == .partial)
    }

    @Test
    func unchangedRefreshIsIdempotentAndAdvancesTheScanCursor() async throws {
        let event = CalendarEventRecord(
            externalID: "event-1",
            calendarItemIdentifier: "local-1",
            title: "Dentist",
            startDate: Date(timeIntervalSince1970: 2_000),
            endDate: Date(timeIntervalSince1970: 3_000),
            calendarTitle: "Personal"
        )
        let source = FakeCalendarEventSource(authorization: .fullAccess, events: [event])
        let store = try ObservationStore()
        try await store.record([], advancing: .calendar, cursor: "5000")
        let ingestor = CalendarIngestor(
            source: source,
            store: store,
            clock: { Date(timeIntervalSince1970: 4) }
        )

        let first = try await ingestor.run(
            from: Date(timeIntervalSince1970: 1_000),
            to: Date(timeIntervalSince1970: 4_000)
        )
        let second = try await ingestor.run(
            from: Date(timeIntervalSince1970: 1_000),
            to: Date(timeIntervalSince1970: 4_000)
        )

        #expect(first.indexed == 1)
        #expect(first.cursor == 5_001)
        #expect(second.indexed == 0)
        #expect(second.cursor == 5_002)
        #expect(try await store.sourceCursor(for: .calendar) == "5002")
    }

    @Test
    func deniedAccessDoesNotAdvanceTheCursor() async throws {
        let source = FakeCalendarEventSource(authorization: .denied, events: [])
        let store = try ObservationStore()

        do {
            _ = try await CalendarIngestor(source: source, store: store).run(
                from: Date(timeIntervalSince1970: 1_000),
                to: Date(timeIntervalSince1970: 2_000)
            )
            Issue.record("Expected denied Calendar access to fail")
        } catch let error as ObservationStoreFailure {
            #expect(error.description.contains("denied"))
        }

        #expect(try await store.sourceCursor(for: .calendar) == nil)
        #expect(await source.requestedWindows().isEmpty)
    }
}

private struct CalendarWindow: Equatable, Sendable {
    let start: Date
    let end: Date
}

private actor FakeCalendarEventSource: CalendarEventSource {
    private var authorization: CalendarAuthorizationStatus
    private let availableEvents: [CalendarEventRecord]
    private var accessRequests = 0
    private var windows: [CalendarWindow] = []

    init(
        authorization: CalendarAuthorizationStatus,
        events: [CalendarEventRecord]
    ) {
        self.authorization = authorization
        availableEvents = events
    }

    func authorizationStatus() -> CalendarAuthorizationStatus {
        authorization
    }

    func requestFullAccess() -> Bool {
        accessRequests += 1
        authorization = .fullAccess
        return true
    }

    func events(from startDate: Date, to endDate: Date) -> [CalendarEventRecord] {
        windows.append(CalendarWindow(start: startDate, end: endDate))
        return availableEvents
    }

    func accessRequestCount() -> Int {
        accessRequests
    }

    func requestedWindows() -> [CalendarWindow] {
        windows
    }
}
