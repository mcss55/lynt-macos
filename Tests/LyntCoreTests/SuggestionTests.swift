import XCTest
@testable import LyntCore

final class SuggestionTests: XCTestCase {
    func response(_ document: PreparedDocument, proposals: [SuggestionProposal]) -> WritingReviewResponse {
        .init(segments: document.segments.enumerated().map { .init(id: $1.id, suggestions: $0 == 0 ? proposals : []) })
    }
    func proposal(_ category: SuggestionCategory, _ source: String, _ replacement: String) -> SuggestionProposal {
        .init(category: category, source: source, replacement: replacement, explanation: "A concise explanation.")
    }
    func proposal(_ source: String, _ replacement: String) -> SuggestionProposal {
        proposal(.correctness, source, replacement)
    }
    func testAllFourCategoriesRequireExplicitAcceptance() throws {
        let document = ProtectionEngine().prepare("He don't knows the answer and we really need to begin.")
        let options = ReviewOptions(tone: .init(target: .professional))
        let proposals = [proposal(.correctness, "don't knows", "doesn't know"), proposal(.clarity, "really need to begin", "need to begin"), proposal(.engagement, "begin", "start"), proposal(.delivery, "we really need to begin", "we should begin")]
        let result = try SuggestionValidator().validate(response(document, proposals: proposals), document: document, options: options)
        XCTAssertEqual(Set(result.suggestions.map(\.category)), Set(SuggestionCategory.allCases))
        XCTAssertEqual(try TextRecomposer().recompose(document: document, suggestions: result.suggestions, acceptedIDs: []), document.original)
        let correctness = try XCTUnwrap(result.suggestions.first { $0.category == .correctness })
        XCTAssertEqual(try TextRecomposer().recompose(document: document, suggestions: result.suggestions, acceptedIDs: [correctness.id]), "He doesn't know the answer and we really need to begin.")
    }
    func testOverlappingAlternativesCannotBeComposed() throws {
        let document = ProtectionEngine().prepare("He don't knows the answer.")
        let result = try SuggestionValidator().validate(response(document, proposals: [proposal("don't knows", "doesn't know"), proposal(.clarity, "He don't knows", "He is unsure of")]), document: document, options: .init())
        XCTAssertEqual(result.suggestions.count, 2)
        XCTAssertThrowsError(try TextRecomposer().recompose(document: document, suggestions: result.suggestions, acceptedIDs: Set(result.suggestions.map(\.id))))
    }
    func testUnsafeUnanchoredRepeatedHugeAndDisabledEditsAreDropped() throws {
        let document = ProtectionEngine().prepare("This is a test and this is a test.")
        let proposals = [
            proposal("is a test", "is an example"), // two exact occurrences
            proposal("not present", "is present"),
            proposal("This", String(repeating: "expanded ", count: 200)),
            proposal("This", "https://malicious.test/private"),
            proposal("This", "THIS_API_KEY_123456789"),
            proposal("This", "This"),
            proposal(.clarity, "This", "That")
        ]
        let result = try SuggestionValidator().validate(response(document, proposals: proposals), document: document, options: .init(enabledCategories: [.correctness]))
        XCTAssertTrue(result.suggestions.isEmpty)
        XCTAssertEqual(result.rejectedCount, proposals.count)
    }
    func testMissingDuplicateAndUnknownSegmentIDsRejectWholeResponse() {
        let document = ProtectionEngine().prepare("He don't knows the answer. Can you explain why this happen?")
        for segments: [SegmentReviewResponse] in [[], [.init(id: "unknown", suggestions: [])], [.init(id: "s1", suggestions: []), .init(id: "s1", suggestions: [])]] {
            XCTAssertThrowsError(try SuggestionValidator().validate(.init(segments: segments), document: document, options: .init()))
        }
    }
    func testDuplicatesAreDroppedAndIDsAreDeterministic() throws {
        let document = ProtectionEngine().prepare("He don't knows the answer.")
        let item = proposal("don't knows", "doesn't know")
        let response = response(document, proposals: [item, item])
        let first = try SuggestionValidator().validate(response, document: document, options: .init())
        let second = try SuggestionValidator().validate(response, document: document, options: .init())
        XCTAssertEqual(first.suggestions.count, 1)
        XCTAssertEqual(first.rejectedCount, 1)
        XCTAssertEqual(first.suggestions.map(\.id), second.suggestions.map(\.id))
    }
    func testForgedAndStaleEditsCannotTouchTechnicalSpans() throws {
        let document = ProtectionEngine().prepare("He don't knows the answer. `/api/private` remains unchanged.")
        let forged = Suggestion(id: "forged", segmentID: "s1", category: .correctness, range: .init(location: 28, length: 12), source: "/api/private", replacement: "leak", explanation: "Forged")
        XCTAssertThrowsError(try TextRecomposer().recompose(document: document, suggestions: [forged], acceptedIDs: ["forged"]))
        var stale = document; stale.original = "The document has changed."
        XCTAssertThrowsError(try SuggestionValidator().validate(response(document, proposals: []), document: stale, options: .init()))
        XCTAssertThrowsError(try TextRecomposer().recompose(document: document, suggestions: [], acceptedIDs: ["unknown"]))
    }
    func testUnicodeAnchorsAndProtectedRangesSurviveLengthChanges() throws {
        let input = "🙂 He don't knows the answer.\r\n`e\u{301}_private_👩🏽‍💻`\r\nCan you explain why this happen?"
        let document = ProtectionEngine().prepare(input)
        let result = try SuggestionValidator().validate(response(document, proposals: [proposal("don't knows", "doesn't know")]), document: document, options: .init())
        XCTAssertEqual(result.suggestions.count, 1)
        let output = try TextRecomposer().recompose(document: document, suggestions: result.suggestions, acceptedIDs: Set(result.suggestions.map(\.id)))
        XCTAssertEqual(output, input.replacingOccurrences(of: "don't knows", with: "doesn't know"))
    }
    func testToneIsQualifiedAndSearchDisallowsStylisticEdits() throws {
        let document = ProtectionEngine().prepare("Can you fix it?")
        var value = response(document, proposals: [proposal(.delivery, "Can you fix it?", "Could you please resolve it?")])
        value.toneAssessment = .init(label: "tentative", note: "Short text; limited context.")
        let result = try SuggestionValidator().validate(value, document: document, options: .init())
        XCTAssertTrue(result.suggestions.isEmpty)
        XCTAssertTrue(result.toneAssessment?.note.contains("Subjective") == true)
        let professional = try SuggestionValidator().validate(value, document: document, options: .init(tone: .init(target: .professional)))
        XCTAssertEqual(professional.suggestions.count, 1)
        let search = try SuggestionValidator().validate(value, document: document, options: .init(contextKind: .search))
        XCTAssertTrue(search.suggestions.isEmpty)
        XCTAssertNil(search.toneAssessment)
    }

