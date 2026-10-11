import Foundation

/// Local runtimes can leak model-template delimiters even with thinking disabled.
/// Remove a leading analysis block, or the duplicated reply observed around a stray
/// closing delimiter. Keep ordinary quoted markup and other response text intact.
enum ModelOutput {
    static func reply(_ content: String) -> String {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("<think>") {
            guard let end = text.range(of: "</think>") else { return "" }
            return String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let end = text.range(of: #"(?m)^</think>\r?$"#, options: .regularExpression) {
            let before = String(text[..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let after = String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !after.isEmpty, before == after { return after }
        }
        return text
    }
}
