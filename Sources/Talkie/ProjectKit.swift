import Foundation

struct TextCorrection: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var from: String
    var to: String

    init(id: UUID = UUID(), from: String, to: String) {
        self.id = id
        self.from = from
        self.to = to
    }
}

struct ProjectKit: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var version: Int
    var preferredSpellings: [String]
    var corrections: [TextCorrection]
    var prefix: String
    var suffix: String

    init(id: String = UUID().uuidString, name: String, version: Int = 1,
         preferredSpellings: [String] = [], corrections: [TextCorrection] = [],
         prefix: String = "", suffix: String = "") {
        self.id = id
        self.name = name
        self.version = version
        self.preferredSpellings = preferredSpellings
        self.corrections = corrections
        self.prefix = prefix
        self.suffix = suffix
    }

    /// Explicit phrase substitutions, never fuzzy corrections or chained rewrites.
    /// URLs, email addresses, paths, and fenced/inline code are left untouched.
    func corrected(_ transcript: String) -> String {
        let original = transcript as NSString
        let protected = Self.protectedRanges(in: transcript)
        let explicit = corrections.filter { !$0.from.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let canonical = preferredSpellings.filter { !$0.isEmpty }.map { TextCorrection(from: $0, to: $0) }
        let rules = (explicit + canonical).enumerated().sorted {
            if $0.element.from.count == $1.element.from.count { return $0.offset < $1.offset }
            return $0.element.from.count > $1.element.from.count
        }
        var edits: [(range: NSRange, replacement: String)] = []
        for rule in rules {
            let escaped = NSRegularExpression.escapedPattern(for: rule.element.from)
            let pattern = "(?<![\\p{L}\\p{N}_])" + escaped + "(?![\\p{L}\\p{N}_])"
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            for match in expression.matches(in: transcript, range: NSRange(location: 0, length: original.length)) {
                guard !protected.contains(where: { NSIntersectionRange($0, match.range).length > 0 }),
                      !edits.contains(where: { NSIntersectionRange($0.range, match.range).length > 0 }) else { continue }
                edits.append((match.range, rule.element.to))
            }
        }
        let result = NSMutableString(string: transcript)
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
            result.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        return result as String
    }

    /// Framing is an explicit action. Text is concatenated literally; no template
    /// expressions, placeholders, or substitutions are evaluated in these parts.
    func framed(_ transcript: String) -> String {
        [prefix, transcript, suffix].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private static func protectedRanges(in text: String) -> [NSRange] {
        let patterns = [
            #"(?s)```.*?(?:```|$)|~~~.*?(?:~~~|$)"#,
            #"`[^`\n]*(?:`|$)"#,
            #"(?i)\b(?:[a-z][a-z0-9+.-]*://|www\.)[^\s<>]+"#,
            #"(?i)[a-z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-z0-9-]+(?:\.[a-z0-9-]+)+"#,
            #"(?i)\b(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,63}(?::\d+)?(?:/[^\s<>]*)?"#,
            #"(?<![\p{L}\p{N}_])(?:~/|\./|\.\./|/)[^\s<>]+"#,
            #"\b[\p{L}\p{N}]+_[\p{L}\p{N}_]+\b"#
        ]
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var protected: [NSRange] = []
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let matches = expression.matches(in: text, range: range).map(\.range)
            // A backtick inside a fenced block cannot begin a new inline block
            // that accidentally protects the prose following the closing fence.
            for match in matches where !protected.contains(where: { NSLocationInRange(match.location, $0) }) {
                protected.append(match)
            }
        }
        return protected
    }

    static let defaults: [ProjectKit] = [
        ProjectKit(id: "everyday", name: "Everyday"),
        ProjectKit(id: "meeting-notes", name: "Meeting notes",
                   prefix: "Meeting notes",
                   suffix: "Next steps:"),
        ProjectKit(id: "studio", name: "Studio",
                   preferredSpellings: ["ExampleStudio", "storyboard", "voiceover"],
                   corrections: [TextCorrection(from: "example studio", to: "ExampleStudio"),
                                 TextCorrection(from: "story board", to: "storyboard")])
    ]
}

enum DictationStatus: String, Codable, CaseIterable, Sendable {
    case recording, saved, pasteAttempted, confirmed, readyToCopy
    case transcriptionFailed, notSaved, interrupted

    var needsRecovery: Bool {
        self == .transcriptionFailed || self == .notSaved || self == .interrupted
    }

    var label: String {
        switch self {
        case .recording: return "Recording"
        case .saved: return "Saved"
        case .pasteAttempted: return "Paste attempted"
        case .confirmed: return "Inserted"
        case .readyToCopy: return "Ready to copy"
        case .transcriptionFailed: return "Transcription failed"
        case .notSaved: return "Not saved"
        case .interrupted: return "Interrupted"
        }
    }
}

struct DictationSession: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var rawTranscript: String?
    var correctedTranscript: String?
    var framedTranscript: String?
    var targetBundleID: String?
    var targetAppName: String?
    var projectKitID: String?
    var projectKitVersion: Int?
    var kitSnapshot: ProjectKit?
    var status: DictationStatus
    var errorMessage: String?
    var audioPath: String?
    var durationSeconds: Double?
    var isPinned: Bool

    var audioURL: URL? { audioPath.map { URL(fileURLWithPath: $0) } }
    var displayTranscript: String { framedTranscript ?? correctedTranscript ?? rawTranscript ?? "" }
}
