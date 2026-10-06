import AssistantCore
import Foundation
import LocalInference
import Testing
@testable import AssistantStore

struct StructuredContextReaderTests {
    @Test func fullNameRecallUsesAllNameTokensAndLatestInboundDirection() async throws {
        let store = try ObservationStore()
        try await store.record(contact("asmitha", name: "Asmitha Sathya", handle: "asmitha@example.com"))
        try await store.record(contact("first-only", name: "Asmitha Rao", handle: "rao@example.com"))
        try await store.record(contact("last-only", name: "Sathya Patel", handle: "patel@example.com"))
        try await store.record(contact("organization", name: "Asmitha Jones\nOrganization: Sathya", handle: "jones@example.com"))
        try await store.record(message("old", at: "2026-10-04T09:00:00Z", text: "Let's meet on Sunday.", handle: "asmitha@example.com"))
        try await store.record(message("latest-inbound", at: "2026-10-04T11:00:00Z", text: "Actually, Monday works better.", handle: "asmitha@example.com"))
        try await store.record(message("newer-owner", at: "2026-10-04T12:00:00Z", text: "Monday is good for me.", handle: "asmitha@example.com", outbound: true))
        try await store.record(message("unrelated", at: "2026-10-04T13:00:00Z", text: "Unrelated private conversation.", handle: "rao@example.com"))

        let result = try await IndexedContextSource(store: store).execute(ContextToolCall(
            tool: .messages, person: "Asmitha Sathya", direction: "inbound", limit: 1))
        #expect(result.records.map(\.locator) == ["imsg:latest-inbound"])
        #expect(result.records[0].text.contains("Monday works better"))
        #expect(result.records[0].text.contains("inbound (participant sent)"))
        #expect(result.coverage.contains { $0.contains("All supplied name tokens") })
        try result.validate()
    }

    @Test func ambiguousIdentityReturnsContactsAndNeverOtherPeoplesMessages() async throws {
        let store = try ObservationStore()
        for handle in ["one@example.com", "two@example.com"] {
            try await store.record(contact(handle, name: "Jordan Lee", handle: handle))
            try await store.record(message(handle, at: "2026-10-04T11:00:00Z", text: "Private message.", handle: handle))
        }
        let result = try await EvidenceRetriever(store: store).read(ContextToolCall(
            tool: .messages, person: "Jordan Lee", direction: "inbound", limit: 1))
        #expect(result.records.count == 2)
        #expect(result.records.allSatisfy { $0.source == "contacts" })
        #expect(result.coverage.contains { $0.contains("Multiple contacts") && $0.contains("No unscoped") })
        #expect(!result.records.contains { $0.text.contains("Private message") })
    }

    @Test func topicDatesAndPagingApplyBeforeTheNewestLimit() async throws {
        let store = try ObservationStore()
        for (id, date, text, outbound) in [
            ("before", "2026-10-04T23:59:59Z", "The project is ready.", false),
            ("first", "2026-10-05T09:00:00Z", "The project has a draft.", false),
            ("second", "2026-10-05T10:00:00Z", "The project is approved.", false),
            ("owner", "2026-10-05T11:00:00Z", "I will send the project.", true),
            ("topic-miss", "2026-10-05T12:00:00Z", "Dinner at seven.", false),
            ("exclusive-end", "2026-10-06T00:00:00Z", "The project starts today.", false)
        ] {
            try await store.record(message(id, at: date, text: text, handle: "person@example.com", outbound: outbound))
        }
        let reader = IndexedContextSource(store: store)
        let result = try await reader.execute(ContextToolCall(tool: .messages, query: "project",
            person: "person@example.com", direction: "inbound", from: "2026-10-05T00:00:00Z",
            to: "2026-10-06T00:00:00Z", limit: 1, offset: 1))
        #expect(result.records.map(\.locator) == ["imsg:first"])
        let owner = try await reader.execute(ContextToolCall(tool: .messages, person: "person@example.com",
            direction: "outbound", limit: 1))
        #expect(owner.records.map(\.locator) == ["imsg:owner"])
    }

    @Test func currentHeadsExcludeDeletedAndSupersededMessages() async throws {
        let store = try ObservationStore()
        let first = message("same", at: "2026-10-05T12:00:00Z", text: "Old text.", handle: "person@example.com")
        try await store.record(first)
        try await store.record(Observation(source: .messages, externalID: "same", versionHash: "v2", sourceRevision: 2,
            sourceTimestamp: first.sourceTimestamp, trust: .knownExternal, handles: first.handles,
            text: "Corrected text.", locator: "imsg:same"))
        try await store.record(Observation(source: .messages, externalID: "gone", versionHash: "deleted", sourceRevision: 3,
            sourceTimestamp: date("2026-10-05T13:00:00Z"), trust: .knownExternal,
            handles: first.handles, text: "Deleted text.", locator: "imsg:gone", tombstone: true))
        let result = try await IndexedContextSource(store: store).execute(ContextToolCall(
            tool: .messages, person: "person@example.com", direction: "inbound"))
        #expect(result.records.count == 1)
        #expect(result.records[0].text.contains("Corrected text"))
        #expect(!result.records[0].text.contains("Old text"))
    }

