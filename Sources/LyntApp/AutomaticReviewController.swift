import AppKit
import Combine
import LyntCore
import LyntPlatform

/// Observes only the focused editable field; never registers a keyboard listener.
@MainActor
final class AutomaticReviewController: ObservableObject {
    let model: AppModel
    let preferences: Preferences
    @Published private(set) var status = "Automatic review is starting…" {
        didSet {
            if ProcessInfo.processInfo.arguments.contains("--live-smoke-test") {
                // Test-mode diagnostics contain state/app labels only, never document text or keys.
                print("[Lynt smoke] \(status)")
                fflush(stdout)
            }
        }
    }
    @Published private(set) var shouldShow = false
    @Published private(set) var snapshot: CapturedText?
    @Published private(set) var isApplying = false
    @Published private(set) var errorMessage: String?
    var presentationChanged: (() -> Void)?
    var openFullReview: (() -> Void)?
    var openSettings: (() -> Void)?

    private lazy var monitor = FocusedFieldMonitor(service: model.fields) { [weak self] in self?.handle($0) }
    private var policy = AutomaticReviewPolicy()
    private var debounceTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?
    private var generation = UUID()
    private var fingerprint: String?
    private var pausedForWindow = false
    private var awaitingWriteAcknowledgment = false
    private var subscriptions = Set<AnyCancellable>()

    var visibleSuggestions: [Suggestion] { model.suggestions.filter { !model.ignored.contains($0.id) } }

