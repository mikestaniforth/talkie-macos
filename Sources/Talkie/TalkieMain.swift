import AppKit
import SwiftUI
import Combine
import AVFoundation

@main
struct TalkieMain {
    @MainActor private static var appDelegate: TalkieDelegate?

    @MainActor static func main() {
        let args = CommandLine.arguments
        if args.contains("--download-model") || args.contains("--transcribe") || args.contains("--self-check") || args.contains("--benchmark-speech") {
            Task { await commandLine(args) }
            dispatchMain()
        }
        let app = NSApplication.shared
        let showInDock = TalkieEnvironment.defaults.object(forKey: "showInDock") as? Bool ?? true
        app.setActivationPolicy(showInDock ? .regular : .accessory)
        if let iconURL = Bundle.main.url(forResource: "Talkie", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            app.applicationIconImage = icon
        }
        let delegate = TalkieDelegate()
        appDelegate = delegate
        app.delegate = delegate
        app.run()
    }

    @MainActor static func commandLine(_ args: [String]) async {
        let engine = SpeechEngine(useGPU: args.contains("--gpu"))
        var observer: AnyCancellable?
        var previous = -1
        do {
            if let index = args.firstIndex(of: "--benchmark-speech"), args.indices.contains(index + 1) {
                let url = URL(fileURLWithPath: args[index + 1])
                let start = Date()
                try await engine.prepare()
                let prepared = Date()
                let first = try await engine.transcribe(audioURL: url, vocabulary: [])
                let transcribed = Date()
                await engine.unload()
                let unloaded = Date()
                try await engine.prepare()
                let reloaded = Date()
                let second = try await engine.transcribe(audioURL: url, vocabulary: [])
                let end = Date()
                let report: [String: Any] = ["backend": args.contains("--gpu") ? "CPU + GPU" : "CPU + Neural Engine", "prepareSeconds": prepared.timeIntervalSince(start), "firstRecognitionSeconds": transcribed.timeIntervalSince(prepared), "unloadSeconds": unloaded.timeIntervalSince(transcribed), "reloadSeconds": reloaded.timeIntervalSince(unloaded), "secondRecognitionSeconds": end.timeIntervalSince(reloaded), "firstTranscript": first, "secondTranscript": second]
                print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
                exit(0)
            }
            if args.contains("--self-check") {
                let report: [String: Any] = [
                    "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
                    "bundleID": Bundle.main.bundleIdentifier ?? "swift-package",
                    "modelInstalled": engine.hasDownloadedModel,
                    "microphonePermission": AVCaptureDevice.authorizationStatus(for: .audio).rawValue,
                    "accessibilityTrusted": AXIsProcessTrusted(),
                    "localOnly": true
                ]
                let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                print(String(decoding: data, as: UTF8.self))
                exit(0)
            }
            if args.contains("--download-model") {
                observer = engine.$progress.sink { progress in
                    let percent = Int(progress * 100)
                    if percent / 10 > previous / 10 || previous == -1 { print("Model download: \(percent)%"); fflush(stdout); previous = percent }
                }
                print("Installing verified local speech model…"); fflush(stdout)
                try await engine.downloadModel()
            }
            try await engine.prepare()
            print("Local speech model ready."); fflush(stdout)
            if let index = args.firstIndex(of: "--transcribe"), args.indices.contains(index + 1) {
                let text = try await engine.transcribe(audioURL: URL(fileURLWithPath: args[index + 1]), vocabulary: [])
                print(text)
            }
            withExtendedLifetime(observer) {}
            exit(0)
        } catch {
            fputs("Talkie: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}

@MainActor
final class TalkieDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var libraryWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var hud: NSPanel?
    private var hotkey: GlobalHotkey?
    private var registeredHotkey: HotkeyChoice?
    private var subscriptions = Set<AnyCancellable>()
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Talkie")
            button.toolTip = "\(TalkieEnvironment.displayName) · Control–Option–Space"
            button.target = self
            button.action = #selector(togglePopover)
        }
        popover.contentViewController = NSHostingController(rootView: TalkieMenuView(model: model))
        popover.behavior = .transient
        model.openLibrary = { [weak self] in self?.showLibrary() }
        model.openSettings = { [weak self] in self?.showSettings() }
        model.$showInDock.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] visible in
            self?.applyDockVisibility(visible)
        }.store(in: &subscriptions)
        model.$hudVisible.combineLatest(model.$phase).receive(on: RunLoop.main).sink { [weak self] visible, phase in
            self?.updateHUD(visible)
            self?.statusItem?.button?.image = NSImage(systemSymbolName: phase == .recording ? "mic.fill" : "waveform", accessibilityDescription: "Talkie")
        }.store(in: &subscriptions)
        model.$hotkeyChoice.combineLatest(model.$isRecordingShortcut, model.$shortcutMode).receive(on: RunLoop.main).sink { [weak self] choice, recording, _ in
            if recording { self?.hotkey?.stop() }
            else { self?.installHotkey(choice) }
        }.store(in: &subscriptions)
        model.$accessibilityGranted.removeDuplicates().dropFirst().filter { $0 }.receive(on: RunLoop.main).sink { [weak self] _ in
            guard let self, self.model.hotkeyChoice.kind == .modifier, self.model.phase == .idle, !self.model.isRecordingShortcut else { return }
            self.installHotkey(self.model.hotkeyChoice)
        }.store(in: &subscriptions)
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.model.refreshPermissions()
            }
        }
        Task {
            if !TalkieEnvironment.defaults.bool(forKey: "completedFirstLaunch") || !model.speech.hasDownloadedModel || !model.microphoneGranted || !model.accessibilityGranted {
                showSettings()
                TalkieEnvironment.defaults.set(true, forKey: "completedFirstLaunch")
            }
            await model.initialize()
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else { model.refreshPermissions(); popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
    }

    private func applyDockVisibility(_ visible: Bool) {
        let policy: NSApplication.ActivationPolicy = visible ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        guard NSApp.setActivationPolicy(policy) else {
            model.showInDock = NSApp.activationPolicy() == .regular
            model.error = "Talkie could not change its Dock visibility. Try again in Settings."
            return
        }
    }

    private func installMainMenu() {
        let bar = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: TalkieEnvironment.displayName)
        appMenu.addItem(withTitle: "About \(TalkieEnvironment.displayName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        let library = NSMenuItem(title: "Open Library", action: #selector(showLibrary), keyEquivalent: "l")
        library.target = self
        appMenu.addItem(library)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(TalkieEnvironment.displayName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit \(TalkieEnvironment.displayName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        bar.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        bar.addItem(editItem)
        let windowItem = NSMenuItem()
        let windows = NSMenu(title: "Window")
        windows.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windows.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windows
        bar.addItem(windowItem)
        NSApp.windowsMenu = windows
        NSApp.mainMenu = bar
    }

    private func installHotkey(_ choice: HotkeyChoice) {
        hotkey?.stop()
        hotkey = GlobalHotkey(choice: choice, modifierDelay: model.shortcutMode == .hold ? 0.15 : 0,
                              onKeyDown: { [weak self] in self?.model.hotkeyDown() },
                              onKeyUp: { [weak self] in self?.model.hotkeyUp() },
                              onOtherKey: { [weak self] in self?.model.shortcutUsedForTyping() })
        do {
            try hotkey?.start()
            registeredHotkey = choice
            statusItem?.button?.toolTip = "\(TalkieEnvironment.displayName) · \(choice.label)"
        } catch {
            model.shortcutRecordingError = error.localizedDescription
            if let previous = registeredHotkey, previous != choice {
                // Restore the last working binding instead of saving a conflict
                // that silently disables dictation on the next launch.
                model.hotkeyChoice = previous
            } else if choice.kind == .modifier && !model.accessibilityGranted {
                statusItem?.button?.toolTip = "\(TalkieEnvironment.displayName) · Shortcut needs insertion access"
            } else { model.error = error.localizedDescription }
        }
    }

    @objc func showLibrary() {
        popover.performClose(nil)
        if libraryWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 680), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "\(TalkieEnvironment.displayName) Library"
            window.contentView = NSHostingView(rootView: LibraryWindow(model: model))
            window.minSize = NSSize(width: 870, height: 600)
            window.setFrameAutosaveName("TalkieLibrary")
            window.isReleasedWhenClosed = false
            window.center()
            libraryWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        if libraryWindow?.isMiniaturized == true { libraryWindow?.deminiaturize(nil) }
        libraryWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func showSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 600), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "\(TalkieEnvironment.displayName) Settings"
            window.contentView = NSHostingView(rootView: SettingsWindow(model: model))
            window.minSize = NSSize(width: 720, height: 550)
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        model.refreshPermissions()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func updateHUD(_ visible: Bool) {
        guard visible else { hud?.orderOut(nil); return }
        if hud == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 228, height: 60), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView: RecordingHUD(model: model))
            hud = panel
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            hud?.setFrameOrigin(NSPoint(x: frame.midX - 114, y: frame.minY + 8))
        }
        hud?.orderFrontRegardless()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showLibrary(); return false }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model.unsavedText != nil {
            model.error = "Copy the unsaved text before quitting Talkie."
            showLibrary()
            return .terminateCancel
        }
        if model.phase == .recording {
            Task { await model.finishRecording(interruption: "Talkie was closed during recording."); NSApp.reply(toApplicationShouldTerminate: model.unsavedText == nil) }
            return .terminateLater
        }
        if model.phase == .transcribing {
            model.error = "Talkie is finishing an operation. Wait for it to finish before quitting."
            showLibrary()
            return .terminateCancel
        }
        if model.phase == .testing {
            Task { await model.finishMicTest(); NSApp.reply(toApplicationShouldTerminate: true) }
            return .terminateLater
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) { hotkey?.stop(); permissionTimer?.invalidate(); model.speech.cancel(); model.audio.cancel() }
}
