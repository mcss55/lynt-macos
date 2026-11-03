import AppKit
import ApplicationServices
import Foundation

/// An ephemeral snapshot. Do not persist this object or include it in provider requests.
@MainActor
public struct CapturedText {
    public let text: String
    public let canReplace: Bool
    public let sourceApplication: String
    /// Ephemeral identity only; never contains source text.
    public let targetID: String
    public let sourceBundleIdentifier: String?
    /// Accessibility screen coordinates: origin at the upper-left of the main screen.
    public let sourceBounds: CGRect?
    public let isLiveCapture: Bool
    let processID: pid_t
    let application: AXUIElement
    let element: AXUIElement
    let window: AXUIElement?
    let fullValue: String?
    let selectedRange: CFRange?
    let selectedText: String?
    let strategy: WriteStrategy?
}

enum WriteStrategy: Equatable {
    case selectedText
    case fullValue
    case liveRange
}

/// Prefer whole-value writes for standard form controls. Chromium often advertises
/// selected-range APIs as settable without honoring them, which produced false
/// "target changed" failures on Accept & apply for input/textarea fields.
func liveWriteStrategy(role: String, hasWindow: Bool, valueSettable: Bool,
                       selectedRangeSettable: Bool, selectedTextSettable: Bool,
                       selectionValid: Bool) -> WriteStrategy? {
    guard hasWindow else { return nil }
    if valueSettable,
       [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String].contains(role) {
        return .fullValue
    }
    if selectionValid, selectedRangeSettable, selectedTextSettable {
        return .liveRange
    }
    return nil
}

@MainActor
public final class FocusedFieldService {
    private var primedProcesses: Set<String> = []
    private var smokeDiagnostics: [String: String] = [:]
    public init() {}

    public var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// Call only after an explicit user action. Opening the app never prompts.
    @discardableResult
    public func requestAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    public func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    public func capture() throws -> CapturedText {
        guard isAccessibilityTrusted else { throw TextCaptureError.permissionRequired }
        guard let source = NSWorkspace.shared.frontmostApplication,
              source.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            throw TextCaptureError.noExternalField
        }
        let application = AXUIElementCreateApplication(source.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.25)
        primeChromiumAccessibility(source, application: application)
        let element = try focusedEditableElement(in: application)
        let role = stringAttribute(element, kAXRoleAttribute)

        let selectedText = stringAttribute(element, kAXSelectedTextAttribute)
        let selectedRange = rangeAttribute(element, kAXSelectedTextRangeAttribute)
        let window = elementAttribute(element, kAXWindowAttribute) ?? elementAttribute(application, kAXFocusedWindowAttribute)
        let hasReportedSelection = !(selectedText ?? "").isEmpty || (selectedRange?.length ?? 0) > 0
        let canAttemptSelectedWrite = !(selectedText ?? "").isEmpty && (selectedRange?.length ?? 0) > 0 && window != nil && isSettable(element, kAXSelectedTextAttribute)
        // Prefer the selected text even when the editor does not expose offsets.
        // Read surrounding field contents only to derive an otherwise unreadable
        // selection, capture the explicitly requested whole field, or retain a
        // local safety snapshot for a possible replacement. Copy-only selections
        // with readable text do not need the surrounding value.
        let needsValue = !hasReportedSelection || (selectedText ?? "").isEmpty || canAttemptSelectedWrite
        let fullValue = needsValue ? stringAttribute(element, kAXValueAttribute) : nil
        let effectiveSelection: String? = {
            if let selectedText, !selectedText.isEmpty { return selectedText }
            if let selectedRange, selectedRange.length > 0, let fullValue {
                return substring(fullValue, selectedRange)
            }
            return nil
        }()
        let hasSelection = !(effectiveSelection ?? "").isEmpty
        let text: String
        if hasSelection {
            text = effectiveSelection!
        } else {
            guard !hasReportedSelection else { throw TextCaptureError.unreadableField }
            guard let fullValue else { throw TextCaptureError.unreadableField }
            text = fullValue
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TextCaptureError.emptyField
        }
        guard text.utf16.count <= 200_000 else { throw TextCaptureError.fieldTooLarge }

