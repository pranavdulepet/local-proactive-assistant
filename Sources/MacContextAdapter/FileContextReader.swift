import CryptoKit
import Darwin
import Foundation
import LocalInference
import PDFKit

struct FileContextReader: Sendable {
    static let maximumFileBytes = 8_388_608
    static let maximumTextBytes = 131_072
    let roots: [URL]
    let runner: ContextCommandRunner

    init(roots: [URL], runner: ContextCommandRunner = .system) {
        var seen = Set<String>()
        self.roots = roots.prefix(8).map { $0.standardizedFileURL.resolvingSymlinksInPath() }
            .filter { $0.isFileURL && $0.path != "/" && seen.insert($0.path).inserted }
        self.runner = runner
    }

    func search(_ query: String) async throws -> ContextToolResult {
        let terms = Self.searchTerms(query)
        guard !terms.isEmpty else {
            return ContextToolResult(records: [], coverage: ["File search needs a descriptive filename or content term."])
        }
        let predicate = Self.spotlightPredicate(terms)
        var candidates = [String](), seen = Set<String>()
        var limited = false, unavailable = 0
        for root in roots {
            try Task.checkCancellation()
            do {
                let output = try await runner.run("/usr/bin/mdfind", ["-0", "-onlyin", root.path, predicate],
                                                  nil, 5, 131_072)
                limited = limited || output.truncated
                // A truncated last path is discarded rather than invented.
                let blocks = output.data.split(separator: 0, omittingEmptySubsequences: true)
                let complete = output.truncated && output.data.last != 0 ? blocks.dropLast() : blocks[...]
                for block in complete.prefix(64) {
                    guard let path = String(data: Data(block), encoding: .utf8),
                          seen.insert(path).inserted else { continue }
                    candidates.append(path)
                }
                if blocks.count > 64 { limited = true }
            } catch is CancellationError { throw CancellationError() }
            catch { unavailable += 1 }
        }
        // A new download can be absent from Spotlight. The fallback only searches names,
        // within a bounded walk; it does not recursively ingest the laptop.
        if candidates.isEmpty {
            let snapshot = try filenameCandidates(terms)
            candidates = snapshot.paths
            limited = limited || snapshot.limited
        }
        var records = [EvidenceRecord](), skipped = 0
        for path in candidates.prefix(64) {
            try Task.checkCancellation()
            do {
                let file = try openPermitted(path, maximumBytes: nil)
                defer { try? file.handle.close() }
                let metadata = "File: \(file.url.lastPathComponent)\nPath: \(file.url.path)\n"
                let content: String
                if Self.textExtensions.contains(file.url.pathExtension.lowercased()) {
                    let bytes = try file.handle.read(upToCount: Self.maximumTextBytes) ?? Data()
                    content = Self.matchingExcerpt(try Self.decodeText(bytes), terms: terms)
                } else {
                    content = "Content has not been read; request readFile for a supported text, PDF or document format."
                }
                records.append(Self.record(path: file.url.path, suffix: "search", timestamp: file.modified,
                                           text: metadata + "Excerpt: " + content))
                if records.count == 6 { limited = limited || candidates.count > 6; break }
            } catch is CancellationError { throw CancellationError() }
            catch { skipped += 1 }
        }
        var coverage = ["File search covers permitted document folders and local Spotlight results. Up to 6 excerpts are returned; Spotlight can omit unindexed or cloud-only files. Filename fallback scans at most 400 entries and does not search file contents."]
        if limited || skipped > 0 || unavailable > 0 {
            coverage.append("This file search was bounded or incomplete: \(skipped) candidates could not be read and \(unavailable) folder searches were unavailable. Absence does not prove a file is absent.")
        }
        return ContextToolResult(records: records, coverage: coverage)
    }

