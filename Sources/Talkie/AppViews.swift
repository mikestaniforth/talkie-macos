import SwiftUI
import AppKit

// THESIS: A quiet native workspace for speaking, recovering and preparing words.
// OWN-WORLD: Semantic Mac surfaces, SF typography and the original orange accent.
// STORY: See the actual input state, speak, then trust a truthful delivery receipt.
// FIRST VIEWPORT: Native navigation, a compact take list and a generous text pane.
// FORM: User-pinned Apple Notes / Voice Memos grammar; no website-style staging.

// Select the stable property wrapper on SDKs that also export a State macro.
private typealias ViewState<Value> = SwiftUI.State<Value>
private let talkieAccent = Color(red: 0.70, green: 0.35, blue: 0.19)

private func deliverySymbol(_ status: DictationStatus) -> String {
    switch status {
    case .recording: return "mic.fill"
    case .saved: return "tray"
    case .confirmed: return "checkmark.circle"
    case .pasteAttempted: return "arrow.up.doc"
    case .readyToCopy: return "doc.on.doc"
    case .transcriptionFailed, .notSaved, .interrupted: return "exclamationmark.circle"
    }
}

struct TalkieWordmark: View {
    var body: some View {
        HStack(spacing: 9) {
            if let icon = NSImage(named: NSImage.applicationIconName) {
                Image(nsImage: icon).resizable().interpolation(.high).frame(width: 30, height: 30)
            } else {
                Image(systemName: "waveform").font(.system(size: 21, weight: .medium)).foregroundStyle(talkieAccent)
            }
            Text("Talkie").font(.system(size: 17, weight: .semibold))
        }
        .accessibilityElement(children: .ignore).accessibilityLabel("Talkie")
    }
}

private struct ShortcutKeycaps: View {
    let parts: [String]
    let label: String
    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, key in
                Text(key).font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 6).padding(.vertical, 3).frame(minWidth: 22)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
            }
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(label)
    }
}

private struct InputLevelMeter: View {
    let level: Double
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<12) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Double(index) / 12 < min(1, max(0, level)) ? talkieAccent : Color.primary.opacity(0.10))
                    .frame(width: 3, height: 16)
            }
        }
        .accessibilityElement(children: .ignore).accessibilityLabel("Microphone input level")
        .accessibilityValue("\(Int(min(1, max(0, level)) * 100)) percent")
    }
}

struct TalkieMenuView: View {
    @ObservedObject var model: AppModel
    private var isListening: Bool { model.phase == .recording || model.phase == .testing }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                TalkieWordmark()
                Spacer()
                Label("On-device", systemImage: "desktopcomputer").font(.caption).foregroundStyle(.secondary)
            }.padding(.bottom, 22)

            HStack(alignment: .top, spacing: 11) {
                Image(systemName: isListening ? "mic.fill" : "mic").font(.system(size: 17)).foregroundStyle(isListening ? talkieAccent : .secondary)
                    .frame(width: 22).padding(.top, 1)
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.microphoneName).font(.system(size: 13, weight: .medium)).lineLimit(2)
                    Text(isListening ? (model.audio.level > 0.01 ? "Audio arriving" : "Recording · Waiting for signal") : "Microphone off while idle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(model.message).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 12)

            HStack {
                Text(model.shortcutMode == .hold ? "Hold to dictate" : "Press to dictate").font(.caption).foregroundStyle(.secondary)
                Spacer()
                ShortcutKeycaps(parts: model.hotkeyChoice.symbolParts, label: model.hotkeyChoice.label)
            }.padding(.top, 20).padding(.bottom, 12)

            if model.phase == .recording {
                Button { Task { await model.finishRecording() } } label: {
                    Label("Finish dictation", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).controlSize(.large)
            } else {
                Button { model.startDictation(saveOnly: true) } label: {
                    Label("Record a note", systemImage: "mic").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).controlSize(.large).disabled(model.busy)
            }
            Picker("Project Kit", selection: $model.activeKitID) {
                ForEach(model.history.kits) { kit in Text(kit.name).tag(kit.id) }
            }.pickerStyle(.menu).padding(.top, 12)

            if let text = model.unsavedText {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Text has not been saved", systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                    Button("Copy unsaved text") { model.copy(text) }
                }.padding(.top, 16)
            }

            if !model.recentSessions.isEmpty {
                Divider().padding(.vertical, 18)
                Text("Recent dictations").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).padding(.bottom, 12)
                VStack(spacing: 15) {
                    ForEach(model.recentSessions) { session in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(session.displayTranscript.isEmpty ? session.status.label : session.displayTranscript)
                                    .font(.system(size: 12)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                Label(session.status.label, systemImage: deliverySymbol(session.status))
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            Button { model.copy(session.displayTranscript) } label: { Image(systemName: "doc.on.doc") }
                                .buttonStyle(.borderless).help("Copy dictation").accessibilityLabel("Copy dictation")
                                .disabled(session.displayTranscript.isEmpty)
                        }
                    }
                }
            }
            Divider().padding(.top, 18).padding(.bottom, 13)
            HStack {
                Button("Open Library") { model.openLibrary?() }.buttonStyle(.link)
                Spacer()
                Button { model.openSettings?() } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless).help("Settings").accessibilityLabel("Settings")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .buttonStyle(.borderless).help("Quit Talkie").accessibilityLabel("Quit Talkie")
            }
        }
        .padding(21).frame(width: 356).tint(talkieAccent)
    }
}

