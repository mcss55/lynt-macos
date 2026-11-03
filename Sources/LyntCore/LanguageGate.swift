import Foundation
import NaturalLanguage

public enum LanguageDecision: String, Sendable {
    case english, nonEnglish, ambiguous
}

/// This classifier sees only locally extracted prose. Short fragments default to preservation.
public struct LanguageGate: Sendable {
    public init() {}

    public func classify(_ text: String, forceEnglish: Bool = false) -> LanguageDecision {
        let lowered = text.lowercased()
        let wordPattern = try! NSRegularExpression(pattern: #"[\p{L}]+(?:['’][\p{L}]+)?"#)
        let words = wordPattern.matches(in: lowered, range: NSRange(location: 0, length: lowered.utf16.count))
            .map { (lowered as NSString).substring(with: $0.range) }
        guard !words.isEmpty else { return .ambiguous }
        // NaturalLanguage currently commonly labels Azerbaijani as Turkish. Never rely on that
        // particular distinction, and retain explicit signals even for the short-text override.
        if text.range(of: "[əƏıİğĞşŞçÇöÖüÜ]", options: .regularExpression) != nil { return .nonEnglish }
        let nonEnglishWords: Set<String> = ["bu", "bir", "icin", "için", "neden", "nasil", "nasıl", "niye", "niyə", "hata", "xeta", "xəta", "verir", "olur", "lutfen", "lütfen", "bunu", "ve", "ile", "deyil", "ucun", "üçün"]
        if words.contains(where: nonEnglishWords.contains) { return .nonEnglish }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
        let english = hypotheses[.english] ?? 0
        if let dominant = recognizer.dominantLanguage, dominant != .english,
           (hypotheses[dominant] ?? 0) > 0.75 { return .nonEnglish }
        if forceEnglish {
            // The override is for ambiguous searches, not a translation bypass.
            return text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.allSatisfy { $0.isASCII }
                ? .english : (english >= 0.9 ? .english : .ambiguous)
        }
        guard words.count >= 3, words.joined().count >= 7 else { return .ambiguous }
        return english >= 0.85 ? .english : .ambiguous
    }
}
