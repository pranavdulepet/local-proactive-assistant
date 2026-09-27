import Testing
@testable import AssistantCore

struct PersonHandleTests {
    @Test
    func normalizesEmailPhoneAndSchemes() {
        #expect(PersonHandle.normalize(" MAILTO:Alex@Example.COM ") == "alex@example.com")
        #expect(PersonHandle.normalize("tel:+1 (415) 555-0123") == "+14155550123")
        #expect(PersonHandle.normalize("  ") == nil)
        #expect(PersonHandle.normalize(["A@EXAMPLE.COM", "a@example.com"]) == ["a@example.com"])
    }
}
