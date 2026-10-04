import Foundation
import Observation
import PhoneContext
import PhoneSync

@MainActor
@Observable
final class AssistantViewModel {
    static let shared = AssistantViewModel()
    var sleepEnabled = UserDefaults.standard.bool(forKey: "phone.sleepEnabled")
    var busy = false
    var notice = ""
    var pendingPairing: PhonePairing?
    @ObservationIgnored private let phone = PhoneContextSource()
    @ObservationIgnored private var observing = false
    @ObservationIgnored private var lastCollected: Date?

    func activate() async {
        if sleepEnabled, PhoneUploadClient.shared.pairing != nil {
            await observeSleep()
            await sync()
        } else { await PhoneUploadClient.shared.retry() }
    }

    func receivePairing(_ url: URL) {
        do { pendingPairing = try PhonePairing.decode(url) }
        catch { notice = "Scan the pairing QR code displayed by your own Mac." }
    }

    func confirmPairing(_ pendingPairing: PhonePairing) async {
        do {
            try await PhoneUploadClient.shared.pair(pendingPairing)
            self.pendingPairing = nil
            lastCollected = nil
            await activate()
            if !sleepEnabled { try await PhoneUploadClient.shared.enqueue(sleepEnabled: false, sleep: []) }
        } catch { notice = "Could not save pairing. Scan the Mac code again." }
    }

    func enableSleep() async {
        guard !busy else { return }
        do {
            try await phone.requestSleepAccess()
            sleepEnabled = true
            UserDefaults.standard.set(true, forKey: "phone.sleepEnabled")
            await observeSleep()
            await sync(force: true)
        } catch { notice = "Sleep access is unavailable. You can still chat in Messages." }
    }

    func disableSleep() async {
        sleepEnabled = false
        UserDefaults.standard.set(false, forKey: "phone.sleepEnabled")
        await phone.stopSleepUpdates()
        observing = false; lastCollected = nil
        do { try await PhoneUploadClient.shared.enqueue(sleepEnabled: false, sleep: []) }
        catch { notice = "Sleep sharing stopped. Connect to the Mac to update its status." }
    }

    func disconnect() async {
        await phone.stopSleepUpdates()
        observing = false
        do { try await PhoneUploadClient.shared.disconnect() }
        catch { notice = "Could not remove pairing." }
    }

    func sync(force: Bool = false) async {
        guard !busy, PhoneUploadClient.shared.pairing != nil else { return }
        if !force, let lastCollected, Date().timeIntervalSince(lastCollected) < 900 {
            await PhoneUploadClient.shared.retry(); return
        }
        busy = true
        defer { busy = false }
        do {
            let items = sleepEnabled ? try await phone.sleepDigests() : []
            try await PhoneUploadClient.shared.enqueue(sleepEnabled: sleepEnabled, sleep: items)
            lastCollected = Date()
            if sleepEnabled, items.allSatisfy({ $0.recordedMinutes == nil }) {
                notice = "No readable sleep samples. This can mean missing data or denied read access; it does not mean zero sleep."
            }
        } catch { notice = "Could not collect phone context. Existing updates remain queued." }
    }

    private func observeSleep() async {
        guard !observing else { return }
        observing = true
        let background = await phone.startSleepUpdates { [weak self] in await self?.sync(force: true) }
        notice = background ? "Sleep changes can queue updates in the background." : "Sleep syncs when you open this app. Background delivery is not available with this installation."
    }
}
