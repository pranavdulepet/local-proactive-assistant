import AppleModelAdapter
import Foundation
import LocalInference

@main
struct ModelWorker {
    static func main() async {
        // Installer/CI diagnostic only. This path is never exposed to a model session.
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--sandbox-check" {
            do {
                _ = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
                FileHandle.standardError.write(Data("Worker read a file outside its sandbox.\n".utf8))
                exit(1)
            } catch let error as CocoaError where error.code == .fileReadNoPermission {
                print("Sandbox denied access to the host probe file.")
                return
            } catch {
                FileHandle.standardError.write(Data("Sandbox probe failed for an unexpected reason.\n".utf8))
                exit(1)
            }
        }
        let response: ModelWireResponse
        do {
            var data = Data()
            while let chunk = try FileHandle.standardInput.read(upToCount: 4_096), !chunk.isEmpty {
                data.append(chunk)
                guard data.count <= 49_152 else { throw LocalModelFailure("Model request is too large.") }
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
            case .chat:
                guard let request = message.chatRequest else { throw LocalModelFailure("Missing conversation request.") }
                response = ModelWireResponse(chatReply: try await provider.chat(request))
            case .planContext:
                guard let request = message.contextPlanRequest else { throw LocalModelFailure("Missing context plan request.") }
                response = ModelWireResponse(contextPlan: try await provider.planContext(request))
            }
        } catch is ContextPlanFailure {
            response = ModelWireResponse(failure: "The local worker returned an invalid context plan.", failureKind: "contextPlan")
        } catch is ChatReplyFailure {
            response = ModelWireResponse(failure: "The local worker returned an unverified conversation reply.", failureKind: "chatReply")
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
