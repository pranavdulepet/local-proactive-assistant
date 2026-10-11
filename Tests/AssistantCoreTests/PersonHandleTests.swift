import Testing
@testable import AssistantCore

struct PersonHandleTests {
    @Test
    func normalizesEmailPhoneAndSchemes() {
        #expect(PersonHandle.normalize(" MAILTO:Alex@example.invalid ") == "alex@example.invalid")
        #expect(PersonHandle.normalize("tel:+1 (415) 555-0123") == "+14155550123")
        #expect(PersonHandle.normalize("  ") == nil)
        #expect(PersonHandle.normalize(["A@example.invalid", "a@example.invalid"]) == ["a@example.invalid"])
    }
}
