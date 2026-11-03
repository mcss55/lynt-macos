import AppKit
import ApplicationServices
import Foundation

public enum FocusedFieldEvent {
    case changed(CapturedText)
    case unavailable(TextCaptureError)
}

/// Observes Accessibility changes for the frontmost application while automatic
/// review is enabled. No keyboard event taps, clipboard reads, window-tree walks,
/// or network calls are used. A bounded fallback poll covers editors that omit AX
/// value notifications, and only the current focused editable field is sampled.
@MainActor
public final class FocusedFieldMonitor {
    private let service: FocusedFieldService
    private let onChange: @MainActor (FocusedFieldEvent) -> Void
    private var observer: AXObserver?
    private var observedPID: pid_t?
    private var observedElement: AXUIElement?
    private var workspaceToken: NSObjectProtocol?
    private var timer: Timer?
    private var pendingCapture: Task<Void, Never>?
    private var lastCapture: CapturedText?
    private var lastError: TextCaptureError?
    public private(set) var isRunning = false
    /// Exclusions are tested before field contents are read.
    public var excludedBundleIdentifiers: Set<String> = [] { didSet { refresh() } }

    public init(service: FocusedFieldService, onChange: @escaping @MainActor (FocusedFieldEvent) -> Void) {
        self.service = service
        self.onChange = onChange
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        workspaceToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        let timer = Timer(timeInterval: 0.65, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    public func stop() {
        isRunning = false
        pendingCapture?.cancel()
        pendingCapture = nil
        timer?.invalidate()
        timer = nil
        if let workspaceToken { NSWorkspace.shared.notificationCenter.removeObserver(workspaceToken) }
        workspaceToken = nil
        detachObserver()
        lastCapture = nil
        lastError = nil
    }

    /// Useful after an explicit apply/pause change. It never prompts for permission.
    public func refresh() {
        guard isRunning else { return }
        updateObserver()
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            // The suggestion HUD can become frontmost without the user leaving the editor.
            return
        }
        if let bundleID = front?.bundleIdentifier, excludedBundleIdentifiers.contains(bundleID) {
            emitUnavailable(.excludedApplication)
            return
        }
        do {
            let current = try service.captureLive()
            observeFocusedElement(current.element)
            let changed = lastCapture.map {
                $0.targetID != current.targetID || !$0.text.utf16.elementsEqual(current.text.utf16) || $0.sourceBounds != current.sourceBounds
            } ?? true
            lastCapture = current
            lastError = nil
            if changed { onChange(.changed(current)) }
        } catch {
            removeFocusedElementNotifications()
            emitUnavailable(error as? TextCaptureError ?? .unsupportedField)
        }
    }

    private func scheduleCapture() {
        guard isRunning else { return }
        pendingCapture?.cancel()
        pendingCapture = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            guard let self, !Task.isCancelled, self.isRunning else { return }
            self.refresh()
        }
    }

    private func emitUnavailable(_ issue: TextCaptureError) {
        let changed = lastCapture != nil || lastError != issue
        lastCapture = nil
        lastError = issue
        if changed {
            if ProcessInfo.processInfo.arguments.contains("--live-smoke-test") {
                print("[Lynt AX smoke] unavailable=\(issue)")
                fflush(stdout)
            }
            onChange(.unavailable(issue))
        }
    }

    private func updateObserver() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard service.isAccessibilityTrusted,
              let source = NSWorkspace.shared.frontmostApplication,
              !excludedBundleIdentifiers.contains(source.bundleIdentifier ?? ""),
              source.processIdentifier != ownPID else {
            detachObserver()
            return
        }
        let pid = source.processIdentifier
        guard observedPID != pid else { return }
        detachObserver()
        var created: AXObserver?
        let result = AXObserverCreate(pid, { _, _, _, refcon in
            guard let refcon else { return }
            let instance = Unmanaged<FocusedFieldMonitor>.fromOpaque(refcon).takeUnretainedValue()
            // This source is installed only on the main run loop.
            MainActor.assumeIsolated { instance.scheduleCapture() }
        }, &created)
        observedPID = pid
        guard result == .success, let created else { return }
        observer = created
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.25)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for notification in [kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification,
                             kAXValueChangedNotification, kAXSelectedTextChangedNotification,
                             kAXUIElementDestroyedNotification, kAXWindowMovedNotification,
                             kAXWindowResizedNotification] {
            // Unsupported notifications are expected. The focused-only fallback
            // poll remains available instead of assuming all editors post them.
            _ = AXObserverAddNotification(created, application, notification as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
    }

    private func detachObserver() {
        removeFocusedElementNotifications()
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil
        observedPID = nil
    }

    private func observeFocusedElement(_ element: AXUIElement) {
        guard let observer else { return }
        if let observedElement, CFEqual(observedElement, element) { return }
        removeFocusedElementNotifications()
        observedElement = element
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for notification in [kAXValueChangedNotification, kAXSelectedTextChangedNotification, kAXUIElementDestroyedNotification] {
            _ = AXObserverAddNotification(observer, element, notification as CFString, refcon)
        }
    }

    private func removeFocusedElementNotifications() {
        if let observer, let observedElement {
            for notification in [kAXValueChangedNotification, kAXSelectedTextChangedNotification, kAXUIElementDestroyedNotification] {
                _ = AXObserverRemoveNotification(observer, observedElement, notification as CFString)
            }
        }
        observedElement = nil
    }

    deinit {
        pendingCapture?.cancel()
        timer?.invalidate()
        if let workspaceToken { NSWorkspace.shared.notificationCenter.removeObserver(workspaceToken) }
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
    }
}
