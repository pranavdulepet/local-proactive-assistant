public enum ObservationSource: String, Codable, CaseIterable, Hashable, Sendable {
    case messages
    case calendar
    case contacts
    case mail
    case health
}
