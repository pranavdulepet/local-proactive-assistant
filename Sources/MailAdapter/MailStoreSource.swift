import AssistantCore
import Foundation
import ProcessSupport

/// Read-only Apple Events. The script is fixed; model/user text is never executable input.
public struct MailStoreSource: MailSource {
    public init() {}

    public func inboxSnapshot() async throws -> MailSnapshot {
        do {
            let output = try await BoundedProcessRunner.run(
                executable: "/usr/bin/osascript", arguments: ["-l", "JavaScript", "-e", Self.script],
                timeout: 30
            )
            return try Self.decode(output)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Apple Events errors can contain message content. Keep diagnostics generic.
            throw MailSourceFailure("Apple Mail could not be read. Allow your terminal under macOS Automation > Mail, open Mail with a synced account, and try again. A slow Mail request also stops after 30 seconds.")
        }
    }

    static func decode(_ data: Data) throws -> MailSnapshot {
        guard data.count <= 2_097_152 else { throw MailSourceFailure("Mail response exceeded its size limit.") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(MailSnapshot.self, from: data)
        guard snapshot.messages.count <= 100,
              snapshot.scanned >= snapshot.messages.count,
              snapshot.scanned <= 100,
              snapshot.skipped >= 0,
              snapshot.skipped == snapshot.scanned - snapshot.messages.count,
              snapshot.totalInbox >= snapshot.scanned,
              Set(snapshot.messages.map(\.externalID)).count == snapshot.messages.count,
              snapshot.messages.allSatisfy({
                  !$0.externalID.isEmpty && $0.externalID.utf8.count <= 128 &&
                  $0.sender.utf8.count <= 1_024 && $0.subject.utf8.count <= 1_024 &&
                  $0.body.utf8.count <= 8_192
              }) else { throw MailSourceFailure("Mail returned an invalid bounded snapshot.") }
        return snapshot
    }

    // Mail supplies Inbox order; coverage deliberately does not call it a full or sorted export.
    static let script = #"""
    function run() {
        function bounded(value, count) { return Array.from(String(value || '')).slice(0, count).join(''); }
        var mail = Application('Mail');
        if (mail.accounts().length === 0) throw new Error('No Mail accounts are configured');
        var inbox = mail.inbox.messages();
        var scanned = Math.min(inbox.length, 100);
        var records = [];
        var skipped = 0;
        for (var i = 0; i < scanned; i++) {
            try {
                var m = inbox[i];
                records.push({
                    externalID: String(m.id()),
                    sender: bounded(m.sender(), 256),
                    subject: bounded(m.subject(), 256),
                    receivedAt: m.dateReceived().toISOString().replace(/\.\d{3}Z$/, 'Z'),
                    unread: !m.readStatus(),
                    body: bounded(m.content(), 2000)
                });
            } catch (_) { skipped++; }
        }
        return JSON.stringify({messages: records, totalInbox: inbox.length, scanned: scanned, skipped: skipped});
    }
    """#
}
