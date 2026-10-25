import Combine
import CryptoKit
import Foundation
import AVFoundation
@preconcurrency import WhisperKit

enum SpeechModel: String, CaseIterable, Identifiable, Codable, Sendable {
    case balanced
    case english

    var id: String { rawValue }
    var label: String { self == .balanced ? "Whisper Turbo · Balanced" : "Whisper Small · English" }
    var displayName: String { label }
    var modelID: String { self == .balanced ? "openai_whisper-large-v3-v20240930_626MB" : "openai_whisper-small.en" }
    var downloadSize: String { self == .balanced ? "About 630 MB" : "About 490 MB" }
    fileprivate var tokenizerRepo: String { self == .balanced ? "openai/whisper-large-v3" : "openai/whisper-small.en" }
    fileprivate var tokenizerRevision: String { self == .balanced ? "06f233fe06e710322aca913c1bc4249a0d71fce1" : "e8727524f962ee844a7319d92be39ac1bd25655a" }
}

enum SpeechEngineError: LocalizedError {
    case modelNotDownloaded
    case busy
    case invalidInstallation(String)
    case noSpeech
    case signalTooQuiet
    case invalidAudio
    case repeatedAudio

    var errorDescription: String? {
        switch self {
        case .modelNotDownloaded: "Download a speech model in Settings before dictating. The one-time download runs locally after installation."
        case .busy: "Talkie is finishing another speech operation. Try again when it is ready."
        case .invalidInstallation(let reason): "The local speech model could not be verified. Download it again in Settings. \(reason)"
        case .noSpeech: "No speech was recognised. Your recording can be retried from History."
        case .signalTooQuiet: "The microphone signal was too quiet to transcribe safely. Increase input gain or move closer, then try again. Your saved recording remains available in History."
        case .invalidAudio: "The recording could not be opened. Try a new recording or choose another audio file."
        case .repeatedAudio: "This recording contains repeated old microphone audio, so it may be incomplete. Reconnect the microphone or choose another input, then record again. The original audio has been kept in History."
        }
    }
}

/// All inference runs locally. Network access is confined to downloadModel().
/// Downloads use immutable upstream revisions and are verified against the
/// official repository's Git/LFS hashes before a completed installation exists.
@MainActor
final class SpeechEngine: ObservableObject {
    @Published private(set) var isReady = false
    @Published private(set) var isDownloading = false
    @Published private(set) var isPreparing = false
    @Published private(set) var isTranscribing = false
    @Published private(set) var progress = 0.0
    @Published private(set) var status = "Download a model to get started"
    @Published var selectedModel: SpeechModel {
        didSet {
            guard selectedModel != oldValue else { return }
            guard !isBusy else { selectedModel = oldValue; return }
            TalkieEnvironment.defaults.set(selectedModel.rawValue, forKey: "talkie.speechModel")
            isReady = false
            progress = 0
            status = hasDownloadedModel ? "Local model installed · Load to use" : "Download a model to get started"
        }
    }

    var isBusy: Bool { isDownloading || isPreparing || isTranscribing || isUnloading }
    var hasDownloadedModel: Bool { FileManager.default.fileExists(atPath: installationURL(for: selectedModel).path) }
    var modelsDirectory: URL { baseURL }

    private let baseURL: URL
    private let useGPU: Bool
    private var engine: WhisperKit?
    private var loadedModel: SpeechModel?
    private var isUnloading = false
    private var preparationTask: Task<Void, Error>?
    private var downloadTask: Task<Void, Error>?
    private var transcriptionTask: Task<String, Error>?

    init(modelsDirectory: URL? = nil, useGPU: Bool = false) {
        self.useGPU = useGPU
        baseURL = modelsDirectory ?? TalkieEnvironment.applicationSupportDirectory.appendingPathComponent("Models", isDirectory: true)
        selectedModel = SpeechModel(rawValue: TalkieEnvironment.defaults.string(forKey: "talkie.speechModel") ?? "") ?? .balanced
        if hasDownloadedModel { status = "Local model installed · Load to use" }
    }

