import AVFoundation
import CoreAudio

/// Lists microphones via CoreAudio.
enum AudioDevices {
    struct Device: Identifiable, Hashable {
        let id: AudioDeviceID
        let uid: String
        let name: String
    }

    static func inputs() -> [Device] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard inputChannels(id) > 0, let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return Device(id: id, uid: uid, name: name)
        }
    }

    static func device(uid: String) -> Device? { inputs().first { $0.uid == uid } }

    /// Name of the device an engine is reading from.
    static func name(of engine: AVAudioEngine) -> String? {
        guard let unit = engine.inputNode.audioUnit else { return nil }
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, &size) == noErr else { return nil }
        return inputs().first { $0.id == id }?.name
    }

    /// Bluetooth headsets switch to a low-quality 16 kHz call codec while recording, which hurts accuracy.
    static func isBluetooth(uid: String) -> Bool {
        let id: AudioDeviceID
        if uid.isEmpty {
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                     mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var dev = AudioDeviceID(0)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &dev) == noErr else { return false }
            id = dev
        } else {
            guard let device = device(uid: uid) else { return false }
            id = device.id
        }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport) == noErr else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    private static func inputChannels(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}

/// Captures the microphone as 16 kHz mono Float32, which is what Whisper expects.
/// All AVAudioEngine work happens on a private serial queue, never on the main thread: starting the engine can block or
/// spin a nested run loop, which on the main thread corrupted the Swift runtime's main-actor bookkeeping (0.3.0 crashes).
final class AudioRecorder {
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    private let queue = DispatchQueue(label: "app.dictator.audio", qos: .userInteractive)
    private var engine: AVAudioEngine?               // touched only on `queue`
    private var converter: AVAudioConverter?         // touched only on `queue` / the tap
    private var samples: [Float] = []
    private let lock = NSLock()
    /// Main thread: a recording has been requested and not yet stopped.
    private(set) var isRecording = false

    /// Called on the main thread with the RMS level of each audio chunk (for the waveform).
    var onLevel: ((Float) -> Void)?

    var sampleCount: Int {
        lock.lock(); defer { lock.unlock() }
        return samples.count
    }

    /// A copy of the captured audio in `range` (clamped), readable while recording.
    func samples(in range: Range<Int>) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let r = max(0, range.lowerBound)..<min(samples.count, range.upperBound)
        return r.isEmpty ? [] : Array(samples[r])
    }

    /// Starts recording in the background and returns immediately. `onError` runs on the main thread.
    /// `deviceUID` empty = system default input.
    func start(deviceUID: String = "", onError: @escaping (Error) -> Void) {
        guard !isRecording else { return }
        isRecording = true
        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            let t0 = Date()
            do {
                let name = try self.startEngine(deviceUID: deviceUID)
                Log.write(String(format: "mic started in %.0f ms (%@)", Date().timeIntervalSince(t0) * 1000, name))
            } catch {
                Log.write("microphone failed to start: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.isRecording = false
                    onError(error)
                }
            }
        }
    }

    /// Stops recording; `completion` gets everything captured, on the main thread.
    func stop(_ completion: @escaping ([Float]) -> Void) {
        guard isRecording else { completion([]); return }
        isRecording = false
        queue.async { [weak self] in
            guard let self else { return }
            if let engine = self.engine {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
            }
            self.engine = nil
            self.lock.lock(); let captured = self.samples; self.lock.unlock()
            DispatchQueue.main.async { completion(captured) }
        }
    }

    /// Runs on `queue`. A fresh engine per recording picks up device changes (AirPods connecting, etc.).
    private func startEngine(deviceUID: String) throws -> String {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if !deviceUID.isEmpty, let device = AudioDevices.device(uid: deviceUID), let unit = input.audioUnit {
            var id = device.id
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw NSError(domain: "Dictator", code: 5, userInfo: [NSLocalizedDescriptionKey: "No microphone input"])
        }
        let converter = AVAudioConverter(from: inputFormat, to: Self.format)
        converter?.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converter?.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        self.converter = converter
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
        return (AudioDevices.name(of: engine) ?? "default input") + String(format: ", %.0f Hz", inputFormat.sampleRate)
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = Self.format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        let count = Int(out.frameLength)
        guard count > 0, let channel = out.floatChannelData?[0] else { return }
        // Some devices emit NaN/inf in their first buffers; never let those reach the model.
        let chunk = UnsafeBufferPointer(start: channel, count: count).map { $0.isFinite ? $0 : 0 }
        lock.lock(); samples.append(contentsOf: chunk); lock.unlock()

        let rms = Self.rms(chunk)
        DispatchQueue.main.async { [weak self] in self?.onLevel?(rms) }
    }

    static func rms(_ audio: [Float]) -> Float {
        guard !audio.isEmpty else { return 0 }
        return sqrt(audio.reduce(0) { $0 + $1 * $1 } / Float(audio.count))
    }

    /// Brings quiet speech up to a healthy level (max 12× gain).
    static func normalized(_ audio: [Float]) -> [Float] {
        let peak = audio.reduce(0) { max($0, abs($1)) }
        guard peak > 0.0005, peak < 0.5 else { return audio }
        let gain = min(0.7 / peak, 12)
        return audio.map { $0 * gain }
    }

    static func writeWAV(_ audio: [Float], to url: URL) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audio.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(audio.count)
        audio.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: audio.count) }
        try? FileManager.default.removeItem(at: url)
        if let file = try? AVAudioFile(forWriting: url, settings: format.settings) {
            try? file.write(from: buffer)
        }
    }
}
