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
        try await eventStore.requestFullAccessToEvents()
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
        CalendarEventRecord(
            externalID: event.eventIdentifier ?? event.calendarItemIdentifier,
            calendarItemIdentifier: event.calendarItemIdentifier,
            title: event.title ?? "Untitled event",
            startDate: event.startDate,
            endDate: event.endDate,
            timeZoneIdentifier: event.timeZone?.identifier,
            calendarTitle: event.calendar.title,
            location: event.location,
            organizer: event.organizer.flatMap(participantIdentifier),
            attendees: (event.attendees ?? []).compactMap(participantIdentifier),
            notes: event.notes,
            recurrenceRules: (event.recurrenceRules ?? []).map { String(describing: $0) },
            status: status(event.status),
            isAllDay: event.isAllDay,
            lastModifiedDate: event.lastModifiedDate
        )
    }

    private static func participantIdentifier(_ participant: EKParticipant) -> String? {
        participant.url?.absoluteString ?? participant.name
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
