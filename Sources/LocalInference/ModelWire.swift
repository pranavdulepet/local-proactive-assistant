import Foundation

public struct ModelWireRequest: Codable, Sendable {
    public enum Operation: String, Codable, Sendable { case availability, answer, chat }
    public let operation: Operation
    public let request: EvidenceRequest?
    public let chatRequest: ChatRequest?
    public init(operation: Operation, request: EvidenceRequest? = nil, chatRequest: ChatRequest? = nil) {
        self.operation = operation
        self.request = request
        self.chatRequest = chatRequest
    }
}

public struct ModelWireResponse: Codable, Sendable {
    public let availability: ModelAvailability?
    public let answer: GroundedAnswer?
    public let chatReply: ChatReply?
    public let failure: String?
    public init(availability: ModelAvailability? = nil, answer: GroundedAnswer? = nil, chatReply: ChatReply? = nil, failure: String? = nil) {
        self.availability = availability
        self.answer = answer
        self.chatReply = chatReply
        self.failure = failure
    }
}
