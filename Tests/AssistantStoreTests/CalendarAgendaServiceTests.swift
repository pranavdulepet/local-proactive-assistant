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
        let handler = ControlCommandHandler(store: store, clock: { now })

        let reply = try #require(try await handler.response(to: "What is on my calendar tomorrow?"))
        #expect(reply.contains("Team sync"))
        #expect(reply.contains("— Team sync"))
        #expect(!reply.contains("eventkit:"))
        #expect(reply.contains("Calendar data may be incomplete"))
        #expect(try await handler.response(to: "/ask what is on my calendar tomorrow") == reply)
        #expect(try await handler.response(to: "What is on my calendar tmr") == reply)
    }

    @Test func enabledConversationReceivesCalendarTurnsAndMixedRequestsAvoidTheFastPath() async throws {
        let store = try ObservationStore()
        let handler = ControlCommandHandler(store: store, answerQuestion: { _ in "conversation turn queued" })
        #expect(try await handler.response(to: "What is on my calendar tomorrow?") == "conversation turn queued")
        #expect(try await CalendarAgendaService(store: store).response(
            to: "What should I prepare tomorrow based on my calendar and emails?") == nil)
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
        #expect(reply.contains("I don't see any events starting today."))
        #expect(reply.contains("Calendar data may be incomplete"))
        #expect(!reply.contains("Deleted events are not yet reconciled."))
    }
}
