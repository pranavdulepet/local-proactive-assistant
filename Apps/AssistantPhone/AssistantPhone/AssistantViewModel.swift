import Foundation
import AppleModelAdapter
import LocalInference
import Observation
import PhoneContext
import PhoneSync

@MainActor
@Observable
final class AssistantViewModel {
    static let shared = AssistantViewModel()
    var sleepEnabled = UserDefaults.standard.bool(forKey: "phone.sleepEnabled")
    var activityEnabled = UserDefaults.standard.bool(forKey: "phone.activityEnabled")
    var locationEnabled = UserDefaults.standard.bool(forKey: "phone.locationEnabled")
    var phoneCalendarEnabled = UserDefaults.standard.bool(forKey: "phone.calendarEnabled")
    var busy = false
    var notice = ""
    var pendingPairing: PhonePairing?
    var phoneQuestion = ""
    var phoneContactName = ""
    var phoneAnswer = ""
    var phoneModelDetail = ""
    var phoneBusy = false
    var phoneModelChoice = PhoneModelChoice(rawValue: UserDefaults.standard.string(forKey: "phone.model") ?? "apple") ?? .apple
    var phoneModelReady = false
    var phoneModelInstalled = false
    var phoneDownloading = false
    var phoneImporting = false
    var phoneDownloadProgress = 0.0
    @ObservationIgnored private var phoneAssistant: PhoneLocalAssistant?
    @ObservationIgnored private var configuredPhoneModel: PhoneModelChoice?
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private let phone = PhoneContextSource()
    @ObservationIgnored private var observing = false
    @ObservationIgnored private var lastCollected: Date?
    @ObservationIgnored private var sharingRevision: UInt64 = 0
    @ObservationIgnored private var forcedSyncPending = false

    func checkPhoneModel() async {
        if configuredPhoneModel != phoneModelChoice || phoneAssistant == nil {
            do {
                let provider: any LocalModelProvider
                if phoneModelChoice == .apple { provider = AppleSystemModelProvider() }
                else {
                    provider = MLXPhoneModelProvider(directory: try await PhoneModelStore.shared.directory(for: phoneModelChoice),
                        name: phoneModelChoice.title)
                }
                phoneAssistant = PhoneLocalAssistant(source: phone, provider: provider)
                configuredPhoneModel = phoneModelChoice
            } catch { phoneModelReady = false; phoneModelDetail = String(describing: error); return }
        }
        guard let phoneAssistant else { return }
        phoneModelInstalled = await PhoneModelStore.shared.isInstalled(phoneModelChoice)
        let state = await phoneAssistant.availability()
        phoneModelReady = state.ready
        phoneModelDetail = state.detail
    }

    func selectPhoneModel(_ choice: PhoneModelChoice) async {
        guard !phoneBusy, !phoneDownloading else { return }
        phoneModelChoice = choice
        UserDefaults.standard.set(choice.rawValue, forKey: "phone.model")
        phoneAnswer = ""
        await checkPhoneModel()
    }

    func downloadPhoneModel() {
        guard !phoneDownloading, !phoneBusy, phoneModelChoice.repository != nil else { return }
        let choice = phoneModelChoice
        phoneDownloading = true; phoneDownloadProgress = 0
        downloadTask = Task { [weak self] in
            guard let self else { return }
            defer { self.phoneDownloading = false; self.downloadTask = nil }
            do {
                _ = try await PhoneModelStore.shared.install(choice) { fraction in
                    Task { @MainActor [weak self] in self?.phoneDownloadProgress = fraction }
                }
                self.notice = "Model weights saved on this iPhone. Replies use local files."
            } catch is CancellationError {
                self.notice = "Download cancelled. A complete model was not installed."
            } catch {
                self.notice = "Model download failed: \(EvidenceText.bounded(String(describing: error), bytes: 512))"
            }
            await self.checkPhoneModel()
        }
    }

    func cancelPhoneDownload() { downloadTask?.cancel() }

