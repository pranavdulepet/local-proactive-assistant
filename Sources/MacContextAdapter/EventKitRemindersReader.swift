import CryptoKit
import EventKit
import Foundation
import LocalInference

enum ReminderAccess: Equatable, Sendable { case notDetermined, denied, restricted, fullAccess, unknown }

struct ReminderItem: Equatable, Sendable {
    let id: String
    let title: String
    let notes: String
    let list: String
    let completed: Bool
    let due: Date?
    let dateOnly: Bool
    let completionDate: Date?
    let modified: Date?
}

struct ReminderReadSnapshot: Sendable {
    let items: [ReminderItem]
    let total: Int
    let listCount: Int
    let inspected: Int
}

protocol ReminderStore: Sendable {
    func access() async -> ReminderAccess
    func requestAccess() async throws -> Bool
    func read(_ query: ReminderQuery) async throws -> ReminderReadSnapshot
}

/// Only EventKit's read predicates are exposed. No save/remove/commit calls are present.
struct RemindersContextReader: Sendable {
    let store: any ReminderStore
    let requestPermissions: Bool

    func read(query: String?, now: Date = Date(), calendar: Calendar = .current) async throws -> ContextToolResult {
        switch await store.access() {
        case .notDetermined:
            guard requestPermissions else {
                throw MacContextFailure("Reminders access has not been requested. Run local source setup on this Mac to choose access.", kind: .permissionRequired)
            }
            guard try await store.requestAccess() else {
                let current = await store.access()
                let kind: MacContextFailureKind = current == .denied ? .permissionDenied
                    : current == .restricted ? .permissionRestricted : .permissionRequired
                throw MacContextFailure("Reminders full access was not granted. Check the host's access under macOS Privacy & Security > Reminders; no data was read.", kind: kind)
            }
        case .denied:
            throw MacContextFailure("Reminders access is denied. Change the host's access under macOS Privacy & Security > Reminders if you want this source connected.", kind: .permissionDenied)
        case .restricted:
            throw MacContextFailure("Reminders access is restricted by macOS or device management.", kind: .permissionRestricted)
        case .unknown:
            throw MacContextFailure("macOS returned an unsupported Reminders authorization state.", kind: .readFailed)
        case .fullAccess: break
        }
        try Task.checkCancellation()
        let parsed = ReminderQuery(query: query, now: now, calendar: calendar)
        let snapshot = try await store.read(parsed)
        try Task.checkCancellation()
        var matches = snapshot.items.filter { item in
            parsed.matches(item)
        }
        matches.sort {
            if parsed.completedOnly {
                return ($0.completionDate ?? .distantPast) > ($1.completionDate ?? .distantPast)
            }
            if ($0.due ?? .distantFuture) != ($1.due ?? .distantFuture) {
                return ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture)
            }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        let records = matches.prefix(8).map { item in
            let digest = SHA256.hash(data: Data(item.id.utf8)).map { String(format: "%02x", $0) }.joined()
            let due = item.due.map { ISO8601DateFormatter().string(from: $0) } ?? "none"
            let detail = "List: \(EvidenceText.bounded(item.list, bytes: 100))\nCompleted: \(item.completed ? "yes" : "no")\nDue: \(due)\(item.dateOnly ? " (date only in Mac calendar)" : "")"
            let text = "Title: \(EvidenceText.bounded(item.title, bytes: 180))\n\(detail)\n" + FileContextReader.matchingExcerpt(item.notes, terms: parsed.terms)
            return EvidenceRecord(id: "reminder:" + digest, source: "reminders", timestamp: item.modified,
                text: EvidenceText.bounded(text, bytes: 768),
                locator: "reminders:" + EvidenceText.bounded(item.id, bytes: 220), trust: "unknownExternal")
        }
        let coverage: String
        if snapshot.listCount == 0 {
            coverage = "Reminders is readable, but EventKit exposes no reminder lists for this Mac login. Add or sync a list in Reminders. This is not a denied-permission result."
        } else if snapshot.total == 0 {
            coverage = "Reminders is readable across \(snapshot.listCount) exposed lists. No items matched the \(parsed.scope) predicate; other completion states/dates were not fetched. This is not proof that the entire account is empty."
        } else {
            coverage = "Reminders: \(records.count) of \(matches.count) text matches returned; \(snapshot.inspected) of \(snapshot.total) items inspected across \(snapshot.listCount) EventKit lists for \(parsed.scope). At most 10,000 items and 8 excerpts; titles, list names and bounded notes are searched. Only locally exposed/synced items; attachments and gaps are outside coverage."
        }
        return ContextToolResult(records: records, coverage: [EvidenceText.bounded(coverage, bytes: 512)])
    }
}

