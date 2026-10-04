import AssistantCore
import ContactsAdapter
import EventKitAdapter
import Foundation
import LocalInference
import PhoneSync

public actor PhoneContextSource {
    private let calendar = EventKitCalendarSource()
    private let contacts = ContactsStoreSource()
    #if os(iOS)
    private let sleep = PhoneSleepSource()
    #endif

    public init() {}
    public func requestCalendarAccess() async throws -> Bool { try await calendar.requestFullAccess() }
    public func requestContactsAccess() async throws -> Bool { try await contacts.requestAccess() }
    public func requestSleepAccess() async throws {
        #if os(iOS)
        try await sleep.requestAccess()
        #else
        throw LocalModelFailure("Sleep context is available on iPhone only.")
        #endif
    }

    public func sleepDigests(now: Date = Date()) async throws -> [PhoneSleepDigest] {
        #if os(iOS)
        return try await sleep.digests(now: now)
        #else
        return []
        #endif
    }

    public func startSleepUpdates(_ handler: @escaping @Sendable () async -> Void) async -> Bool {
        #if os(iOS)
        return await sleep.startUpdates(handler)
        #else
        return false
        #endif
    }

    public func stopSleepUpdates() async {
        #if os(iOS)
        await sleep.stopUpdates()
        #endif
    }

    public func request(question: String, contactName: String = "", includeCalendar: Bool, includeContacts: Bool, includeSleep: Bool, now: Date = Date()) async throws -> EvidenceRequest {
        try EvidenceRequest(question: question, records: [], coverage: []).validate()
        var records: [EvidenceRecord] = []
        var coverage = ["Phone context only. Messages and the Mac database are not accessible here."]
        let formatter = ISO8601DateFormatter()

        if includeContacts {
            let status = await contacts.authorizationStatus()
            if status == .authorized || status == .limited {
                let name = contactName.trimmingCharacters(in: .whitespacesAndNewlines)
                if name.isEmpty {
                    coverage.append("Contacts: no person selected; no contact records supplied.")
                } else {
                    let matches = try await contacts.contacts().filter {
                        $0.displayName.caseInsensitiveCompare(name) == .orderedSame || $0.nickname?.caseInsensitiveCompare(name) == .orderedSame
                    }
                    if matches.count == 1, let person = matches.first {
                        records.append(EvidenceRecord(id: "contact", source: "contacts", timestamp: now,
                            text: EvidenceText.bounded("Name: \(person.displayName)\nPhones: \(person.phoneNumbers.joined(separator: ", "))\nEmails: \(person.emailAddresses.joined(separator: ", "))", bytes: 768),
                            locator: EvidenceText.bounded("phone-contact:\(person.externalID)", bytes: 256), trust: "structuredSource"))
                    }
                    coverage.append("Contacts: \(status.rawValue); exact-name matches \(matches.count). Ambiguous people are not guessed.")
                }
            } else { coverage.append("Contacts: \(status.rawValue); no records read.") }
        }
        if includeSleep {
            #if os(iOS)
            let result = try await sleep.summary(now: now)
            if let record = result.record { records.append(record) }
            coverage.append(result.coverage)
            #else
            coverage.append("Health: unavailable on this platform.")
            #endif
        }
        if includeCalendar {
            let status = await calendar.authorizationStatus()
            if status == .fullAccess {
                let end = Calendar.current.date(byAdding: .day, value: 7, to: now)!
                let events = await calendar.events(from: now, to: end).filter { $0.status != .canceled }
                let selected = Array(events.prefix(8 - records.count))
                records += selected.enumerated().map { index, event in
                    EvidenceRecord(id: "calendar\(index + 1)", source: "calendar", timestamp: event.startDate,
                        text: EvidenceText.bounded("Title: \(event.title)\nStart: \(formatter.string(from: event.startDate))\nEnd: \(formatter.string(from: event.endDate))\nLocation: \(event.location ?? "unspecified")\nCalendar: \(event.calendarTitle)", bytes: 768),
                        locator: EvidenceText.bounded("phone-calendar:\(event.externalID)", bytes: 256), trust: "structuredSource")
                }
                coverage.append("Calendar: next seven days only; \(selected.count) of \(events.count) visible events supplied. Refreshed \(formatter.string(from: now)).")
            } else { coverage.append("Calendar: \(status.rawValue); no events read.") }
        }
        let request = EvidenceRequest(question: question, createdAt: now, records: records, coverage: coverage)
        try request.validate()
        return request
    }
}