    func importPhoneModel(_ url: URL) async {
        guard !phoneBusy, !phoneDownloading else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        phoneDownloading = true; phoneImporting = true
        defer { phoneDownloading = false; phoneImporting = false }
        do {
            _ = try await PhoneModelStore.shared.importModel(from: url)
            phoneModelChoice = .imported
            UserDefaults.standard.set(PhoneModelChoice.imported.rawValue, forKey: "phone.model")
            configuredPhoneModel = nil
            phoneAnswer = ""
            await checkPhoneModel()
            notice = "Imported model files stay on this iPhone. The first reply loads the model."
        } catch { notice = "Model import failed: \(EvidenceText.bounded(String(describing: error), bytes: 512))" }
    }

    func removePhoneModel() async {
        guard phoneModelChoice != .apple, !phoneBusy, !phoneDownloading else { return }
        phoneAssistant = nil; configuredPhoneModel = nil
        do {
            try await PhoneModelStore.shared.remove(phoneModelChoice)
            notice = "Removed these phone model files."
            await checkPhoneModel()
        } catch { notice = "Could not remove the phone model: \(String(describing: error))" }
    }

    func newPhoneConversation() async {
        guard !phoneBusy else { return }
        phoneAssistant = nil; configuredPhoneModel = nil; phoneAnswer = ""
        await checkPhoneModel()
    }

    func askOnPhone() async {
        guard !phoneBusy, !phoneDownloading else { return }
        phoneBusy = true
        defer { phoneBusy = false }
        await checkPhoneModel()
        guard phoneModelReady, let phoneAssistant else { return }
        do {
            phoneAnswer = try await phoneAssistant.answer(phoneQuestion, contactName: phoneContactName,
                includeCalendar: phoneCalendarEnabled, includeSleep: sleepEnabled,
                includeActivity: activityEnabled, includeLocation: locationEnabled)
        } catch {
            phoneAnswer = "The phone model could not answer: \(EvidenceText.bounded(String(describing: error), bytes: 512))"
        }
    }

    func enablePhoneCalendar() async {
        do {
            let granted = try await phone.requestCalendarAccess()
            phoneCalendarEnabled = granted
            UserDefaults.standard.set(granted, forKey: "phone.calendarEnabled")
            notice = granted ? "Phone Calendar access enabled." : "Phone Calendar access is unavailable."
        } catch { notice = "Phone Calendar access is unavailable." }
    }

    func enablePhoneContacts() async {
        do {
            let granted = try await phone.requestContactsAccess()
            notice = granted ? "Phone Contacts access enabled." : "Phone Contacts access is unavailable."
        } catch { notice = "Phone Contacts access is unavailable." }
    }

    func activate() async {
        if sleepEnabled || activityEnabled || locationEnabled, PhoneUploadClient.shared.pairing != nil {
            if sleepEnabled { await observeSleep() }
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
            invalidateSharedContext()
            await activate()
            if !sleepEnabled && !activityEnabled && !locationEnabled { await sync(force: true) }
        } catch { notice = "Could not save pairing. Scan the Mac code again." }
    }

    func enableSleep() async {
        guard !busy else { return }
        do {
            try await phone.requestSleepAccess()
            sleepEnabled = true
            UserDefaults.standard.set(true, forKey: "phone.sleepEnabled")
            invalidateSharedContext()
            await observeSleep()
            await sync(force: true)
        } catch { notice = "Sleep access is unavailable. You can still chat in Messages." }
    }

    func disableSleep() async {
        sleepEnabled = false
        UserDefaults.standard.set(false, forKey: "phone.sleepEnabled")
        invalidateSharedContext()
        await phone.stopSleepUpdates()
        observing = false; lastCollected = nil
        await sync(force: true)
    }

    func enableActivity() async {
        guard !busy else { return }
        do {
            try await phone.requestActivityAccess()
            activityEnabled = true
            UserDefaults.standard.set(true, forKey: "phone.activityEnabled")
            invalidateSharedContext()
            notice = "Activity sharing enabled. Unreadable Health values remain unknown."
            await sync(force: true)
        } catch { notice = "Activity access is unavailable: \(String(describing: error))" }
    }

