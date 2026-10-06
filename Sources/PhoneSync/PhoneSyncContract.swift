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

public enum PhoneActivityQuantity: String, Codable, CaseIterable, Hashable, Sendable {
    case steps, activeEnergy, exerciseTime
}

public struct PhoneActivityDigest: Codable, Equatable, Sendable {
    public let start: Date
    public let end: Date
    public let steps: Double?
    public let activeEnergyKilocalories: Double?
    public let exerciseMinutes: Double?
    public let failedQuantities: [PhoneActivityQuantity]

    public init(start: Date, end: Date, steps: Double?, activeEnergyKilocalories: Double?,
                exerciseMinutes: Double?, failedQuantities: [PhoneActivityQuantity] = []) {
        self.start = start; self.end = end; self.steps = steps
        self.activeEnergyKilocalories = activeEnergyKilocalories; self.exerciseMinutes = exerciseMinutes
        self.failedQuantities = failedQuantities
    }

    public var summary: String {
        let formatter = ISO8601DateFormatter()
        func value(_ number: Double?, unit: String) -> String {
            number.map { String(format: "%.0f", $0) + " " + unit } ?? "not readable"
        }
        return "Recorded phone activity, \(formatter.string(from: start)) through \(formatter.string(from: end)): steps \(value(steps, unit: "steps")); active energy \(value(activeEnergyKilocalories, unit: "kcal")); exercise time \(value(exerciseMinutes, unit: "minutes")). These are visible HealthKit totals, not a complete history or a diagnosis. Unreadable totals may mean missing data or denied read access; they do not mean zero."
    }

    public var coverage: String {
        let failed = failedQuantities.isEmpty ? "" : " Some quantity queries failed."
        return "Phone activity: visible HealthKit step, active energy and exercise totals for the phone's local day at collection time only. Raw samples stay on the phone. HealthKit does not disclose denied read access; unreadable is not zero.\(failed)"
    }

    fileprivate func validate(createdAt: Date) throws {
        guard start <= end, start.timeIntervalSince1970.isFinite, end.timeIntervalSince1970.isFinite,
              end.timeIntervalSince(start) <= 26 * 3600,
              end.timeIntervalSince(createdAt) <= 1, createdAt.timeIntervalSince(end) <= 300,
              failedQuantities.count <= 3, Set(failedQuantities).count == failedQuantities.count else {
            throw PhoneSyncFailure("Invalid activity summary window.")
        }
        for value in [steps, activeEnergyKilocalories, exerciseMinutes].compactMap({ $0 }) {
            guard value.isFinite, value >= 0 else { throw PhoneSyncFailure("Invalid activity total.") }
        }
        guard !failedQuantities.contains(.steps) || steps == nil,
              !failedQuantities.contains(.activeEnergy) || activeEnergyKilocalories == nil,
              !failedQuantities.contains(.exerciseTime) || exerciseMinutes == nil else {
            throw PhoneSyncFailure("A failed activity read cannot supply a total.")
        }
    }
}

