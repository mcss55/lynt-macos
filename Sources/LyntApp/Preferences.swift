import Foundation
import Combine
import LyntCore

@MainActor
final class Preferences: ObservableObject {
    private let defaults: UserDefaults
    @Published var cloudEnabled: Bool { didSet { defaults.set(cloudEnabled, forKey: "cloudEnabled") } }
    @Published var fallbackEnabled: Bool { didSet { defaults.set(fallbackEnabled, forKey: "fallbackEnabled") } }
    @Published var automaticReviewEnabled: Bool { didSet { defaults.set(automaticReviewEnabled, forKey: "automaticReviewEnabled") } }
    @Published var reviewDelaySeconds: Double { didSet { defaults.set(reviewDelaySeconds, forKey: "reviewDelaySeconds") } }
    @Published var excludedApplications: Set<String> { didSet { defaults.set(Array(excludedApplications).sorted(), forKey: "excludedApplications") } }
    @Published var enabledCategories: Set<SuggestionCategory> { didSet { defaults.set(enabledCategories.map(\.rawValue), forKey: "categories") } }
    @Published var tone: ToneTarget { didSet { defaults.set(tone.rawValue, forKey: "tone") } }
    @Published var context: ContextKind { didSet { defaults.set(context.rawValue, forKey: "context") } }
    @Published var monthlyTokenLimit: Int { didSet { defaults.set(monthlyTokenLimit, forKey: "monthlyTokenLimit") } }
    @Published var maxOutputTokens: Int { didSet { defaults.set(maxOutputTokens, forKey: "maxOutputTokens") } }
    @Published var deepseekModel: String { didSet { defaults.set(deepseekModel, forKey: "deepseekModel") } }
    @Published var mistralModel: String { didSet { defaults.set(mistralModel, forKey: "mistralModel") } }
    @Published var deepseekEndpoint: String { didSet { defaults.set(deepseekEndpoint, forKey: "deepseekEndpoint") } }
    @Published var mistralEndpoint: String { didSet { defaults.set(mistralEndpoint, forKey: "mistralEndpoint") } }
    @Published var shortcutKey: UInt32 { didSet { defaults.set(Int(shortcutKey), forKey: "shortcutKey") } }
    @Published var shortcutModifiers: UInt32 { didSet { defaults.set(Int(shortcutModifiers), forKey: "shortcutModifiers") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        cloudEnabled = defaults.bool(forKey: "cloudEnabled")
        fallbackEnabled = defaults.object(forKey: "fallbackEnabled") as? Bool ?? true
        automaticReviewEnabled = defaults.object(forKey: "automaticReviewEnabled") as? Bool ?? true
        reviewDelaySeconds = min(5, max(0.8, defaults.object(forKey: "reviewDelaySeconds") as? Double ?? 1.2))
        excludedApplications = Set(defaults.stringArray(forKey: "excludedApplications") ?? [])
        enabledCategories = defaults.stringArray(forKey: "categories").map { Set($0.compactMap(SuggestionCategory.init(rawValue:))) } ?? Set(SuggestionCategory.allCases)
        tone = ToneTarget(rawValue: defaults.string(forKey: "tone") ?? "") ?? .preserve
        context = ContextKind(rawValue: defaults.string(forKey: "context") ?? "") ?? .prompt
        monthlyTokenLimit = defaults.object(forKey: "monthlyTokenLimit") as? Int ?? 100_000
        maxOutputTokens = defaults.object(forKey: "maxOutputTokens") as? Int ?? 1_600
        deepseekModel = defaults.string(forKey: "deepseekModel") ?? "deepseek-flash"
        mistralModel = defaults.string(forKey: "mistralModel") ?? "ministral-3b-2512"
        deepseekEndpoint = defaults.string(forKey: "deepseekEndpoint") ?? "https://api.deepseek.com/chat/completions"
        mistralEndpoint = defaults.string(forKey: "mistralEndpoint") ?? "https://api.mistral.ai/v1/chat/completions"
        shortcutKey = UInt32(clamping: defaults.object(forKey: "shortcutKey") as? Int ?? 5)
        shortcutModifiers = UInt32(clamping: defaults.object(forKey: "shortcutModifiers") as? Int ?? 768)
    }

    func options(forceEnglish: Bool) -> ReviewOptions {
        ReviewOptions(enabledCategories: enabledCategories, tone: .init(target: tone), contextKind: context, forceEnglish: forceEnglish)
    }
}