    /// This method only reads local files. It never downloads missing assets.
    func prepare() async throws {
        if isReady, loadedModel == selectedModel { return }
        guard !isBusy else { throw SpeechEngineError.busy }
        guard hasDownloadedModel else { throw SpeechEngineError.modelNotDownloaded }
        isPreparing = true
        status = "Verifying local model…"
        defer { isPreparing = false; preparationTask = nil }
        if let engine { await engine.unloadModels() }
        engine = nil
        loadedModel = nil
        isReady = false

        let model = selectedModel
        let installationURL = installationURL(for: model)
        let root = modelRoot(for: model)
        let task = Task<Void, Error> { [weak self] in
            let installation = try await Self.verifiedInstallation(at: installationURL, root: root, model: model)
            try Task.checkCancellation()
            guard let self else { throw CancellationError() }
            self.status = "Loading local speech model… First load may take a little longer."
            let tokenizerFolder = root.appendingPathComponent(installation.tokenizerFolder, isDirectory: true)
            // Supplying a tokenizer explicitly prevents WhisperKit's local-load
            // error path from falling back to a network tokenizer download.
            let tokenizer = try await LocalWhisperTokenizer(folder: tokenizerFolder)
            let candidate = try await WhisperKit(WhisperKitConfig(
                model: model.modelID,
                modelFolder: root.appendingPathComponent(installation.modelFolder, isDirectory: true).path,
                tokenizerFolder: tokenizerFolder,
                // Keep the SDK's efficient Neural Engine defaults. The optional
                // GPU route is exposed to the developer benchmark, so startup,
                // unload/reload and recognition can be compared on this Mac.
                computeOptions: self.useGPU ? ModelComputeOptions(melCompute: .cpuAndGPU, audioEncoderCompute: .cpuAndGPU, textDecoderCompute: .cpuAndGPU) : ModelComputeOptions(),
                verbose: false,
                prewarm: false,
                load: false,
                download: false
            ))
            candidate.tokenizer = tokenizer
            candidate.textDecoder.isModelMultilingual = model == .balanced
            do {
                try Task.checkCancellation()
                // Core ML compiles/specialises on first load and manages its
                // cache. Avoid an explicit prewarm load/unload cycle on every
                // wake; this Mac has room for the compressed model's components.
                try await candidate.loadModels()
                try Task.checkCancellation()
                self.engine = candidate
                self.loadedModel = model
            } catch {
                await candidate.unloadModels()
                throw error
            }
        }
        preparationTask = task
        do {
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            isReady = true
            progress = 1
            status = "Ready · On-device speech"
        } catch {
            if let engine { await engine.unloadModels() }
            engine = nil
            loadedModel = nil
            status = error is CancellationError ? "Model loading cancelled" : error.localizedDescription
            throw error
        }
    }

