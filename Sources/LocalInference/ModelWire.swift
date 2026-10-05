import Foundation

public struct ModelWireRequest: Codable, Sendable {
    public enum Operation: String, Codable, Sendable { case availability, answer, chat, planContext }
    public let operation: Operation
    public let request: EvidenceRequest?
    public let chatRequest: ChatRequest?
    public let contextPlanRequest: ContextPlanRequest?
    public init(operation: Operation, request: EvidenceRequest? = nil, chatRequest: ChatRequest? = nil,
                contextPlanRequest: ContextPlanRequest? = nil) {
        self.operation = operation
        self.request = request
        self.chatRequest = chatRequest
        self.contextPlanRequest = contextPlanRequest
    }
}

public struct ModelWireResponse: Codable, Sendable {
    public let availability: ModelAvailability?
    public let answer: GroundedAnswer?
    public let chatReply: ChatReply?
    public let contextPlan: ContextPlan?
    public let failure: String?
    public let failureKind: String?
    public init(availability: ModelAvailability? = nil, answer: GroundedAnswer? = nil, chatReply: ChatReply? = nil,
                contextPlan: ContextPlan? = nil, failure: String? = nil, failureKind: String? = nil) {
        self.availability = availability
        self.answer = answer
        self.chatReply = chatReply
        self.contextPlan = contextPlan
        self.failure = failure
        self.failureKind = failureKind
    }
}
