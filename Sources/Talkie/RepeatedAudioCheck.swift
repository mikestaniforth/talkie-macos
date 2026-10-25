import AVFoundation
import Foundation

/// Detects an input that is replaying exactly the same non-flat PCM, as observed
/// through two native capture APIs with the USB microphone. This is not voice
/// activity detection: normal quiet input, pauses and repeated spoken words
/// have different sample bits and do not match this check.
struct RepeatedAudioCheck {
    private struct Block {
        let hash: UInt64
        let samples: [UInt32]
        let nonFlat: Bool
    }

    private let blockSampleCount: Int
    private let channelCount: Int
    private let requiredMatches = 100 // One second of exact repeated PCM.
    private let maximumLag = 100 // Search periods between 50 ms and one second.
    private var pending: [UInt32] = []
    private var history: [Block] = []
    private var consecutiveMatches: [Int: Int] = [:]
    private(set) var isRepeating = false

    init(sampleRate: Double, channelCount: Int = 1) {
        self.channelCount = max(1, channelCount)
        blockSampleCount = max(1, Int((sampleRate * 0.01).rounded())) * self.channelCount
        pending.reserveCapacity(blockSampleCount)
    }

    /// Inspect the saved capture at its native rate before resampling. This
    /// also protects History retries of captures made before the live guard.
    static func fileContainsRepeatedAudio(_ url: URL) throws -> Bool {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let channels = Int(file.processingFormat.channelCount)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_800) else { return false }
        var check = RepeatedAudioCheck(sampleRate: file.processingFormat.sampleRate, channelCount: channels)
        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer)
            guard buffer.frameLength > 0, let data = buffer.floatChannelData else { break }
            if channels == 1 {
                if check.append(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength))) { return true }
            } else {
                var interleaved = [Float]()
                interleaved.reserveCapacity(Int(buffer.frameLength) * channels)
                for frame in 0..<Int(buffer.frameLength) {
                    for channel in 0..<channels { interleaved.append(data[channel][frame]) }
                }
                if interleaved.withUnsafeBufferPointer({ check.append($0) }) { return true }
            }
        }
        return false
    }

    /// Supply interleaved samples in capture order. Calls must be serialised.
    /// Partial blocks carry across callbacks, so callback sizes do not matter.
    mutating func append(_ samples: UnsafeBufferPointer<Float>) -> Bool {
        guard !isRepeating else { return true }
        for sample in samples {
            pending.append(sample.bitPattern)
            if pending.count == blockSampleCount {
                consumeBlock()
                pending.removeAll(keepingCapacity: true)
                if isRepeating { return true }
            }
        }
        return false
    }

    private mutating func consumeBlock() {
        var hash: UInt64 = 14_695_981_039_346_656_037
        var minimum = [Float](repeating: .greatestFiniteMagnitude, count: channelCount)
        var maximum = [Float](repeating: -.greatestFiniteMagnitude, count: channelCount)
        var finite = true
        for (index, bits) in pending.enumerated() {
            hash = (hash ^ UInt64(bits)) &* 1_099_511_628_211
            let sample = Float(bitPattern: bits)
            finite = finite && sample.isFinite
            let channel = index % channelCount
            minimum[channel] = min(minimum[channel], sample)
            maximum[channel] = max(maximum[channel], sample)
        }
        // Ignore digital silence and DC. Even very faint live noise changes
        // bit-for-bit; the guard is independent of the audibility threshold.
        let nonFlat = zip(minimum, maximum).contains { $0.1 - $0.0 > 0.000_02 }
        let block = Block(hash: hash, samples: pending, nonFlat: finite && nonFlat && hasComplexSignal())
        var nextMatches: [Int: Int] = [:]
        if block.nonFlat, history.count >= 5 {
            for lag in 5...min(maximumLag, history.count) {
                let previous = history[history.count - lag]
                // The hash is only a fast prefilter. Confirm every sample bit
                // before treating a block as identical.
                if previous.nonFlat, previous.hash == block.hash, previous.samples == block.samples {
                    let matches = (consecutiveMatches[lag] ?? 0) + 1
                    nextMatches[lag] = matches
                    if matches >= requiredMatches { isRepeating = true }
                }
            }
        }
        consecutiveMatches = nextMatches
        history.append(block)
        if history.count > maximumLag { history.removeFirst() }
    }

    /// Exclude near-perfect single tones as well as flat input. A sampled sine
    /// follows a second-order recurrence, even with a DC offset after taking
    /// first differences. Natural microphone noise/speech does not follow it
    /// to this precision. This intentionally makes the guard conservative.
    private func hasComplexSignal() -> Bool {
        let frames = pending.count / channelCount
        guard frames > 4 else { return false }
        for channel in 0..<channelCount {
            var differences = [Double]()
            differences.reserveCapacity(frames - 1)
            var previous = Double(Float(bitPattern: pending[channel]))
            for frame in 1..<frames {
                let current = Double(Float(bitPattern: pending[frame * channelCount + channel]))
                differences.append(current - previous)
                previous = current
            }
            var featureEnergy = 0.0
            var crossProduct = 0.0
            var differenceEnergy = 0.0
            for index in 2..<differences.count {
                let feature = differences[index - 1]
                featureEnergy += feature * feature
                crossProduct += (differences[index] + differences[index - 2]) * feature
                differenceEnergy += differences[index] * differences[index]
            }
            guard featureEnergy > 0, differenceEnergy > 0 else { continue }
            let coefficient = crossProduct / featureEnergy
            var residualEnergy = 0.0
            for index in 2..<differences.count {
                let residual = differences[index] + differences[index - 2] - coefficient * differences[index - 1]
                residualEnergy += residual * residual
            }
            if residualEnergy / differenceEnergy > 0.000_000_01 { return true }
        }
        return false
    }
}
