import Foundation

struct HostProfile: Equatable, Sendable {
    let provider: String
    let model: String
    let endpoint: String

    var label: String { provider == "apple" ? "Apple on-device model" : model }

    static func load(from url: URL) throws -> HostProfile {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              (values.fileSize ?? 4097) <= 4096,
              let text = String(data: try Data(contentsOf: url), encoding: .utf8) else {
            throw HostFailure("The saved model settings could not be read. Choose a model with the guided starter.")
        }
        let lines = text.components(separatedBy: "\n")
        guard lines.count == 5, lines[0] == "1", lines[4].isEmpty else {
            throw HostFailure("The saved model settings are invalid. Choose a model with the guided starter.")
        }
        let profile = HostProfile(provider: lines[1], model: lines[2], endpoint: lines[3])
        switch profile.provider {
        case "apple":
            guard profile.model.isEmpty, profile.endpoint.isEmpty else { throw HostFailure("Invalid Apple model settings.") }
        case "ollama":
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:/-")
            guard !profile.model.isEmpty, profile.model.count <= 200,
                  profile.model.unicodeScalars.allSatisfy(allowed.contains),
                  (profile.model.first?.isLetter == true || profile.model.first?.isNumber == true),
                  !profile.model.lowercased().contains(":cloud"), !profile.model.lowercased().contains("-cloud"),
                  profile.endpoint.isEmpty else { throw HostFailure("Choose a local Ollama model with the guided starter.") }
        case "local":
            guard !profile.model.isEmpty, profile.model.count <= 200,
                  !profile.model.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  !profile.model.lowercased().contains(":cloud"), !profile.model.lowercased().contains("-cloud"),
                  let parts = URLComponents(string: profile.endpoint), parts.scheme == "http",
                  ["127.0.0.1", "::1", "[::1]"].contains(parts.host ?? ""),
                  let port = parts.port, (1...65535).contains(port),
                  parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
                  ["/v1", "/v1/"].contains(parts.path) else {
                throw HostFailure("The selected local server must use a literal loopback /v1 endpoint.")
            }
        default: throw HostFailure("Choose a local model with the guided starter before opening this app.")
        }
        return profile
    }

    var arguments: [String] {
        switch provider {
        case "apple": return ["--model", "apple"]
        case "ollama": return ["--model", "ollama", "--model-url", "http://127.0.0.1:11435", "--model-name", model]
        default: return ["--model", "local", "--model-url", endpoint, "--model-name", model]
        }
    }
}

struct HostFailure: Error, CustomStringConvertible, Sendable {
    let description: String
    init(_ description: String) { self.description = description }
}

struct SourceObservation: Codable, Identifiable, Sendable {
    let tool: String
    let ready: Bool
    let checkedAt: Date
    let detail: String
    var id: String { tool }
    var name: String {
        switch tool {
        case "mailInbox": "Mail"
        case "notes": "Notes"
        case "reminders": "Reminders"
        case "searchFiles", "readFile": "Documents"
        case "searchIndex": "Personal index"
        case "deviceInfo": "Mac information"
        case "photos": "Photos"
        default: tool
        }
    }
}

struct RestartBudget: Sendable {
    private(set) var attempts = 0
    mutating func nextDelay(wasReady: Bool, exitStatus: Int32, intentional: Bool) -> Double? {
        guard wasReady, exitStatus != 0, !intentional, attempts < 3 else { return nil }
        let delay = [2.0, 5.0, 15.0][attempts]
        attempts += 1
        return delay
    }
    mutating func reset() { attempts = 0 }
}
