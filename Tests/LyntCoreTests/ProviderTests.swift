import XCTest
@testable import LyntCore

private actor StubTransport: HTTPTransport {
    enum Step: Sendable { case response(HTTPResult), failure(URLError.Code), cancellation }
    var steps: [Step]
    var requests: [URLRequest] = []
    init(_ steps: [Step]) { self.steps = steps }
    func send(_ request: URLRequest, maxResponseBytes: Int) async throws -> HTTPResult {
        requests.append(request)
        guard !steps.isEmpty else { throw URLError(.badServerResponse) }
        switch steps.removeFirst() {
        case .response(let response): return response
        case .failure(let code): throw URLError(code)
        case .cancellation: throw CancellationError()
        }
    }
    var count: Int { requests.count }
}

final class ProviderTests: XCTestCase {
    private var request: WritingReviewRequest {
        .init(enabledCategories: SuggestionCategory.allCases, tone: .init(), contextKind: .prompt,
              segments: [.init(id: "s1", text: "He don't knows the answer.")])
    }
    private var configurations: [ProviderConfiguration] {
        [.init(id: .deepseek, apiKey: "test-deepseek"), .init(id: .mistral, apiKey: "test-mistral")]
    }
    private func success(content: String? = nil, finish: String = "stop", includeUsage: Bool = true) throws -> HTTPResult {
        let body = content ?? #"{"segments":[{"id":"s1","suggestions":[{"category":"correctness","source":"don't knows","replacement":"doesn't know","explanation":"Agreement."}]}],"toneAssessment":null}"#
        var object: [String: Any] = ["choices": [["message": ["content": body], "finish_reason": finish]]]
        if includeUsage { object["usage"] = ["prompt_tokens": 120, "completion_tokens": 45] }
        return .init(data: try JSONSerialization.data(withJSONObject: object), statusCode: 200)
    }

