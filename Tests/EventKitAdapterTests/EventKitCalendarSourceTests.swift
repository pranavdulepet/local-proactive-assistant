import EventKit
import Foundation
import Testing
@testable import EventKitAdapter

struct EventKitCalendarSourceTests {
    @Test
    func equivalentRecurrenceRulesHaveTheSameDescription() {
        let first = weeklyRule()
        let second = weeklyRule()

        #expect(
            EventKitCalendarSource.recurrenceDescription(first)
                == EventKitCalendarSource.recurrenceDescription(second)
        )
        let description = EventKitCalendarSource.recurrenceDescription(first)
        #expect(description.contains("frequency=weekly"))
        #expect(description.contains("interval=2"))
        #expect(description.contains("weekdays=2:0,4:0"))
        #expect(description.contains("occurrenceCount=10"))
        #expect(!description.contains("0x"))
    }

    @Test
    func recurringOccurrencesHaveStableDistinctExternalIDs() {
        let originalOccurrence = Date(timeIntervalSince1970: 1_800_000_000)
        let movedStart = Date(timeIntervalSince1970: 1_800_003_600)
        let nextOccurrence = Date(timeIntervalSince1970: 1_800_604_800)

        let originalID = EventKitCalendarSource.externalID(
            eventIdentifier: "series-1",
            calendarItemIdentifier: "local-1",
            occurrenceDate: originalOccurrence,
            startDate: originalOccurrence,
            isRecurring: true
        )
        let movedID = EventKitCalendarSource.externalID(
            eventIdentifier: "series-1",
            calendarItemIdentifier: "local-1",
            occurrenceDate: originalOccurrence,
            startDate: movedStart,
            isRecurring: true
        )
        let nextID = EventKitCalendarSource.externalID(
            eventIdentifier: "series-1",
            calendarItemIdentifier: "local-1",
            occurrenceDate: nextOccurrence,
            startDate: nextOccurrence,
            isRecurring: true
        )

        #expect(originalID == movedID)
        #expect(originalID != nextID)
        #expect(originalID == "series-1:1800000000000")
    }

    private func weeklyRule() -> EKRecurrenceRule {
        EKRecurrenceRule(
            recurrenceWith: .weekly,
            interval: 2,
            daysOfTheWeek: [
                EKRecurrenceDayOfWeek(.monday),
                EKRecurrenceDayOfWeek(.wednesday),
            ],
            daysOfTheMonth: nil,
            monthsOfTheYear: nil,
            weeksOfTheYear: nil,
            daysOfTheYear: nil,
            setPositions: nil,
            end: EKRecurrenceEnd(occurrenceCount: 10)
        )
    }
}
