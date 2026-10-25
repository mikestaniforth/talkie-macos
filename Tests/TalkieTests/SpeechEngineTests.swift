import Foundation
import XCTest
@testable import Talkie

@MainActor
final class SpeechEngineTests: XCTestCase {
    func testMissingModelFailsLocallyWithoutStartingADownload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let engine = SpeechEngine(modelsDirectory: root)
        XCTAssertFalse(engine.hasDownloadedModel)
        do {
            try await engine.prepare()
            XCTFail("A missing model must require an explicit download")
        } catch SpeechEngineError.modelNotDownloaded {
            XCTAssertFalse(engine.isReady)
            XCTAssertFalse(engine.isDownloading)
            XCTAssertFalse(engine.isBusy)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        }
    }

    func testMalformedInstallationCannotBecomeReady() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = SpeechEngine(modelsDirectory: root)
        let folder = root.appendingPathComponent(engine.selectedModel.rawValue)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not an installation".utf8).write(to: folder.appendingPathComponent("installation.json"))
        do {
            try await engine.prepare()
            XCTFail("An invalid local installation must fail before inference")
        } catch SpeechEngineError.invalidInstallation {
            XCTAssertFalse(engine.isReady)
            XCTAssertFalse(engine.isPreparing)
            XCTAssertFalse(engine.isDownloading)
        }
    }

    func testMissingAudioFailsBeforeLoadingOrDownloadingAModel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let engine = SpeechEngine(modelsDirectory: root)
        do {
            _ = try await engine.transcribe(audioURL: root.appendingPathComponent("missing.wav"), vocabulary: [])
            XCTFail("An unreadable recording must fail locally")
        } catch SpeechEngineError.invalidAudio {
            XCTAssertFalse(engine.isBusy)
            XCTAssertFalse(engine.isDownloading)
        }
    }

    func testUnloadWithoutAModelDoesNotCreateFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let engine = SpeechEngine(modelsDirectory: root)
        engine.cancel()
        await engine.unload()
        XCTAssertFalse(engine.isReady)
        XCTAssertFalse(engine.isBusy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testDigitalSilenceAndDCOffsetCannotReachRecognition() {
        XCTAssertFalse(SpeechEngine.containsNonSilentAudio([]))
        XCTAssertFalse(SpeechEngine.containsNonSilentAudio(Array(repeating: 0, count: 16_000)))
        XCTAssertFalse(SpeechEngine.containsNonSilentAudio(Array(repeating: 0.25, count: 16_000)))
        XCTAssertFalse(SpeechEngine.containsNonSilentAudio([.nan, 0.5]))
        XCTAssertFalse(SpeechEngine.containsNonSilentAudio([.infinity, 0]))
    }

    func testSilenceFloorPreservesVeryQuietSignals() {
        let quiet = (0..<16_000).map { Float(sin(Double($0) * .pi / 20)) * 0.0001 }
        XCTAssertTrue(SpeechEngine.containsNonSilentAudio(quiet))
        XCTAssertTrue(SpeechEngine.containsNonSilentAudio(quiet.map { $0 + 0.25 }))
    }

    func testAudibilityFloorDistinguishesQuietInputFromDigitalSilence() {
        let lowSignal = (0..<16_000).map { Float(sin(Double($0) * .pi / 40)) * 0.0001 }
        XCTAssertEqual(AudioSignalCheck.assess(lowSignal), .tooQuiet)
        XCTAssertEqual(AudioSignalCheck.assess(Array(repeating: 0, count: 16_000)), .digitalSilence)
        let quietSpeechLevel = lowSignal.map { $0 * 15 }
        XCTAssertEqual(AudioSignalCheck.assess(quietSpeechLevel), .usable)
    }

    func testAudibilityFloorRejectsAnIsolatedClick() {
        var click = Array(repeating: Float(0), count: 16_000)
        click[8_000] = 0.8
        XCTAssertEqual(AudioSignalCheck.assess(click), .tooQuiet)
    }
}
