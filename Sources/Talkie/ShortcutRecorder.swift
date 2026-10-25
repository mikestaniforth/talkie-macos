import SwiftUI
import AppKit

struct ShortcutRecorderControl: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Dictation shortcut").fontWeight(.medium)
                    Text(model.isRecordingShortcut ? "Press your shortcut. Esc cancels." : "A key combination, or a modifier held on its own.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                if model.isRecordingShortcut {
                    Label("Listening for keys…", systemImage: "keyboard")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.tint)
                } else {
                    HStack(spacing: 4) {
                        ForEach(Array(model.hotkeyChoice.symbolParts.enumerated()), id: \.offset) { _, part in
                            Text(part).font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 8).padding(.vertical, 6)
                                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.primary.opacity(0.12)))
                        }
                    }.accessibilityElement(children: .ignore).accessibilityLabel(model.hotkeyChoice.label)
                }
                Button(model.isRecordingShortcut ? "Cancel" : "Record shortcut") {
                    if model.isRecordingShortcut { model.cancelShortcutRecording() }
                    else { model.beginShortcutRecording() }
                }.disabled(model.phase != .idle)
            }
            if let message = model.shortcutRecordingError {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if model.hotkeyChoice.kind == .modifier && model.hotkeyChoice.keyCode == 63 {
                Text("Fn / Globe can also trigger its Mac keyboard action. Set that action to Do Nothing in macOS Keyboard settings if it interferes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("Modifier only: press and release it to record the choice.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Restore default") { model.useShortcut(.controlOptionSpace) }
                    .font(.caption).buttonStyle(.link).disabled(model.phase != .idle || model.isRecordingShortcut || model.hotkeyChoice == .controlOptionSpace)
            }
            ShortcutCaptureBridge(recording: model.isRecordingShortcut,
                                  onShortcut: { model.useShortcut($0) },
                                  onError: { model.shortcutRecordingError = $0 },
                                  onCancel: { model.cancelShortcutRecording() })
                .frame(width: 1, height: 1).accessibilityHidden(true)
        }
        .onDisappear { if model.isRecordingShortcut { model.cancelShortcutRecording() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            if model.isRecordingShortcut { model.cancelShortcutRecording() }
        }
    }
}

private struct ShortcutCaptureBridge: NSViewRepresentable {
    let recording: Bool
    let onShortcut: (HotkeyChoice) -> Void
    let onError: (String) -> Void
    let onCancel: () -> Void
    func makeNSView(context: Context) -> ShortcutCaptureView { ShortcutCaptureView() }
    func updateNSView(_ view: ShortcutCaptureView, context: Context) {
        view.onShortcut = onShortcut; view.onError = onError; view.onCancel = onCancel
        view.recording = recording
        if recording { DispatchQueue.main.async { [weak view] in guard let view, view.recording else { return }; view.window?.makeFirstResponder(view) } }
    }
}

private final class ShortcutCaptureView: NSView {
    var onShortcut: ((HotkeyChoice) -> Void)?
    var onError: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var recording = false {
        didSet {
            guard oldValue != recording else { return }
            if recording {
                // Capture before menu key equivalents, so recording Command-Q
                // cannot quit Talkie and Command-W cannot close this window.
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
                    guard let self, self.recording, self.window?.isKeyWindow == true else { return event }
                    if event.type == .keyDown { self.keyDown(with: event) }
                    else { self.flagsChanged(with: event) }
                    return nil
                }
            } else {
                modifierCandidate = nil
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
        }
    }
    private var monitor: Any?
    private var modifierCandidate: UInt32?
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    override var acceptsFirstResponder: Bool { recording }
    override func resignFirstResponder() -> Bool {
        if recording { onCancel?() }
        return true
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording, event.type == .keyDown else { return false }
        keyDown(with: event)
        return true
    }
    override func keyDown(with event: NSEvent) {
        guard recording, !event.isARepeat else { return }
        if event.keyCode == 53 && HotkeyChoice.carbonModifiers(event.modifierFlags) == 0 { onCancel?(); return }
        modifierCandidate = nil
        if event.modifierFlags.contains(.function), !HotkeyChoice.functionKeyCodes.contains(UInt32(event.keyCode)) {
            onError?("Fn combinations with this key are not supported. Record Fn on its own or choose another modifier.")
            return
        }
        let shortcut = HotkeyChoice(kind: .combination, keyCode: UInt32(event.keyCode), modifiers: HotkeyChoice.carbonModifiers(event.modifierFlags), keyLabel: HotkeyChoice.keyName(event))
        if let error = shortcut.validationError { onError?(error) }
        else { onShortcut?(shortcut) }
    }
    override func flagsChanged(with event: NSEvent) {
        guard recording else { return }
        let key = UInt32(event.keyCode)
        let relevant: NSEvent.ModifierFlags = [.control,.option,.shift,.command,.function]
        let flags = event.modifierFlags.intersection(relevant)
        if let candidate = modifierCandidate, candidate == key, let info = HotkeyChoice.modifierInfo[candidate], !flags.contains(info.flag) {
            modifierCandidate = nil
            onShortcut?(HotkeyChoice(kind: .modifier, keyCode: candidate, modifiers: 0, keyLabel: info.name))
        } else if let info = HotkeyChoice.modifierInfo[key], flags == info.flag {
            modifierCandidate = key
        } else { modifierCandidate = nil }
    }
}
