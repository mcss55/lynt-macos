import Foundation

/// All public source offsets are UTF-16, matching macOS Accessibility. No normalization.
public struct UTF16Range: Codable, Hashable, Sendable {
    public var location: Int
    public var length: Int
    public init(location: Int, length: Int) { self.location = location; self.length = length }
    public var upperBound: Int { location + length }
    public var nsRange: NSRange { NSRange(location: location, length: length) }
    public func overlaps(_ other: Self) -> Bool { location < other.upperBound && other.location < upperBound }
    public func contains(_ other: Self) -> Bool { other.location >= location && other.upperBound <= upperBound }
    public func substring(in text: String) -> String? {
        guard location >= 0, length >= 0, location <= text.utf16.count,
              length <= text.utf16.count - location,
              let range = Range(nsRange, in: text) else { return nil }
        return String(text[range])
    }
}

public enum SuggestionCategory: String, Codable, CaseIterable, Sendable, Identifiable {
    case correctness, clarity, engagement, delivery
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .correctness: "Correctness"
        case .clarity: "Clarity"
        case .engagement: "Engagement"
        case .delivery: "Delivery & Tone"
        }
    }
}

public enum ToneTarget: String, Codable, CaseIterable, Sendable { case preserve, formal, confident, friendly, professional }
public enum ContextKind: String, Codable, CaseIterable, Sendable { case prompt, search, general }

public struct TonePreference: Codable, Hashable, Sendable {
    public var detect: Bool
    public var target: ToneTarget
    public init(detect: Bool = true, target: ToneTarget = .preserve) { self.detect = detect; self.target = target }
}

public struct ReviewOptions: Sendable {
    public var enabledCategories: Set<SuggestionCategory>
    public var tone: TonePreference
    public var contextKind: ContextKind
    public var forceEnglish: Bool
    public init(enabledCategories: Set<SuggestionCategory> = Set(SuggestionCategory.allCases),
                tone: TonePreference = .init(), contextKind: ContextKind = .prompt, forceEnglish: Bool = false) {
        self.enabledCategories = enabledCategories
        self.tone = tone
        self.contextKind = contextKind
        self.forceEnglish = forceEnglish
    }
}

public enum ProtectionReason: String, Codable, CaseIterable, Sendable {
    case codeBlock, markup, structuredData, technicalToken, secret, log, searchOperator, number, ambiguous
}

public struct ProtectedSpan: Codable, Hashable, Sendable {
    public var range: UTF16Range
    public var reasons: Set<ProtectionReason>
    public init(range: UTF16Range, reasons: Set<ProtectionReason>) { self.range = range; self.reasons = reasons }
}

public struct TextSegment: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var text: String
    public var range: UTF16Range
    public init(id: String, text: String, range: UTF16Range) { self.id = id; self.text = text; self.range = range }
}

public struct SkippedRegion: Codable, Hashable, Sendable {
    public var range: UTF16Range
    public var reason: String
    public init(range: UTF16Range, reason: String) { self.range = range; self.reason = reason }
}

public struct PreparedDocument: Sendable {
    public var original: String
    public var protectedSpans: [ProtectedSpan]
    public var segments: [TextSegment]
    public var skipped: [SkippedRegion]
    public init(original: String, protectedSpans: [ProtectedSpan], segments: [TextSegment], skipped: [SkippedRegion] = []) {
        self.original = original; self.protectedSpans = protectedSpans; self.segments = segments; self.skipped = skipped
    }
    public func request(options: ReviewOptions) -> WritingReviewRequest {
        let categories = options.contextKind == .search ? options.enabledCategories.intersection([.correctness]) : options.enabledCategories
        return WritingReviewRequest(enabledCategories: SuggestionCategory.allCases.filter { categories.contains($0) },
                                    tone: .init(detect: options.tone.detect && options.contextKind != .search && categories.contains(.delivery), target: options.tone.target),
                                    contextKind: options.contextKind, segments: segments.map { .init(id: $0.id, text: $0.text) })
    }
}

/// This is the only DTO allowed across the provider boundary; no original document or protected values.
public struct WritingReviewRequest: Codable, Sendable {
    public let task: String
    public var enabledCategories: [SuggestionCategory]
    public var tone: TonePreference
    public var contextKind: ContextKind
    public var segments: [ReviewSegment]
    public init(enabledCategories: [SuggestionCategory], tone: TonePreference, contextKind: ContextKind, segments: [ReviewSegment]) {
        self.task = "review_english_prose"; self.enabledCategories = enabledCategories
        self.tone = tone; self.contextKind = contextKind; self.segments = segments
    }
}

public struct ReviewSegment: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var text: String
    public init(id: String, text: String) { self.id = id; self.text = text }
}

public struct WritingReviewResponse: Codable, Sendable {
    public var segments: [SegmentReviewResponse]
    public var toneAssessment: ToneAssessment?
    public init(segments: [SegmentReviewResponse], toneAssessment: ToneAssessment? = nil) {
        self.segments = segments; self.toneAssessment = toneAssessment
    }
}

public struct SegmentReviewResponse: Codable, Sendable {
    public var id: String
    public var suggestions: [SuggestionProposal]
    public init(id: String, suggestions: [SuggestionProposal]) { self.id = id; self.suggestions = suggestions }
}

public struct SuggestionProposal: Codable, Hashable, Sendable {
    public var category: SuggestionCategory
    public var source: String
    public var replacement: String
    public var explanation: String
    public init(category: SuggestionCategory, source: String, replacement: String, explanation: String) {
        self.category = category; self.source = source; self.replacement = replacement; self.explanation = explanation
    }
}

public struct ToneAssessment: Codable, Hashable, Sendable {
    public var label: String
    public var note: String
    public init(label: String, note: String) { self.label = label; self.note = note }
}

public struct Suggestion: Hashable, Sendable, Identifiable {
    public var id: String
    public var segmentID: String
    public var category: SuggestionCategory
    public var range: UTF16Range
    public var source: String
    public var replacement: String
    public var explanation: String
    public init(id: String, segmentID: String, category: SuggestionCategory, range: UTF16Range,
                source: String, replacement: String, explanation: String) {
        self.id = id; self.segmentID = segmentID; self.category = category; self.range = range
        self.source = source; self.replacement = replacement; self.explanation = explanation
    }
}

public struct ValidationResult: Sendable {
    public var suggestions: [Suggestion]
    public var rejectedCount: Int
    public var toneAssessment: ToneAssessment?
    public init(suggestions: [Suggestion], rejectedCount: Int = 0, toneAssessment: ToneAssessment? = nil) {
        self.suggestions = suggestions; self.rejectedCount = rejectedCount; self.toneAssessment = toneAssessment
    }
}

public struct TokenUsage: Codable, Sendable {
    public var input: Int
    public var output: Int
    public init(input: Int = 0, output: Int = 0) { self.input = input; self.output = output }
    public var total: Int { input + output }
}

public struct ProviderReviewResult: Sendable {
    public var response: WritingReviewResponse
    public var usage: TokenUsage
    public var providerID: String
    public var model: String
    public var usedFallback: Bool
    public init(response: WritingReviewResponse, usage: TokenUsage = .init(), providerID: String, model: String, usedFallback: Bool = false) {
        self.response = response; self.usage = usage; self.providerID = providerID; self.model = model; self.usedFallback = usedFallback
    }
}

public protocol LLMProvider: Sendable {
    func review(_ request: WritingReviewRequest) async throws -> ProviderReviewResult
}
