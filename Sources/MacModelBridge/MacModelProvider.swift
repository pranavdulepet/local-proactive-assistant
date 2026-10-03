import Foundation
import LocalInference
import ProcessSupport
import Security

/// The host supplies only JSON evidence to a separately signed, sandboxed worker.
public actor MacModelProvider: LocalModelProvider {
    public nonisolated let modelID = "apple-system"
    private let executable: URL
    private var generating = false

    public init(executable: URL = MacModelProvider.installedExecutable) {
        self.executable = executable
    }

    public static var installedExecutable: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalProactiveAssistant/Models/LocalAssistantModel.app/Contents/MacOS/assistant-model-worker")
    }

    public func availability() async -> ModelAvailability {
        do {
            let response = try await exchange(ModelWireRequest(operation: .availability), timeout: 15)
            guard let state = response.availability else { throw LocalModelFailure("Missing worker availability.") }
            return state
        } catch {
            return ModelAvailability(ready: false, detail: "Signed model worker unavailable. Run ./scripts/setup-local-model.sh with Xcode 26+, then check model-status.")
        }
    }

    public func answer(_ request: EvidenceRequest) async throws -> GroundedAnswer {
        try request.validate()
        guard !generating else { throw LocalModelFailure("A local answer is already in progress.") }
        generating = true
        defer { generating = false }
        let response = try await exchange(ModelWireRequest(operation: .answer, request: request), timeout: 90)
        guard let answer = response.answer else { throw LocalModelFailure(response.failure ?? "Missing worker answer.") }
        try answer.validate(for: request)
        return answer
    }

    private func exchange(_ request: ModelWireRequest, timeout: TimeInterval) async throws -> ModelWireResponse {
        try Self.verifySandboxedSignature(at: executable)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let input = try encoder.encode(request)
        let output = try await BoundedProcessRunner.run(
            executable: executable.path, arguments: [], standardInput: input, timeout: timeout
        )
        guard output.count <= 24_576 else { throw LocalModelFailure("Oversized worker response.") }
        return try JSONDecoder().decode(ModelWireResponse.self, from: output)
    }

    private static func verifySandboxedSignature(at url: URL) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else {
            throw LocalModelFailure("The worker is missing or its signature is invalid.")
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              entitlements["com.apple.security.app-sandbox"] as? Bool == true,
              Set(entitlements.keys) == ["com.apple.security.app-sandbox"] else {
            throw LocalModelFailure("The worker must be sandboxed without network, personal-data or automation entitlements.")
        }
    }
}
