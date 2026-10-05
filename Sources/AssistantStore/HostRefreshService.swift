import AssistantCore
import Foundation

public struct HostRefreshReport: Sendable {
    public let messagesReady: Bool
    public let failures: [ObservationSource]
}

/// Refreshes sources independently, so a Calendar/Contacts permission failure cannot stop chat commands.
public actor HostRefreshService {
    private let messages: MessagesIngestor
    private let calendar: CalendarIngestor
    private let contacts: ContactsIngestor
    private let store: ObservationStore
    private var nextSnapshotRefresh = Date.distantPast

    public init(
        messages: any MessageHistorySource,
        calendar: any CalendarEventSource,
        contacts: any ContactSource,
        store: ObservationStore,
        controlChatIDs: Set<TransportChatID>
    ) {
        self.store = store
        self.messages = MessagesIngestor(source: messages, store: store, excludedChatIDs: controlChatIDs)
        self.calendar = CalendarIngestor(source: calendar, store: store)
        self.contacts = ContactsIngestor(source: contacts, store: store)
    }

    public func refresh(now: Date = Date()) async throws -> HostRefreshReport {
        var failures: [ObservationSource] = []
        var messagesReady = false
        do {
            _ = try await messages.run()
            _ = try await CommitmentService(store: store).extractRecent(days: 30)
            messagesReady = true
        } catch {
            try Task.checkCancellation()
            failures.append(.messages)
            try await store.markSourceUnavailable(.messages)
        }
        try Task.checkCancellation()
        if now >= nextSnapshotRefresh {
            nextSnapshotRefresh = now.addingTimeInterval(900)
            do {
                _ = try await calendar.run(
                    from: now.addingTimeInterval(-90 * 86_400),
                    to: now.addingTimeInterval(365 * 86_400)
                )
            } catch {
                try Task.checkCancellation()
                failures.append(.calendar)
                try await store.markSourceUnavailable(.calendar)
            }
            do {
                _ = try await contacts.run()
            } catch {
                try Task.checkCancellation()
                failures.append(.contacts)
                try await store.markSourceUnavailable(.contacts)
            }
        }
        return HostRefreshReport(messagesReady: messagesReady, failures: failures)
    }
}

