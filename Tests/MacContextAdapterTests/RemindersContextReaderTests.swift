import Foundation
import LocalInference
import Testing
@testable import MacContextAdapter

struct RemindersContextReaderTests {
    @Test func querySearchesPastOldSampleCapAndSortsDueDates() async throws {
        let now = Date(timeIntervalSince1970: 1_791_158_400)
        var items = (0..<300).map { item("r-\($0)", title: "Unrelated task \($0)") }
        items.append(item("later", title: "Maya review", due: now.addingTimeInterval(3600)))
        items.append(item("earlier", title: "Maya review", due: now.addingTimeInterval(60)))
        items.append(item("completed", title: "Maya review", completed: true, due: now))
        let snapshot = ReminderReadSnapshot(items: items, total: items.count, listCount: 2, inspected: items.count)
        let reader = RemindersContextReader(store: FixtureReminderStore(snapshot: snapshot), requestPermissions: false)
        let result = try await reader.read(query: "Maya review", now: now)
        #expect(result.records.count == 2)
        #expect(result.records[0].locator == "reminders:earlier")
        #expect(result.records[1].locator == "reminders:later")
        #expect(result.coverage[0].contains("303 of 303"))
        try result.validate()
    }

    @Test func dateRangesUseMacCalendarAndExcludeNextMidnight() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 19_800)!
        let now = Date(timeIntervalSince1970: 1_791_158_400)
        let start = calendar.startOfDay(for: now)
        let next = calendar.date(byAdding: .day, value: 1, to: start)!
        let items = [item("start", title: "Review", due: start),
                     item("inside", title: "Review", due: next.addingTimeInterval(-1)),
                     item("next", title: "Review", due: next), item("none", title: "Review")]
        let reader = RemindersContextReader(store: FixtureReminderStore(snapshot:
            ReminderReadSnapshot(items: items, total: 4, listCount: 1, inspected: 4)), requestPermissions: false)
        let result = try await reader.read(query: "today", now: now, calendar: calendar)
        #expect(result.records.map(\.locator) == ["reminders:start", "reminders:inside"])
        #expect(result.coverage[0].contains("today in the Mac's calendar"))
    }

    @Test func completedQueriesUseCompletionDatesInsteadOfDueDates() async throws {
        let now = Date(timeIntervalSince1970: 1_791_158_400)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.startOfDay(for: now)
        let recent = item("recent", title: "Review", completed: true,
                          due: now.addingTimeInterval(-86400), completion: start.addingTimeInterval(60))
        let old = item("old", title: "Review", completed: true, due: now,
                       completion: start.addingTimeInterval(-1))
        let reader = RemindersContextReader(store: FixtureReminderStore(snapshot:
            ReminderReadSnapshot(items: [old, recent], total: 2, listCount: 1, inspected: 2)), requestPermissions: false)
        let result = try await reader.read(query: "completed today", now: now, calendar: calendar)
        #expect(result.records.map(\.locator) == ["reminders:recent"])
        #expect(result.coverage[0].contains("completed/completion date"))
    }

    @Test func readableEmptyListsAreDifferentFromNoListsOrAccessErrors() async throws {
        let noLists = RemindersContextReader(store: FixtureReminderStore(snapshot:
            ReminderReadSnapshot(items: [], total: 0, listCount: 0, inspected: 0)), requestPermissions: false)
        let result = try await noLists.read(query: nil)
        #expect(result.records.isEmpty)
        #expect(result.coverage[0].contains("no reminder lists"))
        let empty = RemindersContextReader(store: FixtureReminderStore(snapshot:
            ReminderReadSnapshot(items: [], total: 0, listCount: 2, inspected: 0)), requestPermissions: false)
        #expect(try await empty.read(query: nil).coverage[0].contains("No items matched"))
    }

    @Test func conversationDoesNotRequestPermissionAndDeniedRestrictedAreDistinct() async throws {
        let required = FixtureReminderStore(access: .notDetermined)
        do {
            _ = try await RemindersContextReader(store: required, requestPermissions: false).read(query: nil)
            Issue.record("Expected access requirement")
        } catch let failure as MacContextFailure { #expect(failure.kind == .permissionRequired) }
        #expect(await required.requestCount == 0)
        for (access, kind) in [(ReminderAccess.denied, MacContextFailureKind.permissionDenied), (.restricted, .permissionRestricted)] {
            do {
                _ = try await RemindersContextReader(store: FixtureReminderStore(access: access), requestPermissions: false).read(query: nil)
                Issue.record("Expected access failure")
            } catch let failure as MacContextFailure { #expect(failure.kind == kind) }
        }
    }

    @Test func localSetupCanRequestAccessAndReadFailureIsNotPermissionDenial() async throws {
        let store = FixtureReminderStore(access: .notDetermined)
        _ = try await RemindersContextReader(store: store, requestPermissions: true).read(query: nil)
        #expect(await store.requestCount == 1)
        do {
            _ = try await RemindersContextReader(store: FixtureReminderStore(failure: .timedOut), requestPermissions: false).read(query: nil)
            Issue.record("Expected read deadline failure")
        } catch let failure as MacContextFailure { #expect(failure.kind == .timedOut) }
    }

    @Test func callbackContinuationDeliversOnlyOnceIncludingEarlyCancellation() async throws {
        let bridge = ReadContinuation<Int>()
        bridge.finish(.success(7))
        let value: Int = try await withCheckedThrowingContinuation { bridge.install($0) }
        bridge.finish(.success(8))
        #expect(value == 7)
        let cancelled = ReadContinuation<Int>()
        cancelled.finish(.failure(CancellationError()))
        await #expect(throws: CancellationError.self) {
            try await withCheckedThrowingContinuation { cancelled.install($0) }
        }
    }

    private func item(_ id: String, title: String, completed: Bool = false,
                      due: Date? = nil, completion: Date? = nil) -> ReminderItem {
        ReminderItem(id: id, title: title, notes: "Confirm cost", list: "Work",
            completed: completed, due: due, dateOnly: false, completionDate: completion, modified: nil)
    }
}

private actor FixtureReminderStore: ReminderStore {
    let authorization: ReminderAccess
    let snapshot: ReminderReadSnapshot
    let failure: MacContextFailureKind?
    private(set) var requestCount = 0
    init(access: ReminderAccess = .fullAccess,
         snapshot: ReminderReadSnapshot = .init(items: [], total: 0, listCount: 1, inspected: 0),
         failure: MacContextFailureKind? = nil) {
        authorization = access
        self.snapshot = snapshot
        self.failure = failure
    }
    func access() -> ReminderAccess { authorization }
    func requestAccess() -> Bool { requestCount += 1; return true }
    func read(_ query: ReminderQuery) throws -> ReminderReadSnapshot {
        if let failure { throw MacContextFailure("Fixture read failed", kind: failure) }
        return snapshot
    }
}
