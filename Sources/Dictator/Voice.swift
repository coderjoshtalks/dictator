import Foundation

/// Frame-level voice activity on 16 kHz mono audio, relative to the room's own noise floor
/// (a fixed loudness threshold drops whispers in quiet rooms and lets fan noise through in loud ones).
enum Voice {
    static let sampleRate = 16_000
    static let frame = 320                       // 20 ms

    static func frameRMS(_ audio: ArraySlice<Float>) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(audio.count / frame + 1)
        var i = audio.startIndex
        while i + frame <= audio.endIndex {
            var sum: Float = 0
            for j in i..<(i + frame) { sum += audio[j] * audio[j] }
            out.append(sqrt(sum / Float(frame)))
            i += frame
        }
        return out
    }

    /// The level of the quietest stretches: 10th percentile of frame energy.
    static func noiseFloor(_ rms: [Float]) -> Float {
        guard !rms.isEmpty else { return 1e-4 }
        let sorted = rms.sorted()
        return max(sorted[sorted.count / 10], 1e-5)
    }

    static func voiced(_ rms: [Float], floor: Float) -> [Bool] {
        let threshold = max(floor * 3.5, 0.0003)
        return rms.map { $0 > threshold }
    }

    /// True when there is at least ~0.2 s of speech, even if it's whispered.
    static func hasSpeech(_ audio: [Float]) -> Bool {
        let rms = frameRMS(audio[...])
        return voiced(rms, floor: noiseFloor(rms)).filter { $0 }.count >= 10
    }
}

/// Cleans up microphone audio before recognition:
/// 80 Hz high-pass (rumble, desk knocks, DC offset) → gain to a consistent speech level → soft limiter.
/// Whisper's log-mel features depend on absolute level, so quiet or whispered speech recognizes better once it is levelled.
enum AudioPreprocessor {
    static let targetSpeechRMS: Float = 0.06
    static let maxGain: Float = 40

    static func process(_ input: [Float]) -> [Float] {
        guard !input.isEmpty else { return input }
        var audio = highPass(input, cutoff: 80)

        let rms = Voice.frameRMS(audio[...])
        let mask = Voice.voiced(rms, floor: Voice.noiseFloor(rms))
        var energy: Float = 0, count = 0
        for (i, isVoiced) in mask.enumerated() where isVoiced { energy += rms[i] * rms[i]; count += 1 }
        guard count >= 5 else { return audio }
        let speechRMS = sqrt(energy / Float(count))
        let gain = min(max(targetSpeechRMS / max(speechRMS, 1e-6), 0.5), maxGain)
        for i in audio.indices {
            let x = audio[i] * gain
            let m = abs(x)
            audio[i] = m <= 0.9 ? x : (x < 0 ? -1 : 1) * (0.9 + 0.1 * tanh((m - 0.9) / 0.1))
        }
        return audio
    }

    /// RBJ biquad high-pass, Q = 0.707.
    static func highPass(_ x: [Float], cutoff: Float) -> [Float] {
        let w0 = 2 * Float.pi * cutoff / Float(Voice.sampleRate)
        let alpha = sin(w0) / (2 * 0.7071)
        let c = cos(w0)
        let a0 = 1 + alpha
        let b0 = (1 + c) / 2 / a0, b1 = -(1 + c) / a0, b2 = (1 + c) / 2 / a0
        let a1 = -2 * c / a0, a2 = (1 - alpha) / a0
        var y = [Float](repeating: 0, count: x.count)
        var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
        for i in x.indices {
            let out = b0 * x[i] + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x[i]; y2 = y1; y1 = out
            y[i] = out
        }
        return y
    }
}
