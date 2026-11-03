import AppKit
import Combine
import LyntCore
import LyntPlatform

@MainActor
final class AppModel: ObservableObject {
    let preferences: Preferences
    let fields = FocusedFieldService()
    let keys: KeychainStore
    private let suppliedBudget: TokenBudget?
    private let providerFactory: (@MainActor () throws -> any LLMProvider)?
    lazy var budget = suppliedBudget ?? TokenBudget(monthlyLimit: preferences.monthlyTokenLimit, store: .standard)
    @Published var input = ""
    @Published var document: PreparedDocument?
    @Published var suggestions: [Suggestion] = []
    @Published var accepted: Set<String> = []
    @Published var ignored: Set<String> = []
    @Published var selectedID: String?
    @Published var filter: SuggestionCategory?
    @Published var toneAssessment: ToneAssessment?
    @Published var isReviewing = false
    @Published var isApplying = false
    @Published var message = "Paste text, use the menu-bar action, or try the local playground."
    @Published var isError = false
    @Published var providerDescription = "On demand · No text history"
    @Published var requestPreview = ""
    @Published var showingRequest = false
    @Published var captured: CapturedText?
    @Published var tokenCount = 0
    @Published var budgetDescription = ""
    @Published var isDemo = false
    var reviewTask: Task<Void, Never>?
    private var applyTask: Task<Void, Never>?
    private var operationID = UUID()
    private var subscriptions = Set<AnyCancellable>()

    init(preferences: Preferences? = nil, budget: TokenBudget? = nil,
         providerFactory: (@MainActor () throws -> any LLMProvider)? = nil,
         keychainStore: KeychainStore = KeychainStore()) {
        self.preferences = preferences ?? Preferences()
        self.keys = keychainStore
        self.suppliedBudget = budget
        self.providerFactory = providerFactory
        let preferences = self.preferences
        preferences.$cloudEnabled.dropFirst().filter { !$0 }.sink { [weak self] _ in self?.invalidateReview("Cloud review disabled. Pending requests were cancelled.") }.store(in: &subscriptions)
        preferences.$fallbackEnabled.dropFirst().filter { !$0 }.sink { [weak self] _ in self?.invalidateReview("Fallback disabled. Choose Review English to start a new review.") }.store(in: &subscriptions)
        preferences.$tone.dropFirst().sink { [weak self] _ in self?.invalidateReview("Tone target changed. Choose Review English to request new suggestions.") }.store(in: &subscriptions)
        preferences.$context.dropFirst().sink { [weak self] _ in self?.invalidateReview("Context changed. Choose Review English to request new suggestions.") }.store(in: &subscriptions)
        preferences.$enabledCategories.dropFirst().sink { [weak self] _ in self?.invalidateReview("Categories changed. Choose Review English to request new suggestions.") }.store(in: &subscriptions)
    }

    private func invalidateReview(_ reason: String) {
        guard document != nil || isReviewing || isApplying else { return }
        clearReview()
        message = reason
        isError = false
    }

    var assembled: String {
        guard let document else { return input }
        return (try? TextRecomposer().recompose(document: document, suggestions: suggestions, acceptedIDs: accepted)) ?? document.original
    }
    var selectedSuggestion: Suggestion? { suggestions.first { $0.id == selectedID } }
    var filteredSuggestions: [Suggestion] { suggestions.filter { filter == nil || $0.category == filter } }
    var canApply: Bool {
        guard captured?.canReplace == true, !accepted.isEmpty, !isReviewing, !isApplying, let document,
              document.original.utf16.elementsEqual(input.utf16) else { return false }
        guard captured?.isLiveCapture != true || accepted.count == 1 else { return false }
        return (try? TextRecomposer().recompose(document: document, suggestions: suggestions, acceptedIDs: accepted)) != nil
    }

    func clearReview() {
        operationID = UUID()
        reviewTask?.cancel()
        reviewTask = nil
        applyTask?.cancel()
        applyTask = nil
        isReviewing = false
        isApplying = false
        document = nil
        suggestions = []
        accepted = []
        ignored = []
        selectedID = nil
        toneAssessment = nil
        requestPreview = ""
        showingRequest = false
        providerDescription = "On demand · No text history"
        isDemo = false
    }

    func editedInput() {
        if document != nil || isReviewing { clearReview() }
        captured = nil
    }

    func receive(_ capture: CapturedText) {
        clearReview()
        input = capture.text
        captured = capture
        message = "Captured from \(capture.sourceApplication). Review changes before applying."
        isError = false
    }

