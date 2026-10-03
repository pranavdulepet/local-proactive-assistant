import AssistantCore
import Foundation

public struct ProactivityStatus: Sendable {
    public let paused: Bool
    public let lastGate: String
    public let checkedAt: Date?
    public let lastDelivery: String?
}

public struct ReminderReservation: Sendable {
    public let id: UUID
    public let commitmentID: String

    public var text: String {
        "An open commitment is due soon. Reply /why \(commitmentID) for evidence, "
            + "/done \(commitmentID) if finished, or /pause to stop reminders."
    }
}

/// The one M1 rule. Policy is deterministic; no source text reaches an unsolicited message.
public enum DueCommitmentRule {
    public static func gate(
        evidence: CommitmentEvidence,
        coverage: SourceCoverage?,
        currentObservationID: UUID?,
        now: Date,
        calendar: Calendar
    ) -> String? {
        let commitment = evidence.commitment
        let observation = evidence.observation
        guard commitment.status == .active else { return "completedOrSuperseded" }
        guard commitment.extractorID == DeterministicCommitmentExtractor.extractorID,
              commitment.schemaVersion == DeterministicCommitmentExtractor.schemaVersion,
              commitment.confidence == 1 else { return "unsupportedAssertion" }
        guard observation.source == .messages, observation.trust == .ownerAuthored,
              !observation.tombstone, observation.id == currentObservationID else {
            return "retractedEvidence"
        }
        guard let sentAt = observation.sourceTimestamp,
              (0...7 * 86_400).contains(now.timeIntervalSince(sentAt)) else {
            return "oldEvidence"
        }
        guard let coverage, coverage.status != .unavailable,
              (0...600).contains(now.timeIntervalSince(coverage.lastSuccessfulSync)) else {
            return "staleMessages"
        }
        let hour = calendar.component(.hour, from: now)
        guard hour >= 8 && hour < 22 else { return "quietHours" }
        guard (0...3 * 3_600).contains(commitment.dueAt.timeIntervalSince(now)) else {
            return "outsideDueWindow"
        }
        return nil
    }
}

public struct ProactiveReminderService: Sendable {
    private let store: ObservationStore
    private let transport: any MessageTransport
    private let ledger: OutboundLedger

    public init(
        store: ObservationStore,
        transport: any MessageTransport,
        ledger: OutboundLedger
    ) {
        self.store = store
        self.transport = transport
        self.ledger = ledger
    }

    /// Reserve before touching the transport. An interrupted/ambiguous send is never retried.
    public func tick(
        chatID: TransportChatID,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) async throws -> Bool {
        guard let reservation = try await store.reserveDueReminder(now: now, calendar: calendar) else {
            return false
        }
        do {
            try Task.checkCancellation()
            try await ledger.begin(
                requestID: reservation.id, chatID: chatID,
                text: reservation.text, sentAt: now
            )
            let receipt = try await transport.send(
                OutboundTransportMessage(requestID: reservation.id, text: reservation.text), to: chatID
            )
            try await ledger.confirm(requestID: reservation.id, messageGUID: receipt.messageGUID)
            try await store.finishReminder(
                id: reservation.id, outcome: "submitted", messageGUID: receipt.messageGUID
            )
            return true
        } catch {
            // Even a missing receipt can follow a successful external side effect.
            try await store.finishReminder(id: reservation.id, outcome: "unknown", messageGUID: nil)
            throw error
        }
    }
}
