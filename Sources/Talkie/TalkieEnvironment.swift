import Foundation

/// The public preview deliberately has a different identity from personal
/// builds. Keep bundled and SwiftPM command-line runs in the same preview
/// preference domain, without importing another app's settings or recordings.
enum TalkieEnvironment {
    static let bundleIdentifier = "local.talkie.preview"
    static let displayName = "Talkie Preview"
    static let defaults = UserDefaults(suiteName: bundleIdentifier)!

    static var applicationSupportDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent(displayName, isDirectory: true)
    }
}
