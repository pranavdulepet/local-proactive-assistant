import Foundation

public enum PersonHandle {
    public static func normalize(_ rawValue: String) -> String? {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        let lowercased = value.lowercased()
        if lowercased.hasPrefix("mailto:") {
            value.removeFirst("mailto:".count)
        } else if lowercased.hasPrefix("tel:") {
            value.removeFirst("tel:".count)
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if value.contains("@") {
            return value.lowercased()
        }

        let phoneCharacters = CharacterSet(charactersIn: "+0123456789 ()-.\u{00A0}")
        if value.unicodeScalars.allSatisfy(phoneCharacters.contains) {
            let digits = value.filter(\.isNumber)
            guard !digits.isEmpty else { return nil }
            return value.hasPrefix("+") ? "+\(digits)" : digits
        }

        return value.lowercased()
    }

    public static func normalize(_ rawValues: [String]) -> [String] {
        Set(rawValues.compactMap(normalize)).sorted()
    }
}
