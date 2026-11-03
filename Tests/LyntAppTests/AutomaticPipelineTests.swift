import Foundation
import XCTest
import LyntCore
import LyntPlatform
@testable import LyntApp

private actor PipelineProvider: LLMProvider {
    private struct Pending {
        let result: ProviderReviewResult
        let continuation: CheckedContinuation<ProviderReviewResult, Never>
    }
    private let held: Bool
    private let onRequest: @Sendable (Int) -> Void
    private var pending: [Int: Pending] = [:]
    private(set) var requests: [WritingReviewRequest] = []

    init(held: Bool = false, onRequest: @escaping @Sendable (Int) -> Void = { _ in }) {
        self.held = held
        self.onRequest = onRequest
    }

    func review(_ request: WritingReviewRequest) async throws -> ProviderReviewResult {
        requests.append(request)
        let result = ProviderReviewResult(response: .init(segments: request.segments.map { segment in
            let suggestions: [SuggestionProposal] = segment.text.contains("don't knows")
                ? [.init(category: .correctness, source: "don't knows", replacement: "doesn't know", explanation: "Subject–verb agreement.")]
                : []
            return .init(id: segment.id, suggestions: suggestions)
        }), usage: .init(input: 17, output: 3), providerID: "deepseek", model: "synthetic-pipeline-test")
        let index = requests.count - 1
        if held {
            // Deliberately ignore Task cancellation to simulate an already delivered/late response.
            return await withCheckedContinuation { continuation in
                pending[index] = Pending(result: result, continuation: continuation)
                onRequest(index + 1)
            }
        }
        onRequest(index + 1)
        return result
    }

    func finishRequest(at index: Int) {
        guard let waiting = pending.removeValue(forKey: index) else { return }
        waiting.continuation.resume(returning: waiting.result)
    }
}

private actor PipelineNeverTransport: HTTPTransport {
    private(set) var dispatchCount = 0
    func send(_ request: URLRequest, maxResponseBytes: Int) async throws -> HTTPResult {
        dispatchCount += 1
        throw ProviderIssue.network
    }
}

@MainActor
final class AutomaticPipelineTests: XCTestCase {
    private func withPreferences(_ body: (Preferences, UserDefaults) async throws -> Void) async rethrows {
        let suite = "com.lynt.tests.automatic-pipeline.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try await body(Preferences(defaults: defaults), defaults)
    }

    func testInjectedReviewReceivesOnlyIsolatedProseAndCompletesWithUnacceptedSuggestions() async throws {
        try await withPreferences { preferences, _ in
            preferences.cloudEnabled = true
            let provider = PipelineProvider()
            var factoryCount = 0
            let model = AppModel(preferences: preferences, budget: TokenBudget(), providerFactory: {
                factoryCount += 1
                return provider
            })
            defer { model.cancel() }
            let original = """
            He don't knows the answer.
            ```swift
            let hiddenCode = "PRIVATE_CODE_ISOLATION"
            ```
            Bu xəta niyə baş verir?
            This request return an error.
            My password is PRIVATE_SECRET_ISOLATION.
            """
            model.input = original
            let completed = expectation(description: "Review completion")
            var completionCount = 0
            model.review {
                completionCount += 1
                completed.fulfill()
            }
            await fulfillment(of: [completed], timeout: 3)

            let requests = await provider.requests
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(factoryCount, 1)
            XCTAssertEqual(completionCount, 1)
            let request = try XCTUnwrap(requests.first)
            XCTAssertEqual(request.segments.map(\.text), ["He don't knows the answer.", "This request return an error."])
            let encoded = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
            for forbidden in ["PRIVATE_CODE_ISOLATION", "PRIVATE_SECRET_ISOLATION", "Bu xəta", "hiddenCode"] {
                XCTAssertFalse(encoded.contains(forbidden), "Detected protected content crossed the model boundary")
            }
            XCTAssertEqual(model.suggestions.count, 1)
            XCTAssertTrue(model.accepted.isEmpty)
            XCTAssertTrue(model.assembled.utf16.elementsEqual(original.utf16))
            XCTAssertFalse(model.isReviewing)
            XCTAssertFalse(model.isError)
            XCTAssertNil(model.reviewTask)
            model.accept(try XCTUnwrap(model.suggestions.first))
            XCTAssertEqual(model.assembled, original.replacingOccurrences(of: "don't knows", with: "doesn't know"))
        }
    }