    func showError(_ error: Error) { message = error.localizedDescription; isError = true }

    @discardableResult
    func prepare(forceEnglish: Bool = false) -> WritingReviewRequest? {
        guard !input.isEmpty else { message = "Add text to review."; isError = false; return nil }
        guard input.utf16.count <= 100_000 else { message = "Please review a selection smaller than 100,000 UTF-16 characters."; isError = true; return nil }
        let options = preferences.options(forceEnglish: forceEnglish)
        let prepared = ProtectionEngine().prepare(input, options: options)
        document = prepared
        let request = prepared.request(options: options)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        requestPreview = (try? String(data: encoder.encode(request), encoding: .utf8)) ?? ""
        return request
    }

    func inspectRequest() {
        guard !isReviewing, !isApplying else { return }
        clearReview()
        if prepare() != nil {
            showingRequest = true
            message = "Local inspection only. This is the prose payload; protected ranges and skipped languages are excluded."
            isError = false
        }
    }

    func review(forceEnglish: Bool = false, completion: (@MainActor () -> Void)? = nil) {
        guard !isReviewing, !isApplying else { return }
        defer { if !isReviewing { completion?() } }
        clearReview()
        guard let request = prepare(forceEnglish: forceEnglish), let prepared = document else { return }
        guard !request.segments.isEmpty else {
            message = "No clearly eligible English prose. Text is unchanged; no API request was made."
            isError = false
            return
        }
        guard !request.enabledCategories.isEmpty else { message = "Enable at least one review category."; isError = false; return }
        guard preferences.cloudEnabled else { message = "Cloud review is disabled. Add API keys and enable it in Settings; request inspection and the playground work locally."; isError = false; return }
        do {
            let provider: any LLMProvider
            if let providerFactory { provider = try providerFactory() }
            else {
                let configs = try providerConfigurations()
                guard !configs.isEmpty else { message = "Save an API key in Settings to review this text."; isError = true; return }
                provider = FallbackReviewProvider(configurations: configs, preferred: .deepseek, allowsFallback: preferences.fallbackEnabled, budget: budget)
            }
            let options = preferences.options(forceEnglish: forceEnglish)
            let reviewID = operationID
            isReviewing = true
            message = "Reviewing eligible English prose…"
            isError = false
            reviewTask = Task { [weak self] in
                guard let self else { return }
                do {
                    await self.budget.setLimit(self.preferences.monthlyTokenLimit)
                    let result = try await provider.review(request)
                    try Task.checkCancellation()
                    guard reviewID == self.operationID, self.input.utf16.elementsEqual(prepared.original.utf16) else { return }
                    let validated = try SuggestionValidator().validate(result.response, document: prepared, options: options)
                    self.suggestions = validated.suggestions
                    self.selectedID = validated.suggestions.first?.id
                    self.toneAssessment = validated.toneAssessment
                    self.tokenCount = result.usage.total
                    self.providerDescription = "\(ProviderID(rawValue: result.providerID)?.label ?? result.providerID) · \(result.model)\(result.usedFallback ? " · Fallback used" : "")"
                    self.message = validated.suggestions.isEmpty ? "No validated improvements found. Your original text is unchanged." : "\(validated.suggestions.count) suggestions. Accept each change you want to keep."
                    if validated.rejectedCount > 0 { self.message += " \(validated.rejectedCount) unsafe or ambiguous suggestions were discarded." }
                    self.isError = false
                } catch is CancellationError {
                    guard reviewID == self.operationID else { return }
                    self.message = "Review cancelled. Your text is unchanged."
                    self.isError = false
                } catch {
                    guard reviewID == self.operationID else { return }
                    self.showError(error)
                }
                guard reviewID == self.operationID else { return }
                self.isReviewing = false
                self.reviewTask = nil
                await self.refreshBudget()
                guard reviewID == self.operationID else { return }
                completion?()
            }
        } catch { showError(error) }
    }

    func providerConfigurations() throws -> [ProviderConfiguration] {
        var result: [ProviderConfiguration] = []
        for id in [ProviderID.deepseek, .mistral] {
            guard let key = try keys.get(id.rawValue), !key.isEmpty else { continue }
            let endpointString = id == .deepseek ? preferences.deepseekEndpoint : preferences.mistralEndpoint
            guard let endpoint = URL(string: endpointString), endpoint.scheme == "https", endpoint.host != nil,
                  endpoint.user == nil, endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil else {
                throw AppError.configuration("Use a valid HTTPS completion endpoint without credentials, query, or fragment.")
            }
            let model = (id == .deepseek ? preferences.deepseekModel : preferences.mistralModel).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty else { throw AppError.configuration("A model name is required for each configured provider.") }
            result.append(ProviderConfiguration(id: id, endpoint: endpoint, model: model, apiKey: key, maxOutputTokens: preferences.maxOutputTokens))
        }
        return result
    }

