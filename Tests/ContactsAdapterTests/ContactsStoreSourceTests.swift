import Contacts
import Foundation
import Testing
@testable import ContactsAdapter

struct ContactsStoreSourceTests {
    @Test func stalledMeCardReadTimesOutWithoutWaitingForTheSystemCall() async throws {
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        do {
            _ = try await SelfHandleRead.run(timeout: .milliseconds(20)) {
                gate.wait()
                return ["fixture@example.test"]
            }
            Issue.record("Stalled read unexpectedly completed")
        } catch {
            #expect(String(describing: error).contains("lookup exceeded"))
        }
    }

    @Test func completedMeCardReadReturnsItsActualHandles() async throws {
        #expect(try await SelfHandleRead.run { ["fixture@example.test"] } == ["fixture@example.test"])
    }

    @Test
    func normalizesNamesAndHandlesDeterministically() {
        let contact = CNMutableContact()
        contact.givenName = "  Alex "
        contact.familyName = " Rivera  "
        contact.organizationName = " Example Labs "
        contact.jobTitle = " Engineer "
        contact.phoneNumbers = [
            CNLabeledValue(
                label: CNLabelPhoneNumberMobile,
                value: CNPhoneNumber(stringValue: "+1 (415) 555-0123")
            ),
            CNLabeledValue(
                label: CNLabelPhoneNumberMain,
                value: CNPhoneNumber(stringValue: "+1 415 555 0123")
            ),
        ]
        contact.emailAddresses = [
            CNLabeledValue(label: CNLabelWork, value: " Alex@Example.COM " as NSString),
            CNLabeledValue(label: CNLabelHome, value: "alex@example.com" as NSString),
        ]

        let record = ContactsStoreSource.record(contact)

        #expect(record.displayName == "Alex Rivera")
        #expect(record.givenName == "Alex")
        #expect(record.familyName == "Rivera")
        #expect(record.organizationName == "Example Labs")
        #expect(record.jobTitle == "Engineer")
        #expect(record.phoneNumbers == ["+14155550123"])
        #expect(record.emailAddresses == ["alex@example.com"])
    }

    @Test
    func phoneNormalizationPreservesOnlyAnOptionalLeadingPlusAndDigits() {
        #expect(ContactsStoreSource.normalizedPhoneNumber(" (212) 555-0199 ") == "2125550199")
        #expect(ContactsStoreSource.normalizedPhoneNumber(" +44 20 7946 0958 ") == "+442079460958")
        #expect(ContactsStoreSource.normalizedPhoneNumber(" -- ") == nil)
    }
}
