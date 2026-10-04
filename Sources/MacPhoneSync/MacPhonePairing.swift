#if os(macOS)
import AppKit
import CoreImage
import CryptoKit
import Foundation
import PhoneSync
import ProcessSupport
import Security

public struct MacPhoneIdentity: Codable, Sendable {
    public let pairing: PhonePairing
    public let pkcs12: Data

    public static func load() throws -> Self? { try PairingKeychain.read(Self.self, account: "mac") }

    public static func create(host: String, port: UInt16 = 8765) async throws -> Self {
        guard let url = URL(string: "https://\(host):\(port)"), url.host == host else { throw PhoneSyncFailure("Use your Mac's local hostname or LAN address.") }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw PhoneSyncFailure("Could not create pairing credentials.") }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = directory.appendingPathComponent("key.pem").path
        let cert = directory.appendingPathComponent("cert.pem").path
        let p12 = directory.appendingPathComponent("identity.p12")
        let der = directory.appendingPathComponent("cert.der")
        _ = try await BoundedProcessRunner.run(executable: "/usr/bin/openssl", arguments: ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "3650", "-subj", "/CN=LocalProactiveAssistant", "-keyout", key, "-out", cert])
        _ = try await BoundedProcessRunner.run(executable: "/usr/bin/openssl", arguments: ["pkcs12", "-export", "-inkey", key, "-in", cert, "-out", p12.path, "-passout", "stdin"], standardInput: Data((token + "\n").utf8))
        _ = try await BoundedProcessRunner.run(executable: "/usr/bin/openssl", arguments: ["x509", "-in", cert, "-outform", "DER", "-out", der.path])
        let hash = SHA256.hash(data: try Data(contentsOf: der)).map { String(format: "%02x", $0) }.joined()
        let pairing = PhonePairing(deviceID: UUID(), name: String(Host.current().localizedName?.prefix(100) ?? "My Mac"), server: url, certificateSHA256: hash, token: token)
        try pairing.validate()
        let identity = Self(pairing: pairing, pkcs12: try Data(contentsOf: p12))
        try PairingKeychain.write(identity, account: "mac")
        return identity
    }

    public func securityIdentity() throws -> SecIdentity {
        var imported: CFArray?
        let status = SecPKCS12Import(pkcs12 as CFData, [kSecImportExportPassphrase as String: pairing.token] as CFDictionary, &imported)
        guard status == errSecSuccess, let items = imported as? [[String: Any]], let value = items.first?[kSecImportItemIdentity as String] else {
            throw PhoneSyncFailure("Could not load the local TLS identity.")
        }
        return value as! SecIdentity
    }

    @MainActor
    public func showQR(at url: URL) throws {
        let filter = CIFilter(name: "CIQRCodeGenerator")!
        filter.setValue(Data(try pairing.qrURL().absoluteString.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(image, from: image.extent),
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { throw PhoneSyncFailure("Could not show the pairing QR code.") }
        try png.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        NSWorkspace.shared.open(url)
    }
}
#endif
