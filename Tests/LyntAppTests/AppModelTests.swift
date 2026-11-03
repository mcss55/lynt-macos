import XCTest
import Foundation
import LyntCore
@testable import LyntApp

@MainActor
final class AppModelTests: XCTestCase {
    /// Each test has independent preferences; no user's defaults, keys, or providers are touched.
    private func withModel(_ body: (AppModel, Preferences) throws -> Void) rethrows {
        let suite = "com.lynt.tests.app-model.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        let model = AppModel(preferences: preferences)
        defer { model.cancel() }
        try body(model, preferences)
    }

    func testPlaygroundHasAllFourCategoriesAndAcceptsNothingAutomatically() {
        withModel { model, _ in
            model.playground()
            XCTAssertEqual(model.suggestions.count, 4)
            XCTAssertEqual(Set(model.suggestions.map(\.category)), Set(SuggestionCategory.allCases))
            XCTAssertTrue(model.accepted.isEmpty)
            XCTAssertTrue(model.ignored.isEmpty)
            XCTAssertTrue(model.assembled.utf16.elementsEqual(model.input.utf16))
            XCTAssertTrue(model.isDemo)
            XCTAssertFalse(model.isReviewing)
            XCTAssertNil(model.reviewTask)
            XCTAssertFalse(model.canApply, "A local demonstration never has authority to write to another app")
        }
    }

    func testOnlyAcceptedProposalChangesTheAssembledText() throws {
        try withModel { model, _ in
            model.playground()
            let original = model.input
            let correctness = try XCTUnwrap(model.suggestions.first { $0.category == .correctness })
            let clarity = try XCTUnwrap(model.suggestions.first { $0.category == .clarity })
            model.accept(correctness)
            XCTAssertEqual(model.accepted, [correctness.id])
            XCTAssertEqual(model.assembled, original.replacingOccurrences(of: "don't", with: "doesn't"))
            XCTAssertTrue(model.assembled.contains(clarity.source), "Unaccepted stylistic wording must remain unchanged")
            model.ignore(correctness)
            XCTAssertTrue(model.accepted.isEmpty)
            XCTAssertTrue(model.ignored.contains(correctness.id))
            XCTAssertTrue(model.assembled.utf16.elementsEqual(original.utf16))
            model.undoDecision(correctness)
            XCTAssertFalse(model.ignored.contains(correctness.id))
            XCTAssertTrue(model.accepted.isEmpty)
        }
    }

    func testCancelClearsTextSnapshotsDecisionsAndRequestPreview() throws {
        try withModel { model, _ in
            model.playground()
            let proposal = try XCTUnwrap(model.suggestions.first)
            model.accept(proposal)
            model.requestPreview = "SYNTHETIC_PRIVATE_PROSE_FOR_MEMORY_CLEAR_TEST"
            model.showingRequest = true
            model.cancel()
            XCTAssertTrue(model.input.isEmpty)
            XCTAssertNil(model.document)
            XCTAssertTrue(model.suggestions.isEmpty)
            XCTAssertTrue(model.accepted.isEmpty)
            XCTAssertTrue(model.ignored.isEmpty)
            XCTAssertNil(model.selectedID)
            XCTAssertNil(model.toneAssessment)
            XCTAssertTrue(model.requestPreview.isEmpty)
            XCTAssertFalse(model.showingRequest)
            XCTAssertNil(model.captured)
            XCTAssertFalse(model.isReviewing)
            XCTAssertFalse(model.isApplying)
            XCTAssertNil(model.reviewTask)
        }
    }

    func testChangingReviewOptionsInvalidatesPreviousDecisionsWithoutReviewing() throws {
        try withModel { model, preferences in
            let changes: [(Preferences) -> Void] = [
                { $0.tone = .friendly },
                { $0.context = .search },
                { $0.enabledCategories = [.correctness] }
            ]
            for change in changes {
                model.playground()
                let original = model.input
                model.accept(try XCTUnwrap(model.suggestions.first))
                change(preferences)
                XCTAssertNil(model.document)
                XCTAssertTrue(model.suggestions.isEmpty)
                XCTAssertTrue(model.accepted.isEmpty)
                XCTAssertTrue(model.input.utf16.elementsEqual(original.utf16))
                XCTAssertFalse(model.isReviewing)
                XCTAssertNil(model.reviewTask)
                XCTAssertFalse(model.canApply)
            }
        }
    }

