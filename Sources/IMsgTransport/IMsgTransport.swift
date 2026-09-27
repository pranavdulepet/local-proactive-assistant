import AssistantCore
import Foundation

public struct IMsgTransport: MessageTransport, Sendable {
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

    public func subscribe(
        chatID: TransportChatID,
        after cursor: TransportCursor?
    ) -> AsyncThrowingStream<InboundTransportMessage, Error> {
        var arguments = ["watch", "--chat-id", String(chatID.rawValue), "--json"]
        if let cursor {
            arguments += ["--since-rowid", String(cursor.rawValue)]
        }

        let process = StreamingProcess()
        let lines = process.lines(executable: executable, arguments: arguments)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in lines {
                        let message = try JSONDecoder().decode(IMsgMessage.self, from: line)
                        continuation.yield(try message.transportMessage)
                    }
                    continuation.finish()
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
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, guid, text
        case chatID = "chat_id"
        case isFromMe = "is_from_me"
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

    private static func date(from value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
