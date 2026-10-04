import Foundation

public struct PhoneSyncFailure: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public struct PhonePairing: Codable, Equatable, Sendable {
    public let deviceID: UUID
    public let name: String
    public let server: URL
    public let certificateSHA256: String
    public let token: String

    public init(deviceID: UUID, name: String, server: URL, certificateSHA256: String, token: String) {
        self.deviceID = deviceID; self.name = name; self.server = server
        self.certificateSHA256 = certificateSHA256; self.token = token
    }

    public func validate() throws {
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        guard server.scheme == "https", server.host != nil, server.user == nil, server.password == nil,
              server.query == nil, server.fragment == nil, server.path.isEmpty || server.path == "/",
              name.utf8.count <= 100,
              certificateSHA256.count == 64, token.count == 64,
              certificateSHA256.unicodeScalars.allSatisfy(hex.contains), token.unicodeScalars.allSatisfy(hex.contains) else {
            throw PhoneSyncFailure("Invalid Mac pairing code.")
        }
    }

    public var verificationCode: String { String(certificateSHA256.prefix(8)).uppercased() }

    public func qrURL() throws -> URL {
        try validate()
        let data = try JSONEncoder().encode(self)
        let encoded = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return URL(string: "localassistant://pair/\(encoded)")!
    }

    public static func decode(_ url: URL) throws -> PhonePairing {
        guard url.scheme == "localassistant", url.host == "pair", url.absoluteString.utf8.count <= 2048 else {
            throw PhoneSyncFailure("Scan the pairing code shown by your Mac.")
        }
        var encoded = String(url.path.dropFirst()).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded) else { throw PhoneSyncFailure("Invalid pairing code.") }
        let value = try JSONDecoder().decode(PhonePairing.self, from: data)
        try value.validate()
        return value
    }
}

public struct PhoneSleepDigest: Codable, Equatable, Sendable {
    public let windowHours: Int
    public let start: Date
    public let end: Date
    public let recordedMinutes: Double?
    public let sampleLimitReached: Bool

    public init(windowHours: Int, start: Date, end: Date, recordedMinutes: Double?, sampleLimitReached: Bool) {
        self.windowHours = windowHours; self.start = start; self.end = end
        self.recordedMinutes = recordedMinutes; self.sampleLimitReached = sampleLimitReached
    }
}

public struct PhoneSyncEnvelope: Codable, Equatable, Sendable {
    public static let maximumBytes = 8192
    public let schemaVersion: String
    public let deviceID: UUID
    public let sequence: Int64
    public let createdAt: Date
    public let sleepEnabled: Bool
    public let sleep: [PhoneSleepDigest]

    public init(deviceID: UUID, sequence: Int64, createdAt: Date = Date(), sleepEnabled: Bool, sleep: [PhoneSleepDigest]) {
        schemaVersion = "local-assistant.phone.v1"; self.deviceID = deviceID; self.sequence = sequence
        self.createdAt = createdAt; self.sleepEnabled = sleepEnabled; self.sleep = sleep
    }

    public func validate(now: Date = Date()) throws {
        guard schemaVersion == "local-assistant.phone.v1", sequence > 0,
              createdAt.timeIntervalSince(now) <= 300,
              sleep.count <= 2, Set(sleep.map(\.windowHours)).count == sleep.count,
              sleepEnabled || sleep.isEmpty else { throw PhoneSyncFailure("Invalid phone context envelope.") }
        for item in sleep {
            guard [24, 168].contains(item.windowHours), item.start < item.end,
                  abs(item.end.timeIntervalSince(createdAt)) < 1,
                  abs(item.end.timeIntervalSince(item.start) - Double(item.windowHours) * 3600) < 1 else {
                throw PhoneSyncFailure("Invalid sleep summary window.")
            }
            if let minutes = item.recordedMinutes {
                guard minutes.isFinite, minutes >= 0, minutes <= Double(item.windowHours) * 60 else {
                    throw PhoneSyncFailure("Invalid recorded sleep duration.")
                }
            }
        }
    }

    public func encode() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> PhoneSyncEnvelope {
        guard data.count <= maximumBytes else { throw PhoneSyncFailure("Phone context is too large.") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let value = try decoder.decode(Self.self, from: data)
        try value.validate()
        return value
    }
}
