import Foundation

/// Transcribes and cleans a dictation *while it is being spoken*.
/// Every time the speaker pauses after enough speech, that phrase is cut off and processed in the background,
/// so when the key is released only the last few seconds are left — the wait no longer grows with length.
@MainActor
final class DictationPipeline {
    struct Output {
        var raw = ""
        var text = ""
        var engines: [String] = []
        var fixes = 0
        var llmRejected = false
        var engine: String { engines.contains("english") && !engines.contains("hinglish") ? "english" : (engines.first ?? "hinglish") }
    }

    struct Settings {
        var config: RefinementConfig
        var dictionary: [DictionaryEntry]
        var recognition: RecognitionMode
        var appName: String?
        var contextBefore: String?
    }

    /// Phrases shorter than this keep accumulating; longer ones are cut at the next pause.
    static let minSegment = 6 * Voice.sampleRate
    /// Never let a phrase grow past this without a cut (cut at the quietest moment instead).
    static let maxSegment = 20 * Voice.sampleRate
    /// A pause must last this long to cut there.
    static let pauseFrames = 18                       // 360 ms

    private let engine: SpeechEngine
    private let llm: LLMEngine
    private var settings: Settings?
    private var cut = 0                               // samples already handed to a segment
    /// Absolute sample ranges to silence before recognition (Dictator's own start/lock chirps leak into the mic).
    private var muted: [Range<Int>] = []
    private var chain: Task<Void, Never>?
    private var output = Output()

    init(engine: SpeechEngine, llm: LLMEngine) {
        self.engine = engine
        self.llm = llm
    }

    func begin(_ settings: Settings) {
        self.settings = settings
        cut = 0
        chain = nil
        output = Output()
        muted = [0..<Int(0.18 * Double(Voice.sampleRate))]
    }

    /// Silence `seconds` of audio starting at absolute sample `start` (e.g. while the lock sound plays).
    func mute(from start: Int, seconds: Double) {
        muted.append(start..<(start + Int(seconds * Double(Voice.sampleRate))))
    }

    func cancel() {
        settings = nil
        chain?.cancel()
        chain = nil
    }

    /// Called periodically while recording with everything captured so far.
    func tick(totalSamples: Int, read: (Range<Int>) -> [Float]) {
        guard settings != nil, totalSamples - cut >= Self.minSegment else { return }
        let window = read(cut..<totalSamples)
        guard let end = Self.cutPoint(in: window) else { return }
        enqueue(silenced(Array(window[..<end]), offset: cut))
        cut += end
    }

    /// Processes what's left after the key is released and returns the whole dictation.
    func finish(audio: [Float]) async -> Output {
        if cut < audio.count { enqueue(silenced(Array(audio[cut...]), offset: cut), isLast: true) }
        await chain?.value
        let result = output
        settings = nil
        return result
    }

    private func silenced(_ segment: [Float], offset: Int) -> [Float] {
        var out = segment
        for range in muted {
            let lo = max(range.lowerBound - offset, 0), hi = min(range.upperBound - offset, out.count)
            if lo < hi { for i in lo..<hi { out[i] = 0 } }
        }
        return out
    }

    // MARK: Segmenting

    /// Where to cut `window`: the middle of the last long pause after `minSegment`, or the quietest spot once it's too long.
    static func cutPoint(in window: [Float]) -> Int? {
        let rms = Voice.frameRMS(window[...])
        let mask = Voice.voiced(rms, floor: Voice.noiseFloor(rms))
        let minFrame = minSegment / Voice.frame
        let lastUsable = rms.count - 5                 // keep 100 ms of headroom at the live edge
        var bestCut: Int?
        var run = 0
        if minFrame < lastUsable {
            for f in minFrame..<lastUsable {
                if mask[f] { run = 0; continue }
                run += 1
                if run >= pauseFrames { bestCut = (f - run / 2) * Voice.frame }
            }
        }
        if let bestCut { return bestCut }
        guard window.count >= maxSegment else { return nil }
        // No pause: cut at the quietest 200 ms between 12 s and the live edge.
        let start = 12 * Voice.sampleRate / Voice.frame
        var quietest = start, quietestLevel = Float.greatestFiniteMagnitude
        for f in start..<max(start + 1, lastUsable - 10) {
            let level = rms[f..<min(f + 10, rms.count)].reduce(0, +)
            if level < quietestLevel { quietestLevel = level; quietest = f + 5 }
        }
        return quietest * Voice.frame
    }

    // MARK: Processing

    private func enqueue(_ segment: [Float], isLast: Bool = false) {
        let previous = chain
        chain = Task { [weak self] in
            await previous?.value
            await self?.process(segment)
        }
    }

    private func process(_ segment: [Float]) async {
        guard let settings, !Task.isCancelled else { return }
        guard Voice.hasSpeech(segment) else { return }

        let input = AudioPreprocessor.process(segment) + [Float](repeating: 0, count: Voice.sampleRate / 5)
        guard let heard = try? await engine.transcribe(input, vocabulary: settings.dictionary.map(\.written), mode: settings.recognition),
              !RuleCleaner.stripSoundLabels(heard.text).isEmpty else { return }
        let seconds = Double(segment.count) / Double(Voice.sampleRate)
        if RuleCleaner.isHallucination(heard.text) && seconds < 3 { return }

        let before = [settings.contextBefore, output.text.isEmpty ? nil : output.text].compactMap { $0 }.joined(separator: " ")
        let result = await Refiner.refine(
            RefineRequest(raw: heard.text, config: settings.config, dictionary: settings.dictionary,
                          appName: settings.appName, contextBefore: before.isEmpty ? nil : before),
            llm: llm)
        guard !result.text.isEmpty else { return }
        output.raw += (output.raw.isEmpty ? "" : " ") + heard.text
        output.text += Self.joiner(output.text, result.text) + result.text
        output.engines.append(heard.engine)
        output.fixes += result.fixes
        if result.llmAccepted == false { output.llmRejected = true }
    }

    private static func joiner(_ existing: String, _ next: String) -> String {
        guard let last = existing.last else { return "" }
        if last == "\n" || next.first == "\n" { return "" }
        return " "
    }
}