        var strategy: WriteStrategy?
        if let fullValue, let selectedRange, window != nil,
           rangeIsValid(selectedRange, in: fullValue) {
            if hasSelection,
               exactTextMatch(substring(fullValue, selectedRange), selectedText),
               isSettable(element, kAXSelectedTextAttribute) {
                strategy = .selectedText
            } else if !hasSelection, selectedRange.length == 0,
                      [kAXTextFieldRole as String, kAXComboBoxRole as String].contains(role ?? ""),
                      isSettable(element, kAXValueAttribute) {
                // Whole-value writes to rich/multiline editors can discard their
                // internal formatting. Those surfaces remain Copy only unless
                // a selected-text replacement is available.
                strategy = .fullValue
            }
        }

        return CapturedText(text: text, canReplace: strategy != nil,
                            sourceApplication: source.localizedName ?? "Source application",
                            targetID: targetIdentity(processID: source.processIdentifier, element: element, window: window),
                            sourceBundleIdentifier: source.bundleIdentifier, sourceBounds: bounds(of: element), isLiveCapture: false,
                            processID: source.processIdentifier, application: application,
                            element: element, window: window, fullValue: fullValue,
                            selectedRange: selectedRange, selectedText: selectedText, strategy: strategy)
    }

    /// Called only while the user-enabled automatic mode is running. Reads the focused
    /// editable field, never an arbitrary window or surrounding page contents.
    public func captureLive() throws -> CapturedText {
        guard isAccessibilityTrusted else { throw TextCaptureError.permissionRequired }
        guard let source = NSWorkspace.shared.frontmostApplication,
              source.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            throw TextCaptureError.noExternalField
        }
        let application = AXUIElementCreateApplication(source.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.25)
        primeChromiumAccessibility(source, application: application)
        let element = try focusedEditableElement(in: application)
        let explicitlyEditable = boolAttribute(element, "AXEditable")
        let valueSettable = isSettable(element, kAXValueAttribute)
        let selectedTextSettable = isSettable(element, kAXSelectedTextAttribute)
        smokeDiagnostic("Live field role=\(stringAttribute(element, kAXRoleAttribute) ?? "unknown") editable=\(String(describing: explicitlyEditable)) valueWritable=\(valueSettable) selectedTextWritable=\(selectedTextSettable)", category: "field-evidence")
        guard hasAutomaticEditingEvidence(explicitlyEditable: explicitlyEditable,
                                          valueSettable: valueSettable,
                                          selectedTextSettable: selectedTextSettable) else {
            throw TextCaptureError.unsupportedField
        }
        guard let value = stringAttribute(element, kAXValueAttribute) else { throw TextCaptureError.unreadableField }
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TextCaptureError.emptyField }
        guard value.utf16.count <= 20_000 else { throw TextCaptureError.fieldTooLarge }
        let window = elementAttribute(element, kAXWindowAttribute) ?? elementAttribute(application, kAXFocusedWindowAttribute)
        let selection = rangeAttribute(element, kAXSelectedTextRangeAttribute)
        let selectedText = stringAttribute(element, kAXSelectedTextAttribute)
        let role = stringAttribute(element, kAXRoleAttribute) ?? ""
        let strategy = liveWriteStrategy(
            role: role, hasWindow: window != nil, valueSettable: isSettable(element, kAXValueAttribute),
            selectedRangeSettable: isSettable(element, kAXSelectedTextRangeAttribute),
            selectedTextSettable: isSettable(element, kAXSelectedTextAttribute),
            selectionValid: selection.map { rangeIsValid($0, in: value) } == true
        )
        smokeDiagnostic("Live write strategy=\(String(describing: strategy)) role=\(role)", category: "write-strategy")
        return CapturedText(text: value, canReplace: strategy != nil,
                            sourceApplication: source.localizedName ?? "Source application",
                            targetID: targetIdentity(processID: source.processIdentifier, element: element, window: window),
                            sourceBundleIdentifier: source.bundleIdentifier, sourceBounds: bounds(of: element), isLiveCapture: true,
                            processID: source.processIdentifier, application: application, element: element,
                            window: window, fullValue: value, selectedRange: selection,
                            selectedText: selectedText, strategy: strategy)
    }

    /// The original element's UTF-16 value, independent of which app is frontmost.
    /// Used while the suggestion HUD is visible so Lynt becoming frontmost does not
    /// discard an otherwise unchanged field.
    public func hasUnchangedLiveValue(_ snapshot: CapturedText) -> Bool {
        guard isAccessibilityTrusted else { return false }
        return exactTextMatch(stringAttribute(snapshot.element, kAXValueAttribute), snapshot.fullValue ?? snapshot.text)
    }

    /// Debounce/completion gate for automatic review. Requires the source app to be
    /// frontmost and the captured element to still hold the same UTF-16 value.
    /// Unlike `isCurrent`, it does not require the AX focused-element/window objects
    /// to compare equal — Electron/Chrome often replace those identities while typing.
    public func isStableLiveTarget(_ snapshot: CapturedText) -> Bool {
        guard isAccessibilityTrusted else { return false }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.processID else { return false }
        return hasUnchangedLiveValue(snapshot)
    }

    /// Re-read the same captured element after a confirmed write. Does not require that
    /// element to be the current focused UI element, so a HUD click cannot invalidate it.
    public func recaptureSameTarget(from snapshot: CapturedText) throws -> CapturedText {
        guard isAccessibilityTrusted else { throw TextCaptureError.permissionRequired }
        guard let source = NSRunningApplication(processIdentifier: snapshot.processID), !source.isTerminated else {
            throw TextCaptureError.targetChanged
        }
        let element = snapshot.element
        guard let value = stringAttribute(element, kAXValueAttribute) else { throw TextCaptureError.unreadableField }
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TextCaptureError.emptyField }
        guard value.utf16.count <= 20_000 else { throw TextCaptureError.fieldTooLarge }
        let window = elementAttribute(element, kAXWindowAttribute) ?? snapshot.window
        let selection = rangeAttribute(element, kAXSelectedTextRangeAttribute)
        let selectedText = stringAttribute(element, kAXSelectedTextAttribute)
        let role = stringAttribute(element, kAXRoleAttribute) ?? ""
        let strategy = liveWriteStrategy(
            role: role, hasWindow: window != nil, valueSettable: isSettable(element, kAXValueAttribute),
            selectedRangeSettable: isSettable(element, kAXSelectedTextRangeAttribute),
            selectedTextSettable: isSettable(element, kAXSelectedTextAttribute),
            selectionValid: selection.map { rangeIsValid($0, in: value) } == true
        ) ?? snapshot.strategy
        return CapturedText(text: value, canReplace: strategy != nil,
                            sourceApplication: source.localizedName ?? snapshot.sourceApplication,
                            targetID: targetIdentity(processID: snapshot.processID, element: element, window: window),
                            sourceBundleIdentifier: source.bundleIdentifier ?? snapshot.sourceBundleIdentifier,
                            sourceBounds: bounds(of: element) ?? snapshot.sourceBounds, isLiveCapture: true,
                            processID: snapshot.processID, application: snapshot.application, element: element,
                            window: window, fullValue: value, selectedRange: selection,
                            selectedText: selectedText, strategy: strategy)
    }

    /// Caret movement alone does not stale a whole-field live review. Text, focus,
    /// application, and window identities always must still match exactly.
    public func isCurrent(_ snapshot: CapturedText, requireSelection: Bool = false,
                          allowOwnApplication: Bool = false) -> Bool {
        guard isAccessibilityTrusted else { return false }
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard frontPID == snapshot.processID || (allowOwnApplication && frontPID == ProcessInfo.processInfo.processIdentifier),
              let focused = try? focusedEditableElement(in: snapshot.application), CFEqual(focused, snapshot.element),
              let capturedWindow = snapshot.window,
              let currentWindow = elementAttribute(snapshot.application, kAXFocusedWindowAttribute),
              CFEqual(capturedWindow, currentWindow) else { return false }
        if let value = snapshot.fullValue {
            guard exactTextMatch(stringAttribute(focused, kAXValueAttribute), value) else { return false }
        } else {
            guard exactTextMatch(stringAttribute(focused, kAXSelectedTextAttribute), snapshot.text) else { return false }
        }
        if requireSelection {
            guard let originalRange = snapshot.selectedRange,
                  let currentRange = rangeAttribute(focused, kAXSelectedTextRangeAttribute),
                  currentRange.location == originalRange.location, currentRange.length == originalRange.length,
                  exactTextMatch(stringAttribute(focused, kAXSelectedTextAttribute), snapshot.selectedText) else { return false }
        }
        return true
    }

    /// Re-activates the source only after Apply, restores focus lost to the HUD, then
    /// validates the captured element. Unsupported or changed targets fail closed.
    public func apply(_ replacement: String, to snapshot: CapturedText) async throws {
        try Task.checkCancellation()
        guard isAccessibilityTrusted else { throw TextCaptureError.permissionRequired }
        guard let strategy = snapshot.strategy, snapshot.canReplace,
              let originalValue = snapshot.fullValue,
              snapshot.window != nil else { throw TextCaptureError.copyOnly }
        let focused = try await prepareWritableElement(snapshot, expectedValue: originalValue)
        if strategy == .liveRange {
            do {
                try applyLiveRange(replacement, originalValue: originalValue, focused: focused, snapshot: snapshot)
                return
            } catch {
                // Chromium form controls often fail selected-range writes; whole-value is safe there.
                guard canFallbackToFullValue(focused) else { throw error }
                smokeDiagnostic("liveRange failed; falling back to fullValue", category: "apply-fallback")
                try applyFullValue(replacement, to: focused)
                return
            }
        }
        switch strategy {
        case .selectedText:
            guard let originalRange = snapshot.selectedRange, rangeIsValid(originalRange, in: originalValue) else { throw TextCaptureError.targetChanged }
            let expectedValue = (originalValue as NSString).replacingCharacters(in: NSRange(location: originalRange.location, length: originalRange.length), with: replacement)
            guard isSettable(focused, kAXSelectedTextAttribute) else { throw TextCaptureError.copyOnly }
            let status = AXUIElementSetAttributeValue(focused, kAXSelectedTextAttribute as CFString, replacement as CFString)
            guard status == .success else { throw TextCaptureError.writeFailed }
            guard exactTextMatch(stringAttribute(focused, kAXValueAttribute), expectedValue) else {
                throw TextCaptureError.writeNotVerified
            }
        case .fullValue:
            try applyFullValue(replacement, to: focused)
        case .liveRange:
            throw TextCaptureError.copyOnly
        }
    }

    private func canFallbackToFullValue(_ element: AXUIElement) -> Bool {
        let role = stringAttribute(element, kAXRoleAttribute) ?? ""
        return isSettable(element, kAXValueAttribute)
            && [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String].contains(role)
    }

    private func applyFullValue(_ replacement: String, to element: AXUIElement) throws {
        guard isSettable(element, kAXValueAttribute) else { throw TextCaptureError.copyOnly }
        let status = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, replacement as CFString)
        guard status == .success else { throw TextCaptureError.writeFailed }
        // A successful AX call is not proof that the editor honored the replacement.
        guard exactTextMatch(stringAttribute(element, kAXValueAttribute), replacement) else {
            throw TextCaptureError.writeNotVerified
        }
    }

    /// Brings the source app forward and restores keyboard focus to the captured field.
    /// The floating panel can make Lynt frontmost; that alone must not block Apply.
    private func prepareWritableElement(_ snapshot: CapturedText, expectedValue: String) async throws -> AXUIElement {
        guard let source = NSRunningApplication(processIdentifier: snapshot.processID), !source.isTerminated else {
            throw TextCaptureError.targetChanged
        }
        let currentPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard currentPID == ownPID || currentPID == snapshot.processID else {
            throw TextCaptureError.targetChanged
        }
        if currentPID != snapshot.processID {
            guard source.activate(options: []) else { throw TextCaptureError.targetChanged }
            for _ in 0..<12 {
                try Task.checkCancellation()
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.processID { break }
                try await Task.sleep(for: .milliseconds(30))
            }
        }
        try Task.checkCancellation()
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.processID else {
            throw TextCaptureError.targetChanged
        }
        guard exactTextMatch(stringAttribute(snapshot.element, kAXValueAttribute), expectedValue) else {
            throw TextCaptureError.targetChanged
        }
        if let window = snapshot.window {
            _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
        _ = AXUIElementSetAttributeValue(snapshot.application, kAXFocusedUIElementAttribute as CFString, snapshot.element)
        _ = AXUIElementSetAttributeValue(snapshot.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        for _ in 0..<12 {
            try Task.checkCancellation()
            if elementIsFocused(snapshot) { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        if snapshot.isLiveCapture {
            // Element value identity is the write safety check. Chromium window AX
            // objects are often replaced after activation, so sameWindow is not required.
            guard exactTextMatch(stringAttribute(snapshot.element, kAXValueAttribute), expectedValue) else {
                throw TextCaptureError.targetChanged
            }
            smokeDiagnostic("Apply target restored role=\(stringAttribute(snapshot.element, kAXRoleAttribute) ?? "unknown") focused=\(elementIsFocused(snapshot)) sameWindow=\(sameWindow(snapshot))", category: "apply-restore")
            return snapshot.element
        }
        guard isCurrent(snapshot, requireSelection: true) else { throw TextCaptureError.targetChanged }
        return snapshot.element
    }

    private func elementIsFocused(_ snapshot: CapturedText) -> Bool {
        if let focused = try? focusedEditableElement(in: snapshot.application), CFEqual(focused, snapshot.element) {
            return true
        }
        return boolAttribute(snapshot.element, kAXFocusedAttribute) == true
    }

    private func sameWindow(_ snapshot: CapturedText) -> Bool {
        guard let capturedWindow = snapshot.window else { return false }
        if let focusedWindow = elementAttribute(snapshot.application, kAXFocusedWindowAttribute),
           CFEqual(focusedWindow, capturedWindow) {
            return true
        }
        // Some Chromium fields keep a stable window element even when AX focused-window
        // briefly lags after activation. The captured window identity is enough.
        return elementAttribute(snapshot.element, kAXWindowAttribute).map { CFEqual($0, capturedWindow) } ?? false
    }

    private func applyLiveRange(_ replacement: String, originalValue: String, focused: AXUIElement, snapshot: CapturedText) throws {
        guard let edit = minimalReplacement(original: originalValue, replacement: replacement) else { return }
        var changedRange = CFRange(location: edit.range.location, length: edit.range.length)
        guard let rangeValue = AXValueCreate(.cfRange, &changedRange),
              isSettable(focused, kAXSelectedTextRangeAttribute), isSettable(focused, kAXSelectedTextAttribute) else { throw TextCaptureError.copyOnly }
        let oldRange = rangeAttribute(focused, kAXSelectedTextRangeAttribute)
        guard AXUIElementSetAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, rangeValue) == .success else {
            throw TextCaptureError.writeFailed
        }
        // Setting a selection is not a write transaction. Verify the captured element
        // still holds the original value and the requested range before replacing bytes.
        guard exactTextMatch(stringAttribute(focused, kAXValueAttribute), originalValue),
              let selected = rangeAttribute(focused, kAXSelectedTextRangeAttribute),
              selected.location == changedRange.location, selected.length == changedRange.length,
              exactTextMatch(stringAttribute(focused, kAXSelectedTextAttribute), substring(originalValue, changedRange)) else {
            restoreSelection(oldRange, on: focused, ifValueEquals: originalValue)
            throw TextCaptureError.targetChanged
        }
        if Task.isCancelled {
            restoreSelection(oldRange, on: focused, ifValueEquals: originalValue)
            throw CancellationError()
        }
        let result = AXUIElementSetAttributeValue(focused, kAXSelectedTextAttribute as CFString, edit.text as CFString)
        guard result == .success else {
            restoreSelection(oldRange, on: focused, ifValueEquals: originalValue)
            throw TextCaptureError.writeFailed
        }
        guard exactTextMatch(stringAttribute(focused, kAXValueAttribute), replacement) else { throw TextCaptureError.writeNotVerified }
    }

    private func restoreSelection(_ range: CFRange?, on element: AXUIElement, ifValueEquals value: String) {
        guard exactTextMatch(stringAttribute(element, kAXValueAttribute), value), var range,
              let rangeValue = AXValueCreate(.cfRange, &range) else { return }
        _ = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, rangeValue)
    }

    private func focusedEditableElement(in application: AXUIElement) throws -> AXUIElement {
        guard let focused = elementAttribute(application, kAXFocusedUIElementAttribute) else {
            throw TextCaptureError.unsupportedField
        }
        var element = focused
        // Chromium command palettes / Radix dialogs often put AX focus on the dialog,
        // listbox, or combobox shell while the typed value lives on a child input.
        // Walk a bounded ancestry and only a shallow descendant search under shells —
        // never the full window tree.
        for depth in 0..<6 {
            AXUIElementSetMessagingTimeout(element, 0.25)
            guard !isSecureIncludingAncestors(element) else { throw TextCaptureError.secureField }
            let role = stringAttribute(element, kAXRoleAttribute) ?? ""
            let subrole = stringAttribute(element, kAXSubroleAttribute) ?? ""
            smokeDiagnostic("Focused candidate role=\(role) subrole=\(subrole) depth=\(depth)", category: "candidate-\(depth)")
            if boolAttribute(element, "AXReadOnly") == true {
                if let nested = findTypedEditableDescendant(in: element, depth: 0) { return nested }
                throw TextCaptureError.unsupportedField
            }
            let explicitlyEditable = boolAttribute(element, "AXEditable")
            let enabled = boolAttribute(element, kAXEnabledAttribute)
            if isEligibleEditable(role: role, explicitlyEditable: explicitlyEditable, enabled: enabled) {
                let valueSettable = isSettable(element, kAXValueAttribute)
                let selectedTextSettable = isSettable(element, kAXSelectedTextAttribute)
                if hasAutomaticEditingEvidence(explicitlyEditable: explicitlyEditable,
                                               valueSettable: valueSettable,
                                               selectedTextSettable: selectedTextSettable) {
                    if hasReadableLiveValue(element) { return element }
                    if let nested = findTypedEditableDescendant(in: element, depth: 0) { return nested }
                    if [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String].contains(role) {
                        return element
                    }
                }
            }
            if isFocusShell(role: role, subrole: subrole),
               let nested = findTypedEditableDescendant(in: element, depth: 0) {
                smokeDiagnostic("Resolved nested editable under shell role=\(role)", category: "nested-shell")
                return nested
            }
            guard ["AXStaticText", "AXGroup", "AXUnknown", "AXText", "AXList", "AXScrollArea", "AXDialog"].contains(role),
                  let parent = elementAttribute(element, kAXParentAttribute) else {
                throw TextCaptureError.unsupportedField
            }
            let parentRole = stringAttribute(parent, kAXRoleAttribute) ?? ""
            if [kAXWindowRole as String, kAXApplicationRole as String].contains(parentRole) {
                throw TextCaptureError.unsupportedField
            }
            element = parent
        }
        throw TextCaptureError.unsupportedField
    }

    private func findTypedEditableDescendant(in root: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth < 5 else { return nil }
        var best: (score: Int, element: AXUIElement)?
        for child in axChildren(of: root, limit: 24) {
            AXUIElementSetMessagingTimeout(child, 0.25)
            if isSecureIncludingAncestors(child) || boolAttribute(child, "AXReadOnly") == true { continue }
            let role = stringAttribute(child, kAXRoleAttribute) ?? ""
            let explicitlyEditable = boolAttribute(child, "AXEditable")
            let enabled = boolAttribute(child, kAXEnabledAttribute)
            if isEligibleEditable(role: role, explicitlyEditable: explicitlyEditable, enabled: enabled) {
                let valueSettable = isSettable(child, kAXValueAttribute)
                let selectedTextSettable = isSettable(child, kAXSelectedTextAttribute)
                if hasAutomaticEditingEvidence(explicitlyEditable: explicitlyEditable,
                                               valueSettable: valueSettable,
                                               selectedTextSettable: selectedTextSettable) {
                    let score = editableCandidateScore(child, role: role)
                    if score >= 4, best.map({ score > $0.score }) ?? true {
                        best = (score, child)
                    }
                }
            }
            if let nested = findTypedEditableDescendant(in: child, depth: depth + 1) {
                let nestedRole = stringAttribute(nested, kAXRoleAttribute) ?? ""
                let score = editableCandidateScore(nested, role: nestedRole)
                if score >= 4, best.map({ score > $0.score }) ?? true {
                    best = (score, nested)
                }
            }
        }
        return best?.element
    }

    private func editableCandidateScore(_ element: AXUIElement, role: String) -> Int {
        var score = 0
        if boolAttribute(element, kAXFocusedAttribute) == true { score += 8 }
        if hasReadableLiveValue(element) { score += 4 }
        if [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String].contains(role) {
            score += 2
        }
        return score
    }

    private func hasReadableLiveValue(_ element: AXUIElement) -> Bool {
        guard let value = stringAttribute(element, kAXValueAttribute) else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func axChildren(of element: AXUIElement, limit: Int) -> [AXUIElement] {
        guard let raw = attribute(element, kAXChildrenAttribute) else { return [] }
        let array = raw as! CFArray
        let count = min(CFArrayGetCount(array), max(0, limit))
        var children: [AXUIElement] = []
        children.reserveCapacity(count)
        for index in 0..<count {
            let value = CFArrayGetValueAtIndex(array, index)!
            children.append(Unmanaged<AXUIElement>.fromOpaque(value).takeUnretainedValue())
        }
        return children
    }

    private func targetIdentity(processID: pid_t, element: AXUIElement, window: AXUIElement?) -> String {
        "\(processID)-\(window.map(CFHash) ?? 0)-\(CFHash(element))"
    }

    private func bounds(of element: AXUIElement) -> CGRect? {
        guard let rawPosition = attribute(element, kAXPositionAttribute), CFGetTypeID(rawPosition) == AXValueGetTypeID(),
              let rawSize = attribute(element, kAXSizeAttribute), CFGetTypeID(rawSize) == AXValueGetTypeID() else { return nil }
        let positionValue = rawPosition as! AXValue
        let sizeValue = rawSize as! AXValue
        guard AXValueGetType(positionValue) == .cgPoint, AXValueGetType(sizeValue) == .cgSize else { return nil }
        var position = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position), AXValueGetValue(sizeValue, .cgSize, &size),
              position.x.isFinite, position.y.isFinite, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: position, size: size)
    }

    private func primeChromiumAccessibility(_ source: NSRunningApplication, application: AXUIElement) {
        let bundle = source.bundleIdentifier ?? ""
        guard isChromiumFamily(bundleIdentifier: bundle, bundleURL: source.bundleURL) else { return }
        let identity = "\(source.processIdentifier)-\(source.launchDate?.timeIntervalSince1970 ?? 0)"
        guard primedProcesses.insert(identity).inserted else { return }
        // Electron documents AXManualAccessibility; Chromium documents enhanced UI.
        // Enable at most once per process, never toggle it off on exit because
        // other assistive clients may rely on the same accessibility tree.
        let manual = AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        smokeDiagnostic("Chromium manual accessibility status=\(manual.rawValue)", category: "chromium-\(source.processIdentifier)")
        if manual != .success {
            _ = AXUIElementSetAttributeValue(application, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }

    private func smokeDiagnostic(_ value: String, category: String) {
        guard ProcessInfo.processInfo.arguments.contains("--live-smoke-test"), smokeDiagnostics[category] != value else { return }
        smokeDiagnostics[category] = value
        print("[Lynt AX smoke] \(value)")
        fflush(stdout)
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }

    private func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    private func boolAttribute(_ element: AXUIElement, _ name: String) -> Bool? {
        (attribute(element, name) as? NSNumber)?.boolValue
    }

    private func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func rangeAttribute(_ element: AXUIElement, _ name: String) -> CFRange? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let rangeValue = value as! AXValue
        guard AXValueGetType(rangeValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &range) else { return nil }
        return range
    }

    private func isSettable(_ element: AXUIElement, _ name: String) -> Bool {
        var result = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name as CFString, &result) == .success && result.boolValue
    }

    private func isSecure(_ element: AXUIElement) -> Bool {
        let role = stringAttribute(element, kAXRoleAttribute) ?? ""
        let subrole = stringAttribute(element, kAXSubroleAttribute) ?? ""
        return isSecureRole(role: role, subrole: subrole, protectedContent: boolAttribute(element, "AXProtectedContent"))
    }

    private func isSecureIncludingAncestors(_ element: AXUIElement) -> Bool {
        var current = element
        for _ in 0..<6 {
            AXUIElementSetMessagingTimeout(current, 0.25)
            if isSecure(current) { return true }
            guard let parent = elementAttribute(current, kAXParentAttribute) else { return false }
            let role = stringAttribute(parent, kAXRoleAttribute) ?? ""
            if [kAXWindowRole as String, kAXApplicationRole as String].contains(role) { return false }
            current = parent
        }
        return false
    }

    private func rangeIsValid(_ range: CFRange, in value: String) -> Bool {
        range.location >= 0 && range.length >= 0 && range.location <= value.utf16.count && range.length <= value.utf16.count - range.location
    }

    private func substring(_ value: String, _ range: CFRange) -> String? {
        guard rangeIsValid(range, in: value) else { return nil }
        return (value as NSString).substring(with: NSRange(location: range.location, length: range.length))
    }
}