public struct PhoneLocationDigest: Codable, Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public let horizontalAccuracyMeters: Double
    public let capturedAt: Date
    public let reducedAccuracy: Bool

    public init(latitude: Double, longitude: Double, horizontalAccuracyMeters: Double,
                capturedAt: Date, reducedAccuracy: Bool) {
        self.latitude = latitude; self.longitude = longitude
        self.horizontalAccuracyMeters = horizontalAccuracyMeters
        self.capturedAt = capturedAt; self.reducedAccuracy = reducedAccuracy
    }

    /// Longitude spacing expands toward the poles so rounding still removes about a kilometre of precision.
    public static func coarsened(latitude: Double, longitude: Double, horizontalAccuracyMeters: Double,
                                 capturedAt: Date, reducedAccuracy: Bool, now: Date = Date()) throws -> Self {
        guard latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude), (-180...180).contains(longitude),
              horizontalAccuracyMeters.isFinite, horizontalAccuracyMeters >= 0,
              capturedAt.timeIntervalSince(now) <= 60, now.timeIntervalSince(capturedAt) <= 900 else {
            throw PhoneSyncFailure("No recent readable location is available.")
        }
        let roundedLatitude = (latitude * 100).rounded() / 100
        let step = longitudeStep(at: roundedLatitude)
        let roundedLongitude = abs(roundedLatitude) == 90 ? 0 : min(180, max(-180, (longitude / step).rounded() * step))
        let accuracy = max(1000, ceil((horizontalAccuracyMeters + 800) / 1000) * 1000)
        let result = Self(latitude: roundedLatitude, longitude: roundedLongitude, horizontalAccuracyMeters: accuracy,
                          capturedAt: capturedAt, reducedAccuracy: reducedAccuracy)
        try result.validate(createdAt: now)
        return result
    }

    private static func longitudeStep(at latitude: Double) -> Double {
        0.01 / max(0.000001, cos(latitude * .pi / 180))
    }

    public var summary: String {
        let formatter = ISO8601DateFormatter()
        return "Coarse phone location captured \(formatter.string(from: capturedAt)): latitude \(String(format: "%.2f", latitude)), longitude \(String(format: "%.4f", longitude)). Coordinates were rounded to an approximately 1 km grid; reported uncertainty is at least \(String(format: "%.0f", horizontalAccuracyMeters)) metres. This is one snapshot, not live tracking, a street address or proof of presence.\(reducedAccuracy ? " iOS reduced accuracy was in use." : "")"
    }

    fileprivate func validate(createdAt: Date) throws {
        let step = Self.longitudeStep(at: latitude)
        let longitudeOnGrid = abs(longitude) == 180 || abs(longitude / step - (longitude / step).rounded()) < 0.000001
        guard latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude), (-180...180).contains(longitude),
              abs(latitude * 100 - (latitude * 100).rounded()) < 0.000001, longitudeOnGrid,
              abs(latitude) != 90 || longitude == 0,
              horizontalAccuracyMeters.isFinite, horizontalAccuracyMeters >= 1000, horizontalAccuracyMeters <= 1_000_000,
              capturedAt.timeIntervalSince1970.isFinite,
              capturedAt.timeIntervalSince(createdAt) <= 60, createdAt.timeIntervalSince(capturedAt) <= 900 else {
            throw PhoneSyncFailure("Invalid coarse location snapshot.")
        }
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
    /// Nil means a sleep-only client did not report this source; false revokes its shared snapshot.
    public let activityEnabled: Bool?
    public let activity: PhoneActivityDigest?
    public let locationEnabled: Bool?
    public let location: PhoneLocationDigest?

    public init(deviceID: UUID, sequence: Int64, createdAt: Date = Date(), sleepEnabled: Bool, sleep: [PhoneSleepDigest],
                activityEnabled: Bool? = nil, activity: PhoneActivityDigest? = nil,
                locationEnabled: Bool? = nil, location: PhoneLocationDigest? = nil) {
        schemaVersion = "local-assistant.phone.v1"; self.deviceID = deviceID; self.sequence = sequence
        self.createdAt = createdAt; self.sleepEnabled = sleepEnabled; self.sleep = sleep
        self.activityEnabled = activityEnabled; self.activity = activity
        self.locationEnabled = locationEnabled; self.location = location
    }

    public func validate(now: Date = Date()) throws {
        guard schemaVersion == "local-assistant.phone.v1", sequence > 0,
              createdAt.timeIntervalSince1970.isFinite, createdAt.timeIntervalSince(now) <= 300,
              sleep.count <= 2, Set(sleep.map(\.windowHours)).count == sleep.count,
              sleepEnabled || sleep.isEmpty,
              activityEnabled == true || activity == nil,
              locationEnabled == true || location == nil else { throw PhoneSyncFailure("Invalid phone context envelope.") }
        for item in sleep {
            guard [24, 168].contains(item.windowHours), item.start < item.end,
                  item.end.timeIntervalSince(createdAt) <= 1, createdAt.timeIntervalSince(item.end) <= 300,
                  abs(item.end.timeIntervalSince(item.start) - Double(item.windowHours) * 3600) < 1 else {
                throw PhoneSyncFailure("Invalid sleep summary window.")
            }
            if let minutes = item.recordedMinutes {
                guard minutes.isFinite, minutes >= 0, minutes <= Double(item.windowHours) * 60 else {
                    throw PhoneSyncFailure("Invalid recorded sleep duration.")
                }
            }
        }
        try activity?.validate(createdAt: createdAt)
        try location?.validate(createdAt: createdAt)
    }

    public func encode() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumBytes else { throw PhoneSyncFailure("Phone context is too large.") }
        return data
    }

    public static func decode(_ data: Data) throws -> PhoneSyncEnvelope {
        guard data.count <= maximumBytes else { throw PhoneSyncFailure("Phone context is too large.") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let value = try decoder.decode(Self.self, from: data)
        try value.validate()
        return value
    }
}
