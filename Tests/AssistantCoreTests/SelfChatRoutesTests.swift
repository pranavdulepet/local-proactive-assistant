import Testing
@testable import AssistantCore

struct SelfChatRoutesTests {
    @Test func repliesPreferOneVerifiedPhoneRouteForBothAliases() {
        func chat(_ id: Int64, _ address: String) -> TransportChat {
            TransportChat(id: TransportChatID(rawValue: id), identifier: address, guid: "chat-\(id)",
                displayName: address, service: "iMessage", participants: [address], isGroup: false)
        }
        let email = chat(955, "me@example.com")
        let phone = chat(954, "+14155550123")
        #expect(SelfChatRoutes.replyRoute(primary: email, verified: [phone, email]).id == phone.id)
        #expect(SelfChatRoutes.replyRoute(primary: email, verified: [email]).id == email.id)
    }

    @Test
    func includesOnlyDirectOwnerAliasesAndThePairedRoute() {
        func chat(_ id: Int64, _ address: String, service: String = "iMessage",
                  group: Bool = false, participants: [String]? = nil) -> TransportChat {
            TransportChat(
                id: TransportChatID(rawValue: id), identifier: address,
                guid: "chat-\(id)", displayName: address, service: service,
                participants: participants ?? [address], isGroup: group
            )
        }
        let email = chat(955, "self@example.com")
        let phone = chat(954, "+14155550123")
        let other = chat(44, "friend@example.com")
        let group = chat(45, "+14155550123", group: true)
        let sms = chat(46, "+14155550123", service: "SMS")
        let routes = SelfChatRoutes.resolve(
            primary: email, available: [other, group, email, phone, sms],
            ownerHandles: ["SELF@example.com", "4155550123"]
        )
        #expect(routes.map(\.id.rawValue) == [954, 955])
    }

    @Test
    func missingMeCardStillKeepsOnlyCodePairedChat() {
        let primary = TransportChat(
            id: TransportChatID(rawValue: 7), identifier: "me@example.com",
            guid: "self", displayName: "Me", service: "iMessage",
            participants: [], isGroup: false
        )
        let other = TransportChat(
            id: TransportChatID(rawValue: 8), identifier: "other@example.com",
            guid: "other", displayName: "Other", service: "iMessage",
            participants: [], isGroup: false
        )
        #expect(SelfChatRoutes.resolve(
            primary: primary, available: [other, primary], ownerHandles: []
        ).map(\.id.rawValue) == [7])
    }
}