    func testIneligibleAndCloudDisabledInputsNeverConstructOrInvokeProvider() async {
        await withPreferences { preferences, _ in
            let provider = PipelineProvider()
            var factoryCount = 0
            let model = AppModel(preferences: preferences, budget: TokenBudget(), providerFactory: {
                factoryCount += 1
                return provider
            })
            defer { model.cancel() }
            preferences.cloudEnabled = true
            let ineligible = ["Bu hatayı nasıl düzeltebilirim?", "Bu xəta niyə baş verir?",
                              "```swift\nlet hiddenValue = \"PRIVATE_CODE\"\n```",
                              "My password is PRIVATE_SECRET_VALUE.", "https://example.test/private", "500 123", " \r\n\t"]
            for original in ineligible {
                model.input = original
                var completionCount = 0
                model.review { completionCount += 1 }
                XCTAssertEqual(completionCount, 1, "Local early exits must release the automatic scheduler")
                XCTAssertFalse(model.isReviewing)
                XCTAssertNil(model.reviewTask)
                XCTAssertTrue(model.assembled.utf16.elementsEqual(original.utf16))
            }
            preferences.cloudEnabled = false
            model.input = "He don't knows the answer."
            var disabledCompletion = 0
            model.review { disabledCompletion += 1 }
            XCTAssertEqual(disabledCompletion, 1)
            XCTAssertEqual(factoryCount, 0)
            let calls = await provider.requests
            XCTAssertTrue(calls.isEmpty)
        }
    }

    func testCancellingHeldResponseDoesNotRestoreSuggestionsOrInvokeStaleCompletion() async throws {
        try await withPreferences { preferences, _ in
            preferences.cloudEnabled = true
            let started = expectation(description: "Provider entered")
            let provider = PipelineProvider(held: true) { _ in started.fulfill() }
            let model = AppModel(preferences: preferences, budget: TokenBudget(), providerFactory: { provider })
            defer { model.cancel() }
            model.input = "He don't knows the answer."
            var completions = 0
            model.review { completions += 1 }
            await fulfillment(of: [started], timeout: 3)
            let oldTask = try XCTUnwrap(model.reviewTask)

            model.cancel()
            await provider.finishRequest(at: 0)
            await oldTask.value

            XCTAssertEqual(completions, 0)
            XCTAssertTrue(model.input.isEmpty)
            XCTAssertNil(model.document)
            XCTAssertTrue(model.suggestions.isEmpty)
            XCTAssertFalse(model.isReviewing)
            XCTAssertFalse(model.isError)
            XCTAssertNil(model.reviewTask)
        }
    }

    func testEditedInputOldResponseCannotFinishOrClobberNewReview() async throws {
        try await withPreferences { preferences, _ in
            preferences.cloudEnabled = true
            let firstStarted = expectation(description: "First request")
            let secondStarted = expectation(description: "Second request")
            let provider = PipelineProvider(held: true) { count in
                if count == 1 { firstStarted.fulfill() }
                if count == 2 { secondStarted.fulfill() }
            }
            let model = AppModel(preferences: preferences, budget: TokenBudget(), providerFactory: { provider })
            defer { model.cancel() }
            var oldCompletions = 0
            var newCompletions = 0
            model.input = "He don't knows the answer."
            model.review { oldCompletions += 1 }
            await fulfillment(of: [firstStarted], timeout: 3)
            let oldTask = try XCTUnwrap(model.reviewTask)

            let newOriginal = "She don't knows the answer."
            model.input = newOriginal
            model.editedInput()
            model.review { newCompletions += 1 }
            await fulfillment(of: [secondStarted], timeout: 3)
            let newTask = try XCTUnwrap(model.reviewTask)
            await provider.finishRequest(at: 0)
            await oldTask.value

            XCTAssertEqual(oldCompletions, 0)
            XCTAssertEqual(newCompletions, 0)
            XCTAssertTrue(model.isReviewing, "A stale completion must not free the newer in-flight review")
            XCTAssertTrue(model.suggestions.isEmpty)
            XCTAssertTrue(model.input.utf16.elementsEqual(newOriginal.utf16))

            await provider.finishRequest(at: 1)
            await newTask.value
            XCTAssertEqual(oldCompletions, 0)
            XCTAssertEqual(newCompletions, 1)
            XCTAssertFalse(model.isReviewing)
            XCTAssertFalse(model.isError)
            XCTAssertEqual(model.document?.original, newOriginal)
            XCTAssertEqual(model.suggestions.count, 1)
            XCTAssertTrue(model.accepted.isEmpty)
        }
    }

