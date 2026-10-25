import AVFoundation
import AudioToolbox
import Combine
import CoreAudio
import Foundation

struct AudioDevice: Identifiable, Equatable {
    let uid: String
    let name: String
    var id: String { uid }
}

enum AudioCaptureError: LocalizedError {
    case microphonePermission
    case alreadyRecording
    case deviceUnavailable
    case deviceRouting(OSStatus)
    case invalidFormat
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .microphonePermission: return "Allow microphone access in System Settings before recording."
        case .alreadyRecording: return "A recording is already in progress."
        case .deviceUnavailable: return "The selected microphone is unavailable. Reconnect it or choose another input."
        case .deviceRouting(let status): return "The microphone could not be selected (audio error \(status))."
        case .invalidFormat: return "This microphone did not provide a usable input format."
        case .writeFailed(let message): return "Recording stopped: \(message)"
        }
    }
}

/// The tap only reserves a bounded slot and copies its temporary PCM buffer.
/// Disk writes and metering run on one serial queue. The short state lock is
/// never held during disk I/O, buffer copying or draining the queue.
private final class RecordingWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "local.talkie.preview.recording-writer", qos: .userInitiated)
    private let pending = DispatchGroup()
    private let maximumOutstandingBuffers = 32
    private var accepting = true
    private var outstandingBuffers = 0
    // Accessed only on `queue`, apart from initialization before publication.
    private var file: AVAudioFile?
    private var failure: Error?
    private var reportedFailure = false
    private var repeatedAudio: RepeatedAudioCheck

    init(url: URL, format: AVAudioFormat) throws {
        repeatedAudio = RepeatedAudioCheck(sampleRate: format.sampleRate, channelCount: Int(format.channelCount))
        // Audio files store interleaved PCM; the processing format may still
        // be noninterleaved, as AVAudioEngine normally supplies it.
        var fileSettings = format.settings
        fileSettings[AVLinearPCMIsNonInterleaved] = false
        file = try AVAudioFile(forWriting: url, settings: fileSettings,
                               commonFormat: format.commonFormat, interleaved: format.isInterleaved)
    }

    func enqueue(_ buffer: AVAudioPCMBuffer, completion: @escaping @Sendable (Double, String?) -> Void) {
        guard buffer.frameLength > 0 else { return }
        lock.lock()
        guard accepting else { lock.unlock(); return }
        guard outstandingBuffers < maximumOutstandingBuffers else {
            let message = recordFailureLocked(Self.writerError("The audio writer could not keep up. Recording stopped; some recent audio could not be saved."))
            lock.unlock()
            if let message { completion(0, message) }
            return
        }
        outstandingBuffers += 1
        // Enter under the same lock that closes admission. Even a buffer still
        // being copied is included when close() waits for the recording tail.
        pending.enter()
        lock.unlock()

        guard let copy = Self.copyBuffer(buffer) else {
            let message = recordFailure(Self.writerError("An audio buffer could not be copied. Recording stopped; some recent audio could not be saved."))
            finishPendingBuffer()
            if let message { completion(0, message) }
            return
        }
        queue.async { [self] in
            var message: String?
            do {
                guard let file else { throw Self.writerError("The recording file closed before this audio could be saved.") }
                try file.write(from: copy)
                if isRepeatedInput(copy) {
                    throw Self.writerError("The microphone input began repeating old audio instead of capturing new sound. Reconnect the microphone or choose another input, then try again. The partial recording has been saved.")
                }
            }
            catch { message = recordFailure(error) }
            let meter = Self.level(copy)
            finishPendingBuffer()
            completion(meter, message)
        }
    }

    private func finishPendingBuffer() {
        lock.lock()
        outstandingBuffers -= 1
        lock.unlock()
        pending.leave()
    }

    private func recordFailure(_ error: Error) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return recordFailureLocked(error)
    }

    private func recordFailureLocked(_ error: Error) -> String? {
        accepting = false
        if failure == nil { failure = error }
        guard !reportedFailure else { return nil }
        reportedFailure = true
        return failure?.localizedDescription
    }

    private static func writerError(_ message: String) -> Error {
        NSError(domain: "Talkie.AudioCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func copyBuffer(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else { return nil }
        copy.frameLength = source.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else { return nil }
        for index in sourceBuffers.indices {
            let input = sourceBuffers[index]
            guard input.mDataByteSize <= destinationBuffers[index].mDataByteSize,
                  let inputData = input.mData, let outputData = destinationBuffers[index].mData else { return nil }
            memcpy(outputData, inputData, Int(input.mDataByteSize))
            destinationBuffers[index].mDataByteSize = input.mDataByteSize
        }
        return copy
    }

    private static func level(_ buffer: AVAudioPCMBuffer) -> Double {
        var peakRMS = 0.0
        if let channels = buffer.floatChannelData, buffer.frameLength > 0 {
            let frames = Int(buffer.frameLength)
            let channelCount = Int(buffer.format.channelCount)
            for channel in 0..<channelCount {
                let samples = buffer.format.isInterleaved ? channels[0] : channels[channel]
                var squareSum = 0.0
                for index in 0..<frames {
                    let offset = buffer.format.isInterleaved ? index * channelCount + channel : index
                    let sample = Double(samples[offset])
                    squareSum += sample * sample
                }
                peakRMS = max(peakRMS, sqrt(squareSum / Double(frames)))
            }
        }
        return max(0, min(1, (20 * log10(max(peakRMS, 0.000_001)) + 60) / 60))
    }

    private func isRepeatedInput(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard let channels = buffer.floatChannelData else { return false }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        if buffer.format.isInterleaved || channelCount == 1 {
            return repeatedAudio.append(UnsafeBufferPointer(start: channels[0], count: frames * channelCount))
        }
        var interleaved = [Float]()
        interleaved.reserveCapacity(frames * channelCount)
        for frame in 0..<frames {
            for channel in 0..<channelCount { interleaved.append(channels[channel][frame]) }
        }
        return interleaved.withUnsafeBufferPointer { repeatedAudio.append($0) }
    }

    func close() -> Error? {
        lock.lock()
        accepting = false
        lock.unlock()
        // Called after removing the tap and stopping the engine, never on the
        // writer queue. Wait for reserved/copying buffers as well as queued I/O.
        pending.wait()
        queue.sync { file = nil }
        lock.lock()
        let result = failure
        lock.unlock()
        return result
    }
}