struct RecordingHUD: View {
    @ObservedObject var model: AppModel
    private var latest: DictationSession? {
        model.history.sessions.first { $0.id == model.selectedSessionID } ?? model.history.sessions.first
    }
    private var elapsed: String {
        let seconds = max(0, Int(model.recordingElapsed))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
    var body: some View {
        HStack(spacing: 13) {
            if model.phase == .recording {
                Circle().fill(.red).frame(width: 6, height: 6).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Listening").fontWeight(.medium)
                    Text(model.microphoneName).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }.frame(maxWidth: 165, alignment: .leading)
                InputLevelMeter(level: model.audio.level)
                Text(elapsed).font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                    .accessibilityLabel("Recording time \(elapsed)")
                Button { Task { await model.finishRecording() } } label: { Image(systemName: "stop.fill") }
                    .buttonStyle(.borderless).help("Finish dictation").accessibilityLabel("Finish dictation")
            } else if model.phase == .starting || model.phase == .transcribing {
                ProgressView().controlSize(.small)
                Text(model.message).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Image(systemName: model.unsavedText != nil ? "exclamationmark.triangle" : latest.map { deliverySymbol($0.status) } ?? "waveform")
                    .foregroundStyle(model.unsavedText != nil ? Color.orange : .secondary)
                Text(model.message).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                if let text = model.unsavedText ?? latest?.displayTranscript, !text.isEmpty {
                    Button("Copy") { model.copy(text) }.controlSize(.small)
                }
                Button { model.hudVisible = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).help("Dismiss").accessibilityLabel("Dismiss recording status")
            }
        }
        .font(.system(size: 13)).padding(.horizontal, 17).padding(.vertical, 12)
        .frame(minWidth: 300, maxWidth: 490, minHeight: 57)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .padding(8).tint(talkieAccent)
    }
}

