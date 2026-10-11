import AssistantCore
import Foundation

/// Slow turns get a native indicator when available, otherwise one short acknowledgement.
actor ConversationProgress {
    private let transport: any MessageTransport
    private let ledger: OutboundLedger
    private let chatID: TransportChatID
    private let text: String
    private let delay: Duration
    private var task: Task<Void, Never>?
    private var typingActive = false

    init(transport: any MessageTransport, ledger: OutboundLedger, chatID: TransportChatID,
         text: String, delay: Duration) {
        self.transport = transport
        self.ledger = ledger
        self.chatID = chatID
        self.text = text
        self.delay = delay
    }

    func start() { task = Task { await self.run() } }

    func stop() async {
        guard let current = task else { return }
        task = nil
        current.cancel()
        // Drain any started acknowledgement before the final answer so it cannot arrive late.
        await current.value
        if typingActive {
            typingActive = false
            let transport = self.transport
            let chatID = self.chatID
            _ = await Task { await transport.setTyping(false, to: chatID) }.value
        }
    }

    private func run() async {
        do {
            try await Task.sleep(for: delay)
            typingActive = await transport.setTyping(true, to: chatID)
            try Task.checkCancellation()
            if typingActive {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(4))
                    // Refresh the native indicator during retrieval and generation.
                    if !(await transport.setTyping(true, to: chatID)) { break }
                }
                return
            }
            let outbound = OutboundTransportMessage(text: text, isProgress: true)
            try await ledger.begin(requestID: outbound.requestID, chatID: chatID, text: text)
            do {
                try Task.checkCancellation()
                let receipt = try await transport.send(outbound, to: chatID)
                try await ledger.confirm(requestID: outbound.requestID, messageGUID: receipt.messageGUID)
            } catch is CancellationError {
                // Cancellation can interrupt a send whose text already reached Messages.
                try? await ledger.markRecovered(requestID: outbound.requestID)
            } catch let failure as TransportFailure where failure.retrySafe {
                try? await ledger.cancel(requestID: outbound.requestID)
            } catch {
                try? await ledger.markRecovered(requestID: outbound.requestID)
            }
        } catch {
            // Feedback must never fail the owner's actual answer.
        }
    }
}
