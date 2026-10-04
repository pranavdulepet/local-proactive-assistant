import AssistantCore
import Foundation
import Testing
@testable import AssistantStore

struct HostRefreshServiceTests {
    @Test
    func isolatesPermissionFailuresAndRetainsSuccessfulSyncTime() async throws {
        let store = try ObservationStore()
        let old = Date(timeIntervalSince1970: 1_000)
        try await store.refreshCoverage(for: .calendar, status: .partial, limitations: [], at: old)
        let source = RefreshSources()
        let service = HostRefreshService(messages: source, calendar: source, contacts: source, store: store, controlChatIDs: [TransportChatID(rawValue: 42)])
        let now = Date()
        let first = try await service.refresh(now: now)
        #expect(first.messagesReady)
        #expect(first.failures == [.calendar, .contacts])
        #expect(try await store.sourceCoverage(for: .calendar)?.lastSuccessfulSync == old)
        #expect(try await store.sourceCoverage(for: .calendar)?.status == .unavailable)
        let second = try await service.refresh(now: now.addingTimeInterval(60))
        #expect(second.messagesReady)
        #expect(second.failures.isEmpty)
        #expect(await source.calendarChecks == 1)
        #expect(await source.contactChecks == 1)
        #expect(await source.messageChecks == 2)
        _ = try await service.refresh(now: now.addingTimeInterval(901))
        #expect(await source.calendarChecks == 2)
    }

    @Test
    func failedMessagesDisableDispatchAndDoNotAdvanceCursor() async throws {
        let store = try ObservationStore()
        let old = Date(timeIntervalSince1970: 1_000)
        try await store.refreshCoverage(for: .messages, status: .partial, limitations: [], at: old)
        let source = RefreshSources(failMessages: true)
        let service = HostRefreshService(messages: source, calendar: source, contacts: source, store: store, controlChatIDs: [TransportChatID(rawValue: 42)])
        let result = try await service.refresh()
        #expect(!result.messagesReady)
        #expect(result.failures.contains(.messages))
        #expect(try await store.sourceCursor(for: .messages) == nil)
        #expect(try await store.sourceCoverage(for: .messages)?.lastSuccessfulSync == old)
        #expect(try await store.sourceCoverage(for: .messages)?.status == .unavailable)
    }
}

private actor RefreshSources: MessageHistorySource, CalendarEventSource, ContactSource {
    let failMessages: Bool
    var messageChecks = 0
    var calendarChecks = 0
    var contactChecks = 0

    init(failMessages: Bool = false) { self.failMessages = failMessages }
    func messages(after cursor: TransportCursor, limit: Int) throws -> MessageHistoryPage {
        messageChecks += 1
        if failMessages { throw TransportFailure("read unavailable") }
        return MessageHistoryPage(messages: [], nextCursor: cursor, hasMore: false)
    }
    func authorizationStatus() -> CalendarAuthorizationStatus {
        calendarChecks += 1
        return .denied
    }
    func authorizationStatus() -> ContactAuthorizationStatus {
        contactChecks += 1
        return .denied
    }
    func requestFullAccess() -> Bool { false }
    func events(from startDate: Date, to endDate: Date) -> [CalendarEventRecord] { [] }
    func requestAccess() -> Bool { false }
    func contacts() -> [ContactRecord] { [] }
}
