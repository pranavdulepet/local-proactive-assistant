import Foundation
import Security

public enum PairingKeychain {
    private static let service = "org.localproactiveassistant.phone-sync"

    public static func read<T: Decodable>(_ type: T.Type, account: String) throws -> T? {
        var query = attributes(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw PhoneSyncFailure("Could not read paired-device credentials from Keychain.") }
        return try JSONDecoder().decode(type, from: data)
    }

    public static func write<T: Encodable>(_ value: T, account: String) throws {
        let data = try JSONEncoder().encode(value)
        let query = attributes(account)
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw PhoneSyncFailure("Could not update pairing credentials.") }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw PhoneSyncFailure("Could not save pairing credentials.") }
    }

    public static func remove(account: String) throws {
        let status = SecItemDelete(attributes(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw PhoneSyncFailure("Could not remove pairing credentials.") }
    }

    private static func attributes(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}

public actor PhoneUploadQueue {
    public let directory: URL

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    public func enqueue(pairing: PhonePairing, sleepEnabled: Bool, sleep: [PhoneSleepDigest],
                        activityEnabled: Bool? = nil, activity: PhoneActivityDigest? = nil,
                        locationEnabled: Bool? = nil, location: PhoneLocationDigest? = nil) throws -> URL {
        let files = try pending()
        guard files.count < 128 else { throw PhoneSyncFailure("Phone context is waiting for your Mac. Connect before collecting more updates.") }
        let counterURL = directory.appendingPathComponent("sequence")
        let saved = (try? String(contentsOf: counterURL, encoding: .utf8)).flatMap { Int64($0) } ?? 0
        let highest = files.compactMap { Int64($0.deletingPathExtension().lastPathComponent) }.max() ?? 0
        let previous = max(saved, highest)
        guard previous < Int64.max else { throw PhoneSyncFailure("Phone sync sequence is exhausted. Pair with your Mac again.") }
        let sequence = previous + 1
        let envelope = PhoneSyncEnvelope(deviceID: pairing.deviceID, sequence: sequence, sleepEnabled: sleepEnabled, sleep: sleep,
            activityEnabled: activityEnabled, activity: activity, locationEnabled: locationEnabled, location: location)
        let path = directory.appendingPathComponent(String(format: "%020lld.json", sequence))
        #if os(iOS)
        try envelope.encode().write(to: path, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try envelope.encode().write(to: path, options: .atomic)
        #endif
        try String(sequence).write(to: counterURL, atomically: true, encoding: .utf8)
        return path
    }

    public func pending() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public func acknowledge(_ sequence: Int64) throws {
        let counterURL = directory.appendingPathComponent("sequence")
        let previous = (try? String(contentsOf: counterURL, encoding: .utf8)).flatMap { Int64($0) } ?? 0
        if sequence > previous { try String(sequence).write(to: counterURL, atomically: true, encoding: .utf8) }
        for file in try pending() where (Int64(file.deletingPathExtension().lastPathComponent) ?? Int64.max) <= sequence {
            try FileManager.default.removeItem(at: file)
        }
    }

    public func reset() throws {
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            try FileManager.default.removeItem(at: file)
        }
    }
}