struct MinimalTextReplacement {
    let range: NSRange
    let text: String
}

/// Compute a single smallest grapheme-safe edit without canonical normalization.
func minimalReplacement(original: String, replacement: String) -> MinimalTextReplacement? {
    guard !original.utf16.elementsEqual(replacement.utf16) else { return nil }
    var originalStart = original.startIndex
    var replacementStart = replacement.startIndex
    while originalStart < original.endIndex, replacementStart < replacement.endIndex,
          String(original[originalStart]).utf16.elementsEqual(String(replacement[replacementStart]).utf16) {
        original.formIndex(after: &originalStart)
        replacement.formIndex(after: &replacementStart)
    }
    var originalEnd = original.endIndex
    var replacementEnd = replacement.endIndex
    while originalEnd > originalStart, replacementEnd > replacementStart {
        let previousOriginal = original.index(before: originalEnd)
        let previousReplacement = replacement.index(before: replacementEnd)
        guard String(original[previousOriginal]).utf16.elementsEqual(String(replacement[previousReplacement]).utf16) else { break }
        originalEnd = previousOriginal
        replacementEnd = previousReplacement
    }
    return .init(range: NSRange(originalStart..<originalEnd, in: original), text: String(replacement[replacementStart..<replacementEnd]))
}

func isEligibleEditable(role: String, explicitlyEditable: Bool?, enabled: Bool?) -> Bool {
    guard enabled != false, explicitlyEditable != false else { return false }
    if [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String].contains(role) { return true }
    return explicitlyEditable == true && ["AXGroup", "AXWebArea", "AXText"].contains(role)
}

