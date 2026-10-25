import AppKit
import AVFoundation
import Combine
import ServiceManagement

enum CapturePhase: String { case idle, starting, recording, transcribing, testing }
enum ShortcutMode: String, CaseIterable { case hold, toggle }

@MainActor
final class AppModel: ObservableObject {
    let audio = AudioCapture()
    let speech = SpeechEngine()
    let history = HistoryStore()
    let insertion = TextInsertion()
    @Published var phase: CapturePhase = .idle
    @Published var message = "Getting ready…"
    @Published var hudVisible = false
    @Published var selectedSessionID: UUID?
    @Published var activeKitID: String { didSet { TalkieEnvironment.defaults.set(activeKitID, forKey: "activeKitID") } }
    @Published var shortcutMode: ShortcutMode { didSet { TalkieEnvironment.defaults.set(shortcutMode.rawValue, forKey: "shortcutMode") } }
    @Published var hotkeyChoice: HotkeyChoice { didSet { if let data = try? JSONEncoder().encode(hotkeyChoice) { TalkieEnvironment.defaults.set(data, forKey: "recordedHotkey") } } }
    @Published var isRecordingShortcut = false
    @Published var shortcutRecordingError: String?
    @Published private(set) var recordingElapsed: TimeInterval = 0
    @Published var soundEnabled: Bool { didSet { TalkieEnvironment.defaults.set(soundEnabled, forKey: "soundEnabled") } }
    @Published var soundVolume: Double { didSet { TalkieEnvironment.defaults.set(soundVolume, forKey: "soundVolume") } }
    @Published var releaseModelAfterIdle: Bool { didSet { TalkieEnvironment.defaults.set(releaseModelAfterIdle, forKey: "releaseModelAfterIdle") } }
    @Published var microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @Published var accessibilityGranted = AXIsProcessTrusted()
    @Published var unsavedText: String?
    @Published var lastTestURL: URL?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var isPreparing = false
    @Published var error: String?
    var openLibrary: (() -> Void)?
    var openSettings: (() -> Void)?
    private var activeSession: DictationSession?
    private var destination: InsertionTarget?
    private var destinationDiagnostic: String?
    private var recordingStarted: Date?
    private var releasePending = false
    private var cancelPendingShortcut = false
    private var captureTask: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()
    private var sound: NSSound?
    private var testPlayer: AVAudioPlayer?
    private var micTestID = UUID()
    private var lastActivity = Date()
    private var idleTimer: Timer?
    private var elapsedTimer: Timer?