    func testDisablingCloudCancelsHeldResponseWithoutAResultCallback() async throws {
        try await withPreferences { preferences, _ in
            preferences.cloudEnabled = true
            let started = expectation(description: "Provider entered")
            let provider = PipelineProvider(held: true) { _ in started.fulfill() }
            let model = AppModel(preferences: preferences, budget: TokenBudget(), providerFactory: { provider })
            defer { model.cancel() }
            let original = "He don't knows the answer."
            model.input = original
            var completions = 0
            model.review { completions += 1 }
            await fulfillment(of: [started], timeout: 3)
            let oldTask = try XCTUnwrap(model.reviewTask)
            preferences.cloudEnabled = false
            await provider.finishRequest(at: 0)
            await oldTask.value
            XCTAssertEqual(completions, 0)
            XCTAssertFalse(model.isReviewing)
            XCTAssertTrue(model.suggestions.isEmpty)
            XCTAssertTrue(model.input.utf16.elementsEqual(original.utf16))
        }
    }

    func testSharedInjectedBudgetStopsDispatchAndStillCompletesThePipeline() async {
        await withPreferences { preferences, _ in
            preferences.cloudEnabled = true
            preferences.monthlyTokenLimit = 5
            let budget = TokenBudget(monthlyLimit: 5)
            let transport = PipelineNeverTransport()
            let adapter = FallbackReviewProvider(configurations: [.init(id: .deepseek, apiKey: "synthetic-not-a-real-key")], budget: budget, transport: transport)
            let model = AppModel(preferences: preferences, budget: budget, providerFactory: { adapter })
            defer { model.cancel() }
            let original = "He don't knows the answer."
            model.input = original
            let completed = expectation(description: "Budget error completes")
            model.review { completed.fulfill() }
            await fulfillment(of: [completed], timeout: 3)
            let dispatches = await transport.dispatchCount
            let snapshot = await budget.snapshot()
            XCTAssertEqual(dispatches, 0)
            XCTAssertEqual(snapshot.limit, 5)
            XCTAssertEqual(snapshot.usedTokens, 0)
            XCTAssertEqual(snapshot.reservedTokens, 0)
            XCTAssertTrue(model.isError)
            XCTAssertFalse(model.isReviewing)
            XCTAssertTrue(model.suggestions.isEmpty)
            XCTAssertTrue(model.input.utf16.elementsEqual(original.utf16))
        }
    }

    func testAutomaticPreferencePersistsWithoutEnablingCloudOrOverridingPause() async {
        await withPreferences { initial, defaults in
            XCTAssertTrue(initial.automaticReviewEnabled)
            XCTAssertFalse(initial.cloudEnabled)
            initial.automaticReviewEnabled = false
            let paused = Preferences(defaults: defaults)
            XCTAssertFalse(paused.automaticReviewEnabled)
            XCTAssertFalse(paused.cloudEnabled)
            paused.cloudEnabled = true
            let cloudAllowed = Preferences(defaults: defaults)
            XCTAssertTrue(cloudAllowed.cloudEnabled)
            XCTAssertFalse(cloudAllowed.automaticReviewEnabled, "Saving cloud consent must not unpause automatic review")
            cloudAllowed.automaticReviewEnabled = true
            cloudAllowed.cloudEnabled = false
            let cloudDisabled = Preferences(defaults: defaults)
            XCTAssertTrue(cloudDisabled.automaticReviewEnabled)
            XCTAssertFalse(cloudDisabled.cloudEnabled, "Automatic mode must not bypass the independent cloud switch")
        }
    }

    func testVisibleSuggestionsStayWhenLyntBecomesFrontmost() {
        XCTAssertTrue(FloatingSuggestionRetention.shouldIgnoreUnavailable(.noExternalField, presenting: true, frontmostIsSelf: true))
        XCTAssertFalse(FloatingSuggestionRetention.shouldIgnoreUnavailable(.noExternalField, presenting: true, frontmostIsSelf: false))
        XCTAssertFalse(FloatingSuggestionRetention.shouldIgnoreUnavailable(.noExternalField, presenting: false, frontmostIsSelf: true))
        XCTAssertFalse(FloatingSuggestionRetention.shouldIgnoreUnavailable(.emptyField, presenting: true, frontmostIsSelf: true))
        XCTAssertFalse(FloatingSuggestionRetention.shouldIgnoreUnavailable(.excludedApplication, presenting: true, frontmostIsSelf: true))
    }
}