/// Dialog / command-palette / list shells that can own focus while typing happens in a child.
func isFocusShell(role: String, subrole: String) -> Bool {
    if ["AXGroup", "AXDialog", "AXList", "AXScrollArea", "AXComboBox", "AXWebArea", "AXWindow"].contains(role) {
        return true
    }
    return subrole.localizedCaseInsensitiveContains("dialog")
}

func hasAutomaticEditingEvidence(explicitlyEditable: Bool?, valueSettable: Bool, selectedTextSettable: Bool) -> Bool {
    guard explicitlyEditable != false else { return false }
    return explicitlyEditable == true || valueSettable || selectedTextSettable
}

func isSecureRole(role: String, subrole: String, protectedContent: Bool?) -> Bool {
    [role, subrole].contains { $0.localizedCaseInsensitiveContains("secure") || $0.localizedCaseInsensitiveContains("password") } || protectedContent == true
}

func isChromiumFamily(bundleIdentifier: String, bundleURL: URL?) -> Bool {
    let known = ["com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "org.chromium.Chromium", "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi"]
    if known.contains(bundleIdentifier) { return true }
    // Electron app bundle metadata, rather than speculative writes to every app.
    guard let bundleURL else { return false }
    return FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path)
}

/// Swift's normal String equality treats canonically equivalent Unicode strings
/// as equal. Editor snapshots instead require the identical UTF-16 sequence.
func exactTextMatch(_ lhs: String?, _ rhs: String?) -> Bool {
    switch (lhs, rhs) {
    case (.none, .none): return true
    case (.some(let lhs), .some(let rhs)): return lhs.utf16.elementsEqual(rhs.utf16)
    default: return false
    }
}