struct ReminderQuery: Sendable {
    let terms: [String]
    let completedOnly: Bool
    let start: Date?
    let end: Date?
    let scope: String

    init(query: String?, now: Date, calendar: Calendar) {
        let words = FileContextReader.searchTerms(query ?? "")
        completedOnly = words.contains { ["completed", "done", "finished"].contains($0) }
        let today = calendar.startOfDay(for: now)
        let interval: (Date?, Date?, String)
        if words.contains("today") {
            interval = (today, calendar.date(byAdding: .day, value: 1, to: today), "today")
        } else if words.contains("tomorrow") {
            interval = (calendar.date(byAdding: .day, value: 1, to: today), calendar.date(byAdding: .day, value: 2, to: today), "tomorrow")
        } else if words.contains("yesterday") {
            interval = (calendar.date(byAdding: .day, value: -1, to: today), today, "yesterday")
        } else if words.contains("overdue") {
            interval = (nil, now, "before now")
        } else if words.contains("week") || words.contains("month") {
            let unit: Calendar.Component = words.contains("week") ? .weekOfYear : .month
            let shift = words.contains("next") ? 1 : words.contains("last") || words.contains("previous") ? -1 : 0
            let shifted = calendar.date(byAdding: unit, value: shift, to: now) ?? now
            let dates = calendar.dateInterval(of: unit, for: shifted)
            interval = (dates?.start, dates?.end, "\(shift == 1 ? "next" : shift == -1 ? "previous" : "current") \(unit == .weekOfYear ? "week" : "month")")
        } else if let day = Self.explicitDay(words, calendar: calendar) {
            interval = (day, calendar.date(byAdding: .day, value: 1, to: day), "requested calendar day")
        } else {
            interval = (nil, nil, "all dates")
        }
        start = interval.0
        end = interval.1
        scope = "\(completedOnly ? "completed/completion date" : "incomplete/due date"), \(interval.2) in the Mac's calendar"
        var excluded: Set<String> = ["reminder", "reminders", "task", "tasks", "todo", "todos", "due", "today", "tomorrow", "yesterday", "overdue", "completed", "done", "finished", "incomplete", "unfinished", "open", "check", "show", "list"]
        if words.contains("week") || words.contains("month") { excluded.formUnion(["week", "month", "next", "last", "previous", "this", "current"]) }
        let hasCalendarDay = Self.explicitDay(words, calendar: calendar) != nil
        terms = words.filter { !excluded.contains($0) && !(hasCalendarDay && Self.isCalendarDay($0)) }
    }

    private static func isCalendarDay(_ text: String) -> Bool {
        text.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }
    private static func explicitDay(_ words: [String], calendar: Calendar) -> Date? {
        guard let value = words.first(where: isCalendarDay) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter.date(from: value)
    }

