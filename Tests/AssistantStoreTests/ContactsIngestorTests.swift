import AssistantCore
import Foundation
import Testing
@testable import AssistantStore

struct ContactsIngestorTests {
    @Test
    func requestsAccessAndIndexesContactsIdempotently() async throws {
        let contact = ContactRecord(
            externalID: "contact-1",
            displayName: "Alex Rivera",
            givenName: "Alex",
            familyName: "Rivera",
            organizationName: "Example Labs",
            jobTitle: "Engineer",
            phoneNumbers: ["+14155550123"],
            emailAddresses: ["alex@example.com"]
        )
        let source = FakeContactSource(authorization: .notDetermined, contacts: [contact])
        let store = try ObservationStore()
        let ingestor = ContactsIngestor(
            source: source,
            store: store,
            clock: { Date(timeIntervalSince1970: 1_900_000_000) }
        )

        let first = try await ingestor.run()
        let second = try await ingestor.run()

        #expect(first == ContactsIngestionSummary(
            scanned: 1,
            indexed: 1,
            tombstoned: 0,
            cursor: 1_900_000_000_000,
            authorization: .authorized
        ))
        #expect(second.indexed == 0)
        #expect(second.cursor == 1_900_000_000_001)
        #expect(await source.accessRequestCount() == 1)
        #expect(try await store.sourceCursor(for: .contacts) == "1900000000001")

        let stored = try await store.current(source: .contacts, externalID: "contact-1")
        #expect(stored?.trust == .structuredSource)
        #expect(stored?.text.contains("Alex Rivera") == true)
        #expect(stored?.text.contains("alex@example.com") == true)
        #expect(stored?.handles == ["+14155550123", "alex@example.com"])
        #expect(try await store.search("Rivera", sources: [.contacts]).count == 1)
        #expect(try await store.sourceCoverage(for: .contacts)?.status == .ready)
    }

    @Test
    func fullAccessTombstonesContactsMissingFromTheNextSnapshot() async throws {
        let source = FakeContactSource(
            authorization: .authorized,
            contacts: [ContactRecord(externalID: "contact-1", displayName: "Alex Rivera")]
        )
        let store = try ObservationStore()
        let ingestor = ContactsIngestor(source: source, store: store)
        _ = try await ingestor.run()
        await source.replaceContacts([])

        let summary = try await ingestor.run()

        #expect(summary.tombstoned == 1)
        #expect(summary.indexed == 0)
        #expect(try await store.current(source: .contacts, externalID: "contact-1")?.tombstone == true)
        #expect(try await store.search("Rivera", sources: [.contacts]).isEmpty)
    }

    @Test
    func limitedAccessDoesNotTreatHiddenContactsAsDeleted() async throws {
        let store = try ObservationStore()
        let fullSource = FakeContactSource(
            authorization: .authorized,
            contacts: [ContactRecord(externalID: "contact-1", displayName: "Alex Rivera")]
        )
        _ = try await ContactsIngestor(source: fullSource, store: store).run()
        let limitedSource = FakeContactSource(authorization: .limited, contacts: [])

        let summary = try await ContactsIngestor(source: limitedSource, store: store).run()

        #expect(summary.authorization == .limited)
        #expect(summary.tombstoned == 0)
        #expect(try await store.current(source: .contacts, externalID: "contact-1")?.tombstone == false)
    }
}

private actor FakeContactSource: ContactSource {
    private var authorization: ContactAuthorizationStatus
    private var availableContacts: [ContactRecord]
    private var accessRequests = 0

    init(authorization: ContactAuthorizationStatus, contacts: [ContactRecord]) {
        self.authorization = authorization
        availableContacts = contacts
    }

    func authorizationStatus() -> ContactAuthorizationStatus {
        authorization
    }

    func requestAccess() -> Bool {
        accessRequests += 1
        authorization = .authorized
        return true
    }

    func contacts() -> [ContactRecord] {
        availableContacts
    }

    func replaceContacts(_ contacts: [ContactRecord]) {
        availableContacts = contacts
    }

    func accessRequestCount() -> Int {
        accessRequests
    }
}
