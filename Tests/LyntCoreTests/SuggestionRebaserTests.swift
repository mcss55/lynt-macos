import XCTest
@testable import LyntCore

final class SuggestionRebaserTests: XCTestCase {
    private func validate(_ input: String, options: ReviewOptions = .init(), proposals: [SuggestionProposal]) throws -> (PreparedDocument, [Suggestion]) {
        let document = ProtectionEngine().prepare(input, options: options)
        let response = WritingReviewResponse(segments: document.segments.map { segment in
            .init(id: segment.id, suggestions: proposals.filter { segment.text.contains($0.source) })
        })
        let result = try SuggestionValidator().validate(response, document: document, options: options)
        return (document, result.suggestions)
    }

    func testRebaseShiftsRemainingRangesAfterLengthChangeAndPreservesProtectedUnicode() throws {
        let input = "He don't knows the answer.\r\n`👩🏽‍💻_e\u{301}_private`\r\nWe really need to begin."
        let (document, suggestions) = try validate(input, proposals: [
            .init(category: .correctness, source: "don't knows", replacement: "doesn't know", explanation: "Agreement."),
            .init(category: .clarity, source: "really need", replacement: "need", explanation: "Optional brevity.")
        ])
        XCTAssertEqual(suggestions.count, 2)
        let accepted = try XCTUnwrap(suggestions.first { $0.category == .correctness })
        let result = try SuggestionRebaser().rebase(document: document, suggestions: suggestions, appliedID: accepted.id, options: .init())
        XCTAssertEqual(result.document.original, input.replacingOccurrences(of: "don't knows", with: "doesn't know"))
        XCTAssertEqual(result.validation.suggestions.count, 1)
        let remaining = try XCTUnwrap(result.validation.suggestions.first)
        XCTAssertEqual(remaining.range.substring(in: result.document.original), "really need")
        let output = try TextRecomposer().recompose(document: result.document, suggestions: result.validation.suggestions, acceptedIDs: [remaining.id])
        XCTAssertEqual(output, input.replacingOccurrences(of: "don't knows", with: "doesn't know").replacingOccurrences(of: "really need", with: "need"))
        XCTAssertTrue(output.contains("`👩🏽‍💻_e\u{301}_private`\r\n"))
    }

    func testRebaseDropsOverlappingAlternativesAndRetainsEarlierSuggestions() throws {
        let input = "We really need to begin. He don't knows the answer."
        let (document, suggestions) = try validate(input, proposals: [
            .init(category: .clarity, source: "really need", replacement: "need", explanation: "Optional brevity."),
            .init(category: .correctness, source: "don't knows", replacement: "doesn't know", explanation: "Agreement."),
            .init(category: .clarity, source: "He don't knows", replacement: "He is unsure of", explanation: "Alternative wording.")
        ])
        XCTAssertEqual(suggestions.count, 3)
        let accepted = try XCTUnwrap(suggestions.first { $0.category == .correctness })
        let result = try SuggestionRebaser().rebase(document: document, suggestions: suggestions, appliedID: accepted.id, options: .init())
        XCTAssertEqual(result.validation.suggestions.count, 1)
        XCTAssertEqual(result.validation.suggestions.first?.source, "really need")
        XCTAssertEqual(result.validation.suggestions.first?.range, suggestions.first?.range)
    }

    func testNewAmbiguousAnchorIsDroppedRatherThanAttachedToDifferentOccurrence() throws {
        let input = "He is nice and kind, and she is pleasant."
        let (document, suggestions) = try validate(input, proposals: [
            .init(category: .engagement, source: "nice", replacement: "pleasant", explanation: "Optional word choice."),
            .init(category: .engagement, source: "pleasant", replacement: "helpful", explanation: "Optional word choice.")
        ])
        let accepted = try XCTUnwrap(suggestions.first { $0.source == "nice" })
        let result = try SuggestionRebaser().rebase(document: document, suggestions: suggestions, appliedID: accepted.id, options: .init())
        XCTAssertTrue(result.validation.suggestions.isEmpty)
        XCTAssertEqual(result.validation.rejectedCount, 1)
    }

    func testRebaseRechecksEnabledCategoriesAndRejectsUnknownOrStaleAppliedEdit() throws {
        let input = "He don't knows the answer. We really need to begin."
        let (document, suggestions) = try validate(input, proposals: [
            .init(category: .correctness, source: "don't knows", replacement: "doesn't know", explanation: "Agreement."),
            .init(category: .clarity, source: "really need", replacement: "need", explanation: "Optional brevity.")
        ])
        let accepted = try XCTUnwrap(suggestions.first { $0.category == .correctness })
        let result = try SuggestionRebaser().rebase(document: document, suggestions: suggestions, appliedID: accepted.id, options: .init(enabledCategories: [.correctness]))
        XCTAssertTrue(result.validation.suggestions.isEmpty)
        XCTAssertThrowsError(try SuggestionRebaser().rebase(document: document, suggestions: suggestions, appliedID: "unknown", options: .init()))
        var stale = document
        stale.original = "The original field has changed."
        XCTAssertThrowsError(try SuggestionRebaser().rebase(document: stale, suggestions: suggestions, appliedID: accepted.id, options: .init()))
    }
}
