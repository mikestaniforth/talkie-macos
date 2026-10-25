import AVFoundation
import Foundation

/// Detects an input that is replaying exactly the same non-flat PCM, as observed
/// through two native capture APIs with the USB microphone. This is not voice
/// activity detection: normal quiet input, pauses and repeated spoken words
/// have different sample bits and do not match this check. Matching includes
/// quiet/DC blocks; audibility and complexity qualify the complete matched
/// window, so a quiet block in each frozen cycle cannot hide the repetition.
/// An entirely quiet floor or a pure tone is excluded. A positive result is an
/// integrity warning, never a stop rule or proof that speech is missing.
struct RepeatedAudioCheck {
    private struct Block {
        let hash: UInt64
        let samples: [UInt32]
        let finite: Bool
        /// Per-channel AC power only where that channel contains complex PCM.
        let complexPower: [Double]
    }

    private struct MatchRun {
        var count: Int
        var complexPower: [Double]
    }

    private let blockSampleCount: Int
    private let channelCount: Int
    private let requiredMatches = 100 // One second of exact repeated PCM.
    private let maximumLag = 100 // Search periods between 50 ms and one second.
    private let minimumAudiblePower = pow(10, AudioSignalCheck.minimumRMSDecibels / 10)
    private var pending: [UInt32] = []
    private var history: [Block] = []
    private var consecutiveMatches: [Int: MatchRun] = [:]
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
        var finite = true
        var sums = [Double](repeating: 0, count: channelCount)
        var squares = [Double](repeating: 0, count: channelCount)
        for (index, bits) in pending.enumerated() {
            hash = (hash ^ UInt64(bits)) &* 1_099_511_628_211
            let sample = Float(bitPattern: bits)
            finite = finite && sample.isFinite
            let channel = index % channelCount
            sums[channel] += Double(sample)
            squares[channel] += Double(sample) * Double(sample)
        }
        // Qualification is independent of exact matching. Each quiet or DC
        // block still extends a finite matched run; its complex AC power is
        // simply zero. Keep channel evidence separate so a loud tone on one
        // channel cannot make an inaudible noise floor on another qualify.
        let frames = Double(pending.count / channelCount)
        var complexPower = [Double](repeating: 0, count: channelCount)
        if finite {
            let complexChannels = complexSignalChannels()
            for channel in 0..<channelCount where complexChannels[channel] {
                let mean = sums[channel] / frames
                complexPower[channel] = max(0, squares[channel] / frames - mean * mean)
            }
        }
        let block = Block(hash: hash, samples: pending, finite: finite, complexPower: complexPower)
        var nextMatches: [Int: MatchRun] = [:]
        if block.finite, history.count >= 5 {
            for lag in 5...min(maximumLag, history.count) {
                let previous = history[history.count - lag]
                // The hash is only a fast prefilter. Confirm every sample bit
                // before treating a block as identical.
                if previous.finite, previous.hash == block.hash, previous.samples == block.samples {
                    var run = consecutiveMatches[lag]
                        ?? MatchRun(count: 0, complexPower: [Double](repeating: 0, count: channelCount))
                    if run.count == requiredMatches {
                        let expired = history[history.count - requiredMatches]
                        for channel in 0..<channelCount {
                            run.complexPower[channel] -= expired.complexPower[channel]
                        }
                    } else { run.count += 1 }
                    for channel in 0..<channelCount { run.complexPower[channel] += block.complexPower[channel] }
                    nextMatches[lag] = run
                    if run.count == requiredMatches,
                       run.complexPower.contains(where: { $0 / Double(requiredMatches) >= minimumAudiblePower }) {
                        isRepeating = true
                    }
                }
            }
        }
        consecutiveMatches = nextMatches
        history.append(block)
        if history.count > max(maximumLag, requiredMatches) { history.removeFirst() }
    }

    /// Exclude near-perfect single tones as well as flat input. A sampled sine
    /// follows a second-order recurrence, even with a DC offset after taking
    /// first differences. Allow for Float sample rounding, which otherwise
    /// dominates those differences for low tones or a large DC offset.
    /// Natural microphone noise/speech does not follow this recurrence.
    private func complexSignalChannels() -> [Bool] {
        let frames = pending.count / channelCount
        var result = [Bool](repeating: false, count: channelCount)
        guard frames > 4 else { return result }
        for channel in 0..<channelCount {
            var differences = [Double]()
            differences.reserveCapacity(frames - 1)
            var roundingBounds = [Double]()
            roundingBounds.reserveCapacity(frames)
            let first = Float(bitPattern: pending[channel])
            roundingBounds.append(Double(first.ulp) * 0.5)
            var previous = Double(first)
            for frame in 1..<frames {
                let sample = Float(bitPattern: pending[frame * channelCount + channel])
                let current = Double(sample)
                roundingBounds.append(Double(sample.ulp) * 0.5)
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
            // A real sinusoid has coefficient 2*cos(frequency), so clamping
            // also bounds each sample's contribution to rounding error.
            let coefficient = max(-2, min(2, crossProduct / featureEnergy))
            var residualEnergy = 0.0
            var roundingEnergy = 0.0
            for index in 2..<differences.count {
                let residual = differences[index] + differences[index - 2] - coefficient * differences[index - 1]
                residualEnergy += residual * residual
                // Expanded into four original samples, the recurrence has
                // weights 1, -(1+c), 1+c, -1. With |c| <= 2, their absolute
                // rounding errors are bounded by weights 1, 3, 3, 1.
                let bound = roundingBounds[index + 1] + 3 * roundingBounds[index]
                    + 3 * roundingBounds[index - 1] + roundingBounds[index - 2]
                roundingEnergy += bound * bound
            }
            result[channel] = residualEnergy > max(differenceEnergy * 0.000_000_01, roundingEnergy)
        }
        return result
    }
}
