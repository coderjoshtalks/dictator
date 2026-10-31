import CoreML
import Foundation
import WhisperKit

/// On-device speech recognition: Whisper large-v3-turbo fine-tuned for English + Hinglish
/// (Oriserve Hindi2Hinglish-Apex), running through WhisperKit on CoreML / the Neural Engine.
actor Transcriber {
    enum Failure: LocalizedError {
        case modelMissing, notLoaded
        var errorDescription: String? {
            switch self {
            case .modelMissing: return "Speech model not found in \(Paths.speechModel.path)"
            case .notLoaded: return "Speech model is still loading"
            }
        }
    }

    static let sampleRate = 16_000
    private var kit: WhisperKit?
    let folder: URL
    private let compute: ModelComputeOptions?

    /// `compute` nil = WhisperKit's default (Neural Engine).
    init(folder: URL = Paths.speechModel, compute: ModelComputeOptions? = nil) {
        self.folder = folder
        self.compute = compute
    }

    var isLoaded: Bool { kit != nil }

    func load() async throws {
        guard kit == nil else { return }
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("TextDecoder.mlmodelc").path) else { throw Failure.modelMissing }
        let config = WhisperKitConfig(
            modelFolder: folder.path,
            tokenizerFolder: folder,
            computeOptions: compute,
            verbose: false,
            logLevel: .error,
            prewarm: false,
            load: true,
            download: false
        )
        let loaded = try await WhisperKit(config)
        kit = loaded
        // The first CoreML prediction is slow; pay that cost now instead of on the first dictation.
        _ = try? await loaded.transcribe(audioArray: [Float](repeating: 0, count: Self.sampleRate), decodeOptions: options(for: 1, vocabulary: []))
    }

    /// `vocabulary` biases the decoder toward names and jargon the user cares about.
    func transcribe(_ audio: [Float], vocabulary: [String] = [], language: String = "en") async throws -> String {
        guard let kit else { throw Failure.notLoaded }
        var opts = options(for: audio.count, vocabulary: vocabulary)
        opts.language = language
        let results = try await kit.transcribe(audioArray: audio, decodeOptions: opts)
        return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The most likely language in the first 30 s and its probability (0…1).
    func detectLanguage(_ audio: [Float]) async throws -> (language: String, probability: Float) {
        guard let kit else { throw Failure.notLoaded }
        let result = try await kit.detectLangauge(audioArray: audio)
        let logProb = result.langProbs[result.language] ?? -.infinity   // WhisperKit reports a log-probability
        return (result.language, exp(logProb))
    }

    private func options(for sampleCount: Int, vocabulary: [String]) -> DecodingOptions {
        // The Hinglish fine-tune writes romanized text when decoding as "en"; forcing "hi" yields Devanagari.
        var opts = DecodingOptions(
            task: .transcribe,
            language: "en",
            temperature: 0,
            temperatureFallbackCount: 2,
            usePrefillPrompt: true,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            chunkingStrategy: sampleCount > 29 * Self.sampleRate ? .vad : ChunkingStrategy.none
        )
        if !vocabulary.isEmpty, let tokenizer = kit?.tokenizer {
            let prompt = " " + vocabulary.joined(separator: ", ") + "."
            opts.promptTokens = tokenizer.encode(text: prompt).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        }
        return opts
    }
}