public enum TextCaptureError: LocalizedError, Equatable {
    case permissionRequired
    case noExternalField
    case unsupportedField
    case secureField
    case unreadableField
    case emptyField
    case fieldTooLarge
    case excludedApplication
    case copyOnly
    case targetChanged
    case writeFailed
    case writeNotVerified

    public var errorDescription: String? {
        switch self {
        case .permissionRequired: return "Allow Lynt in System Settings → Privacy & Security → Accessibility, or paste text manually."
        case .noExternalField: return "Focus an editable field in another application, then invoke Review English. You can also paste text manually."
        case .unsupportedField: return "This focused control does not expose a supported editable text field. Paste the text manually."
        case .secureField: return "Secure fields are never read or reviewed."
        case .unreadableField: return "This editor does not expose readable text. Paste the text manually."
        case .emptyField: return "There is no text to review in the focused field."
        case .fieldTooLarge: return "The focused field is too large. Select a smaller passage to review."
        case .excludedApplication: return "Automatic review is paused for this application."
        case .copyOnly: return "This editor supports Copy only. Copy the accepted preview and paste it yourself."
        case .targetChanged: return "The source app, window, field, selection, or text changed. Capture it again, or copy the accepted preview."
        case .writeFailed: return "The editor refused the Accessibility replacement. Copy the accepted preview instead."
        case .writeNotVerified: return "The editor did not confirm the expected result. Check its contents before continuing; Lynt did not retry the write."
        }
    }
}