struct LibraryWindow: View {
    @ObservedObject var model: AppModel
    @ViewState private var navigation: String? = "all"
    @ViewState private var query = ""
    private var filter: String { navigation ?? "all" }
    private var filtered: [DictationSession] {
        model.history.sessions.filter { session in
            let include = filter == "all" || filter == "kits"
                || filter == "pinned" && session.isPinned
                || filter == "attention" && [.transcriptionFailed, .readyToCopy, .pasteAttempted, .interrupted, .notSaved].contains(session.status)
                || filter == "kit:" + (session.projectKitID ?? "")
            return include && (query.isEmpty || session.displayTranscript.localizedCaseInsensitiveContains(query)
                || (session.targetAppName ?? "").localizedCaseInsensitiveContains(query))
        }
    }
    private var selected: DictationSession? {
        let visible = filtered
        return visible.first { $0.id == model.selectedSessionID } ?? visible.first
    }
    private var filterTitle: String {
        switch filter {
        case "attention": return "Needs attention"
        case "pinned": return "Pinned"
        default:
            return model.history.kits.first { "kit:" + $0.id == filter }?.name ?? "All dictations"
        }
    }
    var body: some View {
        NavigationSplitView {
            List(selection: $navigation) {
                Section("Library") {
                    Label("All dictations", systemImage: "tray").tag("all")
                    Label("Needs attention", systemImage: "exclamationmark.circle").tag("attention")
                    Label("Pinned", systemImage: "pin").tag("pinned")
                }
                Section("Projects") {
                    ForEach(model.history.kits) { kit in
                        Label(kit.name, systemImage: "folder").tag("kit:" + kit.id)
                    }
                }
                Section {
                    Label("Project Kits", systemImage: "square.stack").tag("kits")
                }
            }
            .listStyle(.sidebar).navigationTitle("Talkie")
            .navigationSplitViewColumnWidth(min: 165, ideal: 184, max: 220)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Label("On this Mac", systemImage: "internaldrive").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button { model.openSettings?() } label: { Image(systemName: "gearshape") }
                        .buttonStyle(.borderless).help("Settings").accessibilityLabel("Settings")
                }.padding(.horizontal, 16).padding(.vertical, 12)
            }
        } detail: {
            if filter == "kits" { ProjectKitsView(model: model) }
            else {
                HSplitView {
                    takeList.frame(minWidth: 220, idealWidth: 260, maxWidth: 300)
                    if let selected { TranscriptDetail(model: model, session: selected).id(selected.id) }
                    else { emptyDetail.frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity) }
                }
            }
        }
        .navigationSplitViewStyle(.balanced).frame(minWidth: 850, minHeight: 570).tint(talkieAccent)
        .onAppear { keepSelectionVisible() }
        .onChange(of: navigation) { _, _ in model.selectedSessionID = filtered.first?.id }
        .onChange(of: query) { _, _ in keepSelectionVisible() }
        .onChange(of: filtered.map(\.id)) { _, _ in keepSelectionVisible() }
        .alert("Talkie needs attention", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
    private var takeList: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(filterTitle).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("\(filtered.count)").font(.caption).foregroundStyle(.secondary)
                }
                TextField("Search dictations", text: $query).textFieldStyle(.roundedBorder)
            }.padding(14)
            Divider()
            List(selection: $model.selectedSessionID) {
                ForEach(filtered) { session in
                    VStack(alignment: .leading, spacing: 9) {
                        Text(session.displayTranscript.isEmpty ? session.status.label : session.displayTranscript)
                            .font(.system(size: 13, weight: .medium)).lineLimit(3).lineSpacing(2)
                        HStack(spacing: 6) {
                            Image(systemName: deliverySymbol(session.status))
                            Text(session.status.label).lineLimit(1)
                            Spacer(minLength: 0)
                        }.font(.system(size: 11)).foregroundStyle(.secondary)
                        Text(session.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                            .font(.caption2).foregroundStyle(.secondary)
                    }.padding(.vertical, 8).tag(session.id)
                }
            }.listStyle(.inset).background(Color(nsColor: .controlBackgroundColor))
        }.background(Color(nsColor: .controlBackgroundColor))
    }
    @ViewBuilder private var emptyDetail: some View {
        if !query.isEmpty {
            ContentUnavailableView("No matching dictations", systemImage: "magnifyingglass", description: Text("Try another word or choose All dictations."))
        } else if filter == "attention" {
            ContentUnavailableView("Nothing needs attention", systemImage: "tray", description: Text("Dictations that need copying or recovery appear here."))
        } else {
            ContentUnavailableView("Your words, kept close", systemImage: "waveform", description: Text("Use \(model.hotkeyChoice.label) to dictate. Your saved takes appear here."))
        }
    }
    private func keepSelectionVisible() {
        if !filtered.contains(where: { $0.id == model.selectedSessionID }) { model.selectedSessionID = filtered.first?.id }
    }
}

