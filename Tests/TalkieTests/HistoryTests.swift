import XCTest
@testable import Talkie

final class HistoryTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TalkieHistoryTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @MainActor
    func testCaptureWarningPersistsFullDurationAndAudioWithoutTranscript() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        var sessionID = UUID()
        do {
            let store = HistoryStore(directory: folder)
            let take = try store.beginSession()
            sessionID = take.id
            try Data("synthetic recording".utf8).write(to: XCTUnwrap(take.audioURL))
            try store.markCaptureWarning(sessionID: take.id,
                                         warning: "Synthetic input quality warning", durationSeconds: 18.5)
        }
        let saved = try XCTUnwrap(HistoryStore(directory: folder).sessions.first { $0.id == sessionID })
        XCTAssertEqual(saved.durationSeconds, 18.5)
        XCTAssertEqual(saved.status, .interrupted)
        XCTAssertEqual(saved.captureWarning, "Synthetic input quality warning")
        XCTAssertNil(saved.rawTranscript)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(saved.audioURL).path))
    }

    @MainActor
    func testSQLiteRestartPreservesOriginalCorrectedFrameAndPasteState() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let kit = ProjectKit(id: "test", name: "Test", preferredSpellings: ["ExampleStudio"],
            corrections: [TextCorrection(from: "example studio", to: "ExampleStudio")],
            prefix: "Use the supplied image.", suffix: "Keep {{transcript}} literal.")
        var sessionID: UUID!
        do {
            let store = HistoryStore(directory: folder)
            XCTAssertTrue(store.isAvailable, store.lastError ?? "")
            let session = try store.beginSession(targetBundleID: "test.editor", targetAppName: "Test Editor", kit: kit)
            sessionID = session.id
            XCTAssertEqual(session.status, .recording)
            XCTAssertEqual(store.sessions.count, 1)
            try Data("synthetic recording".utf8).write(to: XCTUnwrap(session.audioURL))
            let saved = try store.updateTranscript(sessionID: session.id, raw: "example studio makes a film.", durationSeconds: 4)
            XCTAssertEqual(saved.status, .saved)
            XCTAssertEqual(saved.rawTranscript, "example studio makes a film.")
            XCTAssertEqual(saved.correctedTranscript, "ExampleStudio makes a film.")
            XCTAssertNil(saved.framedTranscript, "Framing must never happen implicitly during dictation.")
            try store.setStatus(sessionID: session.id, status: .pasteAttempted)
        }
        do {
            let store = HistoryStore(directory: folder)
            let saved = try XCTUnwrap(store.sessions.first)
            XCTAssertEqual(saved.id, sessionID)
            XCTAssertEqual(saved.status, .pasteAttempted)
            XCTAssertEqual(saved.rawTranscript, "example studio makes a film.")
            XCTAssertEqual(saved.targetBundleID, "test.editor")
            XCTAssertEqual(saved.targetAppName, "Test Editor")
            XCTAssertEqual(saved.durationSeconds, 4)
            let framed = try store.applyFrame(sessionID: saved.id)
            XCTAssertEqual(framed.displayTranscript,
                "Use the supplied image.\n\nExampleStudio makes a film.\n\nKeep {{transcript}} literal.")
            XCTAssertEqual(framed.rawTranscript, saved.rawTranscript)
        }
        let restarted = HistoryStore(directory: folder)
        XCTAssertEqual(restarted.sessions.first?.status, .readyToCopy)
        XCTAssertNotNil(restarted.sessions.first?.framedTranscript)
    }

    @MainActor
    func testStartupReconcilesInterruptedRecordingWithoutInterruptingRefresh() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = HistoryStore(directory: folder)
        let session = try first.beginSession()
        try Data("synthetic partial audio".utf8).write(to: XCTUnwrap(session.audioURL))
        try first.refresh()
        XCTAssertEqual(first.sessions.first?.status, .recording)

        let restarted = HistoryStore(directory: folder)
        XCTAssertEqual(restarted.sessions.first?.status, .interrupted)
        XCTAssertEqual(restarted.sessions.first?.errorMessage, "Recording was interrupted. Retry the saved audio.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(restarted.sessions.first?.audioPath)))
    }

    @MainActor
    func testProjectKitEditsDoNotChangeCapturedVersion() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HistoryStore(directory: folder)
        var kit = ProjectKit(id: "custom", name: "Custom", corrections: [TextCorrection(from: "alpha", to: "one")])
        try store.upsertKit(kit)
        let session = try store.beginSession(kit: kit)
        kit.corrections = [TextCorrection(from: "alpha", to: "two")]
        kit.prefix = "Second frame"
        try store.upsertKit(kit)
        let updatedKit = try XCTUnwrap(store.kits.first { $0.id == kit.id })
        XCTAssertEqual(updatedKit.version, 2)
        let saved = try store.updateTranscript(sessionID: session.id, raw: "alpha")
        XCTAssertEqual(saved.correctedTranscript, "one")
        XCTAssertEqual(saved.projectKitVersion, 1)
        let framed = try store.applyFrame(sessionID: session.id, kit: updatedKit)
        XCTAssertEqual(framed.displayTranscript, "Second frame\n\ntwo")
        XCTAssertEqual(framed.projectKitVersion, 2)
        XCTAssertEqual(framed.rawTranscript, "alpha")
    }

    func testCorrectionsUsePhraseBoundariesProtectCodeLinksAndNeverChain() {
        let kit = ProjectKit(name: "Test", preferredSpellings: ["ExampleStudio"], corrections: [
            TextCorrection(from: "rod", to: "RØDE"),
            TextCorrection(from: "example studio", to: "ExampleStudio"),
            TextCorrection(from: "alpha", to: "beta"),
            TextCorrection(from: "beta", to: "gamma")
        ])
        let input = "rod, rods, arod, rod_id; example studio; examplestudio. https://rod.example/rod rod@example.com `rod example studio` ```\nrod\n``` /tmp/rod alpha beta"
        let expected = "RØDE, rods, arod, rod_id; ExampleStudio; ExampleStudio. https://rod.example/rod rod@example.com `rod example studio` ```\nrod\n``` /tmp/rod beta gamma"
        XCTAssertEqual(kit.corrected(input), expected)
    }

    func testLongestExplicitPhraseWinsAndFramePreservesExactText() {
        let kit = ProjectKit(name: "Test", corrections: [
            TextCorrection(from: "camera", to: "lens"),
            TextCorrection(from: "camera left", to: "screen right")
        ], prefix: "  Exact prefix\n{{transcript}}", suffix: "\nExact $suffix  ")
        XCTAssertEqual(kit.corrected("Camera left, camera."), "screen right, lens.")
        let transcript = "  Keep my\nline breaks.  "
        XCTAssertEqual(kit.framed(transcript), "  Exact prefix\n{{transcript}}\n\n" + transcript + "\n\n\nExact $suffix  ")
    }

    @MainActor
    func testRetentionKeepsPinnedTextActiveRecordingAndUnresolvedRecovery() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HistoryStore(directory: folder)
        let pinned = try store.beginSession()
        let expired = try store.beginSession()
        let failed = try store.beginSession()
        let active = try store.beginSession()
        for session in [pinned, expired, failed, active] {
            try Data("synthetic audio".utf8).write(to: XCTUnwrap(session.audioURL))
        }
        _ = try store.updateTranscript(sessionID: pinned.id, raw: "Keep this text.")
        try store.setPinned(sessionID: pinned.id, true)
        _ = try store.updateTranscript(sessionID: expired.id, raw: "Expired text.")
        try store.setStatus(sessionID: failed.id, status: .transcriptionFailed, error: "Synthetic engine failure")
        try store.runRetention(now: Date().addingTimeInterval(31 * 86_400))
        XCTAssertNotNil(store.sessions.first { $0.id == pinned.id })
        XCTAssertNil(store.sessions.first { $0.id == pinned.id }?.audioPath)
        XCTAssertFalse(store.sessions.contains { $0.id == expired.id })
        XCTAssertEqual(store.sessions.first { $0.id == active.id }?.status, .recording)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(active.audioPath)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(failed.audioPath)))
        XCTAssertTrue(store.lastError?.contains("older than seven days were kept") == true)
    }

    @MainActor
    func testSuccessfulAudioExpiresAfter24HoursWithoutLosingTranscript() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HistoryStore(directory: folder)
        let session = try store.beginSession()
        let audio = try XCTUnwrap(session.audioURL)
        try Data("synthetic audio".utf8).write(to: audio)
        _ = try store.updateTranscript(sessionID: session.id, raw: "Saved before insertion.")
        try store.runRetention(now: Date().addingTimeInterval(25 * 3_600))
        XCTAssertEqual(store.sessions.first?.rawTranscript, "Saved before insertion.")
        XCTAssertNil(store.sessions.first?.audioPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
    }

    @MainActor
    func testCacheCapNeverEvictsUnresolvedAudio() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HistoryStore(directory: folder)
        let failed = try store.beginSession()
        let audio = try XCTUnwrap(failed.audioURL)
        XCTAssertTrue(FileManager.default.createFile(atPath: audio.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: audio)
        try handle.truncate(atOffset: 1_073_741_825) // Sparse synthetic fixture, no audio payload.
        try handle.close()
        try store.setStatus(sessionID: failed.id, status: .interrupted)
        try store.runRetention()
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertTrue(store.lastError?.contains("exceeds 1 GB") == true)
    }

    @MainActor
    func testBrokenStorageIsVisibleAndCannotAcceptNewRecordingJournal() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let blocked = folder.appendingPathComponent("not-a-directory")
        try Data("synthetic file".utf8).write(to: blocked)
        let store = HistoryStore(directory: blocked)
        XCTAssertFalse(store.isAvailable)
        XCTAssertNotNil(store.lastError)
        XCTAssertThrowsError(try store.beginSession())
    }
}
