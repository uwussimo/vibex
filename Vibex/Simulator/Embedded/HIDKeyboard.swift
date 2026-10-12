import Foundation

/// US-layout characters → USB HID keyboard usages, for typing into the simulator.
nonisolated enum HIDKeyboard {
    struct Stroke: Equatable {
        let usage: UInt32
        let shift: Bool
    }

    static let leftShift: UInt32 = 0xE1

    static let named: [String: UInt32] = [
        "return": 0x28, "enter": 0x28, "escape": 0x29, "esc": 0x29, "backspace": 0x2A, "delete": 0x2A,
        "tab": 0x2B, "space": 0x2C, "right": 0x4F, "left": 0x50, "down": 0x51, "up": 0x52,
        "arrowright": 0x4F, "arrowleft": 0x50, "arrowdown": 0x51, "arrowup": 0x52, "home": 0x4A, "end": 0x4D,
    ]

    private static let plain: [Character: UInt32] = {
        var map: [Character: UInt32] = [:]
        for (offset, letter) in "abcdefghijklmnopqrstuvwxyz".enumerated() { map[letter] = 0x04 + UInt32(offset) }
        for (offset, digit) in "123456789".enumerated() { map[digit] = 0x1E + UInt32(offset) }
        map["0"] = 0x27
        map["\n"] = 0x28; map["\t"] = 0x2B; map[" "] = 0x2C
        map["-"] = 0x2D; map["="] = 0x2E; map["["] = 0x2F; map["]"] = 0x30; map["\\"] = 0x31
        map[";"] = 0x33; map["'"] = 0x34; map["`"] = 0x35; map[","] = 0x36; map["."] = 0x37; map["/"] = 0x38
        return map
    }()

    private static let shifted: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "~": "`", "<": ",", ">": ".", "?": "/",
    ]

    /// nil for characters the US layout cannot produce (emoji, accents).
    static func stroke(for character: Character) -> Stroke? {
        if let usage = plain[character] { return Stroke(usage: usage, shift: false) }
        if character.isUppercase, let lower = character.lowercased().first, let usage = plain[lower] {
            return Stroke(usage: usage, shift: true)
        }
        if let base = shifted[character], let usage = plain[base] { return Stroke(usage: usage, shift: true) }
        return nil
    }

    static func stroke(forKeyName name: String) -> Stroke? {
        if let usage = named[name.lowercased()] { return Stroke(usage: usage, shift: false) }
        if name.count == 1, let character = name.first { return stroke(for: character) }
        return nil
    }
}
