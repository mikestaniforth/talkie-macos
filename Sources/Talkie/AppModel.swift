import AppKit
import AVFoundation
import Combine
import ServiceManagement
import UniformTypeIdentifiers

enum CapturePhase: String { case idle, starting, recording, transcribing, testing }
enum ShortcutMode: String, CaseIterable { case hold, toggle }

struct ShortcutHUDNotice: Equatable {
    let title: String
    let detail: String
    var symbolName: String = "hourglass"
}

@MainActor
final class AppModel: ObservableObject {
    let audio = AudioCapture()
    let speech = SpeechEngine()
    let history = HistoryStore()
    let insertion = TextInsertion()
    @Published var phase: CapturePhase = .idle
    @Published var message = "Getting ready…"
    @Published var hudVisible = false
    @Published private(set) var hudNotice: ShortcutHUDNotice?
    @Published var selectedSessionID: UUID?
    @Published var activeKitID: String { didSet { TalkieEnvironment.defaults.set(activeKitID, forKey: "activeKitID") } }
    @Published var shortcutMode: ShortcutMode { didSet { TalkieEnvironment.defaults.set(shortcutMode.rawValue, forKey: "shortcutMode") } }
    @Published var hotkeyChoice: HotkeyChoice { didSet { if let data = try? JSONEncoder().encode(hotkeyChoice) { TalkieEnvironment.defaults.set(data, forKey: "recordedHotkey") } } }
    @Published var isRecordingShortcut = false
    @Published var shortcutRecordingError: String?
    @Published private(set) var recordingElapsed: TimeInterval = 0
    @Published var soundEnabled: Bool { didSet { TalkieEnvironment.defaults.set(soundEnabled, forKey: "soundEnabled") } }
    @Published var soundVolume: Double { didSet { TalkieEnvironment.defaults.set(soundVolume, forKey: "soundVolume") } }
    @Published private(set) var customActivationSoundFile: String? {
        didSet {
            if let customActivationSoundFile { TalkieEnvironment.defaults.set(customActivationSoundFile, forKey: "customActivationSoundFile") }
            else { TalkieEnvironment.defaults.removeObject(forKey: "customActivationSoundFile") }
        }
    }
    @Published private(set) var activationSoundNotice: String?
    @Published private(set) var isChoosingActivationSound = false
    @Published var releaseModelAfterIdle: Bool { didSet { TalkieEnvironment.defaults.set(releaseModelAfterIdle, forKey: "releaseModelAfterIdle") } }
    @Published var showInDock: Bool { didSet { TalkieEnvironment.defaults.set(showInDock, forKey: "showInDock") } }
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
    private var startupInterruption: String?
    private var captureTask: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()
    private var sound: NSSound?
    private var customSound: AVAudioPlayer?
    private static let managedActivationSoundFilename = "activation-custom.audio"
    private static let maximumActivationSoundBytes = 5_000_000
    private var testPlayer: AVAudioPlayer?
    private var micTestID = UUID()
    private var lastActivity = Date()
    private var idleTimer: Timer?
    private var elapsedTimer: Timer?
    private var hudNoticeTask: Task<Void, Never>?

