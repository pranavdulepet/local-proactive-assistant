import Foundation

public struct EchoEvent: Equatable, Sendable {
    public let inbound: InboundTransportMessage
    public let decision: InboundDecision
    public let receipt: SendReceipt?

    public init(
        inbound: InboundTransportMessage,
        decision: InboundDecision,
        receipt: SendReceipt?
    ) {
        self.inbound = inbound
        self.decision = decision
        self.receipt = receipt
    }
}

public struct EchoService: Sendable {
    private let transport: any MessageTransport
    private let ledger: OutboundLedger
    private let reply: @Sendable (String) -> String

    public init(
        transport: any MessageTransport,
        ledger: OutboundLedger,
        reply: @escaping @Sendable (String) -> String = { "echo: \($0)" }
    ) {
        self.transport = transport
        self.ledger = ledger
        self.reply = reply
    }

    public func events(
        chatID: TransportChatID,
        after cursor: TransportCursor? = nil
    ) -> AsyncThrowingStream<EchoEvent, Error> {
        let inbound = transport.subscribe(chatID: chatID, after: cursor)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let filter = ControlMessageFilter(
                        controlChatID: chatID,
                        ledger: ledger
                    )
                    var lastCursor = cursor

                    for try await message in inbound {
                        let decision = try await filter.evaluate(message, after: lastCursor)
                        if let previous = lastCursor {
                            lastCursor = max(previous, message.cursor)
                        } else {
                            lastCursor = message.cursor
                        }
                        guard decision == .accept else {
                            continuation.yield(
                                EchoEvent(inbound: message, decision: decision, receipt: nil)
                            )
                            continue
                        }

                        let outbound = OutboundTransportMessage(text: reply(message.text))
                        try await ledger.begin(
                            requestID: outbound.requestID,
                            chatID: chatID,
                            text: outbound.text
                        )

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
                                    receipt: receipt
                                )
                            )
                        } catch let failure as TransportFailure where failure.retrySafe {
                            try await ledger.cancel(requestID: outbound.requestID)
                            throw failure
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
