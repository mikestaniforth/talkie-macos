// Appended to the production AudioCapture.swift by test-capture.sh. This keeps
// RecordingWriter private in the app while testing the exact implementation.
private final class WriterFailures: @unchecked Sendable {
    let lock = NSLock()
    var count = 0
    func record(_ message: String?) {
        guard message != nil else { return }
        lock.lock(); count += 1; lock.unlock()
    }
}

@main
struct WriterHarness {
    static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("talkie-writer-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for interleaved in [false, true] {
            for channels in [1, 2] {
                let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: AVAudioChannelCount(channels), interleaved: interleaved)!
                let url = folder.appendingPathComponent("snapshot-\(interleaved)-\(channels).caf")
                let writer = try RecordingWriter(url: url, format: format)
                let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
                source.frameLength = 4_800
                let failures = WriterFailures()
                for block in 0..<24 {
                    for frame in 0..<4_800 {
                        for channel in 0..<channels {
                            let value = Float((block * 4_800 + frame + channel * 31) % 100_000) / 100_000
                            if interleaved { source.floatChannelData![0][frame * channels + channel] = value }
                            else { source.floatChannelData![channel][frame] = value }
                        }
                    }
                    writer.enqueue(source) { _, error in failures.record(error) }
                    // AVAudioEngine may reuse tap memory immediately on return.
                    for buffer in UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList) {
                        memset(buffer.mData!, 0, Int(buffer.mDataByteSize))
                    }
                }
                precondition(writer.close() == nil && failures.count == 0, "Writer unexpectedly failed")
                let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
                let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_800)!
                var read = 0
                while file.framePosition < file.length {
                    try file.read(into: buffer)
                    guard buffer.frameLength > 0 else { break }
                    for frame in 0..<Int(buffer.frameLength) {
                        for channel in 0..<channels {
                            let expected = Float((read + frame + channel * 31) % 100_000) / 100_000
                            precondition(buffer.floatChannelData![channel][frame].bitPattern == expected.bitPattern, "Tap snapshot was corrupted")
                        }
                    }
                    read += Int(buffer.frameLength)
                }
                precondition(read == 115_200, "Writer lost the recording tail")
                print("PASS exact writer snapshot reuse and tail drain: \(channels)ch interleaved=\(interleaved)")
            }
        }

        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let url = folder.appendingPathComponent("stale-input.caf")
        let writer = try RecordingWriter(url: url, format: format)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
        buffer.frameLength = 4_800
        var seed: UInt64 = 45
        let cycle = (0..<12_000).map { _ -> Float in
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            return Float(Int32(truncatingIfNeeded: seed >> 32)) / Float(Int32.max) * 0.02
        }
        let failures = WriterFailures()
        for block in 0..<24 {
            for frame in 0..<4_800 { buffer.floatChannelData![0][frame] = cycle[(block * 4_800 + frame) % cycle.count] }
            writer.enqueue(buffer) { _, error in failures.record(error) }
        }
        precondition(writer.close() != nil, "Stale input was treated as a complete recording")
        precondition(failures.count == 1, "Stale-input failure must be reported once")
        let saved = try AVAudioFile(forReading: url)
        precondition(saved.length > 0, "Stale-input recovery audio was discarded")
        print("PASS exact writer stops stale input once and preserves partial audio")
    }
}
