import Foundation
import WhisperKit

enum RecognitionMode: String, CaseIterable, Identifiable {
    case auto, english, hinglish
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Auto — English + Hinglish (recommended)"
        case .english: return "English only"
        case .hinglish: return "Hinglish / Hindi only"
        }
    }
}

/// Two speech models, best of both:
///  - the Hinglish model (Whisper turbo fine-tuned on Hindi/Hinglish) understands mixed speech and writes Hindi in Roman script;
///  - OpenAI's Whisper turbo makes about half the errors on pure English.
/// In Auto mode the Hinglish model runs first; if it heard any Hindi words its text is used, otherwise the English model re-transcribes.
/// (Language detection alone mislabels English-heavy Hinglish like "let's do the call kal subah" as English.)
final class SpeechEngine {
    struct Result {
        let text: String
        let engine: String
    }

    let hinglish = Transcriber(folder: Paths.speechModel)
    let english = Transcriber(folder: Paths.englishModel)
    private(set) var englishLoaded = false

    func load() async throws {
        try await hinglish.load()
        if Paths.englishModelInstalled {
            do {
                try await english.load()
                englishLoaded = true
            } catch {
                Log.write("English model failed to load, using the Hinglish model for everything: \(error.localizedDescription)")
            }
        }
    }

    func transcribe(_ audio: [Float], vocabulary: [String], mode: RecognitionMode) async throws -> Result {
        if mode == .hinglish || !englishLoaded {
            return Result(text: try await hinglish.transcribe(audio, vocabulary: vocabulary), engine: "hinglish")
        }
        if mode == .english {
            return Result(text: try await english.transcribe(audio, vocabulary: vocabulary), engine: "english")
        }
        // Sequential on purpose: both models share the Neural Engine, so running them together gains nothing,
        // and Hinglish dictations finish as soon as the first model is done.
        let hinglishText = try await hinglish.transcribe(audio, vocabulary: vocabulary)
        if Self.containsHindi(hinglishText) {
            return Result(text: hinglishText, engine: "hinglish")
        }
        if let englishText = try? await english.transcribe(audio, vocabulary: vocabulary),
           !englishText.trimmingCharacters(in: .whitespaces).isEmpty {
            return Result(text: englishText, engine: "english")
        }
        return Result(text: hinglishText, engine: "hinglish")
    }

    /// Common Hindi words in Roman script that don't double as English words.
    static let hindiWords: Set<String> = Set("""
    hai hain ki ka ke ko mein nahi nahin kya kyun kyon yaar yar bhai toh jab tab tum aap mujhe mera meri mere hum ham kal aaj abhi
    bahut accha acha achha achchha theek thik karo karna kar raha rahi rahe gaya gayi hoga hogi haan matlab lekin aur bhi se wala wali
    vaala wale yeh yah ye vo woh kuch sab log baje chahiye lagta pata kaise kaun kahan kab phir fir chalo dekho bolo batao samajh hisaab
    tak liye diya kiya karta karti hoon hun tha thi hamen humein hame unko usko isko inko uska iska apna apni zyada jyada thoda thodi
    """.split(whereSeparator: \.isWhitespace).map(String.init))

    static func containsHindi(_ text: String) -> Bool {
        text.lowercased().split { !$0.isLetter }.contains { hindiWords.contains(String($0)) }
    }
}
