import Foundation

public enum EchoSendOutcome: Equatable, Sendable {
    case notAttempted
    case confirmed
    case notStarted
    case uncertain
}

public struct EchoEvent: Equatable, Sendable {
    public let inbound: InboundTransportMessage
    public let decision: InboundDecision
    public let receipt: SendReceipt?
    public let sendOutcome: EchoSendOutcome

    public init(
        inbound: InboundTransportMessage,
        decision: InboundDecision,
        receipt: SendReceipt?,
        sendOutcome: EchoSendOutcome = .notAttempted
    ) {
        self.inbound = inbound
        self.decision = decision
        self.receipt = receipt
        self.sendOutcome = sendOutcome
    }
}

public struct EchoService: Sendable {
    private let transport: any MessageTransport
    private let ledger: OutboundLedger
    private let cursorStore: CursorStore
    private let reply: @Sendable (String) async throws -> String?
    private let reconnectDelay: @Sendable (Int) -> TimeInterval
    private let onReconnect: @Sendable (Int, TimeInterval, String) -> Void

    public init(
        transport: any MessageTransport,
        ledger: OutboundLedger,
        cursorStore: CursorStore = CursorStore(),
        reply: @escaping @Sendable (String) async throws -> String? = { "echo: \($0)" },
        reconnectDelay: @escaping @Sendable (Int) -> TimeInterval = { attempt in
            min(pow(2, Double(attempt - 1)), 30)
        },
        onReconnect: @escaping @Sendable (Int, TimeInterval, String) -> Void = { _, _, _ in }
    ) {
        self.transport = transport
        self.ledger = ledger
        self.cursorStore = cursorStore
        self.reply = reply
        self.reconnectDelay = reconnectDelay
        self.onReconnect = onReconnect
    }

    public func events(
        chatID: TransportChatID,
        after cursor: TransportCursor? = nil
    ) -> AsyncThrowingStream<EchoEvent, Error> {
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let filter = ControlMessageFilter(
                        controlChatID: chatID,
                        ledger: ledger
                    )
                    let storedCursor = await cursorStore.cursor(for: chatID)
                    var lastCursor = [cursor, storedCursor].compactMap { $0 }.max()
                    var reconnectAttempt = 0

                    while !Task.isCancelled {
                        let inbound = transport.subscribe(chatID: chatID, after: lastCursor)
                        do {
                            for try await message in inbound {
                                reconnectAttempt = 0
                                let decision = try await filter.evaluate(
                                    message,
                                    after: lastCursor
                                )
                                guard decision == .accept else {
                                    lastCursor = max(lastCursor ?? message.cursor, message.cursor)
                                    try await cursorStore.advance(
                                        chatID: chatID,
                                        to: message.cursor
                                    )
                                    continuation.yield(
                                        EchoEvent(
                                            inbound: message,
                                            decision: decision,
                                            receipt: nil
                                        )
                                    )
                                    continue
                                }

                                guard let replyText = try await reply(message.text) else {
                                    lastCursor = max(lastCursor ?? message.cursor, message.cursor)
                                    try await cursorStore.advance(
                                        chatID: chatID,
                                        to: message.cursor
                                    )
                                    continuation.yield(
                                        EchoEvent(
                                            inbound: message,
                                            decision: .accept,
                                            receipt: nil
                                        )
                                    )
                                    continue
                                }

                                let outbound = OutboundTransportMessage(text: replyText)
                                try await ledger.begin(
                                    requestID: outbound.requestID,
                                    chatID: chatID,
                                    text: outbound.text
                                )
                                // At-most-once delivery: persist the incoming row before dispatch.
                                // A crash or ambiguous send must never replay this command.
                                do {
                                    try await cursorStore.advance(chatID: chatID, to: message.cursor)
                                } catch {
                                    try? await ledger.cancel(requestID: outbound.requestID)
                                    throw error
                                }
                                lastCursor = max(lastCursor ?? message.cursor, message.cursor)

                                do {
                                    let receipt = try await transport.send(outbound, to: chatID)
                                    try await ledger.confirm(
                                        requestID: outbound.requestID,
                                        messageGUID: receipt.messageGUID
                                    )
                                    continuation.yield(
                                        EchoEvent(
                                            inbound: message,
                                            decision: .accept,
                                            receipt: receipt,
                                            sendOutcome: .confirmed
                                        )
                                    )
                                } catch let failure as TransportFailure where failure.retrySafe {
                                    try await ledger.cancel(requestID: outbound.requestID)
                                    continuation.yield(
                                        EchoEvent(
                                            inbound: message,
                                            decision: .accept,
                                            receipt: nil,
                                            sendOutcome: .notStarted
                                        )
                                    )
                                } catch {
                                    // The send may already be visible on the phone. The
                                    // input is checkpointed; keep echo suppression and listen.
                                    try await ledger.markRecovered(requestID: outbound.requestID)
                                    continuation.yield(
                                        EchoEvent(
                                            inbound: message,
                                            decision: .accept,
                                            receipt: nil,
                                            sendOutcome: .uncertain
                                        )
                                    )
                                }
                            }

                            break
                        } catch let failure as TransportFailure where failure.retrySafe {
                            reconnectAttempt += 1
                            let delay = reconnectDelay(reconnectAttempt)
                            onReconnect(reconnectAttempt, delay, failure.message)
                            try await Task.sleep(
                                for: .milliseconds(Int64(delay * 1_000))
                            )
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