    func read(_ path: String) async throws -> ContextToolResult {
        let file = try openPermitted(path)
        defer { try? file.handle.close() }
        let ext = file.url.pathExtension.lowercased()
        if ext == "pdf" {
            let data = try file.handle.read(upToCount: Self.maximumFileBytes + 1) ?? Data()
            guard data.count <= Self.maximumFileBytes, let document = PDFDocument(data: data),
                  !document.isLocked else {
                throw MacContextFailure("This PDF is unavailable, locked, invalid or larger than 8 MiB.")
            }
            var records = [EvidenceRecord]()
            let pages = Self.samplePositions(count: document.pageCount, maximum: 8)
            for index in pages {
                try Task.checkCancellation()
                guard let text = document.page(at: index)?.string, !text.isEmpty else { continue }
                try Self.rejectPrivateKeyText(text)
                records.append(Self.record(path: file.url.path, suffix: "page-\(index + 1)",
                    timestamp: file.modified,
                    text: "Path: \(file.url.path)\nPage: \(index + 1)\n" + text))
            }
            return ContextToolResult(records: records, coverage: [EvidenceText.bounded("PDF read: \(file.url.path). Up to 8 page excerpts sampled across \(document.pageCount) pages, including beginning and end, each bounded to the evidence limit. Unsampled text and scanned images are not read or OCRed.", bytes: 512)])
        }
        let text: String
        let coverage: String
        if Self.textExtensions.contains(ext) {
            let data = try file.handle.read(upToCount: Self.maximumFileBytes + 1) ?? Data()
            guard data.count <= Self.maximumFileBytes else { throw MacContextFailure("The text file grew beyond the 8 MiB input limit.") }
            text = try Self.decodeText(data)
            coverage = "Text file read: at most 8 MiB decoded locally; up to 8 excerpts supplied. Large text is sampled across beginning, middle and end with character offsets; gaps are outside this answer's evidence."
        } else if Self.documentExtensions.contains(ext) {
            let data = try file.handle.read(upToCount: Self.maximumFileBytes + 1) ?? Data()
            guard data.count <= Self.maximumFileBytes else {
                throw MacContextFailure("This document exceeds the 8 MiB input limit.")
            }
            let output = try await runner.run("/usr/bin/textutil",
                ["-convert", "txt", "-stdout", "-format", ext, "-stdin"], data, 10, Self.maximumTextBytes)
            text = try Self.decodeText(output.data)
            coverage = "Document read: locally converted text, at most 128 KiB inspected and 8 excerpts sampled with character offsets. Formatting, images, attachments and gaps are not read.\(output.truncated ? " The conversion output was truncated; later text is unavailable." : "")"
        } else {
            throw MacContextFailure("This file type is not yet readable. Supported content: text/source files, PDF text, DOC/DOCX, RTF, ODT and HTML. File search can still return other file paths.")
        }
        let records = Self.textRecords(text, path: file.url.path, modified: file.modified)
        return ContextToolResult(records: records, coverage: [coverage])
    }

    private struct OpenedFile {
        let handle: FileHandle
        let url: URL
        let modified: Date
    }

