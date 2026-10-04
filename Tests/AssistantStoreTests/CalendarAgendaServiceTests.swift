import AssistantCore
import Foundation
import Testing
@testable import AssistantStore

struct CalendarAgendaServiceTests {
    @Test
    func answersTomorrowFromIndexedEventsWithoutAskingTheModel() async throws {
        let calendar = Calendar.autoupdatingCurrent
        let now = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 10, day: 4, hour: 12
        )))
        let tomorrow = try #require(calendar.date(
            byAdding: .day, value: 1, to: calendar.startOfDay(for: now)
        ))
        let store = try ObservationStore()
        let event = Observation(
            source: .calendar, externalID: "event-1", versionHash: "v1",
            sourceRevision: 1, sourceTimestamp: tomorrow.addingTimeInterval(10 * 3600),
            trust: .structuredSource,
            text: "Team sync\nStart: 2026-10-05T10:00:00Z\nStatus: confirmed\nAll day: no",
            locator: "eventkit:event-1"
        )
        try await store.record(event)
        try await store.refreshCoverage(
            for: .calendar, status: .partial,
            limitations: ["Deleted events are not yet reconciled."], at: now
        )
        let handler = ControlCommandHandler(
            store: store, clock: { now },
            answerQuestion: { _ in "model should not answer an exact agenda query" }
        )

        let reply = try #require(try await handler.response(to: "What is on my calendar tomorrow?"))
        #expect(reply.contains("Team sync"))
        #expect(reply.contains("eventkit:event-1"))
        #expect(reply.contains("Calendar partial"))
        #expect(!reply.contains("model should not answer"))
        #expect(try await handler.response(to: "/ask what is on my calendar tomorrow") == reply)
    }

    @Test
    func emptyAgendaDoesNotClaimTheCalendarIsComplete() async throws {
        let store = try ObservationStore()
        let now = Date()
        try await store.refreshCoverage(
            for: .calendar, status: .partial,
            limitations: ["Deleted events are not yet reconciled."], at: now
        )
        let reply = try #require(try await CalendarAgendaService(
            store: store, clock: { now }
        ).response(to: "What's on my schedule today?"))
        #expect(reply.contains("No indexed Calendar events start today."))
        #expect(reply.contains("Calendar partial"))
        #expect(reply.contains("Deleted events are not yet reconciled."))
    }
}
