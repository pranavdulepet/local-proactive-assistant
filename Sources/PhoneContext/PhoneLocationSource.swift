#if os(iOS)
@preconcurrency import CoreLocation
import Foundation
import PhoneSync
import UIKit

@MainActor
public final class PhoneLocationSource: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var accessContinuation: CheckedContinuation<Bool, Never>?
    private var locationContinuation: CheckedContinuation<PhoneLocationDigest, any Error>?
    private var accessDeadline: Task<Void, Never>?
    private var locationDeadline: Task<Void, Never>?
    private var requestDate: Date?

    public override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        manager.distanceFilter = kCLDistanceFilterNone
    }

    /// Call only in response to the owner's location opt-in. It never requests Always or precise authorization.
    public func requestAccess() async -> Bool {
        guard UIApplication.shared.applicationState == .active, CLLocationManager.locationServicesEnabled() else { return false }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: return true
        case .denied, .restricted: return false
        case .notDetermined: break
        @unknown default: return false
        }
        guard accessContinuation == nil else { return false }
        return await withTaskCancellationHandler {
            if Task.isCancelled { return false }
            return await withCheckedContinuation { continuation in
                accessContinuation = continuation
                accessDeadline = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(120)) } catch { return }
                    self?.finishAccess(false)
                }
                manager.requestWhenInUseAuthorization()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finishAccess(false) }
        }
    }

    public func digest(now: Date = Date()) async throws -> PhoneLocationDigest {
        try Task.checkCancellation()
        guard UIApplication.shared.applicationState == .active else { throw PhoneSyncFailure("Open the phone companion to capture a new coarse location.") }
        guard CLLocationManager.locationServicesEnabled() else { throw PhoneSyncFailure("Location services are disabled on this phone.") }
        guard manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways else {
            throw PhoneSyncFailure("Location access is not granted. Enable coarse location in the phone companion first.")
        }
        guard locationContinuation == nil else { throw PhoneSyncFailure("A coarse location request is already in progress.") }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                locationContinuation = continuation
                requestDate = now
                locationDeadline = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(12)) } catch { return }
                    self?.finishLocation(.failure(PhoneSyncFailure("A recent coarse location was not available within 12 seconds.")))
                }
                manager.desiredAccuracy = manager.accuracyAuthorization == .reducedAccuracy ? kCLLocationAccuracyReduced : kCLLocationAccuracyKilometer
                manager.requestLocation()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finishLocation(.failure(CancellationError())) }
        }
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: finishAccess(true)
        case .denied, .restricted:
            finishAccess(false)
            finishLocation(.failure(PhoneSyncFailure("Location access is denied or restricted.")))
        case .notDetermined: break
        @unknown default: finishAccess(false)
        }
    }

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard locationContinuation != nil else { return }
        guard let location = locations.filter({ $0.horizontalAccuracy >= 0 }).max(by: { $0.timestamp < $1.timestamp }) else {
            finishLocation(.failure(PhoneSyncFailure("No recent readable location is available."))); return
        }
        do {
            let snapshot = try PhoneLocationDigest.coarsened(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                horizontalAccuracyMeters: location.horizontalAccuracy, capturedAt: location.timestamp,
                reducedAccuracy: manager.accuracyAuthorization == .reducedAccuracy, now: requestDate ?? Date())
            finishLocation(.success(snapshot))
        } catch { finishLocation(.failure(error)) }
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        finishLocation(.failure(PhoneSyncFailure("Core Location could not provide a recent coarse snapshot.")))
    }

    private func finishAccess(_ granted: Bool) {
        accessDeadline?.cancel(); accessDeadline = nil
        let continuation = accessContinuation; accessContinuation = nil
        continuation?.resume(returning: granted)
    }

    private func finishLocation(_ result: Result<PhoneLocationDigest, any Error>) {
        manager.stopUpdatingLocation()
        locationDeadline?.cancel(); locationDeadline = nil
        let continuation = locationContinuation; locationContinuation = nil
        requestDate = nil
        continuation?.resume(with: result)
    }
}
#endif
