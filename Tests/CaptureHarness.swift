import AVFoundation
import Foundation

@main
struct CaptureHarness {
    struct Failure: Error { let message: String }
    static var checks = 0

    static func main() throws {
        for rate in [16_000.0, 44_100.0, 48_000.0] {
            let cycle = noise(count: Int(rate / 4))
            let repeated = Array(repeating: cycle, count: 12).flatMap { $0 }
            try check("250 ms exact loop at \(Int(rate)) Hz rejected", repeating(repeated, rate: rate))
            let blockFrames = Int((rate * 0.01).rounded())
            let quietRange = (9 * blockFrames)..<(10 * blockFrames)
            var quietGap = cycle
            quietGap.replaceSubrange(quietRange, with: noise(count: blockFrames).map { $0 * 0.01 })
            try check("audible loop with one quiet block per cycle at \(Int(rate)) Hz rejected", repeating(Array(repeating: quietGap, count: 12).flatMap { $0 }, rate: rate))
            var silentGap = cycle
            silentGap.replaceSubrange(quietRange, with: repeatElement(Float(0), count: blockFrames))
            try check("audible loop with one silent block per cycle at \(Int(rate)) Hz rejected", repeating(Array(repeating: silentGap, count: 12).flatMap { $0 }, rate: rate))
            var dcGap = cycle
            dcGap.replaceSubrange(quietRange, with: repeatElement(Float(0.25), count: blockFrames))
            try check("audible loop with one DC block per cycle at \(Int(rate)) Hz rejected", repeating(Array(repeating: dcGap, count: 12).flatMap { $0 }, rate: rate))
            try check("changing live samples at \(Int(rate)) Hz accepted", !repeating(noise(count: Int(rate * 4)), rate: rate))
            try check("less than one second repetition accepted", !repeating(Array(repeated.prefix(Int(rate))), rate: rate))
            let toneCycle = (0..<Int(rate / 4)).map { Float(0.05 * sin(2 * .pi * 1_000 * Double($0) / rate)) }
            try check("exact single tone excluded at \(Int(rate)) Hz", !repeating(Array(repeating: toneCycle, count: 12).flatMap { $0 }, rate: rate))
            var gatedTone = toneCycle
            gatedTone.replaceSubrange(quietRange, with: repeatElement(Float(0), count: blockFrames))
            try check("tonal loop with a silent block excluded at \(Int(rate)) Hz", !repeating(Array(repeating: gatedTone, count: 12).flatMap { $0 }, rate: rate))
            for frequency in [4.0, 16.0, 60.0, 1_000.0] {
                for amplitude in [0.01, 0.05] {
                    for offset in [0.0, 0.25] {
                        let quantisedTone = (0..<Int(rate / 4)).map {
                            Float(offset + amplitude * sin(2 * .pi * frequency * Double($0) / rate))
                        }
                        try check("Float tone \(Int(frequency)) Hz, amplitude \(amplitude), DC \(offset) excluded at \(Int(rate)) Hz", !repeating(Array(repeating: quantisedTone, count: 12).flatMap { $0 }, rate: rate))
                    }
                }
            }
        }
        try check("digital silence excluded", !repeating([Float](repeating: 0, count: 160_000), rate: 16_000))
        try check("constant DC excluded", !repeating([Float](repeating: 0.2, count: 160_000), rate: 16_000))
        let differentDC = (0..<160_000).flatMap { _ in [Float(0.1), Float(-0.2)] }
        try check("different stereo DC excluded", !repeating(differentDC, rate: 16_000, channels: 2))
        let cycle = noise(count: 12_000)
        let stereoCycle = cycle.flatMap { [$0, $0 * 0.5] }
        let stereoLoop = Array(repeating: stereoCycle, count: 12).flatMap { $0 }
        try check("stereo exact loop rejected", repeating(stereoLoop, rate: 48_000, channels: 2))
        let quietCycle = cycle.map { $0 * 0.01 } // about -79 dBFS, idle DSP floor
        let quietLoop = Array(repeating: quietCycle, count: 24).flatMap { $0 }
        try check("inaudible repeated noise floor accepted", !repeating(quietLoop, rate: 48_000))
        try check("inaudible repeats followed by changing speech accepted", !repeating(quietLoop + noise(count: 48_000), rate: 48_000))
        try check("DC offset does not make quiet repeated noise audible", !repeating(quietLoop.map { $0 + 0.25 }, rate: 48_000))
        let nearFloorCycle = cycle.map { $0 * 0.06 + 0.25 }
        try check("audible complex loop near the floor survives DC and quantisation allowance", repeating(Array(repeating: nearFloorCycle, count: 12).flatMap { $0 }, rate: 48_000))
        let audibleTone: [Float] = (0..<cycle.count).map { index in
            Float(0.05 * sin(Double(index) * 2 * Double.pi * 1_000 / 48_000))
        }
        let toneAndQuietNoise: [Float] = (0..<cycle.count).flatMap { [audibleTone[$0], quietCycle[$0]] }
        try check("audible tone plus a separate quiet noise channel excluded", !repeating(Array(repeating: toneAndQuietNoise, count: 12).flatMap { $0 }, rate: 48_000, channels: 2))
        let nearRepeats = (0..<12).flatMap { index in cycle.map { $0 + Float(index) * 0.000_001 } }
        try check("near-repeat cycles with distinct PCM accepted", !repeating(nearRepeats, rate: 48_000))

        // Optional private fixture arguments remain outside the repository.
        // --reject path: known corrupt capture; --accept path: known good audio.
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count % 2 == 0 else { throw Failure(message: "Use --reject/--accept followed by each fixture path") }
        for index in stride(from: 0, to: args.count, by: 2) {
            let expected = args[index] == "--reject"
            guard expected || args[index] == "--accept" else { throw Failure(message: "Unknown fixture expectation") }
            let (samples, rate, channels) = try load(URL(fileURLWithPath: args[index + 1]))
            try check("optional native fixture \(index / 2 + 1)", repeating(samples, rate: rate, channels: channels) == expected)
            let fileIsRepeating = try RepeatedAudioCheck.fileContainsRepeatedAudio(URL(fileURLWithPath: args[index + 1]))
            try check("production file preflight fixture \(index / 2 + 1)", fileIsRepeating == expected)
            if !expected {
                let quiet = samples.map { $0 * 0.001 }
                try check("optional attenuated fixture \(index / 2 + 1)", !repeating(quiet, rate: rate, channels: channels))
            }
        }
        print("\(checks) capture signal checks passed. No audio or transcript content was printed.")
    }

