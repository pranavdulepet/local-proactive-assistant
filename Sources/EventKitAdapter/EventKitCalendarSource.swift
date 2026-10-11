import AssistantCore
import EventKit
import Foundation

public actor EventKitCalendarSource: CalendarEventSource {
    private let eventStore: EKEventStore

    public init() {
        eventStore = EKEventStore()
    }

    public func authorizationStatus() -> CalendarAuthorizationStatus {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined:
            .notDetermined
        case .restricted:
            .restricted
        case .denied:
            .denied
        case .writeOnly:
            .writeOnly
        case .fullAccess:
            .fullAccess
        @unknown default:
            .unknown
        }
    }

    public func requestFullAccess() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            eventStore.requestFullAccessToEvents { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    public func events(from startDate: Date, to endDate: Date) -> [CalendarEventRecord] {
        let predicate = eventStore.predicateForEvents(
            withStart: startDate,
            end: endDate,
            calendars: nil
        )
        return eventStore.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .map(Self.record)
    }

    private static func record(_ event: EKEvent) -> CalendarEventRecord {
        let recurrenceRules = event.recurrenceRules ?? []
        return CalendarEventRecord(
            externalID: externalID(
                eventIdentifier: event.eventIdentifier,
                calendarItemIdentifier: event.calendarItemIdentifier,
                occurrenceDate: event.occurrenceDate,
                startDate: event.startDate,
                isRecurring: !recurrenceRules.isEmpty
            ),
            calendarItemIdentifier: event.calendarItemIdentifier,
            title: event.title ?? "Untitled event",
            startDate: event.startDate,
            endDate: event.endDate,
            timeZoneIdentifier: event.timeZone?.identifier,
            calendarTitle: event.calendar.title,
            location: event.location,
            organizer: event.organizer.flatMap(participantIdentifier),
            attendees: (event.attendees ?? []).compactMap(participantIdentifier).sorted(),
            notes: event.notes,
            recurrenceRules: recurrenceRules.map(recurrenceDescription).sorted(),
            status: status(event.status),
            isAllDay: event.isAllDay,
            lastModifiedDate: event.lastModifiedDate
        )
    }

    private static func participantIdentifier(_ participant: EKParticipant) -> String? {
        let address = participant.url.absoluteString
        return address.isEmpty ? participant.name : address
    }

    static func externalID(
        eventIdentifier: String?,
        calendarItemIdentifier: String,
        occurrenceDate: Date?,
        startDate: Date,
        isRecurring: Bool
    ) -> String {
        let identifier = eventIdentifier ?? calendarItemIdentifier
        guard isRecurring else { return identifier }

        let occurrence = occurrenceDate ?? startDate
        let milliseconds = Int64(occurrence.timeIntervalSince1970 * 1_000)
        return "\(identifier):\(milliseconds)"
    }

    static func recurrenceDescription(_ rule: EKRecurrenceRule) -> String {
        var fields = [
            "frequency=\(frequencyName(rule.frequency))",
            "interval=\(rule.interval)",
            "weekStart=\(rule.firstDayOfTheWeek)",
        ]
        append(
            "weekdays",
            value: rule.daysOfTheWeek?.map {
                "\($0.dayOfTheWeek.rawValue):\($0.weekNumber)"
            }.joined(separator: ","),
            to: &fields
        )
        append("monthDays", value: numberList(rule.daysOfTheMonth), to: &fields)
        append("months", value: numberList(rule.monthsOfTheYear), to: &fields)
        append("yearWeeks", value: numberList(rule.weeksOfTheYear), to: &fields)
        append("yearDays", value: numberList(rule.daysOfTheYear), to: &fields)
        append("setPositions", value: numberList(rule.setPositions), to: &fields)

        if let end = rule.recurrenceEnd {
            if let endDate = end.endDate {
                let milliseconds = Int64(endDate.timeIntervalSince1970 * 1_000)
                fields.append("endDate=\(milliseconds)")
            } else {
                fields.append("occurrenceCount=\(end.occurrenceCount)")
            }
        }
        return fields.joined(separator: ";")
    }

    private static func frequencyName(_ frequency: EKRecurrenceFrequency) -> String {
        switch frequency {
        case .daily:
            "daily"
        case .weekly:
            "weekly"
        case .monthly:
            "monthly"
        case .yearly:
            "yearly"
        @unknown default:
            "unknown-\(frequency.rawValue)"
        }
    }

    private static func numberList(_ numbers: [NSNumber]?) -> String? {
        numbers?.map(\.stringValue).joined(separator: ",")
    }

    private static func append(_ name: String, value: String?, to fields: inout [String]) {
        if let value, !value.isEmpty {
            fields.append("\(name)=\(value)")
        }
    }

    private static func status(_ status: EKEventStatus) -> CalendarEventStatus {
        switch status {
        case .none:
            .none
        case .confirmed:
            .confirmed
        case .tentative:
            .tentative
        case .canceled:
            .canceled
        @unknown default:
            .unknown
        }
    }
}
