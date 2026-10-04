import Foundation

/// A control route must be a direct iMessage chat addressed to a verified owner handle.
/// The code-paired primary route is included even if Contacts has no Me card.
public enum SelfChatRoutes {
    public static func resolve(
        primary: TransportChat,
        available: [TransportChat],
        ownerHandles: Set<String>
    ) -> [TransportChat] {
        let handles = Set(ownerHandles.compactMap(canonical))
        let eligible = available.filter { chat in
            guard !chat.isGroup, chat.service == "iMessage" else { return false }
            if chat.id == primary.id { return true }
            let identifier = canonical(chat.identifier)
            return identifier.map(handles.contains) == true
        }
        return eligible.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    private static func canonical(_ raw: String) -> String? {
        guard let handle = PersonHandle.normalize(raw) else { return nil }
        if !handle.contains("@") {
            let digits = handle.filter(\\.isNumber)
            if digits.count == 10 { return "+1" + digits }
            if digits.count == 11 && digits.hasPrefix("1") { return "+" + digits }
        }
        return handle
    }
}