    /// Deliberate one-time download. No audio or transcript is sent upstream.
    func downloadModel() async throws {
        guard !isBusy else { throw SpeechEngineError.busy }
        isDownloading = true
        isReady = false
        progress = 0
        status = "Preparing model download…"
        defer { isDownloading = false; downloadTask = nil }
        if let engine { await engine.unloadModels() }
        engine = nil
        loadedModel = nil
        let model = selectedModel
        let root = modelRoot(for: model)
        let marker = installationURL(for: model)
        let task = Task<Void, Error> { [weak self] in
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            // Remove the success marker before repairing or replacing any assets.
            if FileManager.default.fileExists(atPath: marker.path) { try FileManager.default.removeItem(at: marker) }
            let hub = HubApiWrapper(downloadBase: root.appendingPathComponent("snapshot", isDirectory: true), hfToken: "")
            let modelRepo = HubApiWrapper.Repo(id: Self.modelRepository)
            let tokenizerRepo = HubApiWrapper.Repo(id: model.tokenizerRepo)
            let modelManifest = try await Self.remoteManifest(repo: Self.modelRepository, revision: Self.modelRevision, folder: model.modelID)
            let tokenizerManifest = try await Self.remoteManifest(repo: model.tokenizerRepo, revision: model.tokenizerRevision, folder: nil)
                .filter { Self.tokenizerFiles.contains($0.path) }
            guard !modelManifest.isEmpty, tokenizerManifest.contains(where: { $0.path == "tokenizer.json" }),
                  tokenizerManifest.contains(where: { $0.path == "tokenizer_config.json" }) else {
                throw SpeechEngineError.invalidInstallation("The upstream asset list was incomplete.")
            }
            let snapshot = try await hub.snapshot(from: modelRepo, revision: Self.modelRevision, matching: ["\(model.modelID)/*"]) { [weak self] update in
                let fraction = update.fractionCompleted
                Task { @MainActor [weak self] in
                    guard let self, self.isDownloading, self.progress <= 0.9 else { return }
                    self.progress = min(0.9, fraction * 0.9)
                    self.status = "Downloading \(model.downloadSize.lowercased())… \(Int(fraction * 100))%"
                }
            }
            try Task.checkCancellation()
            let tokenizerSnapshot = try await hub.snapshot(from: tokenizerRepo, revision: model.tokenizerRevision, matching: Self.tokenizerFiles) { [weak self] update in
                let fraction = update.fractionCompleted
                Task { @MainActor [weak self] in
                    guard let self, self.isDownloading, self.progress <= 0.93 else { return }
                    self.progress = 0.9 + fraction * 0.03
                    self.status = "Downloading speech tokenizer…"
                }
            }
            try Task.checkCancellation()
            self?.status = "Verifying downloaded files…"
            self?.progress = 0.94
            let prefix = Self.relativePath(of: snapshot, in: root)
            let tokenizerPrefix = Self.relativePath(of: tokenizerSnapshot, in: root)
            let files = modelManifest.map { $0.prefixed(prefix) } + tokenizerManifest.map { $0.prefixed(tokenizerPrefix) }
            let installation = SpeechInstallation(
                schemaVersion: 1,
                model: model,
                modelRevision: Self.modelRevision,
                tokenizerRevision: model.tokenizerRevision,
                modelFolder: prefix + "/" + model.modelID,
                tokenizerFolder: tokenizerPrefix,
                files: files
            )
            try await Self.verifyFiles(files, root: root, deleteInvalidFiles: true)
            // Parse before marking ready so a corrupt tokenizer never triggers a
            // hidden fallback during prepare().
            _ = try await LocalWhisperTokenizer(folder: tokenizerSnapshot)
            try Task.checkCancellation()
            let data = try JSONEncoder().encode(installation)
            try data.write(to: marker, options: .atomic)
        }
        downloadTask = task
        do {
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            progress = 1
            status = "Model verified · Ready to load"
        } catch {
            status = error is CancellationError ? "Download cancelled · You can try again" : error.localizedDescription
            throw error
        }
    }

