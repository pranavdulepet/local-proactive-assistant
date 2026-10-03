import Foundation

public struct ModelWireRequest: Codable, Sendable {
    public enum Operation: String, Codable, Sendable { case availability, answer }
    public let operation: Operation
    public let request: EvidenceRequest?
    public init(operation: Operation, request: EvidenceRequest? = nil) {
        self.operation = operation
        self.request = request
    }
}

public struct ModelWireResponse: Codable, Sendable {
    public let availability: ModelAvailability?
    public let answer: GroundedAnswer?
    public let failure: String?
    public init(availability: ModelAvailability? = nil, answer: GroundedAnswer? = nil, failure: String? = nil) {
        self.availability = availability
        self.answer = answer
        self.failure = failure
    }
}
