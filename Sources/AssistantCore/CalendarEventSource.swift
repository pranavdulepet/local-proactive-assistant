import Foundation

public enum CalendarAuthorizationStatus: String, Codable, Sendable {
    case notDetermined
    case restricted
    case denied
    case writeOnly
    case fullAccess
    case unknown
}

public enum CalendarEventStatus: String, Codable, Sendable {
    case none
    case confirmed
    case tentative
    case canceled
    case unknown
}

public struct CalendarEventRecord: Codable, Equatable, Sendable {
    public let externalID: String
    public let calendarItemIdentifier: String
    public let title: String
    public let startDate: Date
    public let endDate: Date
    public let timeZoneIdentifier: String?
    public let calendarTitle: String
    public let location: String?
    public let organizer: String?
    public let attendees: [String]
    public let notes: String?
    public let recurrenceRules: [String]
    public let status: CalendarEventStatus
    public let isAllDay: Bool
    public let lastModifiedDate: Date?

    public init(
        externalID: String,
        calendarItemIdentifier: String,
        title: String,
        startDate: Date,
        endDate: Date,
        timeZoneIdentifier: String? = nil,
        calendarTitle: String,
        location: String? = nil,
        organizer: String? = nil,
        attendees: [String] = [],
        notes: String? = nil,
        recurrenceRules: [String] = [],
        status: CalendarEventStatus = .none,
        isAllDay: Bool = false,
        lastModifiedDate: Date? = nil
    ) {
        self.externalID = externalID
        self.calendarItemIdentifier = calendarItemIdentifier
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.timeZoneIdentifier = timeZoneIdentifier
        self.calendarTitle = calendarTitle
        self.location = location
        self.organizer = organizer
        self.attendees = attendees
        self.notes = notes
        self.recurrenceRules = recurrenceRules
        self.status = status
        self.isAllDay = isAllDay
        self.lastModifiedDate = lastModifiedDate
    }
}

public protocol CalendarEventSource: Sendable {
    func authorizationStatus() async -> CalendarAuthorizationStatus
    func requestFullAccess() async throws -> Bool
    func events(from startDate: Date, to endDate: Date) async throws -> [CalendarEventRecord]
}
