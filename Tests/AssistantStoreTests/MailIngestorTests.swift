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
        #expect(request.coverage.contains { $0.contains("not a complete account search") })
        let searched = try await EvidenceRetriever(store: store).request(question: "Find email from Maya about project", now: now)
        #expect(searched.records.count == 1)
        #expect(searched.records[0].text.contains("Project review"))
        #expect(!ConversationContextRouter.requestsMail("What is Maya's email address?"))
        #expect(ConversationContextRouter.retrievalQuery(for: "Check my emails", previous: nil) != nil)
    }

    @Test func refreshRetiresOldSampleWithoutClaimingDeletion() async throws {
        let store = try ObservationStore()
        let record = MailMessageRecord(externalID: "old", sender: "Maya", subject: "Review", receivedAt: Date(), unread: true, body: "body")
        try await MailIngestor(source: FixtureMail(snapshot: MailSnapshot(messages: [record], totalInbox: 1, scanned: 1)), store: store).run()
        try await MailIngestor(source: FixtureMail(snapshot: MailSnapshot(messages: [], totalInbox: 0, scanned: 0)), store: store).run()
        let request = try await EvidenceRetriever(store: store).request(question: "Check my emails")
        #expect(request.records.isEmpty)
        #expect(request.coverage.contains { $0.contains("does not prove an email was deleted") })
    }

    @Test func skippedMessagesDoNotRetireAnExistingSample() async throws {
        let store = try ObservationStore()
        let record = MailMessageRecord(externalID: "old", sender: "Maya", subject: "Review", receivedAt: Date(), unread: true, body: "body")
        try await MailIngestor(source: FixtureMail(snapshot: MailSnapshot(messages: [record], totalInbox: 1, scanned: 1)), store: store).run()
        await #expect(throws: Error.self) {
            try await MailIngestor(source: FixtureMail(snapshot: MailSnapshot(messages: [], totalInbox: 1, scanned: 1, skipped: 1)), store: store).run()
        }
        #expect(try await store.current(source: .mail, externalID: "old")?.tombstone == false)
    }
}

private struct FixtureMail: MailSource {
    let snapshot: MailSnapshot
    func inboxSnapshot() -> MailSnapshot { snapshot }
}