    func matches(_ item: ReminderItem) -> Bool {
        guard item.completed == completedOnly else { return false }
        let date = completedOnly ? item.completionDate : item.due
        if start != nil || end != nil {
            guard let date else { return false }
            if let start, date < start { return false }
            if let end, date >= end { return false }
        }
        let searchable = [item.title, item.list, item.notes].joined(separator: "\n")
        return terms.allSatisfy { searchable.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}

actor EventKitReminderStore: ReminderStore {
    private let store = EKEventStore()
    private var requests: [UUID: (Any, ReadContinuation<ReminderReadSnapshot>)] = [:]

    func access() -> ReminderAccess {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        case .fullAccess: .fullAccess
        case .writeOnly: .unknown
        @unknown default: .unknown
        }
    }

    func requestAccess() async throws -> Bool {
        let keys = ["NSRemindersFullAccessUsageDescription", "NSRemindersUsageDescription"]
        guard keys.contains(where: { (Bundle.main.object(forInfoDictionaryKey: $0) as? String)?.isEmpty == false }) else {
            throw MacContextFailure("The host is missing its Reminders usage description. Update or rebuild the assistant; changing permissions will not fix this configuration.", kind: .configurationMissing)
        }
        let completion = ReadContinuation<Bool>()
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            completion.finish(.failure(MacContextFailure("Waiting for the Reminders permission choice exceeded 60 seconds. The system prompt may still be open on the Mac.", kind: .timedOut)))
        }
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion.install(continuation)
                store.requestFullAccessToReminders { granted, error in
                    if let error {
                        let status = EKEventStore.authorizationStatus(for: .reminder)
                        let kind: MacContextFailureKind = status == .denied ? .permissionDenied
                            : status == .restricted ? .permissionRestricted : .readFailed
                        completion.finish(.failure(MacContextFailure("EventKit could not complete the Reminders permission request. No reminder data was read.", kind: kind, systemCode: (error as NSError).code)))
                    } else {
                        completion.finish(.success(granted))
                    }
                }
            }
        } onCancel: { completion.finish(.failure(CancellationError())) }
    }

    func read(_ query: ReminderQuery) async throws -> ReminderReadSnapshot {
        try Task.checkCancellation()
        let lists = store.calendars(for: .reminder)
        guard !lists.isEmpty else { return ReminderReadSnapshot(items: [], total: 0, listCount: 0, inspected: 0) }
        let listCount = lists.count
        let predicate = query.completedOnly
            ? store.predicateForCompletedReminders(withCompletionDateStarting: query.start, ending: query.end, calendars: lists)
            : store.predicateForIncompleteReminders(withDueDateStarting: query.start, ending: query.end, calendars: lists)
        let identifier = UUID()
        let completion = ReadContinuation<ReminderReadSnapshot>()
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            cancel(identifier, failure: MacContextFailure("EventKit did not return reminders before the 12-second read deadline. Permission denial was not reported.", kind: .timedOut))
        }
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion.install(continuation)
                let request = store.fetchReminders(matching: predicate) { reminders in
                    if let reminders {
                        // EventKit objects never cross the continuation; only immutable values do.
                        let items = reminders.prefix(10_000).map(Self.item)
                        completion.finish(.success(ReminderReadSnapshot(items: items,
                            total: reminders.count, listCount: listCount, inspected: items.count)))
                    } else {
                        completion.finish(.failure(MacContextFailure("EventKit returned no Reminders response. This differs from a successfully read empty list.", kind: .readFailed)))
                    }
                    Task { await self.finished(identifier) }
                }
                requests[identifier] = (request, completion)
            }
        } onCancel: { Task { await self.cancel(identifier, failure: CancellationError()) } }
    }

    private func cancel(_ identifier: UUID, failure: any Error) {
        guard let (request, completion) = requests.removeValue(forKey: identifier) else { return }
        // Apple does not call the fetch completion after cancelFetchRequest, so resume ours.
        store.cancelFetchRequest(request)
        completion.finish(.failure(failure))
    }
    private func finished(_ identifier: UUID) { requests.removeValue(forKey: identifier) }

    private nonisolated static func item(_ reminder: EKReminder) -> ReminderItem {
        let components = reminder.dueDateComponents
        let calendar = components?.calendar ?? .current
        return ReminderItem(id: reminder.calendarItemIdentifier,
            title: EvidenceText.bounded(reminder.title ?? "Untitled reminder", bytes: 1_024),
            notes: EvidenceText.bounded(reminder.notes ?? "", bytes: 16_384),
            list: EvidenceText.bounded(reminder.calendar?.title ?? "Unknown list", bytes: 1_024), completed: reminder.isCompleted,
            due: components.flatMap { calendar.date(from: $0) }, dateOnly: components?.hour == nil,
            completionDate: reminder.completionDate, modified: reminder.lastModifiedDate)
    }
}

/// Permission/fetch callbacks can race cancellation. Exactly one immutable result is delivered.
final class ReadContinuation<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    private var result: Result<T, any Error>?
    private var delivered = false
    func install(_ value: CheckedContinuation<T, any Error>) {
        let ready: Result<T, any Error>? = lock.withLock {
            guard !delivered else { return nil }
            if let result { delivered = true; return result }
            continuation = value
            return nil
        }
        if let ready { value.resume(with: ready) }
    }
    func finish(_ value: Result<T, any Error>) {
        let pending: CheckedContinuation<T, any Error>? = lock.withLock {
            guard !delivered, result == nil else { return nil }
            result = value
            guard let pending = continuation else { return nil }
            delivered = true
            continuation = nil
            return pending
        }
        pending?.resume(with: value)
    }
}