    init() {
        let defaults = TalkieEnvironment.defaults
        activeKitID = defaults.string(forKey: "activeKitID") ?? "everyday"
        shortcutMode = ShortcutMode(rawValue: defaults.string(forKey: "shortcutMode") ?? "hold") ?? .hold
        if let data = defaults.data(forKey: "recordedHotkey"), let stored = try? JSONDecoder().decode(HotkeyChoice.self, from: data), stored.validationError == nil {
            hotkeyChoice = stored
        } else { hotkeyChoice = HotkeyChoice(rawValue: defaults.string(forKey: "hotkeyChoice") ?? "") ?? .controlOptionSpace }
        soundEnabled = defaults.object(forKey: "soundEnabled") as? Bool ?? true
        soundVolume = defaults.object(forKey: "soundVolume") as? Double ?? 0.5
        releaseModelAfterIdle = defaults.object(forKey: "releaseModelAfterIdle") as? Bool ?? false
        audio.selectedDeviceUID = defaults.string(forKey: "preferredMicrophoneUID")
        for publisher in [audio.objectWillChange.eraseToAnyPublisher(), speech.objectWillChange.eraseToAnyPublisher(), history.objectWillChange.eraseToAnyPublisher()] {
            publisher.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        }
        audio.$selectedDeviceUID.dropFirst().sink { uid in
            if let uid { defaults.set(uid, forKey: "preferredMicrophoneUID") } else { defaults.removeObject(forKey: "preferredMicrophoneUID") }
        }.store(in: &subscriptions)
        audio.onInterruption = { [weak self] reason in
            guard let self else { return }
            Task { @MainActor in
                if self.phase == .testing { await self.finishMicTest(); self.message = reason }
                else if self.phase == .recording { await self.finishRecording(interruption: reason) }
            }
        }
        if !history.kits.contains(where: { $0.id == activeKitID }), let first = history.kits.first { activeKitID = first.id }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase == .idle else { return }
                do { try self.history.runRetention() } catch { self.error = error.localizedDescription }
                if let warning = self.history.lastError { self.error = warning }
                if self.releaseModelAfterIdle, Date().timeIntervalSince(self.lastActivity) > 300, self.speech.isReady {
                    await self.speech.unload()
                    self.message = "Ready · Speech model asleep until needed"
                }
            }
        }
    }

    var activeKit: ProjectKit? { history.kits.first { $0.id == activeKitID } ?? history.kits.first }
    var busy: Bool { phase != .idle || speech.isBusy || isPreparing || unsavedText != nil }
    var recentSessions: [DictationSession] { Array(history.sessions.prefix(3)) }
    var microphoneName: String {
        guard let uid = audio.selectedDeviceUID else { return "System input" }
        return audio.devices.first { $0.uid == uid }?.name ?? "Preferred microphone unavailable"
    }

    func beginShortcutRecording() {
        guard phase == .idle else { return }
        shortcutRecordingError = nil
        isRecordingShortcut = true
    }

    func cancelShortcutRecording() {
        isRecordingShortcut = false
        shortcutRecordingError = nil
    }

    func useShortcut(_ choice: HotkeyChoice) {
        if let reason = choice.validationError { shortcutRecordingError = reason; return }
        shortcutRecordingError = nil
        hotkeyChoice = choice
        isRecordingShortcut = false
    }

    func initialize() async {
        if let failure = history.lastError { error = failure }
        await loadExistingModel()
        refreshPermissions()
    }

    func loadExistingModel() async {
        guard !isPreparing, !speech.isDownloading else { return }
        isPreparing = true
        defer { isPreparing = false }
        do {
            try await speech.prepare()
            message = "Ready · On this Mac"
        } catch {
            message = "Set up the local speech model in Settings"
        }
    }

    func downloadModel() {
        guard !busy else { return }
        captureTask = Task {
            do {
                try await speech.downloadModel()
                try await speech.prepare()
                message = "Ready · Offline speech available"
            } catch { self.error = error.localizedDescription; message = "Model setup needs attention" }
        }
    }

    func hotkeyDown() {
        guard !isRecordingShortcut else { return }
        if shortcutMode == .toggle, phase == .recording { Task { await finishRecording() }; return }
        guard phase == .idle else { if phase == .transcribing { message = "Finishing this take…" }; return }
        startDictation()
    }

    func hotkeyUp() {
        guard !isRecordingShortcut else { return }
        guard shortcutMode == .hold else { return }
        if phase == .starting { releasePending = true }
        else if phase == .recording { Task { await finishRecording() } }
    }

    func shortcutUsedForTyping() {
        if phase == .starting { cancelPendingShortcut = true }
        else if phase == .recording {
            Task { await finishRecording(interruption: "The modifier was used with another key. Recording kept for recovery; no text was inserted.") }
        }
    }

    func startDictation(saveOnly: Bool = false) {
        guard !busy, !isRecordingShortcut else { return }
        guard speech.hasDownloadedModel else {
            message = "Download the local speech model first"
            openSettings?()
            return
        }
        guard microphoneGranted else { message = "Enable microphone access in Settings"; openSettings?(); return }
        destination = saveOnly ? nil : insertion.captureTarget()
        destinationDiagnostic = saveOnly ? nil : insertion.lastDiagnostic
        releasePending = false
        cancelPendingShortcut = false
        phase = .starting
        message = speech.isReady ? "Opening microphone…" : "Waking local speech model…"
        hudVisible = true
        captureTask = Task { [self] in
            do {
                if !speech.isReady { try await speech.prepare() }
                guard !cancelPendingShortcut else {
                    destination = nil; destinationDiagnostic = nil
                    reset("Shortcut used with another key")
                    return
                }
                guard !releasePending || shortcutMode == .toggle else { reset("Ready · Hold the shortcut to speak"); return }
                let session = try history.beginSession(targetBundleID: destination?.bundleIdentifier, targetAppName: destination?.appName, kit: activeKit)
                activeSession = session
                guard let url = session.audioURL else { throw AppFailure("A recording destination could not be created.") }
                try await audio.start(to: url)
                recordingStarted = Date()
                recordingElapsed = 0
                elapsedTimer?.invalidate()
                elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, let started = self.recordingStarted else { return }
                        self.recordingElapsed = Date().timeIntervalSince(started)
                    }
                }
                playActivationSound()
                phase = .recording
                message = "Listening"
                if releasePending && shortcutMode == .hold { await finishRecording() }
            } catch {
                elapsedTimer?.invalidate(); elapsedTimer = nil
                if let session = activeSession { try? history.setStatus(sessionID: session.id, status: .interrupted, error: error.localizedDescription) }
                activeSession = nil
                recordingStarted = nil
                destination = nil
                destinationDiagnostic = nil
                reset("Could not start recording")
                self.error = error.localizedDescription
            }
        }
    }

    func finishRecording(interruption: String? = nil) async {
        guard phase == .recording, let session = activeSession else { return }
        phase = .transcribing
        elapsedTimer?.invalidate(); elapsedTimer = nil
        message = interruption == nil ? "Transcribing on this Mac…" : "Microphone interrupted · Saving take…"
        let duration = recordingStarted.map { Date().timeIntervalSince($0) }
        let target = destination
        let captureDiagnostic = destinationDiagnostic
        defer {
            activeSession = nil
            recordingStarted = nil
            destination = nil
            destinationDiagnostic = nil
        }
        let raw: String
        do {
            let stopped = try await audio.stop()
            guard let url = stopped ?? session.audioURL else { throw AppFailure("No audio was captured.") }
            raw = try await speech.transcribe(audioURL: url, vocabulary: session.kitSnapshot?.preferredSpellings ?? [])
            guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppFailure("No speech was recognised. Retry the audio from the Library.") }
        } catch {
            try? history.setStatus(sessionID: session.id, status: .transcriptionFailed, error: error.localizedDescription)
            selectedSessionID = session.id
            reset("Recording kept · Transcription needs retry")
            self.error = error.localizedDescription
            return
        }
        unsavedText = raw
        let saved: DictationSession
        do { saved = try history.updateTranscript(sessionID: session.id, raw: raw, durationSeconds: duration) }
        catch { retainUnsaved(raw, sessionID: session.id, error: error); return }
        unsavedText = nil
        selectedSessionID = saved.id
        if interruption != nil || target == nil {
            recordDelivery(saved.id, status: .readyToCopy, message: interruption == nil ? "Saved · Ready to copy" : "Saved · Mic interrupted · Ready to copy", detail: interruption ?? captureDiagnostic)
        } else if let target {
            switch await insertion.insert(text: saved.displayTranscript, to: target) {
            case .inserted: recordDelivery(saved.id, status: .confirmed, message: "Saved · Insertion confirmed")
            case .pasteAttempted: recordDelivery(saved.id, status: .pasteAttempted, message: "Saved · Check paste in \(target.appName)", detail: insertion.lastDiagnostic)
            case .clipboardReady(let reason): recordDelivery(saved.id, status: .readyToCopy, message: "Saved · Ready to copy", detail: reason)
            case .failed(let reason): recordDelivery(saved.id, status: .readyToCopy, message: "Saved · Open Library to copy", detail: reason)
            }
        }
    }

    func retry(_ session: DictationSession) {
        guard !busy, let url = session.audioURL else { return }
        phase = .transcribing
        message = "Retrying on this Mac…"
        hudVisible = true
        captureTask = Task {
            do {
                if !speech.isReady { try await speech.prepare() }
                let raw = try await speech.transcribe(audioURL: url, vocabulary: session.kitSnapshot?.preferredSpellings ?? [])
                guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppFailure("No speech was recognised in this audio.") }
                unsavedText = raw
                _ = try history.updateTranscript(sessionID: session.id, raw: raw, durationSeconds: session.durationSeconds)
                unsavedText = nil
                selectedSessionID = session.id
                recordDelivery(session.id, status: .readyToCopy, message: "Saved · Ready to copy")
            } catch {
                if let text = unsavedText { retainUnsaved(text, sessionID: session.id, error: error) }
                else { self.error = error.localizedDescription; reset("Retry needs attention") }
            }
        }
    }

    private func recordDelivery(_ id: UUID, status: DictationStatus, message text: String, detail: String? = nil) {
        do { try history.setStatus(sessionID: id, status: status, error: detail) }
        catch { self.error = "Your transcript is saved, but its delivery status could not be updated. \(error.localizedDescription)" }
        reset(text)
    }

    private func retainUnsaved(_ text: String, sessionID: UUID, error: Error) {
        unsavedText = text
        selectedSessionID = sessionID
        self.error = "Text is available, but saving failed: \(error.localizedDescription)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        reset("Not saved · Copy your text now")
        hudVisible = true
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(text, forType: .string) else {
            error = "The clipboard could not be written. Your text is still available in Talkie."
            return
        }
        if text == unsavedText { unsavedText = nil; hudVisible = false }
        message = "Copied to clipboard"
    }

    func requestMicrophone() {
        if [.denied, .restricted].contains(AVCaptureDevice.authorizationStatus(for: .audio)) {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            return
        }
        Task { microphoneGranted = await AVCaptureDevice.requestAccess(for: .audio); refreshPermissions() }
    }

    func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        accessibilityGranted = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func refreshPermissions() {
        microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibilityGranted = AXIsProcessTrusted()
        audio.refreshDevices()
    }

    func toggleMicTest() {
        if phase == .testing { Task { await finishMicTest() }; return }
        guard !busy else { return }
        guard microphoneGranted else { requestMicrophone(); return }
        let testID = UUID()
        micTestID = testID
        testPlayer?.stop()
        phase = .starting
        captureTask = Task {
            do {
                let url = history.storageDirectory.appendingPathComponent("microphone-test.caf")
                try await audio.start(to: url)
                phase = .testing
                message = "Mic test · Listening"
                try await Task.sleep(nanoseconds: 5_000_000_000)
                if phase == .testing && micTestID == testID { await finishMicTest() }
            } catch { self.error = error.localizedDescription; phase = .idle }
        }
    }

    func finishMicTest() async {
        guard phase == .testing else { return }
        do { lastTestURL = try await audio.stop(); message = "Five-second mic test ready to play" }
        catch { self.error = error.localizedDescription }
        phase = .idle
    }

    func playMicTest() {
        guard let url = lastTestURL else { return }
        playRecording(url)
    }

    func playRecording(_ url: URL) {
        do { testPlayer = try AVAudioPlayer(contentsOf: url); testPlayer?.play() }
        catch { self.error = error.localizedDescription }
    }

    func playActivationSound() {
        guard soundEnabled else { return }
        let url = Bundle.main.url(forResource: "activate", withExtension: "wav") ?? Bundle.module.url(forResource: "activate", withExtension: "wav")
        if let url { sound = NSSound(contentsOf: url, byReference: false); sound?.volume = Float(soundVolume); sound?.play() }
    }

    func setLogin(_ enabled: Bool) {
        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; launchAtLogin = SMAppService.mainApp.status == .enabled }
        catch { self.error = error.localizedDescription }
    }

    private func reset(_ text: String) {
        message = text
        phase = .idle
        let stamp = Date()
        lastActivity = stamp
        Task { try? await Task.sleep(nanoseconds: 3_500_000_000); if self.phase == .idle && self.lastActivity == stamp && self.unsavedText == nil { self.hudVisible = false } }
    }
}

struct AppFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
