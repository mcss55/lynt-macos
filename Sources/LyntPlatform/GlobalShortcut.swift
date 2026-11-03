import Carbon
import Foundation

public struct ShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let command = ShortcutModifiers(rawValue: UInt32(cmdKey))
    public static let shift = ShortcutModifiers(rawValue: UInt32(shiftKey))
    public static let option = ShortcutModifiers(rawValue: UInt32(optionKey))
    public static let control = ShortcutModifiers(rawValue: UInt32(controlKey))

    public var display: String {
        [(Self.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .filter { contains($0.0) }.map(\.1).joined()
    }
}

public struct Shortcut: Codable, Hashable, Sendable {
    public var keyCode: UInt32
    public var modifiers: ShortcutModifiers

    public init(keyCode: UInt32, modifiers: ShortcutModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public static let reviewDefault = Shortcut(keyCode: UInt32(kVK_ANSI_G), modifiers: [.command, .shift])

    public var display: String {
        let knownKeys: [UInt32: String] = [UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_R): "R", UInt32(kVK_ANSI_L): "L"]
        return modifiers.display + (knownKeys[keyCode] ?? "Key \(keyCode)")
    }
}

/// A registered Carbon hotkey receives only its own key event. It does not monitor typing.
@MainActor
public final class GlobalShortcut {
    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private var handler: @MainActor () -> Void
    public private(set) var registeredShortcut: Shortcut?
    private static let signature: OSType = 0x4C594E54 // LYNT

    public init(handler: @escaping @MainActor () -> Void) {
        self.handler = handler
    }

    public func register(_ shortcut: Shortcut = .reviewDefault) throws {
        if registeredShortcut == shortcut { return }
        // Bare keys and Shift-only keys would interfere with normal typing.
        guard !shortcut.modifiers.intersection([.command, .control, .option]).isEmpty else {
            throw ShortcutError.modifierRequired
        }
        if eventHandler == nil {
            var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var identifier = EventHotKeyID()
                let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
                guard result == noErr, identifier.signature == 0x4C594E54, identifier.id == 1 else {
                    return OSStatus(eventNotHandledErr)
                }
                let instance = Unmanaged<GlobalShortcut>.fromOpaque(userData).takeUnretainedValue()
                MainActor.assumeIsolated { instance.handler() }
                return noErr
            }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
            guard status == noErr else { throw ShortcutError.registrationFailed(status) }
        }

        var candidate: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers.rawValue,
                                         EventHotKeyID(signature: Self.signature, id: 1),
                                         GetApplicationEventTarget(), 0, &candidate)
        guard status == noErr else { throw ShortcutError.registrationFailed(status) }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = candidate
        registeredShortcut = shortcut
    }

    public func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        registeredShortcut = nil
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}

public enum ShortcutError: LocalizedError {
    case modifierRequired
    case registrationFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .modifierRequired: return "Choose a shortcut containing Command, Control, or Option."
        case .registrationFailed(let status): return "The shortcut could not be registered (status \(status)). Choose another combination; it may already be in use."
        }
    }
}
