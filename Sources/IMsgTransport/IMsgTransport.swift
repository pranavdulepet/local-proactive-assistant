import AssistantCore
import Foundation

public struct IMsgTransport: MessageTransport, MessageHistorySource, Sendable {
    private let executable: String

    public init(executable: String = "imsg") {
        self.executable = executable
    }

    public func probe() async -> TransportHealth {
        do {
            let result = try await rpc(method: "status", params: [:])
            let database = result["database"] as? [String: Any]
            let ready = database?["ready"] as? Bool ?? false
            let version = result["version"] as? String
            let detail = ready
                ? "Messages database is readable."
                : (database?["error"] as? String ?? "Messages database is unavailable.")
            return TransportHealth(ready: ready, version: version, detail: detail)
        } catch {
            return TransportHealth(ready: false, detail: String(describing: error))
        }
    }

    public func chats() async throws -> [TransportChat] {
        let data = try await ProcessRunner.run(
            executable: executable,
            arguments: ["chats", "--limit", "100", "--json"]
        )

        return try data
            .split(separator: 0x0A)
            .filter { !$0.isEmpty }
            .map { try JSONDecoder().decode(IMsgChat.self, from: Data($0)).transportChat }
    }

    public func messages(
        after cursor: TransportCursor,
        limit: Int = 500
    ) async throws -> MessageHistoryPage {
        guard (1...500).contains(limit), cursor.rawValue >= 0 else {
            throw TransportFailure("Invalid history page bounds.", retrySafe: true)
        }
        let result = try await rpc(
            method: "messages.after",
            params: [
                "since_rowid": cursor.rawValue,
                "limit": limit,
                "attachments": false,
                "include_reactions": false,
            ]
        )
        guard let rawMessages = result["messages"] as? [[String: Any]],
              let nextRowID = (result["next_rowid"] as? NSNumber)?.int64Value,
              let hasMore = result["has_more"] as? Bool else {
            throw TransportFailure("imsg returned an invalid history page.")
        }

        let data = try JSONSerialization.data(withJSONObject: rawMessages)
        let messages = try JSONDecoder().decode([IMsgMessage].self, from: data)
        try Self.validatePage(rows: messages.map(\.id), after: cursor.rawValue,
            next: nextRowID, hasMore: hasMore, limit: limit)
        return MessageHistoryPage(
            messages: try messages.map { try $0.historyMessage },
            nextCursor: TransportCursor(rawValue: nextRowID),
            hasMore: hasMore
        )
    }

    public func matchingMessages(_ query: String) async throws -> [InboundTransportMessage] {
        let result = try await rpc(
            method: "messages.search",
            params: ["query": query, "match": "exact", "limit": 20]
        )
        guard let rawMessages = result["messages"] as? [[String: Any]] else {
            throw TransportFailure("imsg returned an invalid search response.")
        }
        let data = try JSONSerialization.data(withJSONObject: rawMessages)
        return try JSONDecoder().decode([IMsgMessage].self, from: data)
            .map { try $0.transportMessage }
            .filter { $0.text == query }
    }

    public func subscribe(
        chatID: TransportChatID,
        after cursor: TransportCursor?
    ) -> AsyncThrowingStream<InboundTransportMessage, Error> {
        let requestID = UUID().uuidString
        var params: [String: Any] = ["chat_id": chatID.rawValue]
        if let cursor {
            params["since_rowid"] = cursor.rawValue
        }

        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": requestID,
            "method": "watch.subscribe",
            "params": params,
        ]

        let input: Data
        do {
            var encoded = try JSONSerialization.data(withJSONObject: request)
            encoded.append(0x0A)
            input = encoded
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }

        let process = StreamingProcess()
        let lines = process.lines(
            executable: executable,
            arguments: ["rpc"],
            initialStandardInput: input
        )

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var subscriptionID: Int?

