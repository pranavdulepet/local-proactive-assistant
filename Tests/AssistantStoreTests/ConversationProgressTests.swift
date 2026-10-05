import AssistantCore
import Foundation
import Testing
@testable import AssistantStore

struct ConversationProgressTests {
    @Test func fastTurnsDoNotSendAnAcknowledgement() async throws {
        let transport = ProgressTransport(nativeTyping: false)
        let progress = ConversationProgress(transport: transport, ledger: try OutboundLedger(), chatID: TransportChatID(rawValue: 954), text: "Working…", delay: .seconds(2))
        await progress.start()
        await progress.stop()
        #expect(await transport.messages().isEmpty)
    }

    @Test func nativeTypingStopsWithoutAddingAMessage() async throws {
        let transport = ProgressTransport(nativeTyping: true)
        let chat = TransportChatID(rawValue: 955)
        let progress = ConversationProgress(transport: transport, ledger: try OutboundLedger(), chatID: chat, text: "Working…", delay: .milliseconds(1))
        await progress.start()
        await transport.waitForTyping()
        await progress.stop()
        let events = await transport.typingEvents()
        #expect(events.first?.0 == true)
        #expect(events.last?.0 == false)
        #expect(events.allSatisfy { $0.1 == chat })
        #expect(await transport.messages().isEmpty)
    }

    @Test func fallbackIsSentOnceAndRecordedForEchoSuppression() async throws {
        let transport = ProgressTransport(nativeTyping: false, uncertain: true)
        let ledger = try OutboundLedger()
        let chat = TransportChatID(rawValue: 954)
        let progress = ConversationProgress(transport: transport, ledger: ledger, chatID: chat, text: "Working…", delay: .milliseconds(1))
        await progress.start()
        await transport.waitForMessage()
        await progress.stop()
        let messages = await transport.messages()
        #expect(messages.count == 1)
        #expect(messages[0].0.isProgress)
        #expect(messages[0].1 == chat)
        #expect(try await ledger.contains(text: "Working…", chatID: chat, messageDate: Date()))
    }
}

private actor ProgressTransport: MessageTransport {
    let nativeTyping: Bool
    let uncertain: Bool
    var sent: [(OutboundTransportMessage, TransportChatID)] = []
    var typing: [(Bool, TransportChatID)] = []
    var typingWaiter: CheckedContinuation<Void, Never>?
    var messageWaiter: CheckedContinuation<Void, Never>?
    init(nativeTyping: Bool, uncertain: Bool = false) { self.nativeTyping = nativeTyping; self.uncertain = uncertain }
    func probe() -> TransportHealth { TransportHealth(ready: true, detail: "fixture") }
    func chats() -> [TransportChat] { [] }
    nonisolated func subscribe(chatID: TransportChatID, after cursor: TransportCursor?) -> AsyncThrowingStream<InboundTransportMessage, Error> { AsyncThrowingStream { $0.finish() } }
    func setTyping(_ state: Bool, to chatID: TransportChatID) -> Bool {
        typing.append((state, chatID))
        typingWaiter?.resume(); typingWaiter = nil
        return nativeTyping
    }
    func send(_ message: OutboundTransportMessage, to chatID: TransportChatID) throws -> SendReceipt {
        sent.append((message, chatID))
        messageWaiter?.resume(); messageWaiter = nil
        if uncertain { throw TransportFailure("Outcome unknown") }
        return SendReceipt(requestID: message.requestID, messageGUID: "fixture", rowID: 1, transport: "fixture")
    }
    func messages() -> [(OutboundTransportMessage, TransportChatID)] { sent }
    func typingEvents() -> [(Bool, TransportChatID)] { typing }
    func waitForTyping() async {
        if !typing.isEmpty { return }
        await withCheckedContinuation { typingWaiter = $0 }
    }
    func waitForMessage() async {
        if !sent.isEmpty { return }
        await withCheckedContinuation { messageWaiter = $0 }
    }
}
