import SwiftUI
import AppKit
import LyntPlatform
import LyntCore

@main
struct LyntApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        MenuBarExtra("Lynt", systemImage: "text.badge.checkmark") {
            LyntMenu(delegate: delegate, preferences: delegate.model.preferences, automatic: delegate.automatic)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model: AppModel
    lazy var automatic = AutomaticReviewController(model: model.siblingModel())
    private var reviewWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var shortcut: GlobalShortcut?
    private var floating: FloatingSuggestions?
    private let smokeDomain: String?

    override init() {
        if ProcessInfo.processInfo.arguments.contains("--live-smoke-test") {
            let domain = "com.lynt.live-smoke.\(ProcessInfo.processInfo.processIdentifier)"
            smokeDomain = domain
            let preferences = Preferences(defaults: UserDefaults(suiteName: domain)!)
            preferences.cloudEnabled = true
            preferences.automaticReviewEnabled = true
            model = AppModel(preferences: preferences, budget: TokenBudget(monthlyLimit: 100_000),
                             providerFactory: { LiveSmokeProvider() }, keychainStore: .init(service: domain))
        } else {
            smokeDomain = nil
            model = AppModel()
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        shortcut = GlobalShortcut { [weak self] in self?.reviewFocusedText() }
        updateShortcut()
        floating = FloatingSuggestions(controller: automatic)
        automatic.presentationChanged = { [weak self] in self?.floating?.update() }
        automatic.openSettings = { [weak self] in self?.showSettings() }
        automatic.openFullReview = { [weak self] in
            guard let self else { return }
            self.model.adoptReview(from: self.automatic.model)
            self.showReview()
        }
        automatic.refreshConfiguration()
        if !model.preferences.cloudEnabled || !model.fields.isAccessibilityTrusted { showReview() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showReview()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        shortcut?.unregister()
        automatic.stop()
        floating?.hide()
        model.cancel()
        if let smokeDomain { UserDefaults.standard.removePersistentDomain(forName: smokeDomain) }
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === reviewWindow { model.cancel() }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.reviewWindow?.isVisible != true, self.settingsWindow?.isVisible != true else { return }
            self.automatic.resumeAfterWindow()
        }
    }

    func showReview() {
        automatic.suspendForWindow()
        if reviewWindow == nil {
            let view = ReviewView(model: model, preferences: model.preferences, showSettings: { [weak self] in self?.showSettings() })
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Lynt · Review English"
            window.contentView = NSHostingView(rootView: view)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            reviewWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        reviewWindow?.makeKeyAndOrderFront(nil)
    }

    func showSettings() {
        automatic.suspendForWindow()
        if settingsWindow == nil {
            let view = SettingsView(model: model, preferences: model.preferences, updateShortcut: { [weak self] in self?.updateShortcut() })
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 630, height: 760), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Lynt Settings"
            window.contentView = NSHostingView(rootView: view)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func reviewFocusedText(forceEnglish: Bool = false) {
        model.clearReview()
        model.captured = nil
        do {
            let capture = try model.fields.capture()
            model.receive(capture)
            showReview()
            model.review(forceEnglish: forceEnglish)
        } catch { model.showError(error); showReview() }
    }

    func updateShortcut() {
        do {
            try shortcut?.register(Shortcut(keyCode: model.preferences.shortcutKey, modifiers: .init(rawValue: model.preferences.shortcutModifiers)))
            model.message = "Shortcut registered: \(shortcut?.registeredShortcut?.display ?? "⌘⇧G")."
            model.isError = false
        } catch { model.showError(error) }
    }
}

private struct LyntMenu: View {
    let delegate: AppDelegate
    @ObservedObject var preferences: Preferences
    @ObservedObject var automatic: AutomaticReviewController

    var body: some View {
        Toggle("Automatic suggestions after typing", isOn: $preferences.automaticReviewEnabled)
        Text(automatic.status).font(.caption)
        if let source = automatic.snapshot?.sourceApplication {
            Button("Pause in \(source)") { automatic.pauseCurrentApplication() }
        }
        Divider()
        Button("Review focused field now") { delegate.reviewFocusedText() }
        Button("Review as English") { delegate.reviewFocusedText(forceEnglish: true) }
        Divider()
        Button("Paste / Open review") { delegate.showReview() }
        Button("Local playground") { delegate.model.playground(); delegate.showReview() }
        Button("Settings…") { delegate.showSettings() }.keyboardShortcut(",")
        Divider()
        Button("Quit Lynt") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
    }
}
