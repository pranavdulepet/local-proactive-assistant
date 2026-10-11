import AssistantCore
import Contacts
import Foundation

public actor ContactsStoreSource: ContactSource {
    private let contactStore: CNContactStore

    public init() {
        contactStore = CNContactStore()
    }

    public func authorizationStatus() -> ContactAuthorizationStatus {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        return switch status {
        case .notDetermined:
            .notDetermined
        case .restricted:
            .restricted
        case .denied:
            .denied
        case .authorized:
            .authorized
        @unknown default:
            status.rawValue == 4 ? .limited : .unknown
        }
    }

    public func requestAccess() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            contactStore.requestAccess(for: .contacts) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    /// Addresses explicitly listed on the user's Contacts Me card.
    public func selfHandles() async throws -> Set<String> {
        try await SelfHandleRead.run {
            #if os(macOS)
            let keys = [CNContactPhoneNumbersKey, CNContactEmailAddressesKey] as [CNKeyDescriptor]
            let me = try CNContactStore().unifiedMeContactWithKeys(toFetch: keys)
            let phones = me.phoneNumbers.compactMap {
                Self.normalizedPhoneNumber($0.value.stringValue)
            }
            let emails = me.emailAddresses.compactMap {
                Self.normalizedEmailAddress($0.value as String)
            }
            return Set(phones + emails)
            #else
            return []
            #endif
        }
    }

    public func contacts() throws -> [ContactRecord] {
        let keys = [
            CNContactIdentifierKey,
            CNContactNamePrefixKey,
            CNContactGivenNameKey,
            CNContactMiddleNameKey,
            CNContactFamilyNameKey,
            CNContactNameSuffixKey,
            CNContactNicknameKey,
            CNContactOrganizationNameKey,
            CNContactDepartmentNameKey,
            CNContactJobTitleKey,
            CNContactPhoneNumbersKey,
            CNContactEmailAddressesKey,
        ] as [CNKeyDescriptor]
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.unifyResults = true
        request.mutableObjects = false
        request.sortOrder = .none

        let collector = ContactCollector()
        try contactStore.enumerateContacts(with: request) { contact, _ in
            collector.records.append(Self.record(contact))
        }
        return collector.records.sorted { $0.externalID < $1.externalID }
    }

    static func record(_ contact: CNContact) -> ContactRecord {
        let namePrefix = value(contact.namePrefix)
        let givenName = value(contact.givenName)
        let middleName = value(contact.middleName)
        let familyName = value(contact.familyName)
        let nameSuffix = value(contact.nameSuffix)
        let nickname = value(contact.nickname)
        let organizationName = value(contact.organizationName)
        let departmentName = value(contact.departmentName)
        let jobTitle = value(contact.jobTitle)
        let phoneNumbers = Set(contact.phoneNumbers.compactMap {
            normalizedPhoneNumber($0.value.stringValue)
        }).sorted()
        let emailAddresses = Set(contact.emailAddresses.compactMap {
            normalizedEmailAddress($0.value as String)
        }).sorted()
        let name = [namePrefix, givenName, middleName, familyName, nameSuffix]
            .compactMap { $0 }
            .joined(separator: " ")
        let displayName = [
            value(name),
            nickname,
            organizationName,
            emailAddresses.first,
            phoneNumbers.first,
        ].compactMap { $0 }.first ?? "Unnamed contact"

        return ContactRecord(
            externalID: contact.identifier,
            displayName: displayName,
            namePrefix: namePrefix,
            givenName: givenName,
            middleName: middleName,
            familyName: familyName,
            nameSuffix: nameSuffix,
            nickname: nickname,
            organizationName: organizationName,
            departmentName: departmentName,
            jobTitle: jobTitle,
            phoneNumbers: phoneNumbers,
            emailAddresses: emailAddresses
        )
    }

    static func normalizedPhoneNumber(_ rawValue: String) -> String? {
        guard let normalized = PersonHandle.normalize(rawValue),
              !normalized.contains("@") else { return nil }
        return normalized
    }

    static func normalizedEmailAddress(_ rawValue: String) -> String? {
        PersonHandle.normalize(rawValue)
    }

    private static func value(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private final class ContactCollector: @unchecked Sendable {
    var records: [ContactRecord] = []
}

/// Contacts may block inside system authorization even with a visible grant.
/// A detached read deadline lets startup retain its already verified self-chat.
enum SelfHandleRead {
    static func run(timeout: Duration = .seconds(5),
                    read: @escaping @Sendable () throws -> Set<String>) async throws -> Set<String> {
        let completion = SelfHandleCompletion()
        let deadline = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            completion.finish(.failure(SelfHandleTimeout()))
        }
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion.install(continuation)
                DispatchQueue.global(qos: .utility).async {
                    completion.finish(Result { try read() })
                }
            }
        } onCancel: {
            completion.finish(.failure(CancellationError()))
        }
    }
}

private struct SelfHandleTimeout: Error, CustomStringConvertible {
    var description: String { "Contacts Me-card lookup exceeded 5 seconds; using verified self-chat routes." }
}

private final class SelfHandleCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Set<String>, Error>?
    private var result: Result<Set<String>, Error>?

    func install(_ continuation: CheckedContinuation<Set<String>, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func finish(_ result: Result<Set<String>, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
