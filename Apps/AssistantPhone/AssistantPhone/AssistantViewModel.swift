import AppleModelAdapter
import Foundation
import LocalInference
import Observation
import PhoneContext

@MainActor
@Observable
final class AssistantViewModel {
    enum ContextChoice: String, CaseIterable, Identifiable {
        case demo = "Demo", phone = "This phone", mac = "Mac snapshot"
        var id: String { rawValue }
    }

    var contextChoice: ContextChoice = .demo
    var question = ContextDocument.demo().question
    var contactName = ""
    var includeCalendar = false
    var includeContacts = false
    var includeSleep = false
    var modelDetail = "Checking the on-device model…"
    var answer = ""
    var notice = ""
    var busy = false
    var imported: EvidenceRequest?
    var evidence: EvidenceRequest?
    @ObservationIgnored private let provider = AppleSystemModelProvider()
    @ObservationIgnored private let phone = PhoneContextSource()
    @ObservationIgnored private var task: Task<Void, Never>?

    func checkModel() async {
        let state = await provider.availability()
        modelDetail = state.detail
    }

    func ask() {
        guard !busy else { return }
        busy = true
        answer = ""
        notice = ""
        task = Task {
            defer { busy = false; task = nil }
            do {
                let request: EvidenceRequest
                switch contextChoice {
                case .demo:
                    let demo = ContextDocument.demo()
                    request = EvidenceRequest(question: question, createdAt: demo.createdAt, records: demo.records, coverage: demo.coverage)
                case .phone:
                    request = try await phone.request(question: question, contactName: contactName, includeCalendar: includeCalendar, includeContacts: includeContacts, includeSleep: includeSleep)
                case .mac:
                    guard let imported else { throw LocalModelFailure("Import a Mac context document first.") }
                    request = EvidenceRequest(question: question, createdAt: imported.createdAt, records: imported.records,
                        coverage: imported.coverage + ["Explicit Mac snapshot; changes since export are not included."])
                }
                try request.validate()
                evidence = request
                let result = try await AnswerService(provider: provider).answer(request)
                try Task.checkCancellation()
                answer = result.text
                await checkModel()
            } catch is CancellationError {
                notice = "Answer cancelled."
            } catch {
                notice = "Could not assemble local context. Check the question length, selected permissions, and imported document."
            }
        }
    }

    func cancel() { task?.cancel() }

    func allowCalendar() async {
        do {
            includeCalendar = try await phone.requestCalendarAccess()
            notice = includeCalendar ? "Calendar access enabled for local questions." : "Calendar access was not granted."
        } catch { notice = "Calendar access is unavailable." }
    }

    func allowContacts() async {
        do {
            includeContacts = try await phone.requestContactsAccess()
            notice = includeContacts ? "Contacts access enabled. Select an exact person name." : "Contacts access was not granted."
        } catch { notice = "Contacts access is unavailable." }
    }

    func allowSleep() async {
        do {
            try await phone.requestSleepAccess()
            includeSleep = true
            notice = "Sleep read request finished. Only available samples contribute to a local summary; read denial is not disclosed by HealthKit."
        } catch { notice = "Health access is unavailable. Calendar, Contacts and imported context still work." }
    }

    func importContext(from url: URL) {
        guard !busy else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let data = try file.read(upToCount: ContextDocument.maximumBytes + 1) ?? Data()
            let context = try ContextDocument.decode(data)
            // Reserve one coverage line for the snapshot warning.
            guard context.coverage.count < 8 else { throw LocalModelFailure("No room for snapshot coverage.") }
            imported = context
            evidence = nil
            contextChoice = .mac
            question = context.question
            answer = ""
            notice = "Imported \(context.records.count) records. Context stays in this app's memory and is cleared when the app exits."
        } catch { notice = "Could not import this bounded context document. Export a fresh .lpa-context file from the Mac." }
    }

    func clearContext() {
        guard !busy else { return }
        imported = nil
        evidence = nil
        answer = ""
        contactName = ""
        includeCalendar = false
        includeContacts = false
        includeSleep = false
        contextChoice = .demo
        question = ContextDocument.demo().question
        notice = "In-memory context cleared. System permissions can be managed in Settings."
    }
}
