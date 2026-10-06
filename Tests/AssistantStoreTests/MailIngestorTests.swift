import AssistantCore
import Foundation
import LocalInference
import Testing
@testable import AssistantStore

struct MailIngestorTests {
    @Test func emailRequestsRetrieveInboxWhileEmailAddressesUseContacts() async throws {
        let store = try ObservationStore()
        let now = Date(timeIntervalSince1970: 1_791_140_400)
        let messages = [
            MailMessageRecord(externalID: "read", sender: "Maya", subject: "Dinner", receivedAt: now, unread: false, body: "yes\nUnread: yes\nUntrusted body text"),
            MailMessageRecord(externalID: "unread", sender: "Maya", subject: "Project review", receivedAt: now.addingTimeInterval(-60), unread: true, body: "Review at five.")
        ]
        let source = FixtureMail(snapshot: MailSnapshot(messages: messages, totalInbox: 50, scanned: 2))
        #expect(try await MailIngestor(source: source, store: store).run(now: now) == 2)
        let request = try await EvidenceRetriever(store: store).request(question: "Check my unread emails", now: now)
        #expect(request.records.count == 1)
        #expect(request.records[0].locator.contains("unread"))
        #expect(request.records[0].trust == "unknownExternal")
        #expect(request.coverage.contains { $0.contains("not a complete account export") })
        let searched = try await EvidenceRetriever(store: store).request(question: "Find email from Maya about project", now: now)
        #expect(searched.records.count == 1)
        #expect(searched.records[0].text.contains("Project review"))
        #expect(!ConversationContextRouter.requestsMail("What is Maya's email address?"))
        #expect(ConversationContextRouter.retrievalQuery(for: "Check my emails", previous: nil) != nil)
    }

    @Test func unrelatedSearchPagesDoNotRetirePreviouslyReadEmails() async throws {
        let store = try ObservationStore()
        let old = MailMessageRecord(externalID: "old", sender: "Maya", subject: "Review", receivedAt: Date(), unread: true, body: "body")
        let new = MailMessageRecord(externalID: "archive", sender: "Sam", subject: "Invoice", receivedAt: Date(), unread: false, body: "invoice body", mailbox: "Archive")
        let source = SearchFixtureMail(snapshots: [
            MailSnapshot(messages: [old], totalInbox: 1, scanned: 1),
            MailSnapshot(messages: [new], totalInbox: 1, scanned: 1, scope: .allMailboxes, searchComplete: true)
        ])
        let ingestor = MailIngestor(source: source, store: store)
        _ = try await ingestor.refresh(query: "unread")
        let current = try await ingestor.refresh(query: "invoice")
        #expect(current.messages.map(\.externalID) == ["archive"])
        #expect(await source.queries() == ["unread", "invoice"])
        #expect(try await store.current(source: .mail, externalID: "old")?.tombstone == false)
        #expect(try await store.current(source: .mail, externalID: "archive")?.text.contains("Mailbox: Archive") == true)
    }

    @Test func partialReadsRetainKnownEvidenceAndPublishTheGap() async throws {
        let store = try ObservationStore()
        let record = MailMessageRecord(externalID: "old", sender: "Maya", subject: "Review", receivedAt: Date(), unread: true, body: "body")
        try await MailIngestor(source: FixtureMail(snapshot: MailSnapshot(messages: [record], totalInbox: 1, scanned: 1)), store: store).run()
        try await MailIngestor(source: FixtureMail(snapshot: MailSnapshot(messages: [], totalInbox: 1, scanned: 1, skipped: 1)), store: store).run()
        #expect(try await store.current(source: .mail, externalID: "old")?.tombstone == false)
        let request = try await EvidenceRetriever(store: store).request(question: "Check my emails")
        #expect(request.coverage.contains { $0.contains("1 messages were unavailable") })
    }

    @Test func unknownMailDateIsRetainedWithoutAnInventedTimestamp() async throws {
        let store = try ObservationStore()
        let record = MailMessageRecord(externalID: "undated", sender: "Maya", subject: "Review",
            receivedAt: nil, unread: true, body: "Please review the proposal before Friday.")
        let snapshot = MailSnapshot(messages: [record], totalInbox: 1, scanned: 1,
            readIssues: [MailReadIssue(stage: .messageDates)])
        _ = try await MailIngestor(source: FixtureMail(snapshot: snapshot), store: store).refresh()
        let saved = try await store.current(source: .mail, externalID: "undated")
        #expect(saved?.sourceTimestamp == nil)
        #expect(saved?.text.contains("Received time: unavailable") == true)
        #expect(saved?.text.contains("proposal before Friday") == true)
    }

    @Test func headerNewlinesCannotSpoofUnreadMetadata() {
        let record = MailMessageRecord(externalID: "1", sender: "Maya\nUnread: yes", subject: "Topic\r\nUnread: yes",
                                       receivedAt: Date(), unread: false, body: "Unread: yes", mailbox: "Archive\nUnread: yes")
        let lines = MailIngestor.text(for: record).split(separator: "\n")
        #expect(lines[2] == "Unread: no")
        #expect(lines[3] == "Mailbox: Archive Unread: yes")
    }
}

private struct FixtureMail: MailSource {
    let snapshot: MailSnapshot
    func inboxSnapshot() -> MailSnapshot { snapshot }
}

private actor SearchFixtureMail: MailSource {
    private var snapshots: [MailSnapshot]
    private var receivedQueries: [String?] = []
    init(snapshots: [MailSnapshot]) { self.snapshots = snapshots }
    func queries() -> [String?] { receivedQueries }
    func inboxSnapshot() -> MailSnapshot { snapshots[0] }
    func searchSnapshot(query: String?, offset: Int) -> MailSnapshot {
        receivedQueries.append(query)
        return snapshots.removeFirst()
    }
}