    @Test func calendarIncludesOvernightAndAllDayOverlapsButExcludesBoundariesAndCanceled() async throws {
        let store = try ObservationStore()
        for (id, start, end, canceled) in [
            ("overnight", "2026-10-04T23:00:00Z", "2026-10-05T02:00:00Z", false),
            ("all-day", "2026-10-04T00:00:00Z", "2026-10-06T00:00:00Z", false),
            ("ends-at-start", "2026-10-04T23:00:00Z", "2026-10-05T00:00:00Z", false),
            ("starts-at-end", "2026-10-06T00:00:00Z", "2026-10-06T01:00:00Z", false),
            ("canceled", "2026-10-05T08:00:00Z", "2026-10-05T09:00:00Z", true)
        ] { try await store.record(event(id, start: start, end: end, canceled: canceled)) }
        let result = try await IndexedContextSource(store: store).execute(ContextToolCall(tool: .calendar,
            from: "2026-10-05T00:00:00Z", to: "2026-10-06T00:00:00Z"))
        #expect(Set(result.records.map(\.locator)) == ["calendar:overnight", "calendar:all-day"])
        #expect(result.coverage.contains { $0.contains("overlapping") })
        #expect(result.records.allSatisfy { $0.text.hasPrefix("Start:") && $0.text.contains("End: 2026-10-") })
        try result.validate()
    }

