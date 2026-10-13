import Foundation

/// A global shortcut written as `ctrl+option+shift+cmd+<key>`. Key codes are the
/// layout-independent ANSI virtual key codes that Carbon's hotkey API expects.
public struct HotkeyChord: Equatable, Hashable, Sendable, CustomStringConvertible {
    public enum Modifier: String, CaseIterable, Sendable {
        case control = "ctrl", option, shift, command = "cmd"
        var symbol: String {
            switch self { case .control: "⌃"; case .option: "⌥"; case .shift: "⇧"; case .command: "⌘" }
        }
    }

    public var keyCode: UInt32
    public var modifiers: Set<Modifier>

    public init?(keyCode: UInt32, modifiers: Set<Modifier>) {
        guard Self.names[keyCode] != nil, !modifiers.subtracting([.shift]).isEmpty else { return nil }
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public init?(_ text: String) {
        let parts = text.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let key = parts.last, !key.isEmpty, let code = Self.codes[key] else { return nil }
        var modifiers = Set<Modifier>()
        for part in parts.dropLast() {
            switch part {
            case "ctrl", "control", "⌃": modifiers.insert(.control)
            case "option", "opt", "alt", "⌥": modifiers.insert(.option)
            case "shift", "⇧": modifiers.insert(.shift)
            case "cmd", "command", "⌘": modifiers.insert(.command)
            default: return nil
            }
        }
        self.init(keyCode: code, modifiers: modifiers)
    }

    /// Canonical, round-trippable form used in config.toml.
    public var description: String {
        (Modifier.allCases.filter(modifiers.contains).map(\.rawValue) + [Self.names[keyCode]!]).joined(separator: "+")
    }

    /// Menu-style form such as ⌃⌥⌘B.
    public var displayString: String {
        let key = Self.names[keyCode]!
        let shown = Self.symbols[key] ?? (key.count == 1 ? key.uppercased() : key.capitalized)
        return Modifier.allCases.filter(modifiers.contains).map(\.symbol).joined() + shown
    }

    private static let symbols = ["space": "Space", "return": "↩", "tab": "⇥", "escape": "⎋", "delete": "⌫",
                                  "left": "←", "right": "→", "up": "↑", "down": "↓"]

    static let codes: [String: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
        "p": 35, "return": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
        "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50, "delete": 51, "escape": 53,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101,
        "f10": 109, "f11": 103, "f12": 111, "left": 123, "right": 124, "down": 125, "up": 126,
    ]
    static let names: [UInt32: String] = Dictionary(uniqueKeysWithValues: codes.map { ($1, $0) })
}