@MainActor
final class AudioCapture: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var level = 0.0
    @Published private(set) var devices: [AudioDevice] = []
    @Published var selectedDeviceUID: String?
    var availableDevices: [AudioDevice] { devices }
    var onInterruption: ((String) -> Void)?

    private var engine: AVAudioEngine?
    private var writer: RecordingWriter?
    private var recordingURL: URL?
    private var stoppedWriteError: Error?
    private var activeDeviceUID: String?
    private var activeSessionID: UUID?
    private var configurationObserver: NSObjectProtocol?
    private var devicesListener: AudioObjectPropertyListenerBlock?

    init() {
        refreshDevices()
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshDevices()
                if self.isRecording, let uid = self.activeDeviceUID,
                   !self.devices.contains(where: { $0.uid == uid }) {
                    self.interrupt("The microphone disconnected. The audio captured so far has been saved.")
                }
            }
        }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address,
                                                DispatchQueue.main, listener) == noErr {
            devicesListener = listener
        }
    }

    deinit {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        if let devicesListener {
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address,
                                                    DispatchQueue.main, devicesListener)
        }
        engine?.stop()
        _ = writer?.close()
    }

    func refreshDevices() {
        devices = Self.inputDeviceIDs().compactMap { id in
            guard let uid = Self.stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = Self.stringProperty(id, kAudioObjectPropertyName) else { return nil }
            return AudioDevice(uid: uid, name: name)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func start(to url: URL) async throws {
        guard !isRecording else { throw AudioCaptureError.alreadyRecording }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw AudioCaptureError.microphonePermission
        }
        refreshDevices()
        let chosenDevice: AudioDeviceID
        if let uid = selectedDeviceUID {
            guard let match = Self.inputDeviceIDs().first(where: {
                Self.stringProperty($0, kAudioDevicePropertyDeviceUID) == uid
            }) else { throw AudioCaptureError.deviceUnavailable }
            chosenDevice = match
        } else {
            guard let systemDefault = Self.defaultInputDevice() else { throw AudioCaptureError.deviceUnavailable }
            chosenDevice = systemDefault
        }
        let captureEngine = AVAudioEngine()
        let input = captureEngine.inputNode
        guard let unit = input.audioUnit else { throw AudioCaptureError.invalidFormat }
        var device = chosenDevice
        let routeStatus = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                               kAudioUnitScope_Global, 0, &device,
                                               UInt32(MemoryLayout<AudioDeviceID>.size))
        guard routeStatus == noErr else { throw AudioCaptureError.deviceRouting(routeStatus) }
        // Capture the hardware's actual format. Speech-engine conversion is
        // a separate, explicit operation.
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioCaptureError.invalidFormat }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let captureWriter = try RecordingWriter(url: url, format: format)
        let sessionID = UUID()
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            captureWriter.enqueue(buffer) { [weak self] meter, error in
                Task { @MainActor [weak self] in
                    guard let self, self.isRecording, self.activeSessionID == sessionID else { return }
                    self.level = meter
                    if let error { self.interrupt("Capture stopped: \(error). Any audio already written has been kept.") }
                }
            }
        }
        do {
            captureEngine.prepare()
            try captureEngine.start()
        } catch {
            input.removeTap(onBus: 0)
            captureEngine.stop()
            _ = captureWriter.close()
            throw error
        }
        engine = captureEngine
        writer = captureWriter
        recordingURL = url
        stoppedWriteError = nil
        activeDeviceUID = Self.stringProperty(chosenDevice, kAudioDevicePropertyDeviceUID)
        activeSessionID = sessionID
        isRecording = true
        level = 0
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: captureEngine, queue: .main
        ) { [weak self, captureEngine] _ in
            // AVAudioEngine may post while reconfiguring its graph. Explicitly
            // defer teardown until the notification callback has returned, and
            // hold the engine through teardown rather than releasing it there.
            DispatchQueue.main.async { [weak self, captureEngine] in
                guard let self, self.activeSessionID == sessionID else { return }
                self.interrupt("The audio input changed. The audio captured so far has been saved; choose an input before continuing.")
                withExtendedLifetime(captureEngine) {}
            }
        }
    }

    func stop() async throws -> URL? {
        finishCapture()
        let result = recordingURL
        recordingURL = nil
        if let error = stoppedWriteError {
            stoppedWriteError = nil
            throw AudioCaptureError.writeFailed(error.localizedDescription)
        }
        return result
    }

    /// Cancellation stops capture but keeps the on-disk partial for recovery.
    func cancel() { finishCapture() }

    private func interrupt(_ message: String) {
        guard isRecording else { return }
        finishCapture()
        onInterruption?(message)
    }

    private func finishCapture() {
        if let observer = configurationObserver {
            NotificationCenter.default.removeObserver(observer)
            configurationObserver = nil
        }
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        stoppedWriteError = writer?.close() ?? stoppedWriteError
        writer = nil
        engine = nil
        isRecording = false
        level = 0
        activeDeviceUID = nil
        activeSessionID = nil
    }

    private static func defaultInputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return device
    }

    private static func inputDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { id in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                     mScope: kAudioDevicePropertyScopeInput,
                                                     mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            return AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr && streamSize > 0
        }
    }

    private static func stringProperty(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        // These CoreAudio string properties return caller-owned CFObjects. Use
        // an unmanaged out-pointer so Swift never forms a raw pointer to an
        // ARC-managed CFString reference, then balance the retained result.
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
