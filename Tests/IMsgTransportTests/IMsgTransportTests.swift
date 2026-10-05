import AssistantCore
import Foundation
import Testing
@testable import IMsgTransport

struct IMsgTransportTests {
    @Test func typingNeverActivatesAnUnavailableBridge() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake-imsg")
        let log = directory.appendingPathComponent("requests")
        let script = """
        #!/bin/sh
        IFS= read -r request
        printf '%s\\n' "$request" >> "\(log.path)"
        printf '%s\\n' '{"result":{"bridge":{"ready":false},"methods":["typing"]}}'
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        #expect(!(await IMsgTransport(executable: executable.path).setTyping(true, to: TransportChatID(rawValue: 954))))
        let requests = try String(contentsOf: log, encoding: .utf8)
        #expect(requests.contains("\"method\":\"status\""))
        #expect(!requests.contains("\"method\":\"typing\""))
        #expect(!requests.contains("launch"))
    }

    @Test func typingUsesOnlyTheVerifiedChatWhenABridgeIsReady() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake-imsg")
        let log = directory.appendingPathComponent("requests")
        let script = """
        #!/bin/sh
        IFS= read -r request
        printf '%s\\n' "$request" >> "\(log.path)"
        printf '%s\\n' '{"result":{"ok":true,"bridge":{"ready":true},"methods":["typing"]}}'
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let transport = IMsgTransport(executable: executable.path)
        #expect(await transport.setTyping(true, to: TransportChatID(rawValue: 954)))
        #expect(await transport.setTyping(false, to: TransportChatID(rawValue: 954)))
        let requests = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        let typing = try requests.compactMap { line -> [String: Any]? in
            let value = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            return value["method"] as? String == "typing" ? value["params"] as? [String: Any] : nil
        }
        #expect(typing.count == 2)
        #expect(typing.allSatisfy { ($0["chat_id"] as? NSNumber)?.int64Value == 954 && $0["to"] == nil })
        #expect(typing[0]["typing"] as? Bool == true)
        #expect(typing[1]["typing"] as? Bool == false)
    }

    @Test
    func boundsHungRequestsWithoutMarkingSendSafeToRetry() async throws {
        do {
            _ = try await ProcessRunner.run(executable: "/bin/sleep", arguments: ["10"], timeout: 0.1)
            Issue.record("Expected a deadline failure")
        } catch let error as TransportFailure {
            #expect(error.description.contains("deadline"))
            #expect(!error.retrySafe)
        }
    }

    @Test
    func cancellationStopsTheChild() async throws {
        let request = Task {
            try await ProcessRunner.run(executable: "/bin/sleep", arguments: ["10"])
        }
        try await Task.sleep(for: .milliseconds(100))
        request.cancel()
        do {
            _ = try await request.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Cancellation is not a successful response or a retry-safe send failure.
        }
    }
    @Test
    func drainsLargeProcessOutputWhileTheChildIsRunning() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("large-output")
        let script = #"""
        #!/bin/sh
        IFS= read -r _
        dd if=/dev/zero bs=131072 count=1 2>/dev/null | tr '\000' x
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path
        )

        let output = try await ProcessRunner.run(
            executable: executable.path,
            arguments: [],
            standardInput: Data("request\n".utf8)
        )

        #expect(output.count == 131_072)
    }

    @Test
    func readsResumableMessageHistoryPages() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("fake-imsg")
        let script = #"""
        #!/bin/sh
        IFS= read -r request
        request_id=$(printf '%s\n' "$request" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
        printf '{"jsonrpc":"2.0","id":"%s","result":{"messages":[{"id":101,"guid":"message-guid","chat_id":42,"chat_identifier":"+14155550123","participants":["+14155550123"],"text":"hello","is_from_me":false,"is_group":false,"sender_name":"Alice","created_at":"2026-09-27T00:57:57.794Z"}],"next_rowid":123,"has_more":true}}\n' "$request_id"
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path
        )

        let page = try await IMsgTransport(executable: executable.path).messages(
            after: TransportCursor(rawValue: 99),
            limit: 20
        )

        #expect(page.nextCursor.rawValue == 123)
        #expect(page.hasMore)
        #expect(page.messages.count == 1)
        #expect(page.messages[0].cursor.rawValue == 101)
        #expect(page.messages[0].guid == "message-guid")
        #expect(page.messages[0].chatID.rawValue == 42)
        #expect(page.messages[0].senderName == "Alice")
        #expect(page.messages[0].participantHandle == "+14155550123")
        #expect(!page.messages[0].isGroup)
    }

    @Test
    func receivesMessagesFromRPCWatchSubscription() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("fake-imsg")
        let script = #"""
        #!/bin/sh
        IFS= read -r request
        request_id=$(printf '%s\n' "$request" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
        printf '{"jsonrpc":"2.0","id":"%s","result":{"subscription":7,"buffer_limit":256}}\n' "$request_id"
        printf '{"jsonrpc":"2.0","method":"message","params":{"subscription":7,"message":{"id":101,"guid":"message-guid","chat_id":42,"text":"hello","is_from_me":true,"created_at":"2026-09-27T00:57:57.794Z"}}}\n'
        while IFS= read -r _; do :; done
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path
        )

        let transport = IMsgTransport(executable: executable.path)
        let stream = transport.subscribe(
            chatID: TransportChatID(rawValue: 42),
            after: nil
        )

        for try await message in stream {
            #expect(message.cursor.rawValue == 101)
            #expect(message.guid == "message-guid")
            #expect(message.chatID.rawValue == 42)
            #expect(message.text == "hello")
            return
        }

        Issue.record("RPC watch ended without emitting a message")
    }
    @Test
    func pollingCatchesNewCommandWithoutWatchNotification() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("fake-imsg")
        let script = #"""
        #!/bin/sh
        IFS= read -r request
        request_id=$(printf '%s\n' "$request" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
        case "$request" in
          *'"method":"messages.history"'*)
            printf '{"jsonrpc":"2.0","id":"%s","result":{"messages":[{"id":100}]}}\n' "$request_id"
            ;;
          *'"method":"messages.after"'*)
            printf '%s\\n' "$request" | grep -q '"chat_id":42' || exit 2
            printf '%s\\n' "$request" | grep -q '"since_rowid":100' || exit 2
            printf '{"jsonrpc":"2.0","id":"%s","result":{"messages":[{"id":101,"guid":"new-command","chat_id":42,"text":"/status","is_from_me":true,"created_at":"2026-09-27T00:57:57.794Z"}],"next_rowid":101,"has_more":false}}\n' "$request_id"
            ;;
          *)
            printf '{"jsonrpc":"2.0","id":"%s","error":{"message":"unexpected request"}}\n' "$request_id"
            ;;
        esac
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: executable.path
        )

        let stream = PollingIMsgTransport(base: IMsgTransport(executable: executable.path))
            .subscribe(chatID: TransportChatID(rawValue: 42), after: nil)
        for try await message in stream {
            #expect(message.cursor.rawValue == 101)
            #expect(message.text == "/status")
            #expect(message.chatID.rawValue == 42)
            return
        }
        Issue.record("History polling ended without a new command")
    }

}