    func disableActivity() async {
        activityEnabled = false
        UserDefaults.standard.set(false, forKey: "phone.activityEnabled")
        invalidateSharedContext()
        await sync(force: true)
    }

    func enableLocation() async {
        guard !busy else { return }
        let granted = await phone.requestLocationAccess()
        guard granted else { notice = "Phone location is unavailable."; return }
        locationEnabled = true
        UserDefaults.standard.set(true, forKey: "phone.locationEnabled")
        invalidateSharedContext()
        notice = "Coarse location sharing enabled while this app is open."
        await sync(force: true)
    }

    func disableLocation() async {
        locationEnabled = false
        UserDefaults.standard.set(false, forKey: "phone.locationEnabled")
        invalidateSharedContext()
        await sync(force: true)
    }

    func disconnect() async {
        invalidateSharedContext()
        forcedSyncPending = false
        do { try await PhoneUploadClient.shared.disconnect() }
        catch { notice = "Could not remove pairing." }
        await phone.stopSleepUpdates()
        observing = false
    }

    func sync(force: Bool = false) async {
        guard let pairing = PhoneUploadClient.shared.pairing else { forcedSyncPending = false; return }
        guard !busy else {
            if force { forcedSyncPending = true }
            return
        }
        if !force, let lastCollected, Date().timeIntervalSince(lastCollected) < 900 {
            await PhoneUploadClient.shared.retry(); return
        }
        busy = true
        forcedSyncPending = false
        let revision = sharingRevision
        let collectSleep = sleepEnabled
        let collectActivity = activityEnabled
        let collectLocation = locationEnabled
        defer {
            busy = false
            if forcedSyncPending {
                forcedSyncPending = false
                Task { [weak self] in await self?.sync(force: true) }
            }
        }
        do {
            var failures: [String] = []
            var items: [PhoneSleepDigest] = []
            var activity: PhoneActivityDigest?
            var location: PhoneLocationDigest?
            if collectSleep {
                do { items = try await phone.sleepDigests() }
                catch is CancellationError { throw CancellationError() }
                catch { failures.append("sleep") }
            }
            if collectActivity {
                do { activity = try await phone.activityDigest() }
                catch is CancellationError { throw CancellationError() }
                catch { failures.append("activity") }
            }
            if collectLocation {
                do { location = try await phone.locationDigest() }
                catch is CancellationError { throw CancellationError() }
                catch { failures.append("coarse location") }
            }
            guard revision == sharingRevision, PhoneUploadClient.shared.pairing == pairing else {
                forcedSyncPending = PhoneUploadClient.shared.pairing != nil
                return
            }
            try await PhoneUploadClient.shared.enqueue(sleepEnabled: collectSleep, sleep: items,
                activityEnabled: collectActivity, activity: activity,
                locationEnabled: collectLocation, location: location)
            guard revision == sharingRevision, PhoneUploadClient.shared.pairing == pairing else {
                forcedSyncPending = PhoneUploadClient.shared.pairing != nil
                return
            }
            lastCollected = Date()
            if !failures.isEmpty { notice = "Could not read \(failures.joined(separator: ", ")). Other enabled summaries were queued." }
            else if sleepEnabled, items.allSatisfy({ $0.recordedMinutes == nil }) {
                notice = "No readable sleep samples. This can mean missing data or denied read access; it does not mean zero sleep."
            }
        } catch { notice = "Could not collect phone context. Existing updates remain queued." }
    }

    private func invalidateSharedContext() {
        sharingRevision &+= 1
        lastCollected = nil
        if busy { forcedSyncPending = true }
    }

    private func observeSleep() async {
        guard !observing else { return }
        observing = true
        let background = await phone.startSleepUpdates { [weak self] in await self?.sync(force: true) }
        notice = background ? "Sleep changes can queue updates in the background." : "Sleep syncs when you open this app. Background delivery is not available with this installation."
    }
}
