import AppKit
import AVFoundation

/// Dictator's own interface sounds, synthesized (no third-party audio): short, soft and distinct from each other.
enum Sounds {
    enum Kind: String, CaseIterable {
        case start, stop, lock, cancel
    }

    private static let version = 1
    private static var cache: [Kind: NSSound] = [:]

    static func play(_ kind: Kind, enabled: Bool = true) {
        guard enabled else { return }
        if cache[kind] == nil, let url = file(for: kind) { cache[kind] = NSSound(contentsOf: url, byReference: true) }
        guard let sound = cache[kind] else { return }
        sound.stop()
        sound.volume = kind == .cancel ? 0.45 : 0.4
        sound.play()
    }

    private static func file(for kind: Kind) -> URL? {
        let dir = Paths.root.appendingPathComponent("Sounds", isDirectory: true)
        let url = dir.appendingPathComponent("\(kind.rawValue)-v\(version).wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        write(samples(for: kind), to: url)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: Synthesis (44.1 kHz)

    private static let rate: Double = 44_100

    private static func samples(for kind: Kind) -> [Float] {
        switch kind {
        case .start:  return glide(from: 540, to: 820, duration: 0.11, gain: 0.55)
        case .stop:   return glide(from: 820, to: 540, duration: 0.12, gain: 0.5)
        case .lock:   return tone(700, 0.06, 0.5) + silence(0.025) + tone(1050, 0.09, 0.5)
        case .cancel: return glide(from: 330, to: 210, duration: 0.14, gain: 0.55)
        }
    }

    /// A pitch glide with a soft second harmonic, quick attack and exponential decay.
    private static func glide(from f0: Double, to f1: Double, duration: Double, gain: Float) -> [Float] {
        let n = Int(duration * rate)
        var phase = 0.0
        return (0..<n).map { i in
            let t = Double(i) / rate
            let progress = t / duration
            let f = f0 * pow(f1 / f0, progress)
            phase += 2 * .pi * f / rate
            let env = min(1, t / 0.004) * exp(-4.2 * progress)
            return gain * Float(env * (sin(phase) + 0.18 * sin(2 * phase)))
        }
    }

    /// A short bell-like note.
    private static func tone(_ f: Double, _ duration: Double, _ gain: Float) -> [Float] {
        let n = Int(duration * rate)
        return (0..<n).map { i in
            let t = Double(i) / rate
            let env = min(1, t / 0.003) * exp(-5.5 * t / duration)
            return gain * Float(env * (sin(2 * .pi * f * t) + 0.12 * sin(2 * .pi * 3 * f * t)))
        }
    }

    private static func silence(_ duration: Double) -> [Float] { [Float](repeating: 0, count: Int(duration * rate)) }

    private static func write(_ samples: [Float], to url: URL) {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        if let file = try? AVAudioFile(forWriting: url, settings: format.settings) { try? file.write(from: buffer) }
    }
}