    @Test func calendarParticipantFilterUsesContactHandlesAndDayDatesUseHostTimezone() async throws {
        let store = try ObservationStore()
        try await store.record(contact("maya", name: "Maya River", handle: "maya@example.com"))
        try await store.record(event("with-maya", start: "2026-10-05T08:00:00Z", end: "2026-10-05T09:00:00Z", handle: "maya@example.com"))
        try await store.record(event("other", start: "2026-10-05T10:00:00Z", end: "2026-10-05T11:00:00Z", handle: "other@example.com"))
        try await store.record(event("prior-local-day", start: "2026-10-05T03:00:00Z", end: "2026-10-05T04:00:00Z", handle: "maya@example.com"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let result = try await StructuredContextReader(store: store, calendar: calendar).execute(ContextToolCall(
            tool: .calendar, person: "Maya River", from: "2026-10-05", to: "2026-10-06"))
        #expect(result.records.map(\.locator) == ["calendar:with-maya"])
        #expect(result.coverage.contains { $0.contains("America/Los_Angeles") })
    }

    @Test func contactsLookupsCanUseExactNamesNicknamesOrPhoneHandles() async throws {
        let store = try ObservationStore()
        try await store.record(contact("alex", name: "Alex River\nNickname: Lex", handle: "+14155550123"))
        let reader = IndexedContextSource(store: store)
        for call in [ContextToolCall(tool: .contacts, person: "Alex River"),
                     ContextToolCall(tool: .contacts, person: "Lex"),
                     ContextToolCall(tool: .contacts, query: "+1 (415) 555-0123")] {
            let result = try await reader.execute(call)
            #expect(result.records.map(\.locator) == ["contacts:alex"])
        }
    }

    @Test func invalidLiteralTopicsAndReversedDatesNeverBroadenARead() async throws {
        let reader = IndexedContextSource(store: try ObservationStore())
        for call in [ContextToolCall(tool: .messages, query: "*"),
                     ContextToolCall(tool: .calendar, from: "2026-10-06", to: "2026-10-05"),
                     ContextToolCall(tool: .calendar, from: "2026-02-30", to: "2026-03-01")] {
            await #expect(throws: Error.self) { _ = try await reader.execute(call) }
        }
    }

    @Test func phoneSnapshotsAreSourceTypedAndKeepOriginalTimesInsteadOfReceiptTimes() async throws {
        let store = try ObservationStore()
        let captured = date("2026-10-02T08:00:00Z")
        let received = date("2026-10-06T10:00:00Z")
        for (id, text) in [("phone-sleep:24", "Recorded sleep over the last 24 hours: 7 hours."),
                           ("phone-sleep:168", "Recorded sleep over the last 168 hours: 49 hours."),
                           ("phone-activity:today", "Recorded phone activity, 2026-10-02T00:00:00Z through 2026-10-02T08:00:00Z: steps not readable.")] {
            try await store.record(Observation(source: .health, externalID: id, versionHash: "v1", sourceRevision: 1,
                observedAt: received, sourceTimestamp: captured, trust: .structuredSource,
                text: text, locator: "phone-health:" + id))
        }
        try await store.record(Observation(source: .location, externalID: "phone-location:coarse", versionHash: "v1", sourceRevision: 1,
            observedAt: received, sourceTimestamp: captured, trust: .structuredSource,
            text: "Coarse phone location captured 2026-10-02T08:00:00Z: latitude 37.8, longitude -122.4; one snapshot, not live.",
            locator: "phone-location:coarse"))
        try await store.record(Observation(source: .health, externalID: "unrelated-health", versionHash: "v1", sourceRevision: 1,
            observedAt: received, sourceTimestamp: received, trust: .structuredSource,
            text: "Unrelated health data.", locator: "health:unrelated"))
        let reader = IndexedContextSource(store: store)
        let all = try await reader.execute(ContextToolCall(tool: .phoneContext))
        #expect(all.records.count == 4)
        #expect(all.records.allSatisfy { $0.timestamp == captured })
        #expect(all.coverage.contains { $0.contains("Mac receipt time does not make an old measurement current") })
        #expect(!all.records.contains { $0.text.contains("Unrelated health") })
        let sleep = try await reader.execute(ContextToolCall(tool: .phoneContext, query: "sleep"))
        #expect(sleep.records.count == 2)
        let activity = try await reader.execute(ContextToolCall(tool: .phoneContext, query: "activity"))
        #expect(activity.records.count == 1)
        #expect(activity.records[0].text.contains("steps not readable"))
        let location = try await reader.execute(ContextToolCall(tool: .phoneContext, query: "location"))
        #expect(location.records.map(\.source) == ["location"])
        #expect(location.records[0].timestamp != received)
        try all.validate()
    }

    @Test func legacyCalendarEndMetadataRetainsIntervalAcrossReopen() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("calendar-\(UUID()).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: file.path + suffix) }
        }
        try await seedLegacyCalendar(file)
        // The pre-upgrade schema has no interval table. Remove the newly created
        // metadata table to exercise real on-open backfill from fixed End lines.
        let sqlite = Process()
        sqlite.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        sqlite.arguments = [file.path, "DROP TABLE observation_intervals;"]
        try sqlite.run()
        sqlite.waitUntilExit()
        try #require(sqlite.terminationStatus == 0)
        let reopened = try ObservationStore(fileURL: file)
        let rows = try await reopened.calendarObservations(from: date("2026-10-05T00:00:00Z"), to: date("2026-10-06T00:00:00Z"))
        #expect(rows.map(\.locator) == ["calendar:legacy"])
        #expect(rows[0].sourceEndTimestamp == date("2026-10-05T02:00:00Z"))
    }

    private func seedLegacyCalendar(_ file: URL) async throws {
        let store = try ObservationStore(fileURL: file)
        try await store.record(Observation(source: .calendar, externalID: "legacy", versionHash: "v1", sourceRevision: 1,
            sourceTimestamp: date("2026-10-04T23:00:00Z"), trust: .structuredSource,
            text: "Overnight\nStart: 2026-10-04T23:00:00Z\nEnd: 2026-10-05T02:00:00Z\nStatus: confirmed\nAll day: no",
            locator: "calendar:legacy"))
    }
    private func contact(_ id: String, name: String, handle: String) -> Observation {
        Observation(source: .contacts, externalID: id, versionHash: "v1", sourceRevision: 1,
            trust: .structuredSource, handles: [handle], text: name + "\nHandles: " + handle, locator: "contacts:" + id)
    }
    private func message(_ id: String, at timestamp: String, text: String, handle: String, outbound: Bool = false) -> Observation {
        Observation(source: .messages, externalID: id, versionHash: "v1", sourceRevision: 1,
            sourceTimestamp: date(timestamp), trust: outbound ? .ownerAuthored : .knownExternal,
            handles: [handle], text: text, locator: "imsg:" + id)
    }
    private func event(_ id: String, start: String, end: String, canceled: Bool = false, handle: String? = nil) -> Observation {
        Observation(source: .calendar, externalID: id, versionHash: "v1", sourceRevision: 1,
            sourceTimestamp: date(start), sourceEndTimestamp: date(end), trust: .structuredSource,
            handles: handle.map { [$0] } ?? [],
            text: id + "\nStart: " + start + "\nEnd: " + end + "\nStatus: " + (canceled ? "canceled" : "confirmed") + "\nAll day: no",
            locator: "calendar:" + id)
    }
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
}
