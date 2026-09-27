import AssistantCore
import Foundation
import Testing
@testable import IMsgTransport

struct IMsgTransportTests {
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
        printf '{"jsonrpc":"2.0","id":"%s","result":{"messages":[{"id":101,"guid":"message-guid","chat_id":42,"text":"hello","is_from_me":false,"is_group":false,"sender_name":"Alice","created_at":"2026-09-27T00:57:57.794Z"}],"next_rowid":123,"has_more":true}}\n' "$request_id"
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
}
