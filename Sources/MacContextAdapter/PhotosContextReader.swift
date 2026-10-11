import CryptoKit
import Foundation
import LocalInference
import Photos

enum PhotoAccess: Equatable, Sendable { case notDetermined, denied, restricted, authorized, limited, unknown }

struct PhotoItem: Equatable, Sendable {
    let id: String
    let created: Date?
    let media: String
    let width: Int
    let height: Int
    let duration: Double?
    let favorite: Bool
    let latitude: Double?
    let longitude: Double?
    let albums: [String]
    let moreAlbums: Bool
}

struct PhotoSnapshot: Sendable {
    let items: [PhotoItem]
    let moreAvailable: Bool
}

enum PhotoFilter: String, Sendable { case photos, videos, screenshots, favorites }

struct PhotoQuery: Sendable {
    let filter: PhotoFilter?
    let start: Date?
    let end: Date?
    let limit: Int

    init(_ call: ContextToolCall, calendar: Calendar) throws {
        guard (1...8).contains(call.limit ?? 8) else { throw MacContextFailure("Photos metadata limit must be 1–8.") }
        if let text = call.query {
            guard let filter = PhotoFilter(rawValue: text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
                throw MacContextFailure("Photos query supports only photos, videos, screenshots or favorites. Omit query for recent visible assets; use from/to for dates. Album-name or image-content search is not enabled.")
            }
            self.filter = filter
        } else { filter = nil }
        start = try call.from.map { try Self.date($0, calendar: calendar) }
        end = try call.to.map { try Self.date($0, calendar: calendar) }
        if let start, let end, start >= end { throw MacContextFailure("Photos dates require from before the exclusive to boundary.") }
        limit = call.limit ?? 8
    }

    private static func date(_ text: String, calendar: Calendar) throws -> Date {
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: text) { return date }
        iso.formatOptions.insert(.withFractionalSeconds)
        if let date = iso.date(from: text) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard text.count == 10, let date = formatter.date(from: text), formatter.string(from: date) == text else {
            throw MacContextFailure("Photos dates must be ISO YYYY-MM-DD or ISO8601 timestamps with a timezone.")
        }
        return date
    }
}

protocol PhotoStore: Sendable {
    func access() async -> PhotoAccess
    func requestAccess() async throws -> PhotoAccess
    func read(_ query: PhotoQuery) async throws -> PhotoSnapshot
}

struct PhotosContextReader: Sendable {
    let store: any PhotoStore
    let requestPermissions: Bool

    func read(_ call: ContextToolCall, calendar: Calendar = .autoupdatingCurrent) async throws -> ContextToolResult {
        let query = try PhotoQuery(call, calendar: calendar)
        try Task.checkCancellation()
        var authorization = await store.access()
        if authorization == .notDetermined, requestPermissions {
            try Task.checkCancellation()
            authorization = try await store.requestAccess()
        }
        guard authorization == .authorized || authorization == .limited else { throw photoAccessFailure(authorization) }
        try Task.checkCancellation()
        let snapshot = try await store.read(query)
        try Task.checkCancellation()
        let formatter = ISO8601DateFormatter()
        let records = snapshot.items.prefix(query.limit).map { item in
            let digest = SHA256.hash(data: Data(item.id.utf8)).map { String(format: "%02x", $0) }.joined()
            var lines = ["Media: \(item.media)", "Created: \(item.created.map(formatter.string(from:)) ?? "unavailable")",
                         "Dimensions: \(item.width) × \(item.height)", "Favorite: \(item.favorite ? "yes" : "no")"]
            if let duration = item.duration, duration.isFinite { lines.append("Duration: \(String(format: "%.1f", duration)) seconds") }
            if let lat = item.latitude, let lon = item.longitude, lat.isFinite, lon.isFinite,
               (-90...90).contains(lat), (-180...180).contains(lon) {
                // Do not serialize precise GPS coordinates to the model.
                let coarseLat = (lat * 10).rounded() / 10, coarseLon = (lon * 10).rounded() / 10
                lines.append("Approximate coordinates (rounded to 0.1°): \(String(format: "%.1f", coarseLat)), \(String(format: "%.1f", coarseLon))")
            } else { lines.append("Location metadata: unavailable") }
            let albums = item.albums.prefix(4).map { EvidenceText.bounded($0, bytes: 80) }.joined(separator: "; ")
            lines.append("Albums: \(albums.isEmpty ? "none exposed" : albums)\(item.moreAlbums ? " (additional albums omitted)" : "")")
            return EvidenceRecord(id: "photo:" + digest, source: "photos", timestamp: item.created,
                text: EvidenceText.bounded(lines.joined(separator: "\n"), bytes: 768),
                locator: "photos:" + EvidenceText.bounded(item.id, bytes: 220), trust: "unknownExternal")
        }
        let range = "[\(query.start.map(formatter.string(from:)) ?? "earliest visible"), \(query.end.map(formatter.string(from:)) ?? "latest visible"))"
        let access = authorization == .limited ? "limited to the assets macOS exposes to this host" : "authorized for the host's visible library"
        let scope = "Photos: \(records.count) metadata records, newest creation date first, \(range), filter \(query.filter?.rawValue ?? "any media"), limit \(query.limit). Access was \(access) at read start.\(snapshot.moreAvailable ? " More matching assets exist beyond this sample." : " No further match was exposed in this bounded fetch; this does not prove the library/account is empty.")"
        return ContextToolResult(records: records, coverage: [EvidenceText.bounded(scope, bytes: 512),
            "Photos metadata only: dates, media type, dimensions, favorites, coarse coordinates and at most four exposed album titles. Hidden assets and nonexposed/sync gaps are outside coverage. No image/video bytes, OCR, face recognition, captions or pixel analysis were requested; iCloud content was not downloaded. Locators are PhotoKit identifiers, not exported file paths."])
    }
}

