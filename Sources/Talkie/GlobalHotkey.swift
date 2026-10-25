import AppKit
import ApplicationServices
import Carbon
import IOKit.hidsystem

/// A physical key combination or a single modifier. Only the chosen shortcut is
/// persisted; shortcut recording never stores ordinary keyboard events.
struct HotkeyChoice: Codable, Equatable, Hashable, Identifiable {
    enum Kind: String, Codable { case combination, modifier }
    let kind: Kind
    let keyCode: UInt32
    let modifiers: UInt32
    let keyLabel: String
    var id: String { "\(kind.rawValue)-\(keyCode)-\(modifiers)" }

    static let controlOptionSpace = HotkeyChoice(kind: .combination, keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey), keyLabel: "Space")
    static let controlShiftSpace = HotkeyChoice(kind: .combination, keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | shiftKey), keyLabel: "Space")
    static let optionShiftSpace = HotkeyChoice(kind: .combination, keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey | shiftKey), keyLabel: "Space")
    static let allCases: [HotkeyChoice] = [.controlOptionSpace, .controlShiftSpace, .optionShiftSpace]
    static let functionKeyCodes: Set<UInt32> = [122,120,99,118,96,97,98,100,101,109,103,111,105,107,113,106,64,79,80,90]

    init(kind: Kind, keyCode: UInt32, modifiers: UInt32, keyLabel: String) {
        self.kind = kind; self.keyCode = keyCode; self.modifiers = modifiers; self.keyLabel = keyLabel
    }
    init?(rawValue: String) {
        switch rawValue {
        case "controlOptionSpace": self = .controlOptionSpace
        case "controlShiftSpace": self = .controlShiftSpace
        case "optionShiftSpace": self = .optionShiftSpace
        default: return nil
        }
    }
    var symbols: String {
        if kind == .modifier { return keyLabel }
        return symbolParts.joined(separator: " ")
    }
    var symbolParts: [String] {
        if kind == .modifier { return [keyLabel] }
        var result: [String] = []
        if modifiers & UInt32(controlKey) != 0 { result.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { result.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { result.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { result.append("⌘") }
        result.append(keyLabel)
        return result
    }
    var label: String {
        if kind == .modifier { return keyLabel }
        var result: [String] = []
        if modifiers & UInt32(controlKey) != 0 { result.append("Control") }
        if modifiers & UInt32(optionKey) != 0 { result.append("Option") }
        if modifiers & UInt32(shiftKey) != 0 { result.append("Shift") }
        if modifiers & UInt32(cmdKey) != 0 { result.append("Command") }
        return (result + [keyLabel]).joined(separator: " + ")
    }
    var validationError: String? {
        guard keyCode <= 127, !keyLabel.isEmpty, keyLabel.count <= 20 else { return "That key is not supported. Try another shortcut." }
        if kind == .modifier {
            return Self.modifierInfo[keyCode] == nil || modifiers != 0 ? "Choose a modifier key or a key combination." : nil
        }
        let allowed = UInt32(controlKey | optionKey | shiftKey | cmdKey)
        guard modifiers & ~allowed == 0, Self.modifierInfo[keyCode] == nil else { return "That combination is not supported." }
        guard modifiers & UInt32(controlKey | optionKey | cmdKey) != 0 || Self.functionKeyCodes.contains(keyCode) else {
            return "Include Control, Option or Command, or use a function key. You can also record a modifier on its own."
        }
        let reserved = (modifiers == UInt32(cmdKey) && [UInt32(kVK_ANSI_Q), UInt32(kVK_ANSI_W), UInt32(kVK_ANSI_V), UInt32(kVK_Tab), UInt32(kVK_Space)].contains(keyCode)) || (modifiers == UInt32(controlKey) && keyCode == UInt32(kVK_Space))
        return reserved ? "That shortcut is used for a standard Mac action. Choose another combination." : nil
    }
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        return result
    }
    static let modifierInfo: [UInt32: (name: String, flag: NSEvent.ModifierFlags)] = [
        54: ("Right Command", .command), 55: ("Left Command", .command),
        56: ("Left Shift", .shift), 60: ("Right Shift", .shift),
        58: ("Left Option", .option), 61: ("Right Option", .option),
        59: ("Left Control", .control), 62: ("Right Control", .control), 63: ("Fn / Globe", .function)
    ]
    static func keyName(_ event: NSEvent) -> String {
        let special: [UInt16: String] = [49:"Space",36:"Return",48:"Tab",53:"Esc",51:"Delete",117:"Forward Delete",123:"←",124:"→",125:"↓",126:"↑",115:"Home",119:"End",116:"Page Up",121:"Page Down",122:"F1",120:"F2",99:"F3",118:"F4",96:"F5",97:"F6",98:"F7",100:"F8",101:"F9",109:"F10",103:"F11",111:"F12",105:"F13",107:"F14",113:"F15",106:"F16",64:"F17",79:"F18",80:"F19",90:"F20"]
        return special[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased().prefix(12).description ?? "Key \(event.keyCode)"
    }
}

/// Event-local shortcut state, independent of permissions and event monitors.
/// Toggle waits for a clean tap; hold arms after its delay and cancels for typing.
struct ModifierShortcutState {
    enum Action: Equatable {
        case arm(UInt64), disarm, beginHold, finishHold, cancelHold, toggle
    }

    let keyCode: UInt32
    let hold: Bool
    private(set) var isPressed = false
    private var blocked = false
    private var activated = false
    private var generation: UInt64 = 0

    mutating func flagsChanged(keyCode eventKey: UInt32, flags: NSEvent.ModifierFlags) -> [Action] {
        guard let info = HotkeyChoice.modifierInfo[keyCode] else { return [] }
        let relevant: NSEvent.ModifierFlags = [.control, .option, .command, .shift, .function]
        let alone = flags.intersection(relevant) == info.flag
        // An unrelated modifier event can prove that a selected-key release
        // was missed. Recover without treating that event as a clean tap.
        if eventKey != keyCode, !flags.contains(info.flag) { return reconcileMissingRelease() }
        guard eventKey == keyCode else { return isPressed && !alone ? blockForTyping() : [] }
        let down = Self.physicalKeyIsDown(keyCode, flags: flags)
        guard down != isPressed else { return isPressed && !alone ? blockForTyping() : [] }
        generation &+= 1
        if down {
            isPressed = true
            blocked = !alone
            activated = false
            return hold && alone ? [.arm(generation)] : []
        }
        let cleanTap = !blocked
        let wasActivated = activated
        isPressed = false
        blocked = false
        activated = false
        if hold { return wasActivated ? [.disarm, .finishHold] : [.disarm] }
        return cleanTap ? [.disarm, .toggle] : [.disarm]
    }

    mutating func keyDown() -> [Action] { isPressed ? blockForTyping() : [] }

    mutating func arm(generation expected: UInt64) -> [Action] {
        guard hold, isPressed, !blocked, !activated, generation == expected else { return [] }
        activated = true
        return [.beginHold]
    }

    mutating func reset() {
        generation &+= 1
        isPressed = false
        blocked = false
        activated = false
    }

    private mutating func reconcileMissingRelease() -> [Action] {
        guard isPressed || blocked || activated else { return [] }
        let wasActivated = activated
        reset()
        return hold && wasActivated ? [.disarm, .cancelHold] : [.disarm]
    }

    private mutating func blockForTyping() -> [Action] {
        guard !blocked else { return [] }
        generation &+= 1
        blocked = true
        let wasActivated = activated
        activated = false
        return wasActivated ? [.disarm, .cancelHold] : [.disarm]
    }

    private static func physicalKeyIsDown(_ keyCode: UInt32, flags: NSEvent.ModifierFlags) -> Bool {
        let left: UInt
        let right: UInt
        let selected: UInt
        switch keyCode {
        case 54, 55:
            left = UInt(NX_DEVICELCMDKEYMASK); right = UInt(NX_DEVICERCMDKEYMASK)
            selected = keyCode == 55 ? left : right
        case 56, 60:
            left = UInt(NX_DEVICELSHIFTKEYMASK); right = UInt(NX_DEVICERSHIFTKEYMASK)
            selected = keyCode == 56 ? left : right
        case 58, 61:
            left = UInt(NX_DEVICELALTKEYMASK); right = UInt(NX_DEVICERALTKEYMASK)
            selected = keyCode == 58 ? left : right
        case 59, 62:
            left = UInt(NX_DEVICELCTLKEYMASK); right = UInt(NX_DEVICERCTLKEYMASK)
            selected = keyCode == 59 ? left : right
        default:
            return HotkeyChoice.modifierInfo[keyCode].map { flags.contains($0.flag) } ?? false
        }
        // Native left/right flags distinguish release from a duplicate event
        // even while the opposite-side key keeps the aggregate modifier set.
        if flags.rawValue & (left | right) != 0 { return flags.rawValue & selected != 0 }
        return HotkeyChoice.modifierInfo[keyCode].map { flags.contains($0.flag) } ?? false
    }
}

enum GlobalHotkeyError: LocalizedError {
    case registration(OSStatus)
    case accessibility
    case invalid(String)
    var errorDescription: String? {
        switch self {
        case .registration(let status): return "The shortcut could not be registered (\(status)). Another app may use it. Record another shortcut in Settings."
        case .accessibility: return "Allow insertion access in Settings to use a modifier key on its own."
        case .invalid(let message): return message
        }
    }
}

@MainActor
final class GlobalHotkey {
    var onKeyDown: () -> Void
    var onKeyUp: () -> Void
    var onOtherKey: () -> Void
    private var hotkey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var held = false
    private var running = false
    private var modifierState: ModifierShortcutState
    private var armTask: Task<Void, Never>?
    private let modifierDelay: TimeInterval
    private let choice: HotkeyChoice
    private static let signature: OSType = 0x54414C4B

    init(choice: HotkeyChoice = .controlOptionSpace, modifierDelay: TimeInterval = 0.15, onKeyDown: @escaping () -> Void, onKeyUp: @escaping () -> Void, onOtherKey: @escaping () -> Void = {}) {
        self.choice = choice; self.modifierDelay = modifierDelay
        modifierState = ModifierShortcutState(keyCode: choice.keyCode, hold: modifierDelay > 0)
        self.onKeyDown = onKeyDown; self.onKeyUp = onKeyUp; self.onOtherKey = onOtherKey
    }
    deinit {
        if let hotkey { UnregisterEventHotKey(hotkey) }
        if let handler { RemoveEventHandler(handler) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        armTask?.cancel()
    }
    func start() throws {
        guard !running else { return }
        if let error = choice.validationError { throw GlobalHotkeyError.invalid(error) }
        if choice.kind == .modifier {
            guard AXIsProcessTrusted() else { throw GlobalHotkeyError.accessibility }
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in self?.receiveModifierEvent(event) }
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in self?.receiveModifierEvent(event); return event }
            guard globalMonitor != nil, localMonitor != nil else { stop(); throw GlobalHotkeyError.registration(OSStatus(eventNotHandledErr)) }
            running = true
            return
        }
        var kinds = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)), EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard result == noErr, identifier.signature == 0x54414C4B, identifier.id == 1 else { return OSStatus(eventNotHandledErr) }
            let controller = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            DispatchQueue.main.async { [weak controller] in controller?.receive(pressed: pressed) }
            return noErr
        }, kinds.count, &kinds, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { throw GlobalHotkeyError.registration(status) }
        let registration = RegisterEventHotKey(choice.keyCode, choice.modifiers, EventHotKeyID(signature: Self.signature, id: 1), GetApplicationEventTarget(), 0, &hotkey)
        guard registration == noErr else { stop(); throw GlobalHotkeyError.registration(registration) }
        running = true
    }
    func stop() {
        running = false
        armTask?.cancel(); armTask = nil
        if let hotkey { UnregisterEventHotKey(hotkey) }
        if let handler { RemoveEventHandler(handler) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        hotkey = nil; handler = nil; globalMonitor = nil; localMonitor = nil; held = false
        modifierState.reset()
    }
    private func receiveModifierEvent(_ event: NSEvent) {
        guard running else { return }
        let actions = event.type == .keyDown
            ? modifierState.keyDown()
            : modifierState.flagsChanged(keyCode: UInt32(event.keyCode), flags: event.modifierFlags)
        applyModifierActions(actions)
    }
    private func applyModifierActions(_ actions: [ModifierShortcutState.Action]) {
        for action in actions {
            switch action {
            case .arm(let generation):
                armTask?.cancel()
                armTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(self?.modifierDelay ?? 0.15)) } catch { return }
                    guard let self, self.running, !Task.isCancelled else { return }
                    self.applyModifierActions(self.modifierState.arm(generation: generation))
                }
            case .disarm: armTask?.cancel(); armTask = nil
            case .beginHold: receive(pressed: true)
            case .finishHold: receive(pressed: false)
            case .cancelHold:
                if held { held = false; onOtherKey() }
            case .toggle: onKeyDown()
            }
        }
    }
    private func receive(pressed: Bool) {
        guard running else { return }
        if pressed { guard !held else { return }; held = true; onKeyDown() }
        else if held { held = false; onKeyUp() }
    }
}