    func testDisablingCloudOrFallbackInvalidatesExistingReviewState() throws {
        try withModel { model, preferences in
            preferences.cloudEnabled = true
            model.playground()
            model.accept(try XCTUnwrap(model.suggestions.first))
            preferences.cloudEnabled = false
            XCTAssertNil(model.document)
            XCTAssertTrue(model.suggestions.isEmpty)
            XCTAssertTrue(model.accepted.isEmpty)
            XCTAssertFalse(model.isReviewing)
            model.playground()
            preferences.fallbackEnabled = false
            XCTAssertNil(model.document)
            XCTAssertTrue(model.suggestions.isEmpty)
            XCTAssertFalse(model.isReviewing)
            XCTAssertNil(model.reviewTask)
        }
    }

    func testCloudDisabledReviewPreparesLocallyWithoutCreatingProviderTask() throws {
        try withModel { model, preferences in
            preferences.cloudEnabled = false
            let original = "He don't knows the answer."
            model.input = original
            model.review()
            let document = try XCTUnwrap(model.document)
            XCTAssertFalse(document.segments.isEmpty)
            XCTAssertTrue(model.message.contains("Cloud review is disabled"))
            XCTAssertFalse(model.isReviewing)
            XCTAssertNil(model.reviewTask)
            XCTAssertTrue(model.suggestions.isEmpty)
            XCTAssertTrue(model.assembled.utf16.elementsEqual(original.utf16))
        }
    }

    func testNonEnglishReviewStopsBeforeProviderSetupEvenWithCloudEnabled() throws {
        try withModel { model, preferences in
            preferences.cloudEnabled = true
            for original in ["Bu hatayı nasıl düzeltebilirim?", "Bu xəta niyə baş verir?"] {
                model.input = original
                model.review()
                XCTAssertTrue(try XCTUnwrap(model.document).segments.isEmpty)
                XCTAssertFalse(model.isReviewing)
                XCTAssertNil(model.reviewTask)
                XCTAssertTrue(model.message.contains("no API request was made"))
                XCTAssertTrue(model.assembled.utf16.elementsEqual(original.utf16))
            }
        }
    }

    func testOverlappingAlternativesRequireUndoingTheFirstDecision() {
        withModel { model, _ in
            model.playground()
            let original = model.input
            let first = Suggestion(id: "minimal", segmentID: "s1", category: .correctness,
                                   range: .init(location: 3, length: 5), source: "don't", replacement: "doesn't", explanation: "Agreement")
            let alternative = Suggestion(id: "alternative", segmentID: "s1", category: .clarity,
                                         range: .init(location: 0, length: 13), source: "He don't know", replacement: "He does not know", explanation: "Alternative wording")
            model.suggestions = [first, alternative]
            model.accept(first)
            XCTAssertTrue(model.isConflicting(alternative))
            model.accept(alternative)
            XCTAssertEqual(model.accepted, [first.id])
            XCTAssertEqual(model.assembled, original.replacingOccurrences(of: "don't", with: "doesn't"))
            model.undoDecision(first)
            XCTAssertFalse(model.isConflicting(alternative))
            model.accept(alternative)
            XCTAssertEqual(model.accepted, [alternative.id])
            XCTAssertEqual(model.assembled, original.replacingOccurrences(of: "He don't know", with: "He does not know"))
        }
    }

    func testCancelPropagatesToThePendingReviewTask() async {
        let suite = "com.lynt.tests.app-model.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(preferences: Preferences(defaults: defaults))
        var observedCancellation = false
        let pending = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(5)) }
            catch { observedCancellation = error is CancellationError }
        }
        model.reviewTask = pending
        model.isReviewing = true
        model.cancel()
        await pending.value
        XCTAssertTrue(pending.isCancelled)
        XCTAssertTrue(observedCancellation)
        XCTAssertFalse(model.isReviewing)
        XCTAssertNil(model.reviewTask)
        XCTAssertTrue(model.input.isEmpty)
    }
}
