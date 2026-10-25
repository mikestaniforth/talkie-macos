import AVFoundation
import Foundation

/// Runs the production audibility helper without XCTest or model loading.
@main
struct SignalHarness {
    private struct Failure: Error, CustomStringConvertible { let description: String }

    static func main() {
        do { try run() }
        catch { fputs("Signal checks failed: \(error)\n", stderr); exit(1) }
    }

    private static func run() throws {
        var count = 0
        func check(_ name: String, _ condition: @autoclosure () -> Bool) throws {
            guard condition() else { throw Failure(description: name) }
            count += 1
            print("PASS \(name)")
        }
        let rate = 16_000.0
        let zeros = [Float](repeating: 0, count: 16_000)
        try check("digital zero", AudioSignalCheck.assess(zeros) == .digitalSilence)
        try check("empty audio", AudioSignalCheck.assess([]) == .digitalSilence)
        try check("DC-only audio", AudioSignalCheck.assess([Float](repeating: 0.25, count: 16_000)) == .digitalSilence)
        try check("nonfinite audio", AudioSignalCheck.assess([0, .nan, 0.1]) == .invalid)
        try check("infinite audio", AudioSignalCheck.assess([0, .infinity, 0.1]) == .invalid)
        var click = zeros
        click[8_000] = 0.8
        try check("isolated loud click", AudioSignalCheck.assess(click) == .tooQuiet)
        var shortSound = zeros
        let shortTone = tone(rmsDB: -30, seconds: 0.04, rate: rate)
        shortSound.replaceSubrange(8_000..<(8_000 + shortTone.count), with: shortTone)
        try check("40 ms sound is insufficient", AudioSignalCheck.assess(shortSound) == .tooQuiet)
        try check("sustained -55 dBFS signal", AudioSignalCheck.assess(tone(rmsDB: -55, seconds: 1, rate: rate)) == .usable)
        let quiet = tone(rmsDB: -60, seconds: 1, rate: rate)
        try check("sustained -60 dBFS signal", AudioSignalCheck.assess(quiet) == .usable)
        try check("quiet signal with DC offset", AudioSignalCheck.assess(quiet.map { $0 + 0.25 }) == .usable)
        try check("sustained -70 dBFS signal is too quiet", AudioSignalCheck.assess(tone(rmsDB: -70, seconds: 1, rate: rate)) == .tooQuiet)
        var briefGap = tone(rmsDB: -60, seconds: 0.12, rate: rate)
        briefGap.replaceSubrange(640..<960, with: repeatElement(Float(0), count: 320))
        try check("one 20 ms gap retains 100 ms signal", AudioSignalCheck.assess(briefGap) == .usable)

        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.count >= 2 {
            let (ambient, ambientRate) = try readMono(URL(fileURLWithPath: arguments[0]))
            try check("optional low-level audio fixture rejected", AudioSignalCheck.assess(ambient, sampleRate: ambientRate) == .tooQuiet)
            let (voice, voiceRate) = try readMono(URL(fileURLWithPath: arguments[1]))
            try check("optional speech fixture retained", AudioSignalCheck.assess(voice, sampleRate: voiceRate) == .usable)
            for targetDB in [-55.0, -60.0] {
                let factor = Float(pow(10, targetDB / 20) / rms(voice))
                let attenuated = voice.map { $0 * factor }
                try check("speech fixture attenuated to \(Int(targetDB)) dBFS RMS retained", AudioSignalCheck.assess(attenuated, sampleRate: voiceRate) == .usable)
            }
        } else {
            print("Fixture checks skipped: supply a low-level mono audio fixture and a synthetic speech fixture as two arguments.")
        }
        print("\(count)/\(count) signal checks passed using production AudioSignalCheck.swift.")
    }

    private static func tone(rmsDB: Double, seconds: Double, rate: Double) -> [Float] {
        let amplitude = pow(10, rmsDB / 20) * sqrt(2)
        return (0..<Int(seconds * rate)).map { Float(sin(Double($0) * 2 * .pi * 200 / rate) * amplitude) }
    }

    private static func rms(_ samples: [Float]) -> Double {
        let mean = samples.reduce(0.0) { $0 + Double($1) } / Double(samples.count)
        return sqrt(samples.reduce(0.0) { $0 + pow(Double($1) - mean, 2) } / Double(samples.count))
    }

    private static func readMono(_ url: URL) throws -> ([Float], Double) {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.processingFormat.channelCount == 1,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw Failure(description: "Fixture must be a readable mono recording")
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else {
            throw Failure(description: "Fixture had no readable PCM samples")
        }
        return (Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))), file.processingFormat.sampleRate)
    }
}