struct TranscriptDetail: View {
    @ObservedObject var model: AppModel
    let session: DictationSession
    @ViewState private var original = false
    @ViewState private var deleteRequested = false
    private var currentText: String { original ? session.rawTranscript ?? "" : session.displayTranscript }
    private var hasFrame: Bool { session.kitSnapshot.map { !$0.prefix.isEmpty || !$0.suffix.isEmpty } ?? false }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 15) {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(session.targetAppName.map { "Dictation for \($0)" } ?? "Saved dictation")
                            .font(.system(size: 21, weight: .semibold))
                        HStack(spacing: 9) {
                            Text(session.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                            if let duration = session.durationSeconds { Text("\(Int(duration)) sec").monospacedDigit() }
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Label(session.status.label, systemImage: deliverySymbol(session.status))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Picker("Version", selection: $original) {
                        Text("Output").tag(false)
                        Text("Original transcription").tag(true)
                    }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("Transcript version").frame(maxWidth: 235)
                    Spacer()
                    Text(session.kitSnapshot?.name ?? "Everyday").font(.caption).foregroundStyle(.secondary)
                }
                if session.framedTranscript == nil && hasFrame {
                    Button("Apply Prompt Frame") {
                        do { _ = try model.history.applyFrame(sessionID: session.id) } catch { model.error = error.localizedDescription }
                    }.disabled(session.displayTranscript.isEmpty)
                }
            }.padding(.horizontal, 28).padding(.top, 28).padding(.bottom, 20)
            Divider()
            if let error = session.errorMessage {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 28).padding(.top, 18)
            }
            if session.framedTranscript != nil && !original {
                Label("Includes a protected Prompt Frame", systemImage: "lock")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 28).padding(.top, 16)
            }
            ScrollView {
                Text(currentText.isEmpty ? "No transcript yet. Retry the saved recording below." : currentText)
                    .font(.system(size: 15)).lineSpacing(6).textSelection(.enabled)
                    .frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 28).padding(.vertical, 24)
            }
            Divider()
            HStack(spacing: 14) {
                if let url = session.audioURL, FileManager.default.fileExists(atPath: url.path) {
                    Button("Play recording", systemImage: "play.circle") { model.playRecording(url) }
                    if session.status == .transcriptionFailed || session.status == .interrupted {
                        Button("Retry transcription", systemImage: "arrow.clockwise") { model.retry(session) }.disabled(model.busy)
                    }
                }
                Spacer(minLength: 0)
            }.controlSize(.small).padding(.horizontal, 24).padding(.vertical, 15)
        }
        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .textBackgroundColor))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { do { try model.history.setPinned(sessionID: session.id, !session.isPinned) } catch { model.error = error.localizedDescription } } label: {
                    Image(systemName: session.isPinned ? "pin.fill" : "pin")
                }.help(session.isPinned ? "Unpin transcript" : "Pin transcript").accessibilityLabel(session.isPinned ? "Unpin transcript" : "Pin transcript")
                Button("Copy text", systemImage: "doc.on.doc") { model.copy(currentText) }.disabled(currentText.isEmpty)
                Menu {
                    Button("Delete dictation", systemImage: "trash", role: .destructive) { deleteRequested = true }
                } label: { Image(systemName: "ellipsis.circle") }
                .help("More dictation actions").accessibilityLabel("More dictation actions")
            }
        }
        .confirmationDialog("Delete this dictation and its recording?", isPresented: $deleteRequested) {
            Button("Delete dictation", role: .destructive) {
                do { try model.history.deleteSession(session.id) } catch { model.error = error.localizedDescription }
            }
        }
    }
}

