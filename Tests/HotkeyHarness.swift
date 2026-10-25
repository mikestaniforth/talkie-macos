import AppKit
import Carbon
import Foundation

/// Exercises the production shortcut data model without registering a shortcut,
/// observing or posting keyboard events, requesting permissions, or recording.
@main
struct HotkeyHarness {
    private struct Failure: Error, CustomStringConvertible { let description: String }

    static func main() {
        do { try run() }
        catch { fputs("Shortcut checks failed: \(error)\n", stderr); exit(1) }
    }

    private static func run() throws {
        var count = 0
        func check(_ name: String, _ condition: @autoclosure () -> Bool) throws {
            guard condition() else { throw Failure(description: name) }
            count += 1
            print("PASS \(name)")
        }
        func combination(_ key: Int, _ modifiers: Int, _ label: String = "A") -> HotkeyChoice {
            HotkeyChoice(kind: .combination, keyCode: UInt32(key), modifiers: UInt32(modifiers), keyLabel: label)
        }
        let legacy: [(String, HotkeyChoice)] = [
            ("controlOptionSpace", .controlOptionSpace),
            ("controlShiftSpace", .controlShiftSpace),
            ("optionShiftSpace", .optionShiftSpace)
        ]
        for (raw, expected) in legacy {
            try check("legacy \(raw) migration", HotkeyChoice(rawValue: raw) == expected)
            try check("legacy \(raw) remains valid", expected.validationError == nil)
        }
        try check("unknown legacy preference is rejected", HotkeyChoice(rawValue: "unknown-old-binding") == nil)
        let custom = combination(kVK_ANSI_L, controlKey | shiftKey, "L")
        let modifier = HotkeyChoice(kind: .modifier, keyCode: UInt32(kVK_RightControl), modifiers: 0, keyLabel: "Right Control")
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for choice in [custom, modifier, .controlOptionSpace] {
            let data = try encoder.encode(choice)
            let decoded = try decoder.decode(HotkeyChoice.self, from: data)
            try check("JSON preserves \(choice.label)", decoded == choice && decoded.id == choice.id)
        }
        let suite = "Talkie.HotkeyHarness." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(try encoder.encode(custom), forKey: "recordedHotkey")
        let stored = preferences.data(forKey: "recordedHotkey").flatMap { try? decoder.decode(HotkeyChoice.self, from: $0) }
        try check("custom choice survives isolated preferences storage", stored == custom)
        let malformed = Data("{\"kind\":\"future-kind\",\"keyCode\":49,\"modifiers\":0,\"keyLabel\":\"Space\"}".utf8)
        try check("unknown JSON kind fails cleanly", (try? decoder.decode(HotkeyChoice.self, from: malformed)) == nil)
        let invalidStored = combination(256, controlKey)
        let invalidDecoded = try decoder.decode(HotkeyChoice.self, from: encoder.encode(invalidStored))
        try check("invalid decoded key is rejected by production validation", invalidDecoded.validationError != nil)

        try check("bare letter is rejected", combination(kVK_ANSI_A, 0).validationError != nil)
        try check("Shift plus letter cannot intercept typing", combination(kVK_ANSI_A, shiftKey).validationError != nil)
        try check("bare Space is rejected", combination(kVK_Space, 0, "Space").validationError != nil)
        try check("bare function key is valid", combination(kVK_F8, 0, "F8").validationError == nil)
        try check("custom modified letter is valid", custom.validationError == nil)
        try check("unknown modifier bits are rejected", combination(kVK_ANSI_A, controlKey | 1).validationError != nil)
        try check("modifier cannot masquerade as a combination", combination(kVK_RightControl, controlKey, "Right Control").validationError != nil)
        try check("unsupported modifier-only key is rejected", HotkeyChoice(kind: .modifier, keyCode: UInt32(kVK_Delete), modifiers: 0, keyLabel: "Delete").validationError != nil)
        try check("modifier-only choice cannot carry a chord mask", HotkeyChoice(kind: .modifier, keyCode: UInt32(kVK_RightControl), modifiers: UInt32(controlKey), keyLabel: "Right Control").validationError != nil)
        try check("empty key label is rejected", combination(kVK_ANSI_A, controlKey, "").validationError != nil)
        try check("oversized key label is rejected", combination(kVK_ANSI_A, controlKey, String(repeating: "A", count: 21)).validationError != nil)
        for (key, info) in HotkeyChoice.modifierInfo.sorted(by: { $0.key < $1.key }) {
            let choice = HotkeyChoice(kind: .modifier, keyCode: key, modifiers: 0, keyLabel: info.name)
            try check("\(info.name) is a supported modifier choice", choice.validationError == nil)
        }
        try check("readable label uses canonical modifier ordering", combination(kVK_ANSI_A, controlKey | optionKey | shiftKey | cmdKey).label == "Control + Option + Shift + Command + A")
        try check("symbol label uses canonical modifier ordering", combination(kVK_ANSI_A, controlKey | optionKey | shiftKey | cmdKey).symbols == "⌃ ⌥ ⇧ ⌘ A")
        try check("modifier-only label omits a redundant mask", modifier.label == "Right Control" && modifier.symbolParts == ["Right Control"])
        let flags: NSEvent.ModifierFlags = [.command, .control, .option, .shift, .capsLock, .numericPad, .function]
        try check("Carbon chord strips unrelated flag bits", HotkeyChoice.carbonModifiers(flags) == UInt32(controlKey | optionKey | shiftKey | cmdKey))
        for (key, label) in [(kVK_ANSI_Q, "Q"), (kVK_ANSI_W, "W"), (kVK_Tab, "Tab"), (kVK_Space, "Space")] {
            try check("Command + \(label) is reserved", combination(key, cmdKey, label).validationError != nil)
        }
        try check("Control + Space is reserved", combination(kVK_Space, controlKey, "Space").validationError != nil)
        // Talkie posts Command+V to deliver dictation. Binding it globally would
        // intercept that very paste and must be rejected even if available.
        try check("Talkie's own Command + V delivery chord is reserved", combination(kVK_ANSI_V, cmdKey, "V").validationError != nil)
        print("\(count)/\(count) shortcut checks passed using production GlobalHotkey.swift.")
        print("No shortcuts were registered, and no keyboard events or microphone activity occurred.")
    }
}
