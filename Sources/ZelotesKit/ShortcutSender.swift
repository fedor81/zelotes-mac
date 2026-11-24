import ApplicationServices
import Foundation

/// Presses a shortcut for the buttons the T-20 reports to the Mac instead of acting on itself. macOS only lets an
/// app post key events with Accessibility in System Settings › Privacy & Security.
public enum ShortcutSender {
    /// Whether the app may post key events.
    public static var isPermitted: Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system's question once, which is what puts the app in the Accessibility list. The user still has
    /// to turn it on there.
    public static func requestPermission() {
        // The name of `kAXTrustedCheckOptionPrompt`, spelled out because that constant is an imported global var.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Whether the Mac knows how to press this shortcut at all.
    public static func canPost(_ stroke: KeyStroke) -> Bool {
        stroke.key.virtualKeyCode != nil
    }

    /// Presses and releases the shortcut. Returns false when the key has no known key code.
    ///
    /// The modifier keys are pressed and released as key events of their own, and an arrow or function key carries
    /// the Function flag a real press of it carries: the system's own shortcuts, Mission Control's among them,
    /// answer to nothing less.
    @discardableResult
    public static func post(_ stroke: KeyStroke) -> Bool {
        guard let keyCode = stroke.key.virtualKeyCode,
              let source = CGEventSource(stateID: .hidSystemState) else { return false }
        var flags = stroke.modifiers.cgEventFlags
        if stroke.key.carriesFunctionFlag { flags.insert(.maskSecondaryFn) }

        let modifiers = stroke.modifiers.modifierKeys
        var steps: [(key: CGKeyCode, isDown: Bool, flags: CGEventFlags)] =
            modifiers.map { ($0.key, true, flags) } + [(keyCode, true, flags), (keyCode, false, flags)]
        for modifier in modifiers.reversed() {
            flags.remove(modifier.flag)
            steps.append((modifier.key, false, flags))
        }
        for step in steps {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: step.key, keyDown: step.isDown) else {
                return false
            }
            event.flags = step.flags
            event.post(tap: .cghidEventTap)
        }
        return true
    }
}

extension KeyModifiers {
    /// The keys whose press sets each of the modifiers, in the order macOS lists them.
    var modifierKeys: [(key: CGKeyCode, flag: CGEventFlags)] {
        var keys: [(key: CGKeyCode, flag: CGEventFlags)] = []
        if contains(.control) { keys.append((0x3B, .maskControl)) }
        if contains(.shift) { keys.append((0x38, .maskShift)) }
        if contains(.option) { keys.append((0x3A, .maskAlternate)) }
        if contains(.command) { keys.append((0x37, .maskCommand)) }
        return keys
    }

    var cgEventFlags: CGEventFlags {
        var flags: CGEventFlags = []
        if contains(.control) { flags.insert(.maskControl) }
        if contains(.shift) { flags.insert(.maskShift) }
        if contains(.option) { flags.insert(.maskAlternate) }
        if contains(.command) { flags.insert(.maskCommand) }
        return flags
    }
}

extension KeyboardKey {
    /// Whether a real press of this key carries the Function modifier. The arrow keys, the navigation block and
    /// the function keys do, and the system's shortcuts match the flag as well as the key.
    var carriesFunctionFlag: Bool {
        (0x3A...0x45).contains(usage) || (0x4A...0x52).contains(usage)
    }

    /// The key code the Mac presses for this key. The codes are the US layout's, so a shortcut that uses a letter
    /// follows the key's position rather than the letter printed on it.
    public var virtualKeyCode: CGKeyCode? {
        Self.virtualKeyCodes[usage]
    }

    private static let virtualKeyCodes: [UInt8: CGKeyCode] = [
        // Letters A to Z.
        0x04: 0, 0x05: 11, 0x06: 8, 0x07: 2, 0x08: 14, 0x09: 3, 0x0A: 5, 0x0B: 4, 0x0C: 34,
        0x0D: 38, 0x0E: 40, 0x0F: 37, 0x10: 46, 0x11: 45, 0x12: 31, 0x13: 35, 0x14: 12, 0x15: 15,
        0x16: 1, 0x17: 17, 0x18: 32, 0x19: 9, 0x1A: 13, 0x1B: 7, 0x1C: 16, 0x1D: 6,
        // The digits 1 to 0.
        0x1E: 18, 0x1F: 19, 0x20: 20, 0x21: 21, 0x22: 23, 0x23: 22, 0x24: 26, 0x25: 28,
        0x26: 25, 0x27: 29,
        // Editing.
        0x28: 36, 0x29: 53, 0x2A: 51, 0x2B: 48, 0x2C: 49, 0x4C: 117,
        // Symbols.
        0x2D: 27, 0x2E: 24, 0x2F: 33, 0x30: 30, 0x31: 42, 0x33: 41, 0x34: 39, 0x35: 50, 0x36: 43,
        0x37: 47, 0x38: 44,
        // Navigation.
        0x4A: 115, 0x4B: 116, 0x4D: 119, 0x4E: 121, 0x4F: 124, 0x50: 123, 0x51: 125, 0x52: 126,
        // Function keys F1 to F12.
        0x3A: 122, 0x3B: 120, 0x3C: 99, 0x3D: 118, 0x3E: 96, 0x3F: 97, 0x40: 98, 0x41: 100,
        0x42: 101, 0x43: 109, 0x44: 103, 0x45: 111,
    ]
}