    func siblingModel() -> AppModel {
        AppModel(preferences: preferences, budget: budget, providerFactory: providerFactory, keychainStore: keys)
    }

    func adoptReview(from other: AppModel) {
        clearReview()
        input = other.input
        captured = other.captured
        document = other.document
        suggestions = other.suggestions
        ignored = other.ignored
        selectedID = other.selectedID
        toneAssessment = other.toneAssessment
        providerDescription = other.providerDescription
        message = other.message
        isError = other.isError
    }

    func refreshBudget() async {
        let snapshot = await budget.snapshot()
        budgetDescription = "\(snapshot.usedTokens.formatted()) / \(snapshot.limit.formatted()) tokens this month"
    }

    func isConflicting(_ suggestion: Suggestion) -> Bool {
        suggestions.contains { accepted.contains($0.id) && $0.id != suggestion.id && $0.range.overlaps(suggestion.range) }
    }

    func accept(_ suggestion: Suggestion) {
        guard !isApplying, !isReviewing, !isConflicting(suggestion) else { return }
        ignored.remove(suggestion.id)
        accepted.insert(suggestion.id)
        if captured?.isLiveCapture == true, accepted.count > 1 {
            message = "Apply one live edit at a time to preserve editor formatting. Copy can include all accepted changes."
        }
    }
    func ignore(_ suggestion: Suggestion) { guard !isApplying else { return }; accepted.remove(suggestion.id); ignored.insert(suggestion.id) }
    func undoDecision(_ suggestion: Suggestion) { guard !isApplying else { return }; accepted.remove(suggestion.id); ignored.remove(suggestion.id) }

    func copy() {
        guard !isReviewing, !isApplying else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(assembled, forType: .string)
        message = "Accepted version copied. Nothing was submitted."
        isError = false
    }

    func apply() {
        guard canApply, let captured else { return }
        let replacement = assembled
        let applyID = operationID
        isApplying = true
        applyTask = Task {
            do {
                try await fields.apply(replacement, to: captured)
                guard applyID == operationID else { return }
                self.captured = nil
                self.message = "Accepted changes applied to the original field."
                self.isError = false
            } catch {
                guard applyID == operationID else { return }
                self.captured = nil; self.showError(error)
            }
            isApplying = false
            applyTask = nil
        }
    }

    func cancel() {
        clearReview()
        input = ""
        captured = nil
        message = "Review cleared from memory."
        isError = false
    }

    func playground() {
        cancel()
        input = "He don't know the answer. In order to begin, we need to start the process. The result is good, and the next result is good. Can you fix it?"
        let prepared = PreparedDocument(original: input, protectedSpans: [], segments: [.init(id: "s1", text: input, range: .init(location: 0, length: input.utf16.count))])
        let proposals: [SuggestionProposal] = [
            .init(category: .correctness, source: "don't", replacement: "doesn't", explanation: "Use singular agreement with ‘He’."),
            .init(category: .clarity, source: "In order to begin, we need to start the process.", replacement: "We need to start the process.", explanation: "An optional shorter phrasing removes repetition."),
            .init(category: .engagement, source: "the next result is good", replacement: "the next result is positive", explanation: "An optional vocabulary alternative for this demonstration."),
            .init(category: .delivery, source: "Can you fix it?", replacement: "Could you fix it, please?", explanation: "Optional professional tone. Accept only if it fits your intent.")
        ]
        let options = ReviewOptions(tone: .init(target: .professional))
        do {
            let result = try SuggestionValidator().validate(.init(segments: [.init(id: "s1", suggestions: proposals)], toneAssessment: .init(label: "Possibly direct", note: "This is a local demonstration, not a measured tone assessment.")), document: prepared, options: options)
            document = prepared
            suggestions = result.suggestions
            toneAssessment = result.toneAssessment
            selectedID = suggestions.first?.id
            providerDescription = "Local playground · No API calls"
            message = "Local samples for all four categories, including a Professional tone alternative. No changes are accepted yet."
            isDemo = true
        } catch { showError(error) }
    }
}

enum AppError: LocalizedError {
    case configuration(String)
    var errorDescription: String? { switch self { case .configuration(let reason): reason } }
}