    init() {
        let defaults = TalkieEnvironment.defaults
        activeKitID = defaults.string(forKey: "activeKitID") ?? "everyday"
        shortcutMode = ShortcutMode(rawValue: defaults.string(forKey: "shortcutMode") ?? "hold") ?? .hold
        if let data = defaults.data(forKey: "recordedHotkey"), let stored = try? JSONDecoder().decode(HotkeyChoice.self, from: data), stored.validationError == nil {
            hotkeyChoice = stored
        } else { hotkeyChoice = HotkeyChoice(rawValue: defaults.string(forKey: "hotkeyChoice") ?? "") ?? .controlOptionSpace }
        soundEnabled = defaults.object(forKey: "soundEnabled") as? Bool ?? true
        soundVolume = defaults.object(forKey: "soundVolume") as? Double ?? 0.5
        let storedSound = defaults.string(forKey: "customActivationSoundFile")
        let validatedStoredSound = storedSound == Self.managedActivationSoundFilename ? storedSound : nil
        customActivationSoundFile = validatedStoredSound
        if storedSound != nil && validatedStoredSound == nil { defaults.removeObject(forKey: "customActivationSoundFile") }
        releaseModelAfterIdle = defaults.object(forKey: "releaseModelAfterIdle") as? Bool ?? false
        showInDock = defaults.object(forKey: "showInDock") as? Bool ?? true
        if customActivationSoundFile != nil {
            do { _ = try activationSoundPlayer(from: activationSoundData(at: managedActivationSoundURL)) }
            catch { activationSoundNotice = "Custom chime unavailable. Using the default; choose the file again or use the default." }
        }
        audio.selectedDeviceUID = defaults.string(forKey: "preferredMicrophoneUID")
        for publisher in [audio.objectWillChange.eraseToAnyPublisher(), speech.objectWillChange.eraseToAnyPublisher(), history.objectWillChange.eraseToAnyPublisher()] {
            publisher.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        }
        audio.$qualityWarning.compactMap { $0 }.sink { [weak self] _ in
            guard let self, self.phase == .recording else { return }
            self.message = "Recording continues · Audio needs review"
        }.store(in: &subscriptions)
        audio.$selectedDeviceUID.dropFirst().sink { uid in
            if let uid { defaults.set(uid, forKey: "preferredMicrophoneUID") } else { defaults.removeObject(forKey: "preferredMicrophoneUID") }
        }.store(in: &subscriptions)
        audio.onInterruption = { [weak self] reason in
            guard let self else { return }
            Task { @MainActor in
                if self.phase == .starting { self.startupInterruption = reason }
                else if self.phase == .testing { await self.finishMicTest(); self.message = reason }
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
    var busy: Bool { phase != .idle || speech.isBusy || isPreparing || unsavedText != nil || isChoosingActivationSound }
    var activationSoundLabel: String { customActivationSoundFile != nil && activationSoundNotice == nil ? "Custom chime" : "Default chime" }
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
        if !isRecordingShortcut, shortcutMode == .toggle, phase == .recording { Task { await finishRecording() }; return }
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
        guard !busy, !isRecordingShortcut else { showRejectedShortcutFeedback(); return }
        clearShortcutFeedback()
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
        startupInterruption = nil
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
                guard audio.isRecording, startupInterruption == nil else {
                    throw AppFailure(startupInterruption ?? "The microphone stopped while opening. The partial take was kept; try again or choose another input.")
                }
                clearShortcutFeedback()
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
        clearShortcutFeedback()
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
        let captureWarning: String?
        do {
            let stopped = try await audio.stop()
            guard let url = stopped ?? session.audioURL else { throw AppFailure("No audio was captured.") }
            captureWarning = try await preserveCaptureWarning(session, audioURL: url, writerWarning: audio.qualityWarning,
                                                             durationSeconds: duration)
            raw = try await speech.transcribe(audioURL: url, vocabulary: session.kitSnapshot?.preferredSpellings ?? [],
                                             allowRepeatedAudio: captureWarning != nil)
            guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SpeechEngineError.noSpeech }
        } catch {
            if handleExpectedSpeechRejection(error, session: session, durationSeconds: duration) { return }
            try? history.setStatus(sessionID: session.id, status: .transcriptionFailed, error: error.localizedDescription, durationSeconds: duration)
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
        if let warning = saved.captureWarning ?? captureWarning {
            // Keep useful recognition, but never deliver suspect input into an
            // external field. The persisted warning survives copying or retry.
            recordDelivery(saved.id, status: .interrupted, message: "Saved · Review incomplete audio", detail: warning)
        } else if interruption != nil || target == nil {
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
        guard !busy, !isRecordingShortcut else { showRejectedShortcutFeedback(); return }
        guard let url = session.audioURL else { return }
        clearShortcutFeedback()
        selectedSessionID = session.id
        phase = .transcribing
        message = "Retrying on this Mac…"
        hudVisible = true
        captureTask = Task {
            do {
                let captureWarning = try await preserveCaptureWarning(session, audioURL: url,
                                                                     durationSeconds: session.durationSeconds)
                if !speech.isReady { try await speech.prepare() }
                let raw = try await speech.transcribe(audioURL: url, vocabulary: session.kitSnapshot?.preferredSpellings ?? [],
                                                     allowRepeatedAudio: captureWarning != nil)
                guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SpeechEngineError.noSpeech }
                unsavedText = raw
                let saved = try history.updateTranscript(sessionID: session.id, raw: raw, durationSeconds: session.durationSeconds)
                unsavedText = nil
                selectedSessionID = session.id
                if let warning = saved.captureWarning ?? captureWarning {
                    recordDelivery(session.id, status: .interrupted, message: "Saved · Review incomplete audio", detail: warning)
                } else {
                    recordDelivery(session.id, status: .readyToCopy, message: "Saved · Ready to copy")
                }
            } catch {
                if let text = unsavedText { retainUnsaved(text, sessionID: session.id, error: error) }
                else {
                    if handleExpectedSpeechRejection(error, session: session, durationSeconds: session.durationSeconds) { return }
                    // Selection can change while recognition awaits. Keep this
                    // failure and the HUD's recovery actions tied to its take.
                    selectedSessionID = session.id
                    let warning = history.sessions.first(where: { $0.id == session.id })?.captureWarning ?? session.captureWarning
                    try? history.setStatus(sessionID: session.id, status: warning == nil ? .transcriptionFailed : .interrupted,
                                           error: error.localizedDescription, durationSeconds: session.durationSeconds)
                    self.error = error.localizedDescription
                    reset("Retry needs attention")
                }
            }
        }
    }

    /// Silence and low input are normal recording outcomes, rather than modal
    /// failures. Keep the take and make the next shortcut eligible immediately.
    private func handleExpectedSpeechRejection(_ failure: Error, session: DictationSession, durationSeconds: Double?) -> Bool {
        guard unsavedText == nil, let rejection = failure as? SpeechEngineError else { return false }
        let notice: ShortcutHUDNotice
        switch rejection {
        case .noSpeech:
            notice = ShortcutHUDNotice(title: "No speech", detail: "No speech was recognised. Ready for your next dictation. The recording is kept in Library.", symbolName: "mic.slash")
        case .signalTooQuiet:
            notice = ShortcutHUDNotice(title: "Too quiet", detail: "Move closer or increase microphone input gain, then try again. The recording is kept in Library.", symbolName: "waveform")
        default: return false
        }
        selectedSessionID = session.id
        let warning = history.sessions.first(where: { $0.id == session.id })?.captureWarning ?? session.captureWarning
        do {
            try history.setStatus(sessionID: session.id, status: warning == nil ? .transcriptionFailed : .interrupted,
                                  error: rejection.localizedDescription, durationSeconds: durationSeconds)
        } catch {
            reset("Recording kept · Recovery status not saved")
            self.error = "Your audio was kept, but Talkie could not save its recovery status. \(error.localizedDescription)"
            return true
        }
        // Dismiss only an earlier instance of these expected outcomes; an
        // unrelated storage or model error must remain visible for recovery.
        if let current = error, [SpeechEngineError.noSpeech.localizedDescription, SpeechEngineError.signalTooQuiet.localizedDescription].contains(current) {
            error = nil
        }
        reset(notice.title)
        showTransientHUDNotice(notice)
        return true
    }

    private func preserveCaptureWarning(_ session: DictationSession, audioURL: URL, writerWarning: String? = nil,
                                        durationSeconds: Double? = nil) async throws -> String? {
        var warning = history.sessions.first(where: { $0.id == session.id })?.captureWarning
            ?? session.captureWarning ?? writerWarning
        if let warning {
            // Preserve an already known fault before preflight or recognition;
            // even a later failure must not erase the take's provenance.
            try history.markCaptureWarning(sessionID: session.id, warning: warning, durationSeconds: durationSeconds)
        }
        let repeated = try await Task.detached(priority: .userInitiated) {
            try RepeatedAudioCheck.fileContainsRepeatedAudio(audioURL)
        }.value
        if repeated, warning == nil {
            let detectedWarning = "This recording contains repeated input and may be incomplete. Listen back and review the recovered text before using it. Nothing was inserted automatically."
            warning = detectedWarning
            try history.markCaptureWarning(sessionID: session.id, warning: detectedWarning, durationSeconds: durationSeconds)
        }
        return warning
    }

    private func showRejectedShortcutFeedback() {
        let notice: ShortcutHUDNotice
        if isRecordingShortcut {
            notice = ShortcutHUDNotice(title: "Shortcut setup", detail: "Finish or cancel shortcut recording before dictating.", symbolName: "keyboard")
        } else if isChoosingActivationSound {
            notice = ShortcutHUDNotice(title: "Choosing chime", detail: "Finish or cancel the audio file picker before dictating.", symbolName: "speaker.wave.2")
        } else if unsavedText != nil {
            notice = ShortcutHUDNotice(title: "Unsaved text", detail: "Copy the unsaved text before starting another take. Your text is still available in Talkie.")
        } else if phase == .transcribing || speech.isTranscribing {
            notice = ShortcutHUDNotice(title: "Finishing take", detail: "Talkie is finishing the current take. A new recording has not started.")
        } else if phase == .starting {
            notice = ShortcutHUDNotice(title: speech.isReady ? "Opening mic" : "Loading model", detail: "Talkie is getting the microphone and speech model ready. Wait for the activation cue before speaking.")
        } else if phase == .testing {
            notice = ShortcutHUDNotice(title: "Mic test active", detail: "Finish the microphone test before starting a dictation.")
        } else if phase == .recording {
            notice = ShortcutHUDNotice(title: "Recording", detail: "Talkie is already recording this take.")
        } else if speech.isDownloading {
            notice = ShortcutHUDNotice(title: "Model download", detail: "Wait for the local speech model download to finish before dictating.")
        } else {
            notice = ShortcutHUDNotice(title: "Loading model", detail: "The local speech model is loading. Wait until it is ready before starting a take.")
        }
        showTransientHUDNotice(notice)
    }

    private func showTransientHUDNotice(_ notice: ShortcutHUDNotice) {
        hudNoticeTask?.cancel()
        hudNotice = notice
        hudVisible = true
        hudNoticeTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3.5)) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.hudNotice = nil
            self.hudNoticeTask = nil
            if self.phase == .idle && self.unsavedText == nil { self.hudVisible = false }
        }
    }

    private func clearShortcutFeedback() {
        hudNoticeTask?.cancel()
        hudNoticeTask = nil
        hudNotice = nil
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
        clearShortcutFeedback()
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
        stopActivationSound()
        if customActivationSoundFile != nil {
            do {
                let player = try activationSoundPlayer(from: activationSoundData(at: managedActivationSoundURL))
                player.volume = Float(min(1, max(0, soundVolume)))
                customSound = player
                if player.play() { activationSoundNotice = nil; return }
                customSound = nil
            } catch { customSound = nil }
            activationSoundNotice = "Custom chime could not play. Using the default; choose the file again or use the default."
        }
        let url = Bundle.main.url(forResource: "activate", withExtension: "wav") ?? Bundle.module.url(forResource: "activate", withExtension: "wav")
        if let url { sound = NSSound(contentsOf: url, byReference: false); sound?.volume = Float(min(1, max(0, soundVolume))); sound?.play() }
    }

    func chooseActivationSound() {
        guard phase == .idle, !isChoosingActivationSound, !isRecordingShortcut else { return }
        stopActivationSound()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = "Choose an activation chime"
        panel.message = "Choose an audio file up to 10 seconds and 5 MB. Talkie keeps a local copy."
        panel.prompt = "Choose"
        isChoosingActivationSound = true
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self, panel] response in
            guard let self else { return }
            self.isChoosingActivationSound = false
            guard response == .OK, let url = panel.url else { return }
            do { try self.setCustomActivationSound(from: url) }
            catch { self.error = error.localizedDescription }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }

    /// The source URL is used only for this read; neither its name nor path is persisted.
    func setCustomActivationSound(from url: URL) throws {
        guard phase == .idle, !isChoosingActivationSound, !isRecordingShortcut else {
            throw AppFailure("Wait for Talkie to finish its current task, then choose the chime again.")
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try activationSoundData(at: url)
        _ = try activationSoundPlayer(from: data)
        stopActivationSound()
        do {
            try FileManager.default.createDirectory(at: managedActivationSoundURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            // Atomic replacement retains the previous managed chime if writing fails.
            try data.write(to: managedActivationSoundURL, options: .atomic)
        } catch {
            throw AppFailure("Talkie could not save the custom chime. The previous setting is unchanged. Check local storage, then choose the file again.")
        }
        customActivationSoundFile = Self.managedActivationSoundFilename
        activationSoundNotice = nil
    }

    func useDefaultActivationSound() {
        guard phase == .idle, !isChoosingActivationSound else { return }
        stopActivationSound()
        customActivationSoundFile = nil
        activationSoundNotice = nil
        do {
            if FileManager.default.fileExists(atPath: managedActivationSoundURL.path) { try FileManager.default.removeItem(at: managedActivationSoundURL) }
        } catch {
            activationSoundNotice = "Default chime selected. The old local copy could not be removed; try Use default again after checking local storage."
            self.error = activationSoundNotice
        }
    }

    private var managedActivationSoundURL: URL {
        history.storageDirectory.appendingPathComponent("Sounds", isDirectory: true).appendingPathComponent(Self.managedActivationSoundFilename)
    }

    private func stopActivationSound() {
        sound?.stop(); sound = nil
        customSound?.stop(); customSound = nil
    }

    private func activationSoundData(at url: URL) throws -> Data {
        do {
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard info.isRegularFile == true else { throw AppFailure("Choose a readable audio file, rather than a folder or other item.") }
            guard (info.fileSize ?? 0) <= Self.maximumActivationSoundBytes else { throw AppFailure("The chime is larger than 5 MB. Choose a smaller audio file.") }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var data = Data()
            // Enforce the limit on actual bytes too, including a file that grows during the read.
            while data.count <= Self.maximumActivationSoundBytes {
                let count = min(65_536, Self.maximumActivationSoundBytes + 1 - data.count)
                guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else { break }
                data.append(chunk)
            }
            guard data.count <= Self.maximumActivationSoundBytes else { throw AppFailure("The chime is larger than 5 MB. Choose a smaller audio file.") }
            return data
        } catch let failure as AppFailure { throw failure }
        catch { throw AppFailure("The audio file could not be read. Choose a readable local audio file and try again.") }
    }

    private func activationSoundPlayer(from data: Data) throws -> AVAudioPlayer {
        let player: AVAudioPlayer
        do { player = try AVAudioPlayer(data: data) }
        catch { throw AppFailure("This audio file could not be opened. Choose a supported audio file such as WAV, AIFF or M4A.") }
        guard player.duration.isFinite, player.duration > 0, player.duration <= 10 else {
            throw AppFailure("Choose an audio chime longer than zero and no more than 10 seconds.")
        }
        return player
    }

    func setLogin(_ enabled: Bool) {
        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; launchAtLogin = SMAppService.mainApp.status == .enabled }
        catch { self.error = error.localizedDescription }
    }

    private func reset(_ text: String) {
        clearShortcutFeedback()
        message = text
        phase = .idle
        let stamp = Date()
        lastActivity = stamp
        Task { try? await Task.sleep(nanoseconds: 3_500_000_000); if self.phase == .idle && self.lastActivity == stamp && self.unsavedText == nil && self.hudNotice == nil { self.hudVisible = false } }
    }
}

struct AppFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