private func photoAccessFailure(_ status: PhotoAccess) -> MacContextFailure {
    switch status {
    case .notDetermined:
        MacContextFailure("Photos access has not been requested. Run local source setup on the Mac to choose access; no library data was read.", kind: .permissionRequired)
    case .denied:
        MacContextFailure("Photos access is denied. Change the host's access under macOS Privacy & Security > Photos if you want this source connected.", kind: .permissionDenied)
    case .restricted:
        MacContextFailure("Photos access is restricted by macOS or device management.", kind: .permissionRestricted)
    default:
        MacContextFailure("macOS returned an unsupported Photos authorization state; no library read was completed.", kind: .readFailed)
    }
}

/// Public PhotoKit metadata reads only. No image manager, resources, change requests
/// or content-editing calls are exposed to a planner.
actor NativePhotoStore: PhotoStore {
    func access() -> PhotoAccess { Self.status(PHPhotoLibrary.authorizationStatus(for: .readWrite)) }

    func requestAccess() async throws -> PhotoAccess {
        try Task.checkCancellation()
        guard (Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryUsageDescription") as? String)?.isEmpty == false else {
            throw MacContextFailure("The host is missing its Photos usage description. Update or rebuild the assistant; changing permissions will not fix this configuration.", kind: .configurationMissing)
        }
        let completion = ReadContinuation<PhotoAccess>()
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            completion.finish(.failure(MacContextFailure("Waiting for the Photos permission choice exceeded 60 seconds. The system prompt may still be open on the Mac.", kind: .timedOut)))
        }
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion.install(continuation)
                guard !Task.isCancelled else { completion.finish(.failure(CancellationError())); return }
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                    completion.finish(.success(Self.status(status)))
                }
            }
        } onCancel: { completion.finish(.failure(CancellationError())) }
    }

    func read(_ query: PhotoQuery) throws -> PhotoSnapshot {
        try Task.checkCancellation()
        let authorization = access()
        guard authorization == .authorized || authorization == .limited else { throw photoAccessFailure(authorization) }
        let options = PHFetchOptions()
        options.fetchLimit = query.limit + 1
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.includeHiddenAssets = false
        var predicates: [NSPredicate] = []
        if let start = query.start { predicates.append(NSPredicate(format: "creationDate >= %@", start as NSDate)) }
        if let end = query.end { predicates.append(NSPredicate(format: "creationDate < %@", end as NSDate)) }
        switch query.filter {
        case .photos: predicates.append(NSPredicate(format: "mediaType == %@", NSNumber(value: PHAssetMediaType.image.rawValue)))
        case .videos: predicates.append(NSPredicate(format: "mediaType == %@", NSNumber(value: PHAssetMediaType.video.rawValue)))
        case .screenshots:
            predicates.append(NSPredicate(format: "(mediaSubtypes & %@) != 0", NSNumber(value: PHAssetMediaSubtype.photoScreenshot.rawValue)))
        case .favorites: predicates.append(NSPredicate(format: "favorite == YES"))
        case nil: break
        }
        if !predicates.isEmpty { options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates) }
        let assets = PHAsset.fetchAssets(with: options)
        var items: [PhotoItem] = []
        for index in 0..<min(query.limit, assets.count) {
            try Task.checkCancellation()
            let asset = assets.object(at: index)
            let albumOptions = PHFetchOptions()
            albumOptions.fetchLimit = 5
            let albums = PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: albumOptions)
            var titles: [String] = []
            for albumIndex in 0..<min(4, albums.count) {
                if let title = albums.object(at: albumIndex).localizedTitle { titles.append(EvidenceText.bounded(title, bytes: 80)) }
            }
            let media: String
            switch asset.mediaType {
            case .image: media = "photo"
            case .video: media = "video"
            case .audio: media = "audio"
            default: media = "unknown"
            }
            let coordinate = asset.location?.coordinate
            items.append(PhotoItem(id: asset.localIdentifier, created: asset.creationDate,
                media: media, width: asset.pixelWidth, height: asset.pixelHeight,
                duration: asset.mediaType == .video || asset.mediaType == .audio ? asset.duration : nil,
                favorite: asset.isFavorite,
                latitude: coordinate.map { ($0.latitude * 10).rounded() / 10 },
                longitude: coordinate.map { ($0.longitude * 10).rounded() / 10 },
                albums: titles, moreAlbums: albums.count > 4))
        }
        try Task.checkCancellation()
        return PhotoSnapshot(items: items, moreAvailable: assets.count > query.limit)
    }

    private nonisolated static func status(_ authorization: PHAuthorizationStatus) -> PhotoAccess {
        switch authorization {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        case .authorized: .authorized
        case .limited: .limited
        @unknown default: .unknown
        }
    }
}
