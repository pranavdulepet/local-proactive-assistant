import Foundation

/// A control route must be a direct iMessage chat addressed to a verified owner handle.
/// The code-paired primary route is included even if Contacts has no Me card.
public enum SelfChatRoutes {
    public static func resolve(
        primary: TransportChat,
        available: [TransportChat],
        ownerHandles: Set<String>
    ) -> [TransportChat] {
        let handles = Set(ownerHandles.compactMap(PersonHandle.normalize))
        let eligible = available.filter { chat in
            guard !chat.isGroup, chat.service == "iMessage" else { return false }
            if chat.id == primary.id { return true }
            let participants = Set(chat.participants.compactMap(PersonHandle.normalize))
            let identifier = PersonHandle.normalize(chat.identifier)
            return (participants.isEmpty || (participants.count == 1 && participants.first == identifier))
                && identifier.map(handles.contains) == true
        }
        return eligible.sorted { $0.id.rawValue < $1.id.rawValue }
    }
}