    func testDeepSeekDefaultOneBatchedRequest() async throws {
        let transport = StubTransport([.response(try success())])
        let provider = FallbackReviewProvider(configurations: configurations, transport: transport)
        let result = try await provider.review(request)
        XCTAssertEqual(result.providerID, "deepseek")
        XCTAssertEqual(result.model, "deepseek-flash")
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.usage.total, 165)
        let calls = await transport.requests
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.url?.host, "api.deepseek.com")
        XCTAssertEqual(calls.first?.value(forHTTPHeaderField: "Authorization"), "Bearer test-deepseek")
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(calls.first?.httpBody)) as? [String: Any])
        XCTAssertEqual((payload["thinking"] as? [String: String])?["type"], "disabled")
        XCTAssertEqual((payload["response_format"] as? [String: String])?["type"], "json_object")
        XCTAssertEqual(payload["stream"] as? Bool, false)
        let messages = try XCTUnwrap(payload["messages"] as? [[String: String]])
        let safeDTO = try JSONDecoder().decode(WritingReviewRequest.self, from: Data(XCTUnwrap(messages.last?["content"]).utf8))
        XCTAssertEqual(safeDTO.enabledCategories.count, 4)
        XCTAssertEqual(safeDTO.segments, request.segments)
    }

    func testCreditExhaustionFallsBackWithIdenticalSafePayload() async throws {
        let transport = StubTransport([.response(.init(data: Data("private provider error".utf8), statusCode: 402)), .response(try success())])
        let result = try await FallbackReviewProvider(configurations: configurations, transport: transport).review(request)
        XCTAssertEqual(result.providerID, "mistral")
        XCTAssertEqual(result.model, "ministral-3b-2512")
        XCTAssertTrue(result.usedFallback)
        let calls = await transport.requests
        XCTAssertEqual(calls.count, 2)
        let first = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(calls[0].httpBody)) as? [String: Any])
        let second = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(calls[1].httpBody)) as? [String: Any])
        XCTAssertEqual((first["messages"] as? [[String: String]])?.last, (second["messages"] as? [[String: String]])?.last)
        XCTAssertNil(second["thinking"])
    }

    func testPreparedMixedDocumentNeverTransmitsProtectedContentToEitherProvider() async throws {
        let original = """
        He don't knows the answer.
        ```swift
        let privateCode = "PRIVATE-CODE-DO-NOT-SEND"
        ```
        Please explain why this request is failing.
        {"privatePayload": "PRIVATE-JSON-DO-NOT-SEND", "nested": [1, 2, 3]}
        Why this endpoint /api/v1/users/PRIVATE-ROUTE-DO-NOT-SEND return an error?
        Bu hatayı nasıl düzeltebilirim?
        My password is PRIVATE-PASSWORD-DO-NOT-SEND and this request is failing.
        """
        let document = ProtectionEngine().prepare(original)
        let outgoing = document.request(options: .init())
        XCTAssertFalse(outgoing.segments.isEmpty)
        let response = WritingReviewResponse(segments: outgoing.segments.map { .init(id: $0.id, suggestions: []) })
        let content = try XCTUnwrap(String(data: JSONEncoder().encode(response), encoding: .utf8))
        let transport = StubTransport([.response(.init(data: Data(), statusCode: 402)), .response(try success(content: content))])
        let result = try await FallbackReviewProvider(configurations: configurations, transport: transport).review(outgoing)
        XCTAssertTrue(result.usedFallback)
        let calls = await transport.requests
        XCTAssertEqual(calls.count, 2)
        for call in calls {
            let body = try XCTUnwrap(String(data: XCTUnwrap(call.httpBody), encoding: .utf8))
            for prohibited in ["PRIVATE-CODE-DO-NOT-SEND", "PRIVATE-JSON-DO-NOT-SEND", "PRIVATE-ROUTE-DO-NOT-SEND", "PRIVATE-PASSWORD-DO-NOT-SEND", "Bu hatayı nasıl düzeltebilirim?"] {
                XCTAssertFalse(body.contains(prohibited), "Leaked protected fixture content")
            }
            XCTAssertFalse(body.contains("protectedSpans"))
            XCTAssertFalse(body.contains("\"original\""))
        }
    }

    func testMistralCanBePreferredAndFallbackToDeepSeek() async throws {
        let transport = StubTransport([.response(.init(data: Data(), statusCode: 429)), .response(try success())])
        let result = try await FallbackReviewProvider(configurations: configurations, preferred: .mistral, transport: transport).review(request)
        XCTAssertEqual(result.providerID, "deepseek")
        XCTAssertTrue(result.usedFallback)
        let calls = await transport.requests
        XCTAssertEqual(calls.first?.url?.host, "api.mistral.ai")
    }

    func testTimeoutAndInvalidJSONFallBack() async throws {
        for first in [StubTransport.Step.failure(.timedOut), .response(.init(data: Data("not json".utf8), statusCode: 200)), .response(try success(content: "  "))] {
            let transport = StubTransport([first, .response(try success())])
            let result = try await FallbackReviewProvider(configurations: configurations, transport: transport).review(request)
            XCTAssertTrue(result.usedFallback)
            let count = await transport.count
            XCTAssertEqual(count, 2)
        }
    }

    func testInvalidSegmentIDsAndTruncatedResponsesFallBack() async throws {
        let badContents = [
            #"{"segments":[]}"#,
            #"{"segments":[{"id":"invented","suggestions":[]}]}"#,
            #"{"segments":[{"id":"s1","suggestions":[]},{"id":"s1","suggestions":[]}]}"#,
            #"{"segments":[{"id":"s1","suggestions":[{"category":"translate","source":"He","replacement":"O","explanation":"Translation"}]}]}"#
        ]
        for content in badContents {
            let transport = StubTransport([.response(try success(content: content)), .response(try success())])
            let result = try await FallbackReviewProvider(configurations: configurations, transport: transport).review(request)
            XCTAssertTrue(result.usedFallback)
        }
        let transport = StubTransport([.response(try success(finish: "length")), .response(try success())])
        let result = try await FallbackReviewProvider(configurations: configurations, transport: transport).review(request)
        XCTAssertTrue(result.usedFallback)
    }

    func testCancellationNeverFallsBack() async throws {
        let transport = StubTransport([.cancellation, .response(try success())])
        do {
            _ = try await FallbackReviewProvider(configurations: configurations, transport: transport).review(request)
            XCTFail("Cancellation must propagate")
        } catch is CancellationError { } catch { XCTFail("Unexpected error") }
        let count = await transport.count
        XCTAssertEqual(count, 1)
    }

    func testBothProvidersFailOnceAndHideResponseBodies() async throws {
        let transport = StubTransport([
            .response(.init(data: Data("sensitive-private-body".utf8), statusCode: 402)),
            .response(.init(data: Data("sensitive-private-body".utf8), statusCode: 500))
        ])
        do {
            _ = try await FallbackReviewProvider(configurations: configurations, transport: transport).review(request)
            XCTFail("Should fail")
        } catch let error as ProvidersUnavailableError {
            XCTAssertEqual(error.failures.count, 2)
            XCTAssertTrue(error.localizedDescription.contains("402"))
            XCTAssertFalse(error.localizedDescription.contains("sensitive-private-body"))
        }
        let count = await transport.count
        XCTAssertEqual(count, 2)
    }

    func testDisableFallbackSendsOnlyToPreferredProvider() async throws {
        let transport = StubTransport([.response(.init(data: Data(), statusCode: 503)), .response(try success())])
        do {
            _ = try await FallbackReviewProvider(configurations: configurations, allowsFallback: false, transport: transport).review(request)
            XCTFail("Should fail")
        } catch let error as ProvidersUnavailableError { XCTAssertEqual(error.failures.count, 1) }
        let count = await transport.count
        XCTAssertEqual(count, 1)
    }

    func testMissingDefaultKeyUsesConfiguredFallback() async throws {
        let transport = StubTransport([.response(try success())])
        let result = try await FallbackReviewProvider(configurations: [.init(id: .mistral, apiKey: "test")], transport: transport).review(request)
        XCTAssertEqual(result.providerID, "mistral")
        XCTAssertTrue(result.usedFallback)
        let count = await transport.count
        XCTAssertEqual(count, 1)
    }

    func testEmptySafeProseMakesZeroRequests() async throws {
        let transport = StubTransport([])
        var empty = request
        empty.segments = []
        let result = try await FallbackReviewProvider(configurations: configurations, transport: transport).review(empty)
        XCTAssertTrue(result.response.segments.isEmpty)
        let count = await transport.count
        XCTAssertEqual(count, 0)
    }

    func testUnsafeEndpointRejectedBeforeTransmission() async throws {
        let transport = StubTransport([])
        for endpoint in ["http://example.com/chat/completions", "https://user:secret@example.com/chat", "https://example.com/chat?key=secret"] {
            do {
                _ = try await FallbackReviewProvider(configurations: [.init(id: .deepseek, endpoint: URL(string: endpoint)!, apiKey: "test")], transport: transport).review(request)
                XCTFail("Unsafe configuration")
            } catch let failure as ProvidersUnavailableError { XCTAssertEqual(failure.failures.first?.issue, .invalidConfiguration) }
        }
        let count = await transport.count
        XCTAssertEqual(count, 0)
    }

    func testInvalidPrimaryConfigurationStillUsesSafeFallback() async throws {
        let transport = StubTransport([.response(try success())])
        let brokenPrimary = ProviderConfiguration(id: .deepseek, endpoint: URL(string: "http://unsafe.invalid/chat")!, apiKey: "test")
        let fallback = ProviderConfiguration(id: .mistral, apiKey: "test")
        let result = try await FallbackReviewProvider(configurations: [brokenPrimary, fallback], transport: transport).review(request)
        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.providerID, "mistral")
        let calls = await transport.requests
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.url?.scheme, "https")
    }

    func testResponseSizeCapRejectsMockTransportOversizeData() async throws {
        let transport = StubTransport([.response(.init(data: Data(repeating: 32, count: 262_145), statusCode: 200)), .response(try success())])
        let result = try await FallbackReviewProvider(configurations: configurations, transport: transport).review(request)
        XCTAssertTrue(result.usedFallback)
    }

    func testBudgetPreflightIncludesPossibleFallbackAndStopsAllNetwork() async throws {
        let transport = StubTransport([.response(try success())])
        let budget = TokenBudget(monthlyLimit: 1)
        do {
            _ = try await FallbackReviewProvider(configurations: configurations, budget: budget, transport: transport).review(request)
            XCTFail("Budget should block")
        } catch is TokenBudgetError { }
        let count = await transport.count
        XCTAssertEqual(count, 0)
        let snapshot = await budget.snapshot()
        XCTAssertEqual(snapshot.usedTokens, 0)
        XCTAssertEqual(snapshot.reservedTokens, 0)
    }

    func testBudgetSettlesActualUsageAndReleasesUnattemptedFallback() async throws {
        let budget = TokenBudget(monthlyLimit: 100_000)
        let transport = StubTransport([.response(try success())])
        _ = try await FallbackReviewProvider(configurations: configurations, budget: budget, transport: transport).review(request)
        let snapshot = await budget.snapshot()
        XCTAssertEqual(snapshot.usedTokens, 165)
        XCTAssertEqual(snapshot.reservedTokens, 0)
    }

    func testCreditRejectionDoesNotConsumeBudgetBeforeSuccessfulFallback() async throws {
        let budget = TokenBudget(monthlyLimit: 100_000)
        let transport = StubTransport([.response(.init(data: Data(), statusCode: 402)), .response(try success())])
        let result = try await FallbackReviewProvider(configurations: configurations, budget: budget, transport: transport).review(request)
        XCTAssertTrue(result.usedFallback)
        let snapshot = await budget.snapshot()
        XCTAssertEqual(snapshot.usedTokens, 165)
        XCTAssertEqual(snapshot.reservedTokens, 0)
    }

    func testBudgetChargesUnknownUsageAndCancelledAttemptConservatively() async throws {
        let budget = TokenBudget(monthlyLimit: 100_000)
        let transport = StubTransport([.cancellation])
        do {
            _ = try await FallbackReviewProvider(configurations: configurations, budget: budget, transport: transport).review(request)
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
        let snapshot = await budget.snapshot()
        XCTAssertGreaterThan(snapshot.usedTokens, 1_600)
        XCTAssertLessThan(snapshot.usedTokens, 15_000)
        XCTAssertEqual(snapshot.reservedTokens, 0)
    }

    func testAbsentUsageIsChargedConservativelyRatherThanAsFree() async throws {
        let budget = TokenBudget(monthlyLimit: 100_000)
        let transport = StubTransport([.response(try success(includeUsage: false))])
        let result = try await FallbackReviewProvider(configurations: configurations, budget: budget, transport: transport).review(request)
        XCTAssertGreaterThan(result.usage.input, 1_000)
        XCTAssertEqual(result.usage.output, 1_600)
        let snapshot = await budget.snapshot()
        XCTAssertEqual(snapshot.usedTokens, result.usage.total)
        XCTAssertEqual(snapshot.reservedTokens, 0)
    }

    func testNewMonthResetsCountersAndCrashReservationRemainsCharged() async throws {
        let suite = "lynt.tests.\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        let oldDate = Date(timeIntervalSince1970: 1_704_110_400) // January 2024, safely away from a month boundary.
        let newDate = Date(timeIntervalSince1970: 1_708_430_400) // February 2024.
        let first = TokenBudget(monthlyLimit: 100, store: store, now: { oldDate })
        _ = try await first.reserve(80)
        // Simulate restart without settling an in-flight request. Its reservation stays charged.
        let restarted = TokenBudget(monthlyLimit: 100, store: store, now: { oldDate })
        let crashed = await restarted.snapshot()
        XCTAssertEqual(crashed.usedTokens, 80)
        XCTAssertEqual(crashed.reservedTokens, 0)
        let nextMonth = TokenBudget(monthlyLimit: 100, store: store, now: { newDate })
        let reset = await nextMonth.snapshot()
        XCTAssertEqual(reset.usedTokens, 0)
    }

    func testBudgetReservationsAreAtomicAndPersistOnlyCounters() async throws {
        let suite = "lynt.tests.\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        let budget = TokenBudget(monthlyLimit: 100, store: store)
        let reservation = try await budget.reserve(80)
        do { _ = try await budget.reserve(21); XCTFail("Budget overrun") } catch is TokenBudgetError { }
        let pending = await budget.snapshot()
        XCTAssertEqual(pending.reservedTokens, 80)
        await budget.settle(reservation, chargedTokens: 20)
        await budget.settle(reservation, chargedTokens: 40)
        let settled = await budget.snapshot()
        XCTAssertEqual(settled.usedTokens, 20)
        let reloaded = TokenBudget(monthlyLimit: 100, store: store)
        let snapshot = await reloaded.snapshot()
        XCTAssertEqual(snapshot.usedTokens, 20)
        XCTAssertEqual(Set(store.persistentDomain(forName: suite)?.keys ?? Dictionary<String, Any>().keys), ["lynt.budget.month", "lynt.budget.charged"])
    }
}