    static func repeating(_ samples: [Float], rate: Double, channels: Int = 1) -> Bool {
        var check = RepeatedAudioCheck(sampleRate: rate, channelCount: channels)
        // Deliberately use an odd callback size to exercise partial block carry.
        return samples.withUnsafeBufferPointer { data in
            for start in stride(from: 0, to: data.count, by: 1_027 * channels) {
                let length = min(1_027 * channels, data.count - start)
                if check.append(UnsafeBufferPointer(start: data.baseAddress!.advanced(by: start), count: length)) { return true }
            }
            return false
        }
    }

    static func noise(count: Int) -> [Float] {
        var seed: UInt64 = 0x814e_39a7_5d62_c0f3
        return (0..<count).map { _ in
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Int32(truncatingIfNeeded: seed >> 32)) / Float(Int32.max) * 0.02
        }
    }

    static func load(_ url: URL) throws -> ([Float], Double, Int) {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let channels = Int(file.processingFormat.channelCount)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_800) else {
            throw Failure(message: "Could not allocate fixture buffer")
        }
        var samples = [Float]()
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0, let data = buffer.floatChannelData else { break }
            for frame in 0..<Int(buffer.frameLength) {
                for channel in 0..<channels { samples.append(data[channel][frame]) }
            }
        }
        return (samples, file.processingFormat.sampleRate, channels)
    }

    static func check(_ label: String, _ condition: @autoclosure () -> Bool) throws {
        guard condition() else { throw Failure(message: label) }
        checks += 1
        print("PASS \(label)")
    }
}
