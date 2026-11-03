import Foundation

public enum SuggestionSafetyError: LocalizedError {
    case invalidSegments, staleDocument, overlappingEdits, invalidEdit
    public var errorDescription: String? {
        switch self {
        case .invalidSegments: "The provider returned missing, duplicate, or unknown segment IDs. No edits were applied."
        case .staleDocument: "The suggestions do not match the original text. Review it again."
        case .overlappingEdits: "Choose only one of the overlapping suggestions."
        case .invalidEdit: "An unsafe suggestion was rejected. No edits were applied."
        }
    }
}

public struct SuggestionValidator: Sendable {
    public init() {}
    public func validate(_ response: WritingReviewResponse, document: PreparedDocument, options: ReviewOptions) throws -> ValidationResult {
        let expectedIDs = Set(document.segments.map(\.id))
        guard expectedIDs.count == document.segments.count,
              response.segments.count == expectedIDs.count,
              Set(response.segments.map(\.id)) == expectedIDs else { throw SuggestionSafetyError.invalidSegments }
        let segments = Dictionary(uniqueKeysWithValues: document.segments.map { ($0.id, $0) })
        let allowed = Set(document.request(options: options).enabledCategories)
        var suggestions: [Suggestion] = []
        var rejected = 0
        var fingerprints = Set<String>()
        for result in response.segments {
            guard let segment = segments[result.id], exactUTF16(segment.range.substring(in: document.original), segment.text) else {
                throw SuggestionSafetyError.staleDocument
            }
            for proposal in result.suggestions {
                guard suggestions.filter({ $0.segmentID == result.id }).count < 8,
                      allowed.contains(proposal.category), !proposal.source.isEmpty,
                      !(proposal.category == .delivery && options.tone.target == .preserve),
                      proposal.source != proposal.replacement,
                      proposal.source.utf16.count <= 1000, proposal.replacement.utf16.count <= 1200,
                      proposal.replacement.utf16.count <= max(40, proposal.source.utf16.count * 2),
                      !proposal.explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      proposal.explanation.utf16.count <= 500,
                      !proposal.replacement.contains("\n"), !proposal.replacement.contains("\r"),
                      !proposal.replacement.contains("\u{0000}"),
                      LanguageGate().classify(proposal.replacement) != .nonEnglish,
                      !Self.hasTechnicalIntroduction(proposal.replacement) else { rejected += 1; continue }
                let source = segment.text as NSString
                let match = source.range(of: proposal.source, options: [.literal])
                guard match.location != NSNotFound else { rejected += 1; continue }
                let nextLocation = match.location + 1
                if nextLocation < source.length,
                   source.range(of: proposal.source, options: [.literal], range: NSRange(location: nextLocation, length: source.length - nextLocation)).location != NSNotFound {
                    rejected += 1; continue
                }
                let range = UTF16Range(location: segment.range.location + match.location, length: match.length)
                guard exactUTF16(range.substring(in: document.original), proposal.source),
                      Self.hasSafeWordBoundaries(match, in: source, source: proposal.source),
                      segment.range.contains(range),
                      !document.protectedSpans.contains(where: { $0.range.overlaps(range) }),
                      Range(range.nsRange, in: document.original) != nil else { rejected += 1; continue }
                let fingerprint = "\(result.id)|\(proposal.category.rawValue)|\(range.location)|\(range.length)|\(proposal.replacement)"
                guard fingerprints.insert(fingerprint).inserted else { rejected += 1; continue }
                suggestions.append(.init(id: "\(result.id)-\(range.location)-\(range.length)-\(proposal.category.rawValue)-\(suggestions.count)", segmentID: result.id,
                                         category: proposal.category, range: range, source: proposal.source,
                                         replacement: proposal.replacement, explanation: proposal.explanation))
            }
        }
        let tone: ToneAssessment?
        if options.tone.detect, allowed.contains(.delivery), let reported = response.toneAssessment,
           !reported.label.isEmpty, reported.label.utf16.count <= 80, reported.note.utf16.count <= 300 {
            tone = .init(label: "Estimated: \(reported.label)", note: "Subjective; may be inaccurate. \(reported.note)")
        } else { tone = nil }
        return .init(suggestions: suggestions.sorted { $0.range.location < $1.range.location }, rejectedCount: rejected, toneAssessment: tone)
    }

    private static func hasTechnicalIntroduction(_ replacement: String) -> Bool {
        // Disallow the model introducing identifiers, numeric facts, code, endpoints, and secrets.
        // Normal apostrophes and plain-prose punctuation remain allowed.
        !ProtectionEngine().protectedSpans(in: replacement).isEmpty
    }
    private static func hasSafeWordBoundaries(_ match: NSRange, in text: NSString, source: String) -> Bool {
        let word = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        let firstIsWord = source.unicodeScalars.first.map(word.contains) ?? false
        let lastIsWord = source.unicodeScalars.last.map(word.contains) ?? false
        if firstIsWord, match.location > 0 {
            let prefix = text.substring(with: NSRange(location: 0, length: match.location))
            if prefix.unicodeScalars.last.map(word.contains) == true { return false }
        }
        let end = match.location + match.length
        if lastIsWord, end < text.length {
            let suffix = text.substring(from: end)
            if suffix.unicodeScalars.first.map(word.contains) == true { return false }
        }
        return true
    }
}

public struct TextRecomposer: Sendable {
    public init() {}
    public func recompose(document: PreparedDocument, suggestions: [Suggestion], acceptedIDs: Set<String>) throws -> String {
        guard Set(suggestions.map(\.id)).count == suggestions.count,
              acceptedIDs.isSubset(of: Set(suggestions.map(\.id))) else { throw SuggestionSafetyError.invalidEdit }
        let accepted = suggestions.filter { acceptedIDs.contains($0.id) }.sorted { $0.range.location < $1.range.location }
        var previous: UTF16Range?
        for edit in accepted {
            guard edit.range.length > 0, exactUTF16(edit.range.substring(in: document.original), edit.source),
                  document.segments.contains(where: { $0.id == edit.segmentID && $0.range.contains(edit.range) && exactUTF16($0.range.substring(in: document.original), $0.text) }),
                  !document.protectedSpans.contains(where: { $0.range.overlaps(edit.range) }) else { throw SuggestionSafetyError.staleDocument }
            if let previous, previous.overlaps(edit.range) { throw SuggestionSafetyError.overlappingEdits }
            previous = edit.range
        }
        var composed = document.original
        for edit in accepted.reversed() {
            guard let range = Range(edit.range.nsRange, in: composed) else { throw SuggestionSafetyError.invalidEdit }
            composed.replaceSubrange(range, with: edit.replacement)
        }
        // Defense in depth: re-map every immutable protected interval through accepted length deltas.
        for protected in document.protectedSpans {
            let shift = accepted.filter { $0.range.upperBound <= protected.range.location }.reduce(0) { $0 + $1.replacement.utf16.count - $1.range.length }
            let finalRange = UTF16Range(location: protected.range.location + shift, length: protected.range.length)
            guard exactUTF16(finalRange.substring(in: composed), protected.range.substring(in: document.original)) else { throw SuggestionSafetyError.invalidEdit }
        }
        return composed
    }
}

/// Swift String equality permits canonical equivalence; snapshots and protected content do not.
private func exactUTF16(_ left: String?, _ right: String?) -> Bool {
    guard let left, let right else { return false }
    return left.utf16.elementsEqual(right.utf16)
}
