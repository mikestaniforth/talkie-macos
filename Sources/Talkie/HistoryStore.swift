import Foundation
import Combine
import CSQLite

enum HistoryStoreError: LocalizedError {
    case unavailable(String)
    case database(String)
    case missingSession
    case missingKit

    var errorDescription: String? {
        switch self {
        case .unavailable(let detail): return "Talkie could not open its local history. \(detail)"
        case .database(let detail): return "Talkie could not save or read local history. \(detail)"
        case .missingSession: return "This dictation is no longer in local history."
        case .missingKit: return "Choose a Project Kit before applying a frame."
        }
    }
}

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var sessions: [DictationSession] = []
    @Published private(set) var kits: [ProjectKit] = []
    @Published private(set) var lastError: String?
    @Published private(set) var isAvailable = false

    let storageDirectory: URL
    let recordingsDirectory: URL
    private var database: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let fileManager = FileManager.default

    init(directory: URL? = nil) {
        storageDirectory = directory ?? TalkieEnvironment.applicationSupportDirectory
        recordingsDirectory = storageDirectory.appendingPathComponent("Recordings", isDirectory: true)
        do {
            try fileManager.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
            let url = storageDirectory.appendingPathComponent("history.sqlite3")
            let result = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
            guard result == SQLITE_OK else { throw sqliteError() }
            sqlite3_busy_timeout(database, 5_000)
            try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON;")
            try execute("CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, payload TEXT NOT NULL, created_at REAL NOT NULL);")
            try execute("CREATE TABLE IF NOT EXISTS kits (id TEXT PRIMARY KEY, payload TEXT NOT NULL);")
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let existing = try readKits()
            for kit in ProjectKit.defaults where !existing.contains(where: { $0.id == kit.id }) {
                try persistKit(kit)
            }
            try loadState()
            // Only reconcile once at launch. Refreshing during a live capture must
            // not mark the current recording as interrupted.
            for var session in sessions where session.status == .recording {
                session.status = .interrupted
                session.updatedAt = Date()
                let hasAudio = session.audioPath.map { fileManager.fileExists(atPath: $0) } ?? false
                session.errorMessage = hasAudio
                    ? "Recording was interrupted. Retry the saved audio."
                    : "Recording was interrupted before audio was saved."
                try persistSession(session)
            }
            try loadState()
            isAvailable = true
        } catch {
            lastError = error.localizedDescription
            isAvailable = false
        }
        if isAvailable {
            do { try runRetention() } catch { lastError = error.localizedDescription }
        }
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    @discardableResult
    func beginSession(targetBundleID: String? = nil, targetAppName: String? = nil,
                      kit: ProjectKit? = nil) throws -> DictationSession {
        try reportingErrors {
            try requireAvailable()
            let id = UUID()
            let now = Date()
            let session = DictationSession(id: id, createdAt: now, updatedAt: now,
                rawTranscript: nil, correctedTranscript: nil, framedTranscript: nil,
                targetBundleID: targetBundleID, targetAppName: targetAppName,
                projectKitID: kit?.id, projectKitVersion: kit?.version, kitSnapshot: kit,
                status: .recording, errorMessage: nil,
                audioPath: recordingsDirectory.appendingPathComponent(id.uuidString + ".caf").path,
                durationSeconds: nil, isPinned: false)
            try persistSession(session)
            try loadState()
            return session
        }
    }

    @discardableResult
    func updateTranscript(sessionID: UUID, raw: String, durationSeconds: Double? = nil) throws -> DictationSession {
        try reportingErrors {
            var session = try sessionForUpdate(sessionID)
            let journal = session
            session.rawTranscript = raw
            session.correctedTranscript = session.kitSnapshot?.corrected(raw) ?? raw
            session.framedTranscript = nil
            session.durationSeconds = durationSeconds ?? session.durationSeconds
            session.status = .saved
            session.errorMessage = nil
            session.updatedAt = Date()
            do { try persistSession(session) }
            catch {
                let saveError = error
                var recovery = journal
                recovery.status = .interrupted
                recovery.durationSeconds = durationSeconds ?? journal.durationSeconds
                recovery.updatedAt = Date()
                recovery.errorMessage = "Transcription completed, but saving its text failed. Retry the saved audio. \(saveError.localizedDescription)"
                // A smaller status write can still succeed after the transcript
                // write failed. Retain the prior transcript versions and journal
                // either way; a second failure must not hide the original one.
                do {
                    try persistSession(recovery)
                    try loadState()
                } catch { }
                throw saveError
            }
            try loadState()
            return session
        }
    }

    @discardableResult
    func applyFrame(sessionID: UUID, kit: ProjectKit? = nil) throws -> DictationSession {
        try reportingErrors {
            var session = try sessionForUpdate(sessionID)
            guard let chosen = kit ?? session.kitSnapshot else { throw HistoryStoreError.missingKit }
            let raw = session.rawTranscript ?? ""
            let corrected = chosen.corrected(raw)
            session.correctedTranscript = corrected
            session.framedTranscript = chosen.framed(corrected)
            session.kitSnapshot = chosen
            session.projectKitID = chosen.id
            session.projectKitVersion = chosen.version
            session.status = .readyToCopy
            session.errorMessage = nil
            session.updatedAt = Date()
            try persistSession(session)
            try loadState()
            return session
        }
    }

    func setStatus(sessionID: UUID, status: DictationStatus, error: String? = nil) throws {
        try reportingErrors {
            var session = try sessionForUpdate(sessionID)
            session.status = status
            session.errorMessage = error
            session.updatedAt = Date()
            try persistSession(session)
            try loadState()
        }
    }

    func setPinned(sessionID: UUID, _ pinned: Bool) throws {
        try reportingErrors {
            var session = try sessionForUpdate(sessionID)
            session.isPinned = pinned
            session.updatedAt = Date()
            try persistSession(session)
            try loadState()
        }
    }

    func deleteSession(_ id: UUID) throws {
        try reportingErrors {
            let session = try sessionForUpdate(id)
            guard session.status != .recording else {
                throw HistoryStoreError.database("Stop recording before deleting this take.")
            }
            // Remove audio before the journal, leaving the recovery visible if
            // filesystem removal fails rather than leaving an untracked recording.
            try removeManagedAudio(session)
            try run("DELETE FROM sessions WHERE id = ?", strings: [id.uuidString])
            try loadState()
        }
    }

    func upsertKit(_ kit: ProjectKit) throws {
        try reportingErrors {
            try requireAvailable()
            var updated = kit
            if let previous = kits.first(where: { $0.id == kit.id }), previous != kit {
                updated.version = max(kit.version, previous.version + 1)
            }
            updated.version = max(1, updated.version)
            try persistKit(updated)
            try loadState()
        }
    }

    func refresh() throws {
        try reportingErrors {
            try requireAvailable()
            try loadState()
        }
    }

    /// Transcript retention is 30 days (pinned text is indefinite). Successful
    /// audio expires after 24 hours. Unresolved failed/interrupted takes are kept
    /// past seven days and surfaced for review, never silently evicted for space.
    func runRetention(now: Date = Date()) throws {
        try reportingErrors {
            try requireAvailable()
            let day: TimeInterval = 86_400
            var warnings: [String] = []
            var remaining = sessions
            for var session in sessions where session.status != .recording {
                let age = now.timeIntervalSince(session.createdAt)
                if !session.isPinned && !session.status.needsRecovery && age > 30 * day {
                    try removeManagedAudio(session)
                    try run("DELETE FROM sessions WHERE id = ?", strings: [session.id.uuidString])
                    remaining.removeAll { $0.id == session.id }
                    continue
                }
                if session.status.needsRecovery {
                    if age > 7 * day, let path = session.audioPath, fileManager.fileExists(atPath: path) {
                        warnings.append("Unresolved recordings older than seven days were kept. Review Needs attention before deleting them.")
                    }
                } else if age > day, session.audioPath != nil {
                    try removeManagedAudio(session)
                    session.audioPath = nil
                    try persistSession(session)
                    if let index = remaining.firstIndex(where: { $0.id == session.id }) { remaining[index] = session }
                }
            }

            let cap: Int64 = 1_073_741_824
            var total = remaining.reduce(Int64(0)) { $0 + audioSize($1) }
            if total > cap {
                // Reclaim successfully transcribed audio oldest first. A text
                // transcript remains; active and unresolved audio is protected.
                let candidates = remaining.filter { !$0.status.needsRecovery && $0.status != .recording }
                    .sorted { $0.createdAt < $1.createdAt }
                for var session in candidates where total > cap {
                    let size = audioSize(session)
                    try removeManagedAudio(session)
                    session.audioPath = nil
                    try persistSession(session)
                    total -= size
                }
                if total > cap {
                    warnings.append("The recording cache exceeds 1 GB. Active or unresolved audio was kept; review Needs attention to free space.")
                }
            }
            try loadState()
            lastError = warnings.isEmpty ? nil : Array(Set(warnings)).sorted().joined(separator: " ")
        }
    }

    private func requireAvailable() throws {
        guard isAvailable, database != nil else {
            throw HistoryStoreError.unavailable(lastError ?? "The database is unavailable.")
        }
    }

    private func sessionForUpdate(_ id: UUID) throws -> DictationSession {
        try requireAvailable()
        guard let session = sessions.first(where: { $0.id == id }) else { throw HistoryStoreError.missingSession }
        return session
    }

    private func reportingErrors<T>(_ action: () throws -> T) throws -> T {
        do { return try action() }
        catch { lastError = error.localizedDescription; throw error }
    }

    private func sqliteError() -> HistoryStoreError {
        .database(database.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite could not open the database.")
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw sqliteError() }
    }

    private func run(_ sql: String, strings: [String]) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw sqliteError() }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in strings.enumerated() {
            guard sqlite3_bind_text(statement, Int32(offset + 1), value, -1, transient) == SQLITE_OK else { throw sqliteError() }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError() }
    }

    private func persistSession(_ session: DictationSession) throws {
        let data = try encoder.encode(session)
        guard let payload = String(data: data, encoding: .utf8) else { throw HistoryStoreError.database("Invalid transcript encoding.") }
        // Each committed SQLite statement is durable before this method returns.
        try run("INSERT INTO sessions(id, payload, created_at) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload, created_at=excluded.created_at",
                strings: [session.id.uuidString, payload, String(session.createdAt.timeIntervalSince1970)])
    }

    private func persistKit(_ kit: ProjectKit) throws {
        let payload = String(decoding: try encoder.encode(kit), as: UTF8.self)
        try run("INSERT INTO kits(id, payload) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload", strings: [kit.id, payload])
    }

    private func payloads(table: String) throws -> [Data] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT payload FROM \(table)", -1, &statement, nil) == SQLITE_OK else { throw sqliteError() }
        defer { sqlite3_finalize(statement) }
        var rows: [Data] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { throw sqliteError() }
            rows.append(Data(String(cString: value).utf8))
        }
        return rows
    }

    private func readKits() throws -> [ProjectKit] {
        try payloads(table: "kits").map { try decoder.decode(ProjectKit.self, from: $0) }
    }

    private func loadState() throws {
        // Decode everything first. A bad row is surfaced, not silently omitted or
        // replaced with a misleading empty-history view.
        let loadedSessions = try payloads(table: "sessions").map { try decoder.decode(DictationSession.self, from: $0) }
        let loadedKits = try readKits()
        sessions = loadedSessions.sorted { $0.createdAt > $1.createdAt }
        kits = loadedKits.sorted {
            let order = ["everyday", "meeting-notes", "studio"]
            let left = order.firstIndex(of: $0.id) ?? Int.max
            let right = order.firstIndex(of: $1.id) ?? Int.max
            return left == right ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending : left < right
        }
    }

    private func removeManagedAudio(_ session: DictationSession) throws {
        guard let url = session.audioURL else { return }
        let parent = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        guard parent == recordingsDirectory.standardizedFileURL.resolvingSymlinksInPath() else {
            throw HistoryStoreError.database("Refused to remove a recording outside Talkie’s recording folder.")
        }
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
    }

    private func audioSize(_ session: DictationSession) -> Int64 {
        guard let path = session.audioPath,
              let attrs = try? fileManager.attributesOfItem(atPath: path),
              let size = attrs[.size] as? NSNumber else { return 0 }
        return size.int64Value
    }
}
