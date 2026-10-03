import Foundation

public enum ContextDocument {
    public static let maximumBytes = 24_576

    public static func decode(_ data: Data) throws -> EvidenceRequest {
        guard data.count <= maximumBytes else { throw LocalModelFailure("Context document is too large.") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let request = try decoder.decode(EvidenceRequest.self, from: data)
        try request.validate()
        return request
    }

    public static func encode(_ request: EvidenceRequest) throws -> Data {
        try request.validate()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(request)
        guard data.count <= maximumBytes else { throw LocalModelFailure("Context document is too large.") }
        return data
    }

    public static func demo(now: Date = Date()) -> EvidenceRequest {
        EvidenceRequest(question: "What is the demo project deadline?", createdAt: now, records: [
            EvidenceRecord(id: "demo1", source: "demo", timestamp: now, text: "The demo project deadline is Friday at 5 PM.", locator: "public demo fixture", trust: "ownerAuthored")
        ], coverage: ["Public demo data only; no personal sources have been read."])
    }
}