    /// Suspect audio may yield a reviewable draft when its warning has been
    /// journalled. The caller must retain that warning and never auto-insert.
    func transcribe(audioURL: URL, vocabulary: [String], allowRepeatedAudio: Bool = false) async throws -> String {
        guard FileManager.default.isReadableFile(atPath: audioURL.path) else { throw SpeechEngineError.invalidAudio }
        if !isReady || loadedModel != selectedModel { try await prepare() }
        guard !isBusy, let engine else { throw SpeechEngineError.busy }
        isTranscribing = true
        status = "Transcribing on your Mac…"
        defer { isTranscribing = false; transcriptionTask = nil }
        let task = Task<String, Error> {
            try Task.checkCancellation()
            // Convert once using the same normalised 16 kHz samples passed to
            // inference. Reject digital silence and sustained inaudible input
            // before Whisper can turn ambient noise into plausible words. This
            // is an audibility floor, not a speech/noise classifier.
            let conversion = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                // A quick release can leave a valid, empty capture file.
                // Treat that as no speech, so it follows the quiet receipt path.
                let inputFile = try AVAudioFile(forReading: audioURL)
                guard inputFile.length > 0 else { throw SpeechEngineError.noSpeech }
                if !allowRepeatedAudio, try RepeatedAudioCheck.fileContainsRepeatedAudio(audioURL) {
                    throw SpeechEngineError.repeatedAudio
                }
                let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: audioURL.path)
                try Task.checkCancellation()
                switch AudioSignalCheck.assess(samples) {
                case .invalid: throw SpeechEngineError.invalidAudio
                case .digitalSilence: throw SpeechEngineError.noSpeech
                case .tooQuiet: throw SpeechEngineError.signalTooQuiet
                case .usable: break
                }
                return samples
            }
            let samples = try await withTaskCancellationHandler { try await conversion.value } onCancel: { conversion.cancel() }
            // Vocabulary is a decoder hint, never a replacement for spoken text.
            let words = vocabulary.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            let prompt = Array(words.prefix(80)).joined(separator: ", ")
            let promptTokens = prompt.isEmpty ? nil : engine.tokenizer.map { Array($0.encode(text: " " + prompt).suffix(180)) }
            let options = DecodingOptions(
                verbose: false,
                task: .transcribe,
                language: "en",
                temperature: 0,
                temperatureFallbackCount: 2,
                usePrefillPrompt: true,
                detectLanguage: false,
                skipSpecialTokens: true,
                withoutTimestamps: true,
                wordTimestamps: false,
                promptTokens: promptTokens,
                suppressBlank: true,
                concurrentWorkerCount: 1
            )
            let results = try await engine.transcribe(audioArray: samples, decodeOptions: options, callback: { _ in
                !Task.isCancelled
            })
            try Task.checkCancellation()
            let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw SpeechEngineError.noSpeech }
            return text
        }
        transcriptionTask = task
        do {
            let text = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            status = "Ready · On-device speech"
            return text
        } catch {
            status = error is CancellationError ? "Transcription cancelled" : error.localizedDescription
            throw error
        }
    }

    func cancel() {
        preparationTask?.cancel()
        downloadTask?.cancel()
        transcriptionTask?.cancel()
        if isBusy { status = "Cancelling…" }
    }

    func unload() async {
        guard !isUnloading else { return }
        isUnloading = true
        cancel()
        if let task = preparationTask { _ = try? await task.value }
        if let task = downloadTask { _ = try? await task.value }
        if let task = transcriptionTask { _ = try? await task.value }
        if let engine { await engine.unloadModels() }
        engine = nil
        loadedModel = nil
        isReady = false
        isUnloading = false
        status = hasDownloadedModel ? "Local model installed · Memory released" : "Download a model to get started"
    }

    func changeModel(to model: SpeechModel) async throws {
        guard !isBusy else { throw SpeechEngineError.busy }
        guard model != selectedModel else { return }
        await unload()
        selectedModel = model
    }

    nonisolated static func containsNonSilentAudio(_ samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return false }
        var total = 0.0
        var squares = 0.0
        var minimum = Float.greatestFiniteMagnitude
        var maximum = -Float.greatestFiniteMagnitude
        for sample in samples {
            guard sample.isFinite else { return false }
            let value = Double(sample)
            total += value
            squares += value * value
            minimum = min(minimum, sample)
            maximum = max(maximum, sample)
        }
        let count = Double(samples.count)
        let mean = total / count
        let acRMS = sqrt(max(0, squares / count - mean * mean))
        return maximum - minimum > 0.000_02 && acRMS > 0.000_001
    }

    private func modelRoot(for model: SpeechModel) -> URL { baseURL.appendingPathComponent(model.rawValue, isDirectory: true) }
    private func installationURL(for model: SpeechModel) -> URL { modelRoot(for: model).appendingPathComponent("installation.json") }

    private nonisolated static let modelRepository = "argmaxinc/whisperkit-coreml"
    private nonisolated static let modelRevision = "0f63a7800b00dd0226abd051b906c246e1907482"
    private nonisolated static let tokenizerFiles = ["tokenizer.json", "tokenizer_config.json", "config.json", "special_tokens_map.json", "added_tokens.json"]

    private nonisolated static func relativePath(of url: URL, in root: URL) -> String {
        String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
    }

    private nonisolated static func remoteManifest(repo: String, revision: String, folder: String?) async throws -> [SpeechAsset] {
        var url = URL(string: "https://huggingface.co/api/models/\(repo)/tree/\(revision)")!
        if let folder { url.appendPathComponent(folder) }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "recursive", value: "true")]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw SpeechEngineError.invalidInstallation("The model asset list could not be downloaded.")
        }
        // The pinned repositories contain fewer than one page of relevant files.
        // Refuse a truncated list rather than silently skipping validation.
        guard response.value(forHTTPHeaderField: "Link")?.contains("rel=\"next\"") != true else {
            throw SpeechEngineError.invalidInstallation("The upstream asset list exceeded one page.")
        }
        return try JSONDecoder().decode([SpeechRemoteAsset].self, from: data).filter { $0.type == "file" }.map {
            SpeechAsset(path: $0.path, bytes: $0.size, hash: $0.lfs?.oid ?? $0.oid, sha256: $0.lfs != nil)
        }
    }

    private nonisolated static func verifiedInstallation(at url: URL, root: URL, model: SpeechModel) async throws -> SpeechInstallation {
        let installation: SpeechInstallation
        do { installation = try JSONDecoder().decode(SpeechInstallation.self, from: Data(contentsOf: url)) }
        catch { throw SpeechEngineError.invalidInstallation("The installation record was unreadable.") }
        guard installation.schemaVersion == 1, installation.model == model,
              installation.modelRevision == modelRevision, installation.tokenizerRevision == model.tokenizerRevision,
              !installation.files.isEmpty else { throw SpeechEngineError.invalidInstallation("The installation record does not match this version.") }
        try await verifyFiles(installation.files, root: root)
        return installation
    }

    private nonisolated static func verifyFiles(_ files: [SpeechAsset], root: URL, deleteInvalidFiles: Bool = false) async throws {
        let task = Task.detached(priority: .utility) {
            for asset in files {
                try Task.checkCancellation()
                guard !asset.path.hasPrefix("/"), !asset.path.split(separator: "/").contains(".."), asset.bytes >= 0 else {
                    throw SpeechEngineError.invalidInstallation("An asset path was invalid.")
                }
                let url = root.appendingPathComponent(asset.path)
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize == asset.bytes else {
                    if deleteInvalidFiles { try? FileManager.default.removeItem(at: url) }
                    throw SpeechEngineError.invalidInstallation("An asset was missing or had the wrong size.")
                }
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                var sha256 = SHA256()
                var sha1 = Insecure.SHA1()
                if !asset.sha256 { sha1.update(data: Data("blob \(asset.bytes)\0".utf8)) }
                while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                    try Task.checkCancellation()
                    if asset.sha256 { sha256.update(data: chunk) } else { sha1.update(data: chunk) }
                }
                let digest = asset.sha256 ? sha256.finalize().map { String(format: "%02x", $0) }.joined() : sha1.finalize().map { String(format: "%02x", $0) }.joined()
                guard digest == asset.hash else {
                    // The pinned downloader can reuse a cached file solely from
                    // matching metadata. Removing a corrupt model asset here makes
                    // the next explicit download repair it instead of reusing it.
                    if deleteInvalidFiles { try? FileManager.default.removeItem(at: url) }
                    throw SpeechEngineError.invalidInstallation("An asset checksum did not match. Try the download again to repair it.")
                }
            }
        }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}