    init(model: AppModel) {
        self.model = model
        self.preferences = model.preferences
        preferences.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshConfiguration() }
        }.store(in: &subscriptions)
    }

    func refreshConfiguration() {
        monitor.stop()
        invalidate()
        monitor.excludedBundleIdentifiers = preferences.excludedApplications
        guard preferences.automaticReviewEnabled else { status = "Automatic review paused"; return }
        guard preferences.cloudEnabled else { status = "Automatic review needs cloud review enabled"; return }
        guard !pausedForWindow else { status = "Automatic review paused while Lynt is open"; return }
        status = model.fields.isAccessibilityTrusted ? "Automatic review ready" : "Accessibility access is needed"
        monitor.start()
    }

    func suspendForWindow() { pausedForWindow = true; refreshConfiguration() }
    func resumeAfterWindow() { pausedForWindow = false; refreshConfiguration() }

    func stop() {
        monitor.stop()
        invalidate()
    }

    private func invalidate() {
        generation = UUID()
        debounceTask?.cancel()
        debounceTask = nil
        writeTask?.cancel()
        writeTask = nil
        policy.cancelInFlight()
        model.cancel()
        snapshot = nil
        fingerprint = nil
        isApplying = false
        errorMessage = nil
        awaitingWriteAcknowledgment = false
        shouldShow = false
        presentationChanged?()
    }

    private func handle(_ event: FocusedFieldEvent) {
        guard preferences.automaticReviewEnabled, preferences.cloudEnabled, !pausedForWindow, !isApplying else { return }
        switch event {
        case .changed(let capture):
            let key = AutomaticReviewFingerprint.make(scopeID: capture.targetID, text: capture.text, options: preferences.options(forceEnglish: false))
            if awaitingWriteAcknowledgment, snapshot?.targetID == capture.targetID {
                snapshot = capture
                fingerprint = key
                policy.suppress(fingerprint: key)
                presentationChanged?()
                return
            }
            if key == fingerprint, snapshot != nil {
                snapshot = capture
                presentationChanged?()
                return
            }
            schedule(capture, fingerprint: key, delay: preferences.reviewDelaySeconds)
        case .unavailable(let reason):
            if FloatingSuggestionRetention.shouldIgnoreUnavailable(
                reason, presenting: shouldShow, frontmostIsSelf: Self.isOwnApplicationFrontmost()
            ) { return }
            invalidate()
            switch reason {
            case .permissionRequired: status = "Accessibility access is needed"
            case .excludedApplication: status = "Automatic review paused in this application"
            case .secureField: status = "Secure field · automatic review skipped"
            case .noExternalField: status = "Automatic review ready"
            default: status = "Waiting for a supported editable field"
            }
        }
    }

    private func schedule(_ capture: CapturedText, fingerprint key: String, delay: Double) {
        invalidate()
        snapshot = capture
        fingerprint = key
        status = "\(capture.sourceApplication) · waiting for typing to pause"
        let token = generation
        debounceTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0.05, delay))) }
            catch { return }
            guard let self, token == self.generation, !Task.isCancelled else { return }
            guard self.model.fields.isStableLiveTarget(capture) else {
                // Drop the pending fingerprint so the next poll can reschedule.
                // A failed isCurrent-style gate used to leave us stuck on the same text.
                self.fingerprint = nil
                self.snapshot = nil
                self.status = "\(capture.sourceApplication) · waiting for a stable editable field"
                return
            }
            let text = capture.text
            let options = self.preferences.options(forceEnglish: false)
            let prepared = await Task.detached(priority: .utility) { ProtectionEngine().prepare(text, options: options) }.value
            guard token == self.generation, !Task.isCancelled else { return }
            guard self.model.fields.isStableLiveTarget(capture) else {
                self.fingerprint = nil
                self.snapshot = nil
                self.status = "\(capture.sourceApplication) · waiting for a stable editable field"
                return
            }
            guard AutomaticReviewPolicy.eligible(request: prepared.request(options: options)) else {
                self.status = "\(capture.sourceApplication) · no eligible English prose"
                return
            }
            switch self.policy.begin(fingerprint: key) {
            case .allowed:
                self.status = "\(capture.sourceApplication) · checking English"
                self.model.receive(capture)
                self.shouldShow = true
                self.model.review { [weak self] in self?.finished(capture, fingerprint: key, generation: token) }
                self.presentationChanged?()
            case .duplicate:
                self.status = "\(capture.sourceApplication) · this version was already reviewed"
            case .inFlight:
                self.status = "Finishing the current review"
            case .throttled(let retryAfter):
                self.schedule(capture, fingerprint: key, delay: max(retryAfter, 0.1))
                self.status = "Waiting briefly to limit API usage"
            }
        }
    }

    private func finished(_ capture: CapturedText, fingerprint key: String, generation token: UUID) {
        guard token == generation else { return }
        policy.complete(fingerprint: key)
        guard preferences.automaticReviewEnabled, preferences.cloudEnabled, !pausedForWindow,
              shouldKeepPresentedResults(for: capture) else {
            invalidate()
            monitor.refresh()
            return
        }
        if snapshot?.targetID != capture.targetID { snapshot = capture }
        errorMessage = model.isError ? model.message : nil
        shouldShow = !visibleSuggestions.isEmpty || errorMessage != nil
        status = model.isError ? "Automatic review needs attention" : "\(capture.sourceApplication) · \(visibleSuggestions.count) suggestions"
        presentationChanged?()
    }

    func dismiss() {
        if let fingerprint { policy.suppress(fingerprint: fingerprint) }
        invalidate()
        status = "Dismissed until the text changes"
    }

    func ignore(_ suggestion: Suggestion) {
        model.ignore(suggestion)
        shouldShow = !visibleSuggestions.isEmpty
        presentationChanged?()
    }

    func pauseCurrentApplication() {
        guard let id = snapshot?.sourceBundleIdentifier else { return }
        preferences.excludedApplications.insert(id)
    }

    func apply(_ suggestion: Suggestion) {
        guard !isApplying, let original = model.document, let capture = snapshot,
              capture.canReplace, shouldKeepPresentedResults(for: capture) else {
            invalidate()
            status = "The field changed; waiting for a fresh review"
            monitor.refresh()
            return
        }
        do {
            let rebased = try SuggestionRebaser().rebase(document: original, suggestions: visibleSuggestions,
                                                       appliedID: suggestion.id, options: preferences.options(forceEnglish: false))
            let previousProvider = model.providerDescription
            let previousTone = model.toneAssessment
            let token = generation
            isApplying = true
            monitor.stop()
            writeTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.model.fields.apply(rebased.document.original, to: capture)
                    try Task.checkCancellation()
                    guard token == self.generation else { return }
                    let updated = try self.model.fields.recaptureSameTarget(from: capture)
                    guard updated.targetID == capture.targetID,
                          updated.text.utf16.elementsEqual(rebased.document.original.utf16) else { throw TextCaptureError.targetChanged }
                    self.model.receive(updated)
                    self.model.document = rebased.document
                    self.model.suggestions = rebased.validation.suggestions
                    self.model.selectedID = self.model.suggestions.first?.id
                    self.model.providerDescription = previousProvider
                    self.model.toneAssessment = previousTone
                    self.snapshot = updated
                    let key = AutomaticReviewFingerprint.make(scopeID: updated.targetID, text: updated.text, options: self.preferences.options(forceEnglish: false))
                    self.fingerprint = key
                    self.policy.suppress(fingerprint: key)
                    self.status = "Applied · \(self.visibleSuggestions.count) suggestions remain"
                    self.shouldShow = !self.visibleSuggestions.isEmpty
                } catch {
                    guard token == self.generation else { return }
                    // Keep the reviewed suggestions so the user can open Review / Copy.
                    self.errorMessage = error.localizedDescription
                    self.awaitingWriteAcknowledgment = false
                    self.status = "Replacement was not confirmed; use Review / Copy if needed"
                    self.shouldShow = true
                }
                self.isApplying = false
                self.writeTask = nil
                self.presentationChanged?()
                self.monitor.start()
            }
        } catch { errorMessage = error.localizedDescription; shouldShow = true; presentationChanged?() }
    }

    private func shouldKeepPresentedResults(for capture: CapturedText) -> Bool {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier == ProcessInfo.processInfo.processIdentifier { return true }
        return model.fields.isStableLiveTarget(capture)
    }

    private static func isOwnApplicationFrontmost() -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
    }
}

enum FloatingSuggestionRetention {
    /// The HUD can make Lynt frontmost; that is not the user leaving the editor.
    static func shouldIgnoreUnavailable(_ reason: TextCaptureError, presenting: Bool, frontmostIsSelf: Bool) -> Bool {
        presenting && frontmostIsSelf && reason == .noExternalField
    }
}