    func testCanonicalEquivalentButDifferentCodeUnitsAreNotValidAnchors() throws {
        let input = "This cafe\u{301} is really good."
        let document = ProtectionEngine().prepare(input)
        let result = try SuggestionValidator().validate(response(document, proposals: [proposal("café", "restaurant")]), document: document, options: .init())
        XCTAssertTrue(result.suggestions.isEmpty)
        let range = (input as NSString).range(of: "cafe\u{301}", options: .literal)
        let forged = Suggestion(id: "forged", segmentID: "s1", category: .correctness, range: .init(location: range.location, length: range.length), source: "café", replacement: "restaurant", explanation: "Different bytes")
        XCTAssertThrowsError(try TextRecomposer().recompose(document: document, suggestions: [forged], acceptedIDs: ["forged"]))
    }

    func testUniqueSubstringInsideWordIsNotAnAnchor() throws {
        let document = ProtectionEngine().prepare("This request fails every time.")
        let result = try SuggestionValidator().validate(response(document, proposals: [proposal("is", "are")]), document: document, options: .init())
        XCTAssertTrue(result.suggestions.isEmpty)
        XCTAssertEqual(result.rejectedCount, 1)
    }

    func testTranslationAndUnrequestedToneShiftAreDropped() throws {
        let document = ProtectionEngine().prepare("Can you fix it?")
        let result = try SuggestionValidator().validate(response(document, proposals: [
            proposal(.clarity, "Can you fix it?", "Bunu düzəldə bilərsən?"),
            proposal(.engagement, "Can you fix it?", "Pouvez-vous le corriger?"),
            proposal(.delivery, "Can you fix it?", "I demand that you fix it.")
        ]), document: document, options: .init())
        XCTAssertTrue(result.suggestions.isEmpty)
        XCTAssertEqual(result.rejectedCount, 3)
        let typo = ProtectionEngine().prepare("This is a raelly good example.")
        let short = try SuggestionValidator().validate(response(typo, proposals: [proposal("raelly", "really")]), document: typo, options: .init())
        XCTAssertEqual(short.suggestions.count, 1)
    }
}