private struct SpeechInstallation: Codable, Sendable {
    let schemaVersion: Int
    let model: SpeechModel
    let modelRevision: String
    let tokenizerRevision: String
    let modelFolder: String
    let tokenizerFolder: String
    let files: [SpeechAsset]
}

private struct SpeechAsset: Codable, Sendable {
    let path: String
    let bytes: Int
    let hash: String
    let sha256: Bool
    func prefixed(_ prefix: String) -> SpeechAsset { SpeechAsset(path: prefix + "/" + path, bytes: bytes, hash: hash, sha256: sha256) }
}

private struct SpeechRemoteAsset: Decodable, Sendable {
    struct LFS: Decodable, Sendable { let oid: String }
    let type: String
    let oid: String
    let size: Int
    let path: String
    let lfs: LFS?
}

/// Local-only adapter for Argmax's public tokenizer. Never uses a pretrained
/// repository identifier, so missing/corrupt tokenizer files fail locally.
private final class LocalWhisperTokenizer: WhisperTokenizer {
    private let wrapped: TokenizerWrapper
    let specialTokens: SpecialTokens
    let allLanguageTokens: Set<Int>

    init(folder: URL) async throws {
        let wrapped = try await AutoTokenizerWrapper.from(modelFolder: folder)
        func token(_ text: String) throws -> Int {
            guard let value = wrapped.convertTokenToId(text) else { throw SpeechEngineError.invalidInstallation("The tokenizer is missing a required speech token.") }
            return value
        }
        self.wrapped = wrapped
        let special = try SpecialTokens(
            endToken: token("<|endoftext|>"),
            englishToken: token("<|en|>"),
            noSpeechToken: token("<|nospeech|>"),
            noTimestampsToken: token("<|notimestamps|>"),
            specialTokenBegin: token("<|endoftext|>"),
            startOfPreviousToken: token("<|startofprev|>"),
            startOfTranscriptToken: token("<|startoftranscript|>"),
            timeTokenBegin: token("<|0.00|>"),
            transcribeToken: token("<|transcribe|>"),
            translateToken: token("<|translate|>"),
            whitespaceToken: wrapped.encode(text: " ", addSpecialTokens: false).first ?? 220
        )
        specialTokens = special
        allLanguageTokens = Set(Constants.languages.values.compactMap { wrapped.convertTokenToId("<|\($0)|>") }.filter { $0 > special.specialTokenBegin })
    }

    func encode(text: String) -> [Int] { wrapped.encode(text: text, addSpecialTokens: false) }
    func decode(tokens: [Int]) -> String { wrapped.decode(tokens: tokens) }
    func convertTokenToId(_ token: String) -> Int? { wrapped.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { wrapped.convertIdToToken(id) }

    // Word timestamps are disabled in Talkie. Keep Unicode bytes together if the
    // framework requests segmentation, then group English whitespace boundaries.
    func splitToWordTokens(tokenIds: [Int]) -> (words: [String], wordTokens: [[Int]]) {
        var words: [String] = []
        var groups: [[Int]] = []
        var pending: [Int] = []
        for id in tokenIds {
            pending.append(id)
            let text = wrapped.decode(tokens: pending)
            if text.contains("\u{fffd}") { continue }
            if text.hasPrefix(" ") || id >= specialTokens.specialTokenBegin || words.isEmpty {
                words.append(text)
                groups.append(pending)
            } else {
                words[words.count - 1] += text
                groups[groups.count - 1].append(contentsOf: pending)
            }
            pending = []
        }
        if !pending.isEmpty { words.append(wrapped.decode(tokens: pending)); groups.append(pending) }
        return (words, groups)
    }
}
