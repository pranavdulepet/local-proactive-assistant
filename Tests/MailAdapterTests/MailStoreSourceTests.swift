import AssistantCore
import Foundation
import ProcessSupport
import Testing
@testable import MailAdapter

struct MailStoreSourceTests {
    @Test func fixedJXAScriptReturnsBoundedReadOnlyInboxData() async throws {
        // Run real JavaScript for Automation with a fake Mail object, without Apple Events.
        let fixture = #"""
        function fakeMail() {
            var items = [];
            for (var i = 0; i < 120; i++) {
                items.push({
                    id: function() { return this.index; }, index: i + 1,
                    sender: function() { return 'Maya <maya@example.test>'; },
                    subject: function() { return 'Review \\"quoted\\" subject'; },
                    dateReceived: function() { return new Date('2026-10-04T18:00:00Z'); },
                    readStatus: function() { return false; },
                    content: function() { return 'Body ' + 'x'.repeat(3000); }
                });
            }
            return {accounts: function() { return [{}]; }, inbox: {messages: function() { return items; }}};
        }
        """#
        let output = try await BoundedProcessRunner.run(
            executable: "/usr/bin/osascript", arguments: ["-l", "JavaScript", "-e",
                MailStoreSource.script + fixture + "\nfunction run() { return readMailInbox(fakeMail()); }"], timeout: 10
        )
        let snapshot = try MailStoreSource.decode(output)
        #expect(snapshot.totalInbox == 120)
        #expect(snapshot.scanned == 100)
        #expect(snapshot.messages.count == 100)
        #expect(snapshot.messages.allSatisfy { $0.unread && $0.body.count == 2000 })
    }

    @Test func decoderRejectsDuplicateIDsAndOversizedBodies() throws {
        let record = MailMessageRecord(externalID: "1", sender: "Maya", subject: "Review", receivedAt: Date(), unread: true, body: "body")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        #expect(throws: Error.self) {
            try MailStoreSource.decode(encoder.encode(MailSnapshot(messages: [record, record], totalInbox: 2, scanned: 2)))
        }
        let big = MailMessageRecord(externalID: "2", sender: "Maya", subject: "Review", receivedAt: Date(), unread: true, body: String(repeating: "x", count: 9000))
        #expect(throws: Error.self) {
            try MailStoreSource.decode(encoder.encode(MailSnapshot(messages: [big], totalInbox: 1, scanned: 1)))
        }
    }
}
