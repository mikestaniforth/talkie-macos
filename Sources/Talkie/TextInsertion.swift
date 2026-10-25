import AppKit
import ApplicationServices
import Carbon

struct InsertionTarget {
    let appName: String
    let bundleIdentifier: String?
    fileprivate let processID: pid_t
    fileprivate let element: AXUIElement
    fileprivate let selection: CFRange?
    fileprivate let originalValue: String?
    fileprivate let originalSelectedText: String?
}

enum InsertionOutcome: Equatable {
    /// The focused field's full value was read back and matched the expected edit.
    case inserted
    /// A mutation or paste was attempted, but field acceptance was not verified.
    case pasteAttempted
    /// Clipboard contains the transcript; this is deliberately not a success claim.
    case clipboardReady(String)
    case failed(String)
}

@MainActor
final class TextInsertion {
    /// Technical delivery metadata only; never includes dictated or field text.
    private(set) var lastDiagnostic: String?

    func captureTarget() -> InsertionTarget? {
        lastDiagnostic = nil
        guard AXIsProcessTrusted() else {
            lastDiagnostic = "Accessibility access is unavailable. Dictation can be saved for manual copying."
            return nil
        }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            lastDiagnostic = "No other app's text field is selected. Dictation can be saved for manual copying."
            return nil
        }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let focused = attribute(appElement, kAXFocusedUIElementAttribute),
              CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            lastDiagnostic = "The selected app did not expose a focused field through Accessibility."
            return nil
        }
        let element = unsafeDowncast(focused, to: AXUIElement.self)
        guard stringAttribute(element, kAXSubroleAttribute) != kAXSecureTextFieldSubrole as String else {
            lastDiagnostic = "The selected field is a secure text field. No text will be inserted."
            return nil
        }
        let role = stringAttribute(element, kAXRoleAttribute) ?? ""
        guard [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String].contains(role)
                || isSettable(element, kAXSelectedTextAttribute) else {
            lastDiagnostic = "The focused element did not expose an editable text role."
            return nil
        }
        lastDiagnostic = "A focused editable field was captured."
        return InsertionTarget(appName: app.localizedName ?? "the selected app", bundleIdentifier: app.bundleIdentifier,
                               processID: app.processIdentifier, element: element, selection: selection(element),
                               originalValue: stringAttribute(element, kAXValueAttribute),
                               originalSelectedText: stringAttribute(element, kAXSelectedTextAttribute))
    }

    func insert(text: String, to target: InsertionTarget) async -> InsertionOutcome {
        guard !text.isEmpty else {
            lastDiagnostic = "No insertion was attempted because the transcript is empty."
            return .failed("There is no text to insert.")
        }
        if let reason = targetMismatchReason(target) {
            return copyForRecovery(text, reason)
        }
        guard await waitForModifiers() else {
            return copyForRecovery(text, "Keyboard modifiers are still held. Release them, then paste your words.")
        }
        if let reason = targetMismatchReason(target) {
            return copyForRecovery(text, reason)
        }
        let expected = expectedValue(text, target)
        // Web and custom editors may claim AXSelectedText is settable and even
        // return success without committing the edit to their actual document.
        // Use the app's ordinary paste path once; never follow it with an AX
        // mutation or an automatic retry that could duplicate accepted text.
        guard writeClipboard(text) else {
            lastDiagnostic = "No paste was attempted because writing the clipboard failed."
            return .failed("The clipboard could not be written. Copy the transcript from History.")
        }
        if let reason = targetMismatchReason(target) { return copyForRecovery(text, reason) }
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
            lastDiagnostic = "No paste was attempted because keyboard events could not be created. The transcript is on the clipboard."
            return .clipboardReady("Your words are on the clipboard. Paste them into the selected field.")
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        guard modifiersAreClear() else {
            lastDiagnostic = "No paste was attempted because keyboard modifiers were pressed again. The transcript is on the clipboard."
            return .clipboardReady("Keyboard modifiers are held. Release them, then paste your words.")
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        // No Enter, automatic retry or clipboard restoration. Those could send
        // a message, duplicate text or replace a newer user clipboard item.
        if await verify(expected, target) {
            lastDiagnostic = "Clipboard + Command–V was sent once. The complete expected field value was verified."
            return .inserted
        }
        lastDiagnostic = expected == nil
            ? "Clipboard + Command–V was sent once. The field does not expose readable text for full insertion verification. Check the field before pasting again."
            : "Clipboard + Command–V was sent once. The complete expected field value could not be verified. Check the field before pasting again."
        return .pasteAttempted
    }

    private func targetMismatchReason(_ target: InsertionTarget) -> String? {
        guard AXIsProcessTrusted() else {
            return "Accessibility access is unavailable. Your words are ready to paste."
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processID else {
            return "The selected app changed while dictating. Your words are ready to paste."
        }
        let application = AXUIElementCreateApplication(target.processID)
        guard let focused = attribute(application, kAXFocusedUIElementAttribute), CFEqual(focused, target.element) else {
            return "The selected field changed or became unavailable. Your words are ready to paste."
        }
        guard stringAttribute(target.element, kAXSubroleAttribute) != kAXSecureTextFieldSubrole as String else {
            return "The selected field became secure. Your words were not inserted and are ready to paste elsewhere."
        }
        let now = selection(target.element)
        if let original = target.selection {
            guard let now, original.location == now.location, original.length == now.length else {
                return "The caret or text selection changed while dictating. Your words are ready to paste."
            }
            guard original.location >= 0, original.length >= 0 else {
                return "The field reported an invalid caret position. Your words are ready to paste."
            }
            if let value = target.originalValue {
                let length = (value as NSString).length
                guard original.location <= length, original.length <= length - original.location else {
                    return "The field reported an invalid text selection. Your words are ready to paste."
                }
            }
        } else {
            // Without an observable caret/selection we cannot safely promise
            // that the field still represents the user's original destination.
            return "This field does not expose its caret position. Your words are ready to paste."
        }
        if let original = target.originalValue,
           stringAttribute(target.element, kAXValueAttribute) != original {
            return "The field's text changed while dictating. Your words are ready to paste."
        }
        if let selected = target.originalSelectedText,
           stringAttribute(target.element, kAXSelectedTextAttribute) != selected {
            return "The selected text changed while dictating. Your words are ready to paste."
        }
        return nil
    }

    private func expectedValue(_ text: String, _ target: InsertionTarget) -> String? {
        guard let original = target.originalValue, let selection = target.selection,
              selection.location >= 0, selection.length >= 0 else { return nil }
        let value = original as NSString
        guard selection.location <= value.length, selection.length <= value.length - selection.location else { return nil }
        return value.replacingCharacters(in: NSRange(location: selection.location, length: selection.length), with: text)
    }

    private func verify(_ expected: String?, _ target: InsertionTarget) async -> Bool {
        guard let expected else { return false }
        for _ in 0..<20 {
            if stringAttribute(target.element, kAXValueAttribute) == expected { return true }
            do { try await Task.sleep(for: .milliseconds(60)) } catch { return false }
        }
        return false
    }

    private func waitForModifiers() async -> Bool {
        for _ in 0..<60 {
            if modifiersAreClear() { return true }
            do { try await Task.sleep(for: .milliseconds(25)) } catch { return false }
        }
        return false
    }

    private func modifiersAreClear() -> Bool {
        let modifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        return CGEventSource.flagsState(.combinedSessionState).intersection(modifiers).isEmpty
    }

    private func copyForRecovery(_ text: String, _ message: String) -> InsertionOutcome {
        lastDiagnostic = "No paste was attempted. \(message)"
        return writeClipboard(text) ? .clipboardReady(message) : .failed("The clipboard could not be written. Copy the transcript from History.")
    }

    private func writeClipboard(_ text: String) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func stringAttribute(_ element: AXUIElement, _ name: String) -> String? { attribute(element, name) as? String }

    private func isSettable(_ element: AXUIElement, _ name: String) -> Bool {
        var result = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name as CFString, &result) == .success && result.boolValue
    }

    private func selection(_ element: AXUIElement) -> CFRange? {
        guard let value = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let rangeValue = unsafeDowncast(value, to: AXValue.self)
        var range = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &range) else { return nil }
        return range
    }
}
