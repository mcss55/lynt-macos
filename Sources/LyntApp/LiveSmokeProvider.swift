import Foundation
import LyntCore

/// Explicit developer smoke-test mode has no API keys, network transport, or real preference store.
/// The visible provider label prevents synthetic results being mistaken for model output.
struct LiveSmokeProvider: LLMProvider {
    func review(_ request: WritingReviewRequest) async throws -> ProviderReviewResult {
        try Task.checkCancellation()
        let response = WritingReviewResponse(segments: request.segments.map { segment in
            let proposals: [SuggestionProposal]
            if segment.text.contains("He don't knows") {
                proposals = [.init(category: .correctness, source: "don't knows", replacement: "doesn't know", explanation: "Local smoke test: agreement with He.")]
            } else if segment.text.contains("He don't know") {
                proposals = [.init(category: .correctness, source: "don't", replacement: "doesn't", explanation: "Local smoke test: singular agreement.")]
            } else { proposals = [] }
            return .init(id: segment.id, suggestions: proposals)
        })
        return .init(response: response, providerID: "Local smoke test", model: "no network")
    }
}
