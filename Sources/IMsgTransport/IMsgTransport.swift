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
            arguments: ["chats", "--limit", "10000", "--json"]
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
        return MessageHistoryPage(
            messages: try messages.map { try $0.historyMessage },
            nextCursor: TransportCursor(rawValue: nextRowID),
            hasMore: hasMore
        )
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
            ]
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

    private func rpc(
        method: String,
        params: [String: Any]
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
            standardInput: input
        )

        guard let line = output.split(separator: 0x0A).first else {
            throw TransportFailure("imsg returned no RPC response.")
        }
        guard let response = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
            throw TransportFailure("imsg returned an invalid RPC response.")
        }

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

    enum CodingKeys: String, CodingKey {
        case id, guid, text
        case chatID = "chat_id"
        case isFromMe = "is_from_me"
        case isGroup = "is_group"
        case senderName = "sender_name"
        case createdAt = "created_at"
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
                createdAt: date
            )
        }
    }

    private static func date(from value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
