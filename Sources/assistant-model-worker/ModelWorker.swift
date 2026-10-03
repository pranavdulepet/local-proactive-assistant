import AppleModelAdapter
import Foundation
import LocalInference

@main
struct ModelWorker {
    static func main() async {
        let response: ModelWireResponse
        do {
            var data = Data()
            while let chunk = try FileHandle.standardInput.read(upToCount: 4_096), !chunk.isEmpty {
                data.append(chunk)
                guard data.count <= 24_576 else { throw LocalModelFailure("Model request is too large.") }
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let message = try decoder.decode(ModelWireRequest.self, from: data)
            let provider = AppleSystemModelProvider()
            switch message.operation {
            case .availability:
                response = ModelWireResponse(availability: await provider.availability())
            case .answer:
                guard let request = message.request else { throw LocalModelFailure("Missing evidence request.") }
                response = ModelWireResponse(answer: try await provider.answer(request))
            }
        } catch {
            // Never echo prompts/source records into diagnostics.
            response = ModelWireResponse(failure: "The local worker could not produce a validated response. Check model-status and retry with a smaller question.")
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(response)
            try FileHandle.standardOutput.write(contentsOf: data)
        } catch {
            exit(1)
        }
    }
}
