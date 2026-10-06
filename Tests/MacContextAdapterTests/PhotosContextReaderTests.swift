import Foundation
import LocalInference
import Testing
@testable import MacContextAdapter

struct PhotosContextReaderTests {
    @Test func chatNeverRequestsPhotosPermissionAndDistinguishesDenial() async throws {
        for (access, kind) in [(PhotoAccess.notDetermined, MacContextFailureKind.permissionRequired),
                               (.denied, .permissionDenied), (.restricted, .permissionRestricted)] {
            let store = PhotoFixtureStore(access: access)
            let reader = PhotosContextReader(store: store, requestPermissions: false)
            do {
                _ = try await reader.read(ContextToolCall(tool: .photos))
                Issue.record("An unauthorized source returned readable data")
            } catch let failure as MacContextFailure { #expect(failure.kind == kind) }
            #expect(await store.requestCount() == 0)
            #expect(await store.readCount() == 0)
        }
    }

    @Test func explicitSetupCanGrantLimitedAccessWithoutClaimingACompleteLibrary() async throws {
        let item = PhotoItem(id: "asset-1", created: ISO8601DateFormatter().date(from: "2026-10-05T10:00:00Z"),
            media: "photo", width: 4032, height: 3024, duration: nil, favorite: true,
            latitude: 37.774929, longitude: -122.419416,
            albums: ["Trip", "Family", "Weekend", "Favorites", "Omitted"], moreAlbums: true)
        let store = PhotoFixtureStore(access: .notDetermined, granted: .limited,
            snapshot: PhotoSnapshot(items: [item], moreAvailable: true))
        let result = try await PhotosContextReader(store: store, requestPermissions: true).read(
            ContextToolCall(tool: .photos, query: "favorites", limit: 1))
        #expect(await store.requestCount() == 1)
        #expect(await store.readCount() == 1)
        #expect(result.records.count == 1)
        #expect(result.records[0].locator == "photos:asset-1")
        #expect(result.records[0].text.contains("37.8, -122.4"))
        #expect(!result.records[0].text.contains("37.774929"))
        #expect(!result.records[0].text.contains("Omitted"))
        #expect(result.coverage.contains { $0.contains("limited to the assets") })
        #expect(result.coverage.contains { $0.contains("More matching assets") })
        #expect(result.coverage.contains { $0.contains("No image/video bytes") && $0.contains("iCloud content was not downloaded") })
        try result.validate()
    }

    @Test func dayDatesUseTheMacTimezoneAndUnsupportedFiltersAreNotIgnored() async throws {
        let store = PhotoFixtureStore(access: .authorized)
        let reader = PhotosContextReader(store: store, requestPermissions: false)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        _ = try await reader.read(ContextToolCall(tool: .photos, query: "screenshots",
            from: "2026-10-05", to: "2026-10-06", limit: 2), calendar: calendar)
        let query = try #require(await store.lastQuery())
        #expect(query.filter == .screenshots)
        #expect(query.start == ISO8601DateFormatter().date(from: "2026-10-05T07:00:00Z"))
        #expect(query.end == ISO8601DateFormatter().date(from: "2026-10-06T07:00:00Z"))
        #expect(query.limit == 2)
        for call in [ContextToolCall(tool: .photos, query: "birthday album"),
                     ContextToolCall(tool: .photos, from: "2026-10-06", to: "2026-10-05"),
                     ContextToolCall(tool: .photos, from: "2026-02-30")] {
            await #expect(throws: MacContextFailure.self) { _ = try await reader.read(call) }
        }
        #expect(await store.readCount() == 1)
    }

    @Test func emptyMetadataDoesNotProveNoPhotosOrDeniedAccess() async throws {
        let result = try await PhotosContextReader(store: PhotoFixtureStore(access: .authorized), requestPermissions: false)
            .read(ContextToolCall(tool: .photos))
        #expect(result.records.isEmpty)
        #expect(result.coverage.contains { $0.contains("does not prove the library/account is empty") })
        #expect(!result.coverage.contains { $0.contains("denied") })
        try result.validate()
    }

    @Test func macSourcePreservesPermissionClassificationAndBoundedMetadata() async throws {
        let unused = ContextCommandRunner { _, _, _, _, _ in throw MacContextFailure("Process runner must not be used for Photos") }
        let source = MacContextSource(allowedRoots: [], runner: unused,
            photoStore: PhotoFixtureStore(access: .denied), requestPermissions: false)
        do {
            _ = try await source.execute(ContextToolCall(tool: .photos))
            Issue.record("Denied Photos source returned success")
        } catch let failure as MacContextFailure {
            #expect(failure.kind == .permissionDenied)
            #expect(failure.description.contains("Photos access is denied"))
        }
    }
}

private actor PhotoFixtureStore: PhotoStore {
    private var authorization: PhotoAccess
    private let granted: PhotoAccess
    private let snapshot: PhotoSnapshot
    private var requests = 0
    private var reads = 0
    private var query: PhotoQuery?
    init(access: PhotoAccess, granted: PhotoAccess = .authorized,
         snapshot: PhotoSnapshot = PhotoSnapshot(items: [], moreAvailable: false)) {
        authorization = access; self.granted = granted; self.snapshot = snapshot
    }
    func access() -> PhotoAccess { authorization }
    func requestAccess() -> PhotoAccess { requests += 1; authorization = granted; return granted }
    func read(_ query: PhotoQuery) -> PhotoSnapshot { reads += 1; self.query = query; return snapshot }
    func requestCount() -> Int { requests }
    func readCount() -> Int { reads }
    func lastQuery() -> PhotoQuery? { query }
}