                    for try await line in lines {
                        let envelope = try JSONDecoder().decode(IMsgRPCEnvelope.self, from: line)

                        if envelope.id == requestID {
                            if let error = envelope.error {
                                throw TransportFailure(error.message)
                            }
                            guard let subscription = envelope.result?.subscription else {
                                throw TransportFailure("imsg returned an invalid watch subscription response.")
                            }
                            subscriptionID = subscription
                            transportDebugLog("watch subscription \(subscription) confirmed")
                            continue
                        }

                        switch envelope.method {
                        case "message":
                            guard let subscriptionID else {
                                throw TransportFailure("imsg emitted a message before confirming the watch subscription.")
                            }
                            guard envelope.params?.subscription == subscriptionID,
                                  let message = envelope.params?.message else {
                                continue
                            }
                            continuation.yield(try message.transportMessage)

                        case "watch.overflow":
                            let cursor = envelope.params?.resumeAfterRowID
                                .map { " Resume after row \($0)." } ?? ""
                            throw TransportFailure("imsg watch buffer overflowed.\(cursor)")

                        default:
                            continue
                        }
                    }
                    if Task.isCancelled {
                        continuation.finish()
                    } else {
                        continuation.finish(
                            throwing: TransportFailure(
                                "imsg RPC watch ended unexpectedly.",
                                retrySafe: true
                            )
                        )
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Paged chat catchup is the control path. It does not depend on filesystem events.
    /// A nil cursor starts at the newest message in this chat, so setup never replays history.
    public func subscribeByPolling(
        chatID: TransportChatID,
        after cursor: TransportCursor?,
        interval: Duration = .seconds(2)
    ) -> AsyncThrowingStream<InboundTransportMessage, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var position: TransportCursor
                    if let cursor {
                        position = cursor
                    } else {
                        position = try await latestCursor(in: chatID)
                    }
                    while !Task.isCancelled {
                        let page = try await chatPage(in: chatID, after: position)
                        guard page.nextCursor >= position else {
                            throw TransportFailure("imsg history cursor moved backwards.")
                        }
                        if page.hasMore && page.nextCursor == position {
                            throw TransportFailure("imsg history page did not advance.")
                        }
                        for message in page.messages {
                            try Task.checkCancellation()
                            continuation.yield(message)
                        }
                        position = page.nextCursor
                        if !page.hasMore {
                            try await Task.sleep(for: interval)
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: TransportFailure(
                        "imsg chat catchup failed: \(error)", retrySafe: true
                    ))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Advance past the current physical scan head for a chat after an uncertain
    /// legacy send. This never dispatches a message.
    public func latestChatCursor(
        in chatID: TransportChatID,
        after saved: TransportCursor
    ) async throws -> TransportCursor {
        var cursor = saved
        while true {
            let page = try await chatPage(in: chatID, after: cursor)
            guard page.nextCursor >= cursor,
                  !page.hasMore || page.nextCursor > cursor else {
                throw TransportFailure("imsg chat history did not advance during recovery.")
            }
            cursor = page.nextCursor
            if !page.hasMore { return cursor }
        }
    }

    private func latestCursor(in chatID: TransportChatID) async throws -> TransportCursor {
        let result = try await rpc(
            method: "messages.history",
            params: ["chat_id": chatID.rawValue, "limit": 1, "attachments": false]
        )
        guard let rawMessages = result["messages"] as? [[String: Any]] else {
            throw TransportFailure("imsg returned an invalid latest message response.")
        }
        guard let latest = rawMessages.first else { return TransportCursor(rawValue: 0) }
        guard let row = (latest["id"] as? NSNumber)?.int64Value else {
            throw TransportFailure("imsg returned a latest message without a row ID.")
        }
        return TransportCursor(rawValue: row)
    }

    private func chatPage(
        in chatID: TransportChatID,
        after cursor: TransportCursor
    ) async throws -> (messages: [InboundTransportMessage], nextCursor: TransportCursor, hasMore: Bool) {
        let result = try await rpc(
            method: "messages.after",
            params: [
                "chat_id": chatID.rawValue,
                "since_rowid": cursor.rawValue,
                "limit": 100,
                "attachments": false,
                "include_reactions": false,
            ]
        )
        guard let rawMessages = result["messages"] as? [[String: Any]],
              let nextRowID = (result["next_rowid"] as? NSNumber)?.int64Value,
              let hasMore = result["has_more"] as? Bool else {
            throw TransportFailure("imsg returned an invalid chat history page.")
        }
        let data = try JSONSerialization.data(withJSONObject: rawMessages)
        let messages = try JSONDecoder().decode([IMsgMessage].self, from: data)
        try Self.validatePage(rows: messages.map(\.id), after: cursor.rawValue,
            next: nextRowID, hasMore: hasMore, limit: 100)
        let inbound = try messages.map { try $0.transportMessage }
        guard inbound.allSatisfy({ $0.chatID == chatID }) else {
            throw TransportFailure("imsg returned a message from another chat.")
        }
        return (inbound, TransportCursor(rawValue: nextRowID), hasMore)
    }

    static func validatePage(rows: [Int64], after: Int64, next: Int64, hasMore: Bool, limit: Int) throws {
        guard next >= after, !hasMore || next > after, rows.count <= limit,
              rows.allSatisfy({ $0 > after && $0 <= next }),
              zip(rows, rows.dropFirst()).allSatisfy({ $0 < $1 }) else {
            throw TransportFailure("imsg returned an invalid history cursor or row order.")
        }
    }

    public func send(
        _ message: OutboundTransportMessage,
        to chatID: TransportChatID
    ) async throws -> SendReceipt {
        let result = try await rpc(
            method: "send",
            params: [
                "chat_id": chatID.rawValue,
                "text": message.text,
                "transport": "applescript",
                "service": "imessage",
                "allow_sms_fallback": false,
            ],
            // A status hint must not hold the final answer behind eight-second echo verification.
            timeout: message.isProgress ? 2 : 60
        )

        guard result["ok"] as? Bool == true else {
            throw TransportFailure("imsg did not confirm the send.")
        }

        return SendReceipt(
            requestID: message.requestID,
            messageGUID: result["guid"] as? String,
            rowID: (result["id"] as? NSNumber)?.int64Value,
            transport: result["transport"] as? String
        )
    }

    public func reconcileSubmission(
        for entry: OutboundLedgerEntry,
        in verifiedChatIDs: Set<TransportChatID>
    ) async throws -> SendReceipt? {
        guard verifiedChatIDs.contains(entry.chatID), !verifiedChatIDs.isEmpty,
              verifiedChatIDs.count <= 16 else {
            throw TransportFailure("Submission lookup requires verified owner chats.", retrySafe: true)
        }
        // imsg's AppleScript verifier inspects one resolved chat. Messages can
        // attach a self-send to the owner's other verified phone/email alias.
        // Read both aliases; do not issue the send again.
        let rows = try await withThrowingTaskGroup(of: [InboundTransportMessage].self) { group in
            for chatID in verifiedChatIDs {
                group.addTask { try await self.submissionRows(in: chatID, since: entry.sentAt) }
            }
            var rows: [InboundTransportMessage] = []
            for try await page in group { rows.append(contentsOf: page) }
            return rows
        }
        return OutboundLedger.submissionReceipt(for: entry, messages: rows, in: verifiedChatIDs)
    }

    private func submissionRows(
        in chatID: TransportChatID,
        since startedAt: Date
    ) async throws -> [InboundTransportMessage] {
        let limit = 100
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let result = try await rpc(method: "messages.history", params: [
            "chat_id": chatID.rawValue, "limit": limit, "attachments": false,
            "start": formatter.string(from: startedAt),
            "end": formatter.string(from: startedAt.addingTimeInterval(120)),
        ], timeout: 3)
        guard let rawMessages = result["messages"] as? [[String: Any]], rawMessages.count <= limit else {
            throw TransportFailure("imsg returned an invalid submission history page.")
        }
        let data = try JSONSerialization.data(withJSONObject: rawMessages)
        let messages = try JSONDecoder().decode([IMsgMessage].self, from: data)
        let rows = try messages.map { try $0.transportMessage }
        guard rows.allSatisfy({ $0.chatID == chatID }),
              Set(rows.map(\.cursor)).count == rows.count else {
            throw TransportFailure("imsg returned an invalid submission history chat or duplicate row.")
        }
        // A busy chat may have more than 100 rows in this window. A truncated
        // window cannot establish that a content match was unique.
        guard rows.count < limit else {
            throw TransportFailure("Submission history is too busy to confirm a unique outgoing row.")
        }
        return rows
    }

    public func setTyping(_ typing: Bool, to chatID: TransportChatID) async -> Bool {
        do {
            let status = try await rpc(method: "status", params: [:], timeout: 2)
            let bridge = status["bridge"] as? [String: Any]
            // Never launch/inject a bridge or use private fallback on a stock Mac.
            guard bridge?["ready"] as? Bool == true,
                  (status["methods"] as? [String])?.contains("typing") == true else { return false }
            let result = try await rpc(method: "typing", params: ["chat_id": chatID.rawValue, "typing": typing], timeout: 2)
            return result["ok"] as? Bool == true
        } catch { return false }
    }

    private func rpc(
        method: String,
        params: [String: Any],
        timeout: TimeInterval = 60
    ) async throws -> [String: Any] {
        let requestID = UUID().uuidString
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": requestID,
            "method": method,
            "params": params,
        ]
        var input = try JSONSerialization.data(withJSONObject: request)
        input.append(0x0A)

        let output = try await ProcessRunner.run(
            executable: executable,
            arguments: ["rpc"],
            standardInput: input,
            timeout: timeout
        )

        let response = try Self.response(in: output, requestID: requestID)

        if let error = response["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "Unknown imsg RPC error."
            let data = error["data"] as? [String: Any]
            throw TransportFailure(message, retrySafe: data?["retry_safe"] as? Bool ?? false)
        }

        guard let result = response["result"] as? [String: Any] else {
            throw TransportFailure("imsg RPC response did not contain a result.")
        }
        return result
    }

    static func response(in output: Data, requestID: String) throws -> [String: Any] {
        for line in output.split(separator: 0x0A) {
            guard let response = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  response["jsonrpc"] as? String == "2.0" else {
                throw TransportFailure("imsg returned an invalid RPC envelope.")
            }
            guard response["id"] as? String == requestID else { continue }
            guard (response["result"] != nil) != (response["error"] != nil) else {
                throw TransportFailure("imsg returned an ambiguous RPC response.")
            }
            return response
        }
        throw TransportFailure("imsg returned no matching RPC response.")
    }
}

private struct IMsgRPCEnvelope: Decodable {
    let id: String?
    let method: String?
    let result: IMsgRPCSubscriptionResult?
    let params: IMsgRPCWatchParams?
    let error: IMsgRPCError?
}

private struct IMsgRPCSubscriptionResult: Decodable {
    let subscription: Int
}

private struct IMsgRPCWatchParams: Decodable {
    let subscription: Int?
    let message: IMsgMessage?
    let resumeAfterRowID: Int64?