    /// Every component is opened relative to an already-open permitted directory. A symlink
    /// replacement cannot redirect the final read into a keychain or another outside folder.
    private func openPermitted(_ path: String, maximumBytes: Int? = Self.maximumFileBytes) throws -> OpenedFile {
        guard path.hasPrefix("/"), !path.contains("\0"), !path.contains("\n"),
              !path.split(separator: "/").contains("..") else {
            throw MacContextFailure("File reads require a normal absolute document path.")
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.utf8.count <= 240,
              let root = roots.filter({ url.path.hasPrefix($0.path + "/") })
                .max(by: { $0.path.count < $1.path.count }) else {
            throw MacContextFailure("This path is outside the permitted document folders or exceeds the source-path limit. Choose an additional folder in local configuration to allow it.")
        }
        let components = url.path.dropFirst(root.path.count + 1).split(separator: "/").map(String.init)
        guard !components.isEmpty, components.allSatisfy(Self.allowedComponent) else {
            throw MacContextFailure("Hidden configuration, credential stores and private-key files are excluded from document reads.")
        }
        let cloud = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        if cloud?.isUbiquitousItem == true,
           cloud?.ubiquitousItemDownloadingStatus != .current && cloud?.ubiquitousItemDownloadingStatus != .downloaded {
            throw MacContextFailure("This iCloud document is not downloaded locally. Download it in Finder first; the assistant does not request cloud downloads.")
        }
        var directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw Self.accessFailure() }
        defer { close(directory) }
        for component in components.dropLast() {
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw Self.accessFailure() }
            close(directory)
            directory = next
        }
        let descriptor = openat(directory, components.last!, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw Self.accessFailure() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_size >= 0, maximumBytes.map({ info.st_size <= off_t($0) }) ?? true else {
            close(descriptor)
            throw MacContextFailure("Only regular documents of at most 8 MiB are readable; folders, sockets and device files are excluded.")
        }
        return OpenedFile(handle: FileHandle(fileDescriptor: descriptor, closeOnDealloc: true),
                          url: url, modified: Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec)))
    }

    private static func accessFailure() -> MacContextFailure {
        MacContextFailure("This document could not be opened. Check that it is downloaded locally and allow the host under macOS Privacy & Security > Files and Folders if prompted.")
    }

    static func allowedComponent(_ component: String) -> Bool {
        let lower = component.lowercased()
        if lower.hasPrefix(".") || lower.hasPrefix("secrets.") || lower.hasPrefix("credentials.") {
            return false
        }
        let names: Set<String> = ["credentials", "secrets", "keychains", "id_rsa", "id_ed25519", "id_ecdsa", "passwords.csv", "passwords.json"]
        let extensions: Set<String> = ["pem", "p12", "pfx", "jks", "keychain", "keychain-db", "mobileprovision"]
        return !names.contains(lower) && !extensions.contains((lower as NSString).pathExtension)
    }

    static func searchTerms(_ query: String) -> [String] {
        let normalized = query.replacingOccurrences(of: "[^\\p{L}\\p{N}_-]+", with: " ", options: .regularExpression)
        let stop: Set<String> = ["file", "files", "document", "documents", "folder", "find", "search", "read", "my", "the", "a", "about", "for", "in"]
        var seen = Set<String>()
        return normalized.split(separator: " ").map { String($0).lowercased() }
            .filter { !stop.contains($0) && seen.insert($0).inserted }
            .prefix(6).map { String($0.prefix(48)) }
    }

    static func spotlightPredicate(_ terms: [String]) -> String {
        // Terms contain only letters, numbers, '_' and '-'; no query operators or wildcards
        // from user/model text survive normalization.
        terms.map { "(kMDItemFSName ==[cd] \"*\($0)*\" || kMDItemTextContent ==[cd] \"*\($0)*\")" }
            .joined(separator: " && ")
    }

    private func filenameCandidates(_ terms: [String]) throws -> (paths: [String], limited: Bool) {
        var paths = [String](), scanned = 0
        let deadline = Date().addingTimeInterval(2)
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(at: root,
                includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in enumerator {
                try Task.checkCancellation()
                scanned += 1
                if scanned > 400 || Date() > deadline { return (paths, true) }
                let filename = url.lastPathComponent.lowercased()
                if terms.allSatisfy({ filename.contains($0) }) { paths.append(url.path) }
                if paths.count >= 64 { return (paths, true) }
            }
        }
        return (paths, false)
    }

    static func decodeText(_ data: Data) throws -> String {
        let text: String
        if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]) {
            guard let decoded = String(data: data, encoding: .utf16) else {
                throw MacContextFailure("This text encoding could not be decoded.")
            }
            text = decoded
        } else {
            guard !data.contains(0) else { throw MacContextFailure("This file contains binary data, rather than readable text.") }
            text = String(decoding: data, as: UTF8.self)
        }
        try rejectPrivateKeyText(text)
        return text
    }

    private static func rejectPrivateKeyText(_ text: String) throws {
        let upper = text.uppercased()
        guard !upper.contains("PRIVATE KEY-----"), !upper.contains("BEGIN OPENSSH PRIVATE KEY") else {
            throw MacContextFailure("Private-key material is excluded from document reads.")
        }
    }

    static func matchingExcerpt(_ text: String, terms: [String]) -> String {
        if let range = terms.compactMap({ text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) }).min(by: { $0.lowerBound < $1.lowerBound }) {
            let start = text.index(range.lowerBound, offsetBy: -80, limitedBy: text.startIndex) ?? text.startIndex
            return EvidenceText.bounded(String(text[start...]), bytes: 600)
        }
        return EvidenceText.bounded(text, bytes: 600)
    }

    static func record(path: String, suffix: String, timestamp: Date?, text: String) -> EvidenceRecord {
        let digest = SHA256.hash(data: Data((path + "#" + suffix).utf8)).map { String(format: "%02x", $0) }.joined()
        return EvidenceRecord(id: "file:" + digest, source: "files", timestamp: timestamp,
                              text: EvidenceText.bounded(text, bytes: 768), locator: path, trust: "unknownExternal")
    }

    static func samplePositions(count: Int, maximum: Int) -> [Int] {
        guard count > 0, maximum > 0 else { return [] }
        if maximum == 1 { return [0] }
        if count <= maximum { return Array(0..<count) }
        return (0..<maximum).map { Int(Double(count - 1) * Double($0) / Double(maximum - 1)) }
    }

    static func textRecords(_ text: String, path: String, modified: Date?) -> [EvidenceRecord] {
        guard !text.isEmpty else { return [] }
        // Reserve metadata space up front; the offset header is kept in every sample.
        let budget = 768 - path.utf8.count - 90
        guard budget > 0 else { return [] }
        var records = [EvidenceRecord]()
        if text.utf8.count <= budget * 8 {
            var remaining = text[...], offset = 0
            while !remaining.isEmpty && records.count < 8 {
                let part = EvidenceText.bounded(String(remaining), bytes: budget)
                guard !part.isEmpty else { break }
                records.append(record(path: path, suffix: "chars-\(offset)", timestamp: modified,
                    text: "Path: \(path)\nCharacters \(offset)..<\(offset + part.count):\n" + part))
                offset += part.count
                remaining = remaining.dropFirst(part.count)
            }
        } else {
            let count = text.count
            for position in samplePositions(count: count, maximum: 8) {
                let start: Int, part: String
                if position == count - 1 {
                    let tail = boundedSuffix(text, bytes: budget)
                    start = count - tail.count
                    part = tail
                } else {
                    start = position
                    let index = text.index(text.startIndex, offsetBy: start)
                    part = EvidenceText.bounded(String(text[index...]), bytes: budget)
                }
                records.append(record(path: path, suffix: "chars-\(start)", timestamp: modified,
                    text: "Path: \(path)\nCharacters \(start)..<\(start + part.count):\n" + part))
            }
        }
        return records
    }

    private static func boundedSuffix(_ text: String, bytes: Int) -> String {
        var characters = [Character](), count = 0
        for character in text.reversed() {
            let size = String(character).utf8.count
            if count + size > bytes { break }
            characters.append(character)
            count += size
        }
        return String(characters.reversed())
    }

    private static let textExtensions: Set<String> = ["txt", "text", "md", "markdown", "csv", "tsv", "json", "jsonl", "yaml", "yml", "xml", "html", "htm", "log", "swift", "py", "js", "ts", "tsx", "jsx", "sh", "rb", "go", "rs", "c", "h", "cpp", "hpp", "java", "css", "sql", "toml", "ini", "conf", "tex", "rst"]
    private static let documentExtensions: Set<String> = ["doc", "docx", "rtf", "odt", "wordml", "webarchive"]
}
