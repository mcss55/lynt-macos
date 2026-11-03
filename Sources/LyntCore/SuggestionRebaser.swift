import Foundation

public struct RebasedSuggestions: Sendable {
    public let document: PreparedDocument
    public let validation: ValidationResult
}

/// Reuses remaining, already validated proposals after one explicit accepted edit.
/// Protection, language eligibility and exact anchors are recomputed locally; no model call is made.
public struct SuggestionRebaser: Sendable {
    public init() {}

    public func rebase(document: PreparedDocument, suggestions: [Suggestion], appliedID: String,
                       options: ReviewOptions) throws -> RebasedSuggestions {
        guard let applied = suggestions.first(where: { $0.id == appliedID }) else {
            throw SuggestionSafetyError.invalidEdit
        }
        let output = try TextRecomposer().recompose(document: document, suggestions: suggestions, acceptedIDs: [appliedID])
        let updated = ProtectionEngine().prepare(output, options: options)
        let delta = applied.replacement.utf16.count - applied.range.length
        var proposals: [String: [SuggestionProposal]] = [:]
        for suggestion in suggestions where suggestion.id != appliedID && !suggestion.range.overlaps(applied.range) {
            let offset = suggestion.range.location >= applied.range.upperBound ? delta : 0
            let shifted = UTF16Range(location: suggestion.range.location + offset, length: suggestion.range.length)
            guard let source = shifted.substring(in: output), source.utf16.elementsEqual(suggestion.source.utf16),
                  let segment = updated.segments.first(where: { $0.range.contains(shifted) }),
                  !updated.protectedSpans.contains(where: { $0.range.overlaps(shifted) }) else { continue }
            proposals[segment.id, default: []].append(.init(category: suggestion.category,
                                                           source: suggestion.source,
                                                           replacement: suggestion.replacement,
                                                           explanation: suggestion.explanation))
        }
        let response = WritingReviewResponse(segments: updated.segments.map {
            SegmentReviewResponse(id: $0.id, suggestions: proposals[$0.id] ?? [])
        })
        let validation = try SuggestionValidator().validate(response, document: updated, options: options)
        return RebasedSuggestions(document: updated, validation: validation)
    }
}