    enum CodingKeys: String, CodingKey {
        case subscription, message
        case resumeAfterRowID = "resume_after_rowid"
    }
}

private struct IMsgRPCError: Decodable {
    let message: String
}

private struct IMsgChat: Decodable {
    let id: Int64
    let identifier: String
    let guid: String
    let name: String
    let displayName: String
    let service: String
    let participants: [String]
    let isGroup: Bool

    enum CodingKeys: String, CodingKey {
        case id, identifier, guid, name, service, participants
        case displayName = "display_name"
        case isGroup = "is_group"
    }

    var transportChat: TransportChat {
        TransportChat(
            id: TransportChatID(rawValue: id),
            identifier: identifier,
            guid: guid,
            displayName: displayName.isEmpty ? name : displayName,
            service: service,
            participants: participants,
            isGroup: isGroup
        )
    }
}

private struct IMsgMessage: Decodable {
    let id: Int64
    let guid: String
    let chatID: Int64
    let text: String
    let isFromMe: Bool
    let isGroup: Bool?
    let senderName: String?
    let createdAt: String
    let sender: String?
    let chatIdentifier: String?
    let participants: [String]?

    enum CodingKeys: String, CodingKey {
        case id, guid, text
        case chatID = "chat_id"
        case isFromMe = "is_from_me"
        case isGroup = "is_group"
        case senderName = "sender_name"
        case createdAt = "created_at"
        case sender
        case chatIdentifier = "chat_identifier"
        case participants
    }

