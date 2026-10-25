import Foundation

/// An audibility floor, not a speech/noise classifier. In particular, loud
/// background noise can pass. The check prevents recognition from inventing
/// words when a recording contains only an extremely weak signal or a click.
enum AudioSignalCheck {
    enum Result: Equatable {
        case invalid
        case digitalSilence
        case tooQuiet
        case usable
    }

    static let minimumRMSDecibels = -65.0
    private static let frameSeconds = 0.02
    private static let requiredActiveFrames = 5

    static func assess(_ samples: [Float], sampleRate: Double = 16_000) -> Result {
        guard sampleRate.isFinite, sampleRate > 0 else { return .invalid }
        guard !samples.isEmpty else { return .digitalSilence }
        var sum = 0.0
        var squares = 0.0
        var minimum = Float.greatestFiniteMagnitude
        var maximum = -Float.greatestFiniteMagnitude
        for sample in samples {
            guard sample.isFinite else { return .invalid }
            let value = Double(sample)
            sum += value
            squares += value * value
            minimum = min(minimum, sample)
            maximum = max(maximum, sample)
        }
        let count = Double(samples.count)
        let mean = sum / count
        let acRMS = sqrt(max(0, squares / count - mean * mean))
        guard maximum - minimum > 0.000_02, acRMS > 0.000_001 else { return .digitalSilence }

        let frameSize = max(1, Int((sampleRate * frameSeconds).rounded()))
        guard samples.count >= frameSize * requiredActiveFrames else { return .tooQuiet }
        let threshold = pow(10, minimumRMSDecibels / 20)
        var activeFrames = 0
        var gapFrames = 0
        for start in stride(from: 0, through: samples.count - frameSize, by: frameSize) {
            var frameSum = 0.0
            var frameSquares = 0.0
            for index in start..<(start + frameSize) {
                let value = Double(samples[index])
                frameSum += value
                frameSquares += value * value
            }
            let frameMean = frameSum / Double(frameSize)
            let rms = sqrt(max(0, frameSquares / Double(frameSize) - frameMean * frameMean))
            if rms >= threshold {
                activeFrames += 1
                if activeFrames >= requiredActiveFrames { return .usable }
            } else if activeFrames > 0, gapFrames == 0 {
                // One 20 ms gap avoids splitting a quiet syllable at a brief
                // closure, while retaining at least 100 ms above the floor.
                gapFrames = 1
            } else {
                activeFrames = 0
                gapFrames = 0
            }
        }
        return .tooQuiet
    }
}