struct ProjectKitsView: View {
    @ObservedObject var model: AppModel
    @ViewState private var selectedID = ""
    @ViewState private var name = ""
    @ViewState private var words = ""
    @ViewState private var corrections = ""
    @ViewState private var prefix = ""
    @ViewState private var suffix = ""
    @ViewState private var saved = false
    var selectedKit: ProjectKit? { model.history.kits.first { $0.id == selectedID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Project Kits").font(.system(size: 22, weight: .semibold))
                    Text("Your terminology and exact prompt structure.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("New kit", systemImage: "plus") { selectedID = ""; loadDraft(nil) }
            }.padding(26)
            Divider()
            Form {
                Section {
                    Picker("Edit kit", selection: $selectedID) {
                        Text("New kit").tag("")
                        ForEach(model.history.kits) { kit in Text(kit.name).tag(kit.id) }
                    }.onChange(of: selectedID) { _, _ in loadDraft(selectedKit) }
                    TextField("Kit name", text: $name)
                }
                Section {
                    kitEditor("Preferred spellings", text: $words, height: 78)
                    Text("One per line. These provide vocabulary to the recogniser.").font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    kitEditor("Approved corrections", text: $corrections, height: 78)
                    Text("One pair per line: example studio → ExampleStudio. URLs, email and marked code are protected.").font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    kitEditor("Opening", text: $prefix, height: 72)
                    Label("Your dictation goes between these sections", systemImage: "waveform").font(.caption).foregroundStyle(.secondary)
                    kitEditor("Closing", text: $suffix, height: 92)
                } header: { Text("Prompt Frame") } footer: {
                    Text("Apply deliberately in the Library. Opening and closing stay exactly as written.")
                }
            }.formStyle(.grouped)
            Divider()
            HStack(spacing: 12) {
                Button("Save kit") { saveKit() }.buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if selectedKit != nil { Button("Use for dictation") { model.activeKitID = selectedID; saved = true } }
                Spacer()
                if saved { Label("Saved on this Mac", systemImage: "checkmark").font(.caption).foregroundStyle(.secondary) }
            }.padding(.horizontal, 26).padding(.vertical, 16)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor))
        .onAppear { selectedID = model.activeKitID; loadDraft(selectedKit) }
    }
    private func kitEditor(_ label: String, text: Binding<String>, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(label).font(.system(size: 13, weight: .medium))
            TextEditor(text: text).font(.system(size: 13)).frame(height: height).padding(5)
                .scrollContentBackground(.hidden).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
                .accessibilityLabel(label)
        }
    }
    private func loadDraft(_ kit: ProjectKit?) {
        name = kit?.name ?? ""; words = kit?.preferredSpellings.joined(separator: "\n") ?? ""
        corrections = kit?.corrections.map { "\($0.from) → \($0.to)" }.joined(separator: "\n") ?? ""
        prefix = kit?.prefix ?? ""; suffix = kit?.suffix ?? ""; saved = false
    }
    private func saveKit() {
        let lines = corrections.split(separator: "\n").map(String.init)
        let pairs = lines.compactMap { line -> TextCorrection? in
            let parts = line.components(separatedBy: "→")
            guard parts.count == 2 else { return nil }
            let from = parts[0].trimmingCharacters(in: .whitespaces), to = parts[1].trimmingCharacters(in: .whitespaces)
            return from.isEmpty || to.isEmpty ? nil : TextCorrection(from: from, to: to)
        }
        guard pairs.count == lines.count else { model.error = "Each correction needs one → between the spoken form and the preferred spelling."; return }
        let kit = ProjectKit(id: selectedID.isEmpty ? UUID().uuidString : selectedID, name: name.trimmingCharacters(in: .whitespacesAndNewlines), version: (selectedKit?.version ?? 0) + 1, preferredSpellings: words.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }, corrections: pairs, prefix: prefix, suffix: suffix)
        do { try model.history.upsertKit(kit); selectedID = kit.id; saved = true } catch { model.error = error.localizedDescription }
    }
}

