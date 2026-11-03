import CryptoKit
import Foundation

/// A local-only identity for an automatic review. The digest is never a provider payload.
/// Length-prefixed UTF-16 preserves distinctions that Swift's canonical String equality ignores.
public enum AutomaticReviewFingerprint {
    public static func make(scopeID: String, text: String, options: ReviewOptions) -> String {
        var bytes = Data()
        append(scopeID, to: &bytes)
        append(text, to: &bytes)
        append(options.contextKind.rawValue, to: &bytes)
        append(options.tone.target.rawValue, to: &bytes)
        append(options.tone.detect ? "detect" : "no-detect", to: &bytes)
        append(options.forceEnglish ? "override" : "automatic-language", to: &bytes)
        for category in options.enabledCategories.map(\.rawValue).sorted() {
            append(category, to: &bytes)
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static func append(_ value: String, to bytes: inout Data) {
        var length = UInt64(value.utf16.count).bigEndian
        withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
        for unit in value.utf16 {
            var encoded = unit.bigEndian
            withUnsafeBytes(of: &encoded) { bytes.append(contentsOf: $0) }
        }
    }
}

/// Main-actor UI orchestration supplies the debounce, captures, and cancellable tasks.
/// This value type independently enforces deduplication, one active review, and a rolling cap.
/// A cancelled or failed attempt stays suppressed until the text/options/scope fingerprint changes.
public struct AutomaticReviewPolicy: Sendable {
    public enum Decision: Equatable, Sendable {
        case allowed
        case duplicate
        case inFlight
        case throttled(retryAfter: TimeInterval)
    }

    public private(set) var activeFingerprint: String?
    public let minimumInterval: TimeInterval
    public let maxRequestsPerMinute: Int
    public let historyLimit: Int
    private var lastAttempt: Date?
    private var recentAttempts: [Date] = []
    private var suppressed: Set<String> = []
    private var suppressionOrder: [String] = []

    public init(minimumInterval: TimeInterval = 4,
                maxRequestsPerMinute: Int = 8,
                historyLimit: Int = 128) {
        self.minimumInterval = minimumInterval.isFinite ? max(0, minimumInterval) : 4
        self.maxRequestsPerMinute = max(1, maxRequestsPerMinute)
        self.historyLimit = max(1, historyLimit)
    }

    /// Call after ProtectionEngine and LanguageGate. This never overrides their decisions.
    /// Short eligible English is useful too: "I is sad" must not be rejected by a second word cap.
    public static func eligible(request: WritingReviewRequest) -> Bool {
        !request.enabledCategories.isEmpty && !request.segments.isEmpty &&
        request.segments.allSatisfy { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// A throttled candidate is not remembered, so the caller can retry it after the returned delay.
    /// Attempt timestamps count review invocations; provider fallback remains one such invocation.
    @discardableResult
    public mutating func begin(fingerprint: String, now: Date = Date()) -> Decision {
        guard activeFingerprint == nil else { return .inFlight }
        guard !fingerprint.isEmpty, !suppressed.contains(fingerprint) else { return .duplicate }
        recentAttempts.removeAll { now.timeIntervalSince($0) >= 60 }
        let intervalDelay = lastAttempt.map { max(0, minimumInterval - now.timeIntervalSince($0)) } ?? 0
        let rateDelay: TimeInterval
        if recentAttempts.count >= maxRequestsPerMinute {
            rateDelay = max(0, 60 - now.timeIntervalSince(recentAttempts[recentAttempts.count - maxRequestsPerMinute]))
        } else { rateDelay = 0 }
        let delay = max(intervalDelay, rateDelay)
        guard delay <= 0 else { return .throttled(retryAfter: delay) }
        activeFingerprint = fingerprint
        lastAttempt = now
        recentAttempts.append(now)
        suppress(fingerprint: fingerprint)
        return .allowed
    }

    /// A late completion from a cancelled request cannot release a newer request's active slot.
    public mutating func complete(fingerprint: String) {
        if activeFingerprint == fingerprint { activeFingerprint = nil }
    }

    /// Use for dismiss/Ignore/Cancel even if no provider request has started.
    public mutating func suppress(fingerprint: String) {
        guard !fingerprint.isEmpty, suppressed.insert(fingerprint).inserted else { return }
        suppressionOrder.append(fingerprint)
        if suppressionOrder.count > historyLimit {
            suppressed.remove(suppressionOrder.removeFirst())
        }
    }

    /// Cancel the associated Task separately. A slot release never makes the same text retryable.
    public mutating func cancelInFlight() { activeFingerprint = nil }

    /// Session reset, intended for a fresh monitoring session rather than each focus event.
    public mutating func reset() {
        activeFingerprint = nil
        lastAttempt = nil
        recentAttempts = []
        suppressed = []
        suppressionOrder = []
    }
}
