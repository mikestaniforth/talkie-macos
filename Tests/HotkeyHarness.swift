import AppKit
import Carbon
import Foundation
import IOKit.hidsystem

/// Exercises shortcut data and the production modifier-event reducer without
/// registering monitors, posting events, requesting permissions, or recording.
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

        func modifierFlags(_ family: NSEvent.ModifierFlags, _ device: UInt = 0) -> NSEvent.ModifierFlags {
            NSEvent.ModifierFlags(rawValue: family.rawValue | device)
        }
        func armToken(_ actions: [ModifierShortcutState.Action]) throws -> UInt64 {
            guard actions.count == 1, case .arm(let token) = actions[0] else {
                throw Failure(description: "Hold press did not request one delayed arm")
            }
            return token
        }
        let leftControl = modifierFlags(.control, UInt(NX_DEVICELCTLKEYMASK))
        var toggle = ModifierShortcutState(keyCode: 59, hold: false)
        try check("toggle press waits for clean release", toggle.flagsChanged(keyCode: 59, flags: leftControl).isEmpty)
        try check("duplicate modifier down cannot toggle", toggle.flagsChanged(keyCode: 59, flags: leftControl).isEmpty)
        try check("solo modifier tap toggles once on release", toggle.flagsChanged(keyCode: 59, flags: []).contains(.toggle))
        try check("duplicate modifier release cannot toggle twice", toggle.flagsChanged(keyCode: 59, flags: []).isEmpty)

        // The same clean tap starts/stops a toggle take. Ctrl+C between taps
        // must emit no toggle and no hold cancellation, regardless of the take.
        var toggleCount = 1
        var typingActions: [ModifierShortcutState.Action] = []
        typingActions += toggle.flagsChanged(keyCode: 59, flags: leftControl)
        typingActions += toggle.keyDown()
        typingActions += toggle.keyDown() // Repeated ordinary key-down.
        typingActions += toggle.flagsChanged(keyCode: 59, flags: [])
        toggleCount += typingActions.filter { $0 == .toggle }.count
        try check("Ctrl+C cannot start or stop a toggle take", toggleCount == 1 && !typingActions.contains(.cancelHold))
        _ = toggle.flagsChanged(keyCode: 59, flags: leftControl)
        toggleCount += toggle.flagsChanged(keyCode: 59, flags: []).filter { $0 == .toggle }.count
        try check("next standalone tap can stop the toggle take", toggleCount == 2)
        try check("ordinary typing without the chosen modifier is ignored", toggle.keyDown().isEmpty)

        var chord = ModifierShortcutState(keyCode: 59, hold: false)
        _ = chord.flagsChanged(keyCode: 59, flags: leftControl)
        _ = chord.flagsChanged(keyCode: 56, flags: modifierFlags([.control, .shift], UInt(NX_DEVICELCTLKEYMASK | NX_DEVICELSHIFTKEYMASK)))
        _ = chord.flagsChanged(keyCode: 56, flags: leftControl)
        try check("extra modifier blocks toggle even when released first", !chord.flagsChanged(keyCode: 59, flags: []).contains(.toggle))
        _ = chord.flagsChanged(keyCode: 59, flags: modifierFlags([.control, .shift], UInt(NX_DEVICELCTLKEYMASK | NX_DEVICELSHIFTKEYMASK)))
        _ = chord.flagsChanged(keyCode: 56, flags: leftControl)
        try check("modifier pressed within an existing chord is not a solo tap", !chord.flagsChanged(keyCode: 59, flags: []).contains(.toggle))

        var hold = ModifierShortcutState(keyCode: 59, hold: true)
        let token = try armToken(hold.flagsChanged(keyCode: 59, flags: leftControl))
        try check("duplicate hold flags do not release or rearm", hold.flagsChanged(keyCode: 59, flags: leftControl).isEmpty)
        try check("hold begins once after arming", hold.arm(generation: token) == [.beginHold])
        try check("repeated arm cannot start another take", hold.arm(generation: token).isEmpty)
        try check("held modifier has no elapsed-time stop action", hold.flagsChanged(keyCode: 59, flags: leftControl).isEmpty)
        try check("hold release finishes exactly once", hold.flagsChanged(keyCode: 59, flags: []) == [.disarm, .finishHold])
        try check("duplicate hold release cannot finish twice", hold.flagsChanged(keyCode: 59, flags: []).isEmpty)

        let beforeTyping = try armToken(hold.flagsChanged(keyCode: 59, flags: leftControl))
        _ = hold.keyDown()
        try check("typing before hold delay prevents arming", hold.arm(generation: beforeTyping).isEmpty)
        try check("typing before hold activation produces no finish", hold.flagsChanged(keyCode: 59, flags: []) == [.disarm])
        let activeToken = try armToken(hold.flagsChanged(keyCode: 59, flags: leftControl))
        _ = hold.arm(generation: activeToken)
        try check("typing during hold requests recovery cancellation", hold.keyDown() == [.disarm, .cancelHold])
        try check("typing repeat cannot cancel twice", hold.keyDown().isEmpty)
        try check("blocked hold release cannot deliver normally", hold.flagsChanged(keyCode: 59, flags: []) == [.disarm])

        let stale = try armToken(hold.flagsChanged(keyCode: 59, flags: leftControl))
        _ = hold.flagsChanged(keyCode: 59, flags: [])
        let current = try armToken(hold.flagsChanged(keyCode: 59, flags: leftControl))
        try check("stale delay cannot arm a new press early", hold.arm(generation: stale).isEmpty)
        try check("new press retains its own arm generation", hold.arm(generation: current) == [.beginHold])
        hold.reset()
        try check("registration reset invalidates outstanding arm", hold.arm(generation: current).isEmpty)
        try check("reset release cannot finish a previous take", hold.flagsChanged(keyCode: 59, flags: []).isEmpty)

        var missedRelease = ModifierShortcutState(keyCode: 59, hold: true)
        let missedToken = try armToken(missedRelease.flagsChanged(keyCode: 59, flags: leftControl))
        _ = missedRelease.arm(generation: missedToken)
        let shiftOnly = modifierFlags(.shift, UInt(NX_DEVICELSHIFTKEYMASK))
        try check("unrelated flags reconcile a missed hold release safely", missedRelease.flagsChanged(keyCode: 56, flags: shiftOnly) == [.disarm, .cancelHold] && !missedRelease.isPressed)
        try check("unrelated release cannot cancel the reconciled hold twice", missedRelease.flagsChanged(keyCode: 56, flags: []).isEmpty)
        try check("missed-release reconciliation invalidates the old arm", missedRelease.arm(generation: missedToken).isEmpty)
        let rearmed = try armToken(missedRelease.flagsChanged(keyCode: 59, flags: leftControl))
        try check("next genuine press arms after missed-release reconciliation", missedRelease.arm(generation: rearmed) == [.beginHold])
        let nativeUp = NSEvent.ModifierFlags(rawValue: 0x100)
        try check("next native selected release finishes once", missedRelease.flagsChanged(keyCode: 59, flags: nativeUp) == [.disarm, .finishHold])
        try check("duplicate native selected release is ignored", missedRelease.flagsChanged(keyCode: 59, flags: nativeUp).isEmpty)

        var pendingRelease = ModifierShortcutState(keyCode: 59, hold: true)
        let pendingToken = try armToken(pendingRelease.flagsChanged(keyCode: 59, flags: leftControl))
        try check("missing release before arm only disarms", pendingRelease.flagsChanged(keyCode: 56, flags: shiftOnly) == [.disarm] && !pendingRelease.isPressed)
        try check("reconciled pending hold cannot start late", pendingRelease.arm(generation: pendingToken).isEmpty)

        var missedToggle = ModifierShortcutState(keyCode: 59, hold: false)
        _ = missedToggle.flagsChanged(keyCode: 59, flags: leftControl)
        try check("toggle reconciliation clears state without activating", missedToggle.flagsChanged(keyCode: 56, flags: shiftOnly) == [.disarm] && !missedToggle.isPressed)
        try check("later unrelated release cannot activate toggle", missedToggle.flagsChanged(keyCode: 56, flags: []).isEmpty)
        try check("next genuine toggle press still waits for release", missedToggle.flagsChanged(keyCode: 59, flags: leftControl).isEmpty)
        try check("next clean tap toggles after reconciliation", missedToggle.flagsChanged(keyCode: 59, flags: nativeUp) == [.disarm, .toggle])

        let sides: [(UInt32, UInt32, NSEvent.ModifierFlags, UInt, UInt)] = [
            (55,54,.command,UInt(NX_DEVICELCMDKEYMASK),UInt(NX_DEVICERCMDKEYMASK)),
            (54,55,.command,UInt(NX_DEVICERCMDKEYMASK),UInt(NX_DEVICELCMDKEYMASK)),
            (56,60,.shift,UInt(NX_DEVICELSHIFTKEYMASK),UInt(NX_DEVICERSHIFTKEYMASK)),
            (60,56,.shift,UInt(NX_DEVICERSHIFTKEYMASK),UInt(NX_DEVICELSHIFTKEYMASK)),
            (58,61,.option,UInt(NX_DEVICELALTKEYMASK),UInt(NX_DEVICERALTKEYMASK)),
            (61,58,.option,UInt(NX_DEVICERALTKEYMASK),UInt(NX_DEVICELALTKEYMASK)),
            (59,62,.control,UInt(NX_DEVICELCTLKEYMASK),UInt(NX_DEVICERCTLKEYMASK)),
            (62,59,.control,UInt(NX_DEVICERCTLKEYMASK),UInt(NX_DEVICELCTLKEYMASK))
        ]
        for (selected, opposite, family, selectedMask, oppositeMask) in sides {
            var physical = ModifierShortcutState(keyCode: selected, hold: true)
            let arm = try armToken(physical.flagsChanged(keyCode: selected, flags: modifierFlags(family, selectedMask)))
            _ = physical.arm(generation: arm)
            try check("opposite side does not release key \(selected)", physical.flagsChanged(keyCode: opposite, flags: modifierFlags(family, selectedMask | oppositeMask)).isEmpty)
            try check("selected side \(selected) releases while opposite is held", physical.flagsChanged(keyCode: selected, flags: modifierFlags(family, oppositeMask)) == [.disarm, .finishHold])
            try check("duplicate selected-side \(selected) release is ignored", physical.flagsChanged(keyCode: selected, flags: modifierFlags(family, oppositeMask)).isEmpty)
        }
        var sidedToggle = ModifierShortcutState(keyCode: 59, hold: false)
        let rightControl = modifierFlags(.control, UInt(NX_DEVICERCTLKEYMASK))
        let bothControls = modifierFlags(.control, UInt(NX_DEVICELCTLKEYMASK | NX_DEVICERCTLKEYMASK))
        try check("opposite-side press cannot activate toggle", sidedToggle.flagsChanged(keyCode: 62, flags: rightControl).isEmpty)
        try check("selected-side press waits while opposite is held", sidedToggle.flagsChanged(keyCode: 59, flags: bothControls).isEmpty)
        try check("selected-side release toggles with opposite still held", sidedToggle.flagsChanged(keyCode: 59, flags: rightControl).contains(.toggle))
        try check("duplicate sided release cannot toggle twice", sidedToggle.flagsChanged(keyCode: 59, flags: rightControl).isEmpty)
        var function = ModifierShortcutState(keyCode: 63, hold: false)
        try check("Fn press waits for release", function.flagsChanged(keyCode: 63, flags: .function).isEmpty)
        try check("Fn release toggles once", function.flagsChanged(keyCode: 63, flags: []).contains(.toggle))
        var aggregate = ModifierShortcutState(keyCode: 59, hold: false)
        _ = aggregate.flagsChanged(keyCode: 59, flags: .control)
        try check("aggregate-only flags retain plain modifier taps", aggregate.flagsChanged(keyCode: 59, flags: []).contains(.toggle))
        print("\(count)/\(count) shortcut checks passed using production GlobalHotkey.swift.")
        print("No shortcuts were registered, and no keyboard events or microphone activity occurred.")
    }
}