private enum SettingsPage: String, CaseIterable, Identifiable {
    case general, microphone, speech, privacy
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "General"
        case .microphone: return "Microphone"
        case .speech: return "Speech model"
        case .privacy: return "Privacy & storage"
        }
    }
    var icon: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .microphone: return "mic"
        case .speech: return "waveform"
        case .privacy: return "hand.raised"
        }
    }
    var subtitle: String {
        switch self {
        case .general: return "Shortcuts, sound and everyday preferences."
        case .microphone: return "Choose your input and check the real signal."
        case .speech: return "Local recognition, ready when you need it."
        case .privacy: return "Your words stay on this Mac."
        }
    }
}

struct SettingsWindow: View {
    @ObservedObject var model: AppModel
    @ViewState private var page: SettingsPage? = .general
    private var current: SettingsPage { page ?? .general }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                TalkieWordmark().padding(.horizontal, 17).padding(.top, 22)
                List(selection: $page) {
                    ForEach(SettingsPage.allCases) { item in Label(item.title, systemImage: item.icon).tag(item) }
                }.listStyle(.sidebar)
                Spacer(minLength: 0)
            }.frame(width: 166).background(Color(nsColor: .windowBackgroundColor))
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(current.title).font(.system(size: 22, weight: .semibold))
                    Text(current.subtitle).font(.callout).foregroundStyle(.secondary)
                }.padding(.horizontal, 26).padding(.top, 26).padding(.bottom, 10)
                settingsContent
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 720, minHeight: 550).tint(talkieAccent)
        .onAppear { model.refreshPermissions() }
        .alert("Talkie needs attention", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
    @ViewBuilder private var settingsContent: some View {
        switch current {
        case .general: general
        case .microphone: microphone
        case .speech: speech
        case .privacy: privacy
        }
    }
    private var general: some View {
        Form {
            Section {
                ShortcutRecorderControl(model: model)
                Picker("Activation", selection: $model.shortcutMode) {
                    Text("Hold to talk").tag(ShortcutMode.hold)
                    Text("Press to start / stop").tag(ShortcutMode.toggle)
                }.disabled(model.phase != .idle)
            } header: { Text("Keyboard") } footer: {
                Text("Finish speaking, then release the shortcut. In toggle mode, press it again to finish. Your words are saved before insertion is attempted.")
            }
            Section {
                Toggle("Activation sound", isOn: $model.soundEnabled)
                HStack(spacing: 14) {
                    Text("Volume")
                    Slider(value: $model.soundVolume, in: 0...1).accessibilityLabel("Activation sound volume")
                    Button("Preview") { model.playActivationSound() }
                }.disabled(!model.soundEnabled)
            } header: { Text("Sound") } footer: {
                Text("The cue plays when the microphone is ready. Wait for it before speaking.")
            }
            Section {
                Toggle("Launch Talkie at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLogin($0) }))
            }
        }.formStyle(.grouped)
    }
    private var microphone: some View {
        Form {
            Section {
                Picker("Preferred input", selection: Binding(get: { model.audio.selectedDeviceUID }, set: { model.audio.selectedDeviceUID = $0 })) {
                    Text("Follow system input").tag(String?.none)
                    ForEach(model.audio.devices) { device in Text(device.name).tag(Optional(device.uid)) }
                    if let uid = model.audio.selectedDeviceUID, !model.audio.devices.contains(where: { $0.uid == uid }) {
                        Text("Preferred microphone unavailable").tag(Optional(uid))
                    }
                }.disabled(model.phase != .idle)
                HStack {
                    Label(model.microphoneGranted ? "Microphone access enabled" : "Microphone access needed", systemImage: model.microphoneGranted ? "checkmark.circle" : "mic.slash")
                    Spacer()
                    if !model.microphoneGranted { Button("Enable microphone") { model.requestMicrophone() } }
                }
                HStack {
                    Label(model.accessibilityGranted ? "Text insertion enabled" : "Insertion access needed", systemImage: model.accessibilityGranted ? "checkmark.circle" : "hand.raised")
                    Spacer()
                    if !model.accessibilityGranted { Button("Enable insertion") { model.requestAccessibility() } }
                }
            } header: { Text("Input & permissions") }
            Section {
                ProgressView(value: model.audio.level).tint(model.audio.level > 0.9 ? .orange : talkieAccent).accessibilityLabel("Input signal")
                Text(model.phase == .testing ? "Listening · Test stops after five seconds" : "Microphone off while idle")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(model.phase == .testing ? "Stop test" : "Record five-second test", systemImage: model.phase == .testing ? "stop.fill" : "record.circle") { model.toggleMicTest() }
                        .disabled(model.phase != .idle && model.phase != .testing)
                    Button("Play test", systemImage: "play") { model.playMicTest() }.disabled(model.lastTestURL == nil || model.phase != .idle)
                }
            } header: { Text("Signal check") } footer: {
                Text("Listen to the test to check the sound. A disconnected microphone stops the take and preserves its captured audio; Talkie does not silently switch inputs.")
            }
            Button("Refresh devices and permissions", systemImage: "arrow.clockwise") { model.refreshPermissions() }
        }.formStyle(.grouped)
    }
    private var speech: some View {
        Form {
            Section {
                Picker("Local model", selection: Binding(get: { model.speech.selectedModel }, set: { next in
                    Task { do { try await model.speech.changeModel(to: next); await model.loadExistingModel() } catch { model.error = error.localizedDescription } }
                })) {
                    ForEach(SpeechModel.allCases) { choice in Text(choice.label).tag(choice) }
                }.disabled(model.busy)
                Text(model.speech.status).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if model.speech.isDownloading {
                    ProgressView(value: model.speech.progress)
                    Button("Cancel download") { model.speech.cancel() }
                } else if model.speech.isReady {
                    Label("Offline ready", systemImage: "checkmark.shield")
                } else if model.isPreparing || model.speech.isPreparing {
                    ProgressView("Loading model on this Mac…")
                } else if model.speech.hasDownloadedModel {
                    Button("Load local model") { Task { await model.loadExistingModel() } }
                } else {
                    Button("Download local model") { model.downloadModel() }.buttonStyle(.borderedProminent)
                }
            } header: { Text("Recognition") } footer: {
                Text("Verified model files are downloaded once. Recognition then works without an internet connection.")
            }
            Section {
                Toggle("Release memory after five idle minutes", isOn: $model.releaseModelAfterIdle)
                if model.speech.isReady {
                    Button("Unload model now") {
                        Task { await model.speech.unload(); model.message = "Speech model unloaded · It will load when needed" }
                    }.disabled(model.busy)
                }
            } header: { Text("Memory") } footer: {
                Text("Talkie keeps the model ready by default. Releasing memory can help demanding creative work; loading again may take a while. Wait for the activation cue.")
            }
            Section {
                Text("Your phrasing is preserved. Approved Project Kit corrections are applied separately; the original transcription remains available.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
    private var privacy: some View {
        Form {
            Section {
                Label("On-device speech recognition", systemImage: "desktopcomputer")
                Label("No account or cloud transcription", systemImage: "network.slash")
                Label("Microphone off while idle", systemImage: "mic.slash")
                Label("Messages stay unsent", systemImage: "paperplane")
            } header: { Text("Private by design") }
            Section {
                LabeledContent("Transcripts", value: "30 days")
                LabeledContent("Pinned text", value: "Until you remove it")
                LabeledContent("Successful audio", value: "24 hours")
                LabeledContent("Recording cache target", value: "1 GB")
            } header: { Text("Local history") } footer: {
                Text("Unresolved failed or interrupted recordings are kept and flagged for review. Recovery audio is protected from silent eviction when the cache target is exceeded.")
            }
            Section {
                Button("Show local data folder", systemImage: "folder") { NSWorkspace.shared.open(model.history.storageDirectory) }
            } footer: {
                Text("Files are stored locally. Your Mac's account and disk encryption settings govern access; Talkie does not add a separate encrypted vault.")
            }
        }.formStyle(.grouped)
    }
}