    var transportMessage: InboundTransportMessage {
        get throws {
            guard let date = Self.date(from: createdAt) else {
                throw TransportFailure("imsg returned an invalid created_at timestamp: \(createdAt)")
            }

            return InboundTransportMessage(
                cursor: TransportCursor(rawValue: id),
                guid: guid,
                chatID: TransportChatID(rawValue: chatID),
                text: text,
                isFromMe: isFromMe,
                createdAt: date
            )
        }
    }

    var historyMessage: HistoricalMessage {
        get throws {
            guard let date = Self.date(from: createdAt) else {
                throw TransportFailure("imsg returned an invalid created_at timestamp: \(createdAt)")
            }
            return HistoricalMessage(
                cursor: TransportCursor(rawValue: id),
                guid: guid,
                chatID: TransportChatID(rawValue: chatID),
                text: text,
                isFromMe: isFromMe,
                isGroup: isGroup ?? false,
                senderName: senderName,
                createdAt: date,
                participantHandle: participants?.first ?? chatIdentifier ?? sender
            )
        }
    }

    private static func date(from value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

public actor PollingIMsgTransport: MessageTransport {
    private let base: IMsgTransport
    private var sendTail: Task<Void, Never>?
    private let replyChatID: TransportChatID?
    private let ownerChatIDs: Set<TransportChatID>

    public init(base: IMsgTransport, replyChatID: TransportChatID? = nil,
                ownerChatIDs: Set<TransportChatID> = []) {
        self.base = base
        self.replyChatID = replyChatID
        self.ownerChatIDs = ownerChatIDs
    }

    public func probe() async -> TransportHealth { await base.probe() }
    public func chats() async throws -> [TransportChat] { try await base.chats() }

    public nonisolated func subscribe(
        chatID: TransportChatID,
        after cursor: TransportCursor?
    ) -> AsyncThrowingStream<InboundTransportMessage, Error> {
        base.subscribeByPolling(chatID: chatID, after: cursor)
    }

    public func send(
        _ message: OutboundTransportMessage,
        to chatID: TransportChatID
    ) async throws -> SendReceipt {
        let destination = try replyDestination(for: chatID)
        // imsg's mutation lane is per RPC child. This shared actor serializes sends
        // across owner routes, model answers, and reminders even though each call
        // launches its own child.
        let previous = sendTail
        let operation = Task { () throws -> SendReceipt in
            if let previous { await previous.value }
            return try await base.send(message, to: destination)
        }
        sendTail = Task { _ = try? await operation.value }
        return try await operation.value
    }

    public func reconcileSubmission(
        for entry: OutboundLedgerEntry,
        in verifiedChatIDs: Set<TransportChatID>
    ) async throws -> SendReceipt? {
        let allowed = ownerChatIDs.isEmpty ? verifiedChatIDs : ownerChatIDs
        guard !verifiedChatIDs.isEmpty, verifiedChatIDs.isSubset(of: allowed) else {
            throw TransportFailure("Submission lookup included an unverified owner chat.", retrySafe: true)
        }
        return try await base.reconcileSubmission(for: entry, in: verifiedChatIDs)
    }

    public func setTyping(_ typing: Bool, to chatID: TransportChatID) async -> Bool {
        guard let destination = try? replyDestination(for: chatID) else { return false }
        return await base.setTyping(typing, to: destination)
    }

    func replyDestination(for requested: TransportChatID) throws -> TransportChatID {
        guard let replyChatID else { return requested }
        guard ownerChatIDs.contains(requested), ownerChatIDs.contains(replyChatID) else {
            throw TransportFailure("The reply route is not a verified owner chat.", retrySafe: true)
        }
        return replyChatID
    }
}
