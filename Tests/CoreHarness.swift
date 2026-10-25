import Foundation
import CSQLite
import Darwin

private struct CoreCheckFailure: Error, CustomStringConvertible {
    let description: String
}

/// Real disk-backed checks for Macs with Command Line Tools but no XCTest SDK.
/// The script compiles the production sources directly; there is no substitute
/// storage/correction implementation and every recording fixture is synthetic.
@main
@MainActor
struct CoreHarness {
    static func main() {
        let tests: [(String, () throws -> Void)] = [
            ("SQLite restart preserves transcript versions and insertion status", restart),
            ("Startup recovers interrupted recording; refresh preserves active take", interrupted),
            ("Capture warning and full duration survive restart without inventing text", captureWarning),
            ("Project Kit edits preserve captured versions", kitVersions),
            ("Corrections respect boundaries, code, links, email and paths", correctionBoundaries),
            ("Longest phrase wins; frame text stays exact and literal", exactFrames),
            ("Retention preserves pinned text, active takes and unresolved recovery", retention),
            ("Successful audio expires at 24 hours while transcript remains", audioExpiry),
            ("1 GB cache cap retains unresolved audio and reports overflow", cacheCap),
            ("Invalid storage and rejected SQLite writes surface without losing journal", storageFailures)
        ]
        var passed = 0
        for (name, test) in tests {
            do {
                try test()
                passed += 1
                print("PASS \(passed)/\(tests.count): \(name)")
            } catch {
                fputs("FAIL: \(name)\n\(error)\n", stderr)
                exit(EXIT_FAILURE)
            }
        }
        print("All \(passed) core checks passed using actual production sources and SQLite.")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw CoreCheckFailure(description: message) }
    }

    private static func fixture(_ test: (URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TalkieCoreFixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try test(folder)
    }

    private static func recordFixture(_ session: DictationSession) throws {
        guard let audio = session.audioURL else { throw CoreCheckFailure(description: "No journaled recording path") }
        try Data("synthetic audio fixture".utf8).write(to: audio)
    }

    private static func captureWarning() throws {
        try fixture { folder in
            var sessionID = UUID()
            do {
                let store = HistoryStore(directory: folder)
                let take = try store.beginSession()
                sessionID = take.id
                try recordFixture(take)
                try store.markCaptureWarning(sessionID: take.id,
                                             warning: "Synthetic input quality warning", durationSeconds: 18.5)
            }
            let reopened = HistoryStore(directory: folder)
            guard let saved = reopened.sessions.first(where: { $0.id == sessionID }) else {
                throw CoreCheckFailure(description: "Capture warning take was lost")
            }
            try require(saved.durationSeconds == 18.5 && saved.status == .interrupted, "Full take duration or review status lost")
            try require(saved.captureWarning == "Synthetic input quality warning", "Integrity warning lost")
            try require(saved.rawTranscript == nil && saved.displayTranscript.isEmpty, "Unreviewed audio became invented text")
            try require(saved.audioURL.map { FileManager.default.fileExists(atPath: $0.path) } == true, "Review audio was removed")
            _ = try reopened.updateTranscript(sessionID: sessionID, raw: "Synthetic recovered text")
            _ = try reopened.applyFrame(sessionID: sessionID, kit: ProjectKit(name: "Synthetic", prefix: "Frame"))
            try reopened.setStatus(sessionID: sessionID, status: .confirmed)
            try reopened.runRetention(now: saved.createdAt.addingTimeInterval(31 * 86_400))
            let last = HistoryStore(directory: folder).sessions.first { $0.id == sessionID }
            try require(last?.captureWarning == saved.captureWarning && last?.status == .interrupted, "Retry/frame/delivery erased the capture warning")
            try require(last?.rawTranscript == "Synthetic recovered text", "Recovered original text was lost")
            try require(last?.audioURL.map { FileManager.default.fileExists(atPath: $0.path) } == true, "Retention removed unresolved review audio")
            var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as! [String: Any]
            legacy.removeValue(forKey: "captureWarning")
            let decoded = try JSONDecoder().decode(DictationSession.self, from: JSONSerialization.data(withJSONObject: legacy))
            try require(decoded.captureWarning == nil && decoded.id == saved.id, "Legacy history cannot decode without the new optional field")
        }
    }

    private static func restart() throws {
        try fixture { folder in
            let kit = ProjectKit(id: "test", name: "Test", corrections: [TextCorrection(from: "example studio", to: "ExampleStudio")],
                                 prefix: "Exact prefix", suffix: "Keep {{transcript}} literal.")
            var id = UUID()
            do {
                let store = HistoryStore(directory: folder)
                try require(store.isAvailable, store.lastError ?? "SQLite unavailable")
                let session = try store.beginSession(targetBundleID: "test.editor", targetAppName: "Test Editor", kit: kit)
                id = session.id
                try require(store.sessions.first?.status == .recording, "Recording was not journaled before capture")
                try recordFixture(session)
                let saved = try store.updateTranscript(sessionID: id, raw: "example studio makes a film.", durationSeconds: 4)
                try require(saved.rawTranscript == "example studio makes a film.", "Original transcription changed")
                try require(saved.correctedTranscript == "ExampleStudio makes a film.", "Correction missing")
                try require(saved.framedTranscript == nil, "Frame was applied without explicit request")
                try store.setStatus(sessionID: id, status: .pasteAttempted)
            }
            do {
                let store = HistoryStore(directory: folder)
                guard let saved = store.sessions.first else { throw CoreCheckFailure(description: "Reopened history is empty") }
                try require(saved.id == id && saved.status == .pasteAttempted, "Persisted paste status lost")
                try require(saved.targetBundleID == "test.editor" && saved.targetAppName == "Test Editor", "Destination metadata lost")
                try require(saved.durationSeconds == 4, "Recording duration lost")
                let framed = try store.applyFrame(sessionID: id)
                try require(framed.displayTranscript == "Exact prefix\n\nExampleStudio makes a film.\n\nKeep {{transcript}} literal.", "Explicit frame changed literal text")
                try require(framed.rawTranscript == saved.rawTranscript, "Framing changed the original transcription")
            }
            let reopened = HistoryStore(directory: folder)
            try require(reopened.sessions.first?.status == .readyToCopy && reopened.sessions.first?.framedTranscript != nil,
                        "Frame did not survive a second reopen")
        }
    }

    private static func interrupted() throws {
        try fixture { folder in
            let store = HistoryStore(directory: folder)
            let session = try store.beginSession()
            try recordFixture(session)
            try store.refresh()
            try require(store.sessions.first?.status == .recording, "Refresh interrupted the live recording")
            let reopened = HistoryStore(directory: folder)
            try require(reopened.sessions.first?.status == .interrupted, "Startup did not reconcile recording journal")
            try require(reopened.sessions.first?.errorMessage == "Recording was interrupted. Retry the saved audio.", "Recovery action is missing")
            try require(FileManager.default.fileExists(atPath: session.audioPath!), "Partial audio was deleted")
        }
    }

    private static func kitVersions() throws {
        try fixture { folder in
            let store = HistoryStore(directory: folder)
            var kit = ProjectKit(id: "versioned", name: "Versioned", corrections: [TextCorrection(from: "alpha", to: "one")])
            try store.upsertKit(kit)
            let session = try store.beginSession(kit: kit)
            kit.corrections = [TextCorrection(from: "alpha", to: "two")]
            kit.prefix = "Second frame"
            try store.upsertKit(kit)
            guard let edited = store.kits.first(where: { $0.id == kit.id }) else { throw CoreCheckFailure(description: "Edited kit missing") }
            try require(edited.version == 2, "Editing did not increment the kit version")
            let saved = try store.updateTranscript(sessionID: session.id, raw: "alpha")
            try require(saved.correctedTranscript == "one" && saved.projectKitVersion == 1, "Editing a kit changed a captured version")
            let framed = try store.applyFrame(sessionID: session.id, kit: edited)
            try require(framed.displayTranscript == "Second frame\n\ntwo" && framed.projectKitVersion == 2, "Explicit kit choice was not captured")
            try require(framed.rawTranscript == "alpha", "Kit application changed original text")
        }
    }

    private static func correctionBoundaries() throws {
        let kit = ProjectKit(name: "Test", preferredSpellings: ["ExampleStudio"], corrections: [
            TextCorrection(from: "rod", to: "RØDE"), TextCorrection(from: "example studio", to: "ExampleStudio"),
            TextCorrection(from: "alpha", to: "beta"), TextCorrection(from: "beta", to: "gamma")
        ])
        let input = "rod, rods, arod, rod_id; example studio; examplestudio. https://rod.example/rod rod@example.com `rod example studio` ```\nrod\n``` /tmp/rod alpha beta"
        let expected = "RØDE, rods, arod, rod_id; ExampleStudio; ExampleStudio. https://rod.example/rod rod@example.com `rod example studio` ```\nrod\n``` /tmp/rod beta gamma"
        try require(kit.corrected(input) == expected, "Protected text changed, following prose skipped, or correction chained")
    }

    private static func exactFrames() throws {
        let kit = ProjectKit(name: "Test", corrections: [
            TextCorrection(from: "camera", to: "lens"), TextCorrection(from: "camera left", to: "screen right")
        ], prefix: "  Exact prefix\n{{transcript}}", suffix: "\nExact $suffix  ")
        try require(kit.corrected("Camera left, camera.") == "screen right, lens.", "Shorter overlapping phrase won")
        let spoken = "  Keep my\nline breaks.  "
        try require(kit.framed(spoken) == kit.prefix + "\n\n" + spoken + "\n\n" + kit.suffix, "Frame trimmed, evaluated, or normalized literal text")
    }

    private static func retention() throws {
        try fixture { folder in
            let store = HistoryStore(directory: folder)
            let pinned = try store.beginSession()
            let expired = try store.beginSession()
            let failed = try store.beginSession()
            let active = try store.beginSession()
            for session in [pinned, expired, failed, active] { try recordFixture(session) }
            _ = try store.updateTranscript(sessionID: pinned.id, raw: "Pinned text")
            try store.setPinned(sessionID: pinned.id, true)
            _ = try store.updateTranscript(sessionID: expired.id, raw: "Expired text")
            try store.setStatus(sessionID: failed.id, status: .transcriptionFailed, error: "Synthetic engine failure")
            try store.runRetention(now: Date().addingTimeInterval(31 * 86_400))
            try require(store.sessions.first(where: { $0.id == pinned.id })?.rawTranscript == "Pinned text", "Pinned text expired")
            try require(store.sessions.first(where: { $0.id == pinned.id })?.audioPath == nil, "Pinned audio incorrectly retained indefinitely")
            try require(!store.sessions.contains(where: { $0.id == expired.id }), "Unpinned text did not expire")
            try require(store.sessions.first(where: { $0.id == active.id })?.status == .recording, "Active take was evicted")
            try require(FileManager.default.fileExists(atPath: failed.audioPath!) && FileManager.default.fileExists(atPath: active.audioPath!), "Recovery or active audio was evicted")
            try require(store.lastError?.contains("older than seven days were kept") == true, "Overdue recovery retention is not visible")
        }
    }

    private static func audioExpiry() throws {
        try fixture { folder in
            let store = HistoryStore(directory: folder)
            let session = try store.beginSession()
            try recordFixture(session)
            _ = try store.updateTranscript(sessionID: session.id, raw: "Saved before insertion")
            try store.runRetention(now: Date().addingTimeInterval(25 * 3_600))
            try require(store.sessions.first?.rawTranscript == "Saved before insertion", "Audio expiry removed transcript")
            try require(store.sessions.first?.audioPath == nil && !FileManager.default.fileExists(atPath: session.audioPath!), "Successful audio did not expire")
        }
    }

    private static func cacheCap() throws {
        try fixture { folder in
            let store = HistoryStore(directory: folder)
            let failed = try store.beginSession()
            _ = FileManager.default.createFile(atPath: failed.audioPath!, contents: Data())
            let handle = try FileHandle(forWritingTo: failed.audioURL!)
            try handle.truncate(atOffset: 1_073_741_825) // Sparse fixture; does not write 1 GB of audio.
            try handle.close()
            try store.setStatus(sessionID: failed.id, status: .interrupted)
            try store.runRetention()
            try require(FileManager.default.fileExists(atPath: failed.audioPath!), "Cache cap removed unresolved audio")
            try require(store.lastError?.contains("exceeds 1 GB") == true, "Protected cache overflow was not surfaced")
        }
    }

    private static func storageFailures() throws {
        try fixture { folder in
            let blocked = folder.appendingPathComponent("blocked")
            try Data("synthetic file in place of directory".utf8).write(to: blocked)
            let broken = HistoryStore(directory: blocked)
            try require(!broken.isAvailable && broken.lastError != nil, "Initialization failure appeared as empty usable history")
            do {
                _ = try broken.beginSession()
                throw CoreCheckFailure(description: "Unavailable storage accepted a recording")
            } catch is HistoryStoreError { }

            let store = HistoryStore(directory: folder.appendingPathComponent("writes"))
            let session = try store.beginSession()
            try recordFixture(session)
            var database: OpaquePointer?
            guard sqlite3_open(store.storageDirectory.appendingPathComponent("history.sqlite3").path, &database) == SQLITE_OK else {
                throw CoreCheckFailure(description: "Could not create storage-failure fixture")
            }
            defer { sqlite3_close(database) }
            // A synthetic SQLite rejection exercises failure handling without
            // filling the user's disk or changing permissions on real data.
            let trigger = """
                CREATE TRIGGER reject_transcript BEFORE UPDATE ON sessions
                WHEN json_extract(NEW.payload, '$.rawTranscript') IS NOT NULL
                BEGIN SELECT RAISE(ABORT, 'Synthetic original transcript write failure'); END;
                CREATE TRIGGER reject_recovery BEFORE UPDATE ON sessions
                WHEN json_extract(NEW.payload, '$.status') = 'interrupted'
                BEGIN SELECT RAISE(ABORT, 'Synthetic secondary recovery write failure'); END;
                """
            guard sqlite3_exec(database, trigger, nil, nil, nil) == SQLITE_OK else { throw CoreCheckFailure(description: "Could not install write-rejection fixture") }
            do {
                _ = try store.updateTranscript(sessionID: session.id, raw: "Must not be considered saved")
                throw CoreCheckFailure(description: "Rejected transcript write appeared successful")
            } catch is HistoryStoreError { }
            try require(store.lastError?.contains("Synthetic original transcript write failure") == true,
                        "The secondary status failure hid the original transcript write error")
            try require(store.lastError?.contains("Synthetic secondary") == false, "Secondary recovery error replaced the original save error")
            try require(store.sessions.first?.status == .recording && store.sessions.first?.rawTranscript == nil, "Failed write discarded or falsely updated journal")
            guard sqlite3_exec(database, "DROP TRIGGER reject_recovery", nil, nil, nil) == SQLITE_OK else { throw CoreCheckFailure(description: "Could not remove secondary failure fixture") }
            do {
                _ = try store.updateTranscript(sessionID: session.id, raw: "Still retained by the caller", durationSeconds: 5)
                throw CoreCheckFailure(description: "Rejected transcript write appeared successful")
            } catch is HistoryStoreError { }
            try require(store.sessions.first?.status == .interrupted, "Successful secondary status write did not enable same-launch recovery")
            try require(store.sessions.first?.rawTranscript == nil && store.sessions.first?.durationSeconds == 5,
                        "Recovery falsely stored rejected text or lost recording duration")
            try require(store.sessions.first?.errorMessage?.contains("saving its text failed") == true,
                        "Same-launch recovery does not explain the transcript save failure")
            try require(store.lastError?.contains("Synthetic original transcript write failure") == true,
                        "Successful recovery status write masked the original save error")
            try require(FileManager.default.fileExists(atPath: session.audioPath!), "Recovery status write removed the saved audio")
            guard sqlite3_exec(database, "DROP TRIGGER reject_transcript", nil, nil, nil) == SQLITE_OK else { throw CoreCheckFailure(description: "Could not remove transcript failure fixture") }
            let reopened = HistoryStore(directory: store.storageDirectory)
            try require(reopened.isAvailable && reopened.sessions.first?.status == .interrupted, "Failed-write journal was not recoverable on restart")
        }
    }
}
