import AssistantCore
import Foundation
import Testing
@testable import IMsgTransport

struct SubmissionReconciliationTests {
    @Test func appleScriptUnknownFindsActualOutgoingRowOnOtherAliasWithoutAnotherSend() async throws {
        let fixture = try SubmissionRPCFixture(observesOutgoing: true)
        defer { fixture.remove() }
        let email = TransportChatID(rawValue: 955), phone = TransportChatID(rawValue: 954)
        let transport = PollingIMsgTransport(base: IMsgTransport(executable: fixture.executable.path),
            replyChatID: phone, ownerChatIDs: [phone, email])
        let ledger = try OutboundLedger()
        let outbound = OutboundTransportMessage(text: fixture.text)
        let entry = try await ledger.begin(requestID: outbound.requestID, chatID: email,
            text: outbound.text, sentAt: fixture.started)
        await #expect(throws: TransportFailure.self) { _ = try await transport.send(outbound, to: email) }
        let receipt = try #require(try await transport.reconcileSubmission(for: entry, in: [phone, email]))
        #expect(receipt.messageGUID == "actual-outgoing-guid")
        #expect(receipt.rowID == 200)
        #expect(receipt.requestID == outbound.requestID)
        let requests = try fixture.requests()
        #expect(requests.filter { $0["method"] as? String == "send" }.count == 1)
        let history = requests.filter { $0["method"] as? String == "messages.history" }
        #expect(history.count == 2)
        let routes = Set(history.compactMap { (($0["params"] as? [String: Any])?["chat_id"] as? NSNumber)?.int64Value })
        #expect(routes == [954, 955])
        for request in history {
            let params = try #require(request["params"] as? [String: Any])
            #expect(Set(params.keys) == ["chat_id", "limit", "attachments", "start", "end"])
        }
    }

    @Test func noOutgoingRowLeavesSubmissionUnknownInsteadOfAcknowledgingAnIncomingEcho() async throws {
        let fixture = try SubmissionRPCFixture(observesOutgoing: false)
        defer { fixture.remove() }
        let email = TransportChatID(rawValue: 955), phone = TransportChatID(rawValue: 954)
        let transport = IMsgTransport(executable: fixture.executable.path)
        let ledger = try OutboundLedger()
        let entry = try await ledger.begin(requestID: UUID(), chatID: email,
            text: fixture.text, sentAt: fixture.started)
        #expect(try await transport.reconcileSubmission(for: entry, in: [phone, email]) == nil)
        #expect(try fixture.requests().allSatisfy { $0["method"] as? String == "messages.history" })
    }
}

private struct SubmissionRPCFixture {
    let directory: URL
    let executable: URL
    let log: URL
    let text = "Assistant: Your review is tomorrow at 10."
    let started = Date(timeIntervalSince1970: 1_790_000_000)

    init(observesOutgoing: Bool) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        executable = directory.appendingPathComponent("fake-imsg")
        log = directory.appendingPathComponent("requests")
        let phone = directory.appendingPathComponent("phone.json")
        let email = directory.appendingPathComponent("email.json")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let row: [String: Any] = [
            "id": 200, "guid": "actual-outgoing-guid", "chat_id": 955,
            "text": text, "is_from_me": observesOutgoing,
            "created_at": formatter.string(from: started.addingTimeInterval(1)),
        ]
        var rows = [row]
        if !observesOutgoing {
            var ownerEcho = row
            ownerEcho["id"] = 201
            ownerEcho["guid"] = "owner-question-echo"
            ownerEcho["is_from_me"] = true
            ownerEcho["created_at"] = formatter.string(from: started.addingTimeInterval(-1))
            rows.append(ownerEcho)
        }
        try JSONSerialization.data(withJSONObject: ["messages": []]).write(to: phone)
        try JSONSerialization.data(withJSONObject: ["messages": rows]).write(to: email)
        let script = """
        #!/bin/sh
        IFS= read -r request
        printf '%s\\n' "$request" >> "\(log.path)"
        request_id=$(printf '%s\\n' "$request" | sed -n 's/.*"id":"\\([^"]*\\)".*/\\1/p')
        case "$request" in
          *'"method":"send"'*)
            printf '{"jsonrpc":"2.0","id":"%s","error":{"message":"Delivery outcome unknown","data":{"retry_safe":false}}}\\n' "$request_id"
            ;;
          *'"method":"messages.history"'*)
            printf '{"jsonrpc":"2.0","id":"%s","result":' "$request_id"
            case "$request" in
              *'"chat_id":954'*) cat "\(phone.path)" ;;
              *'"chat_id":955'*) cat "\(email.path)" ;;
              *) exit 3 ;;
            esac
            printf '}\\n'
            ;;
          *) exit 2 ;;
        esac
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    func requests() throws -> [[String: Any]] {
        try Data(contentsOf: log).split(separator: 0x0A).map {
            try JSONSerialization.jsonObject(with: Data($0)) as! [String: Any]
        }
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}
