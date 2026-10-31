import Foundation
import WhisperKit

/// Headless test modes, using the same config as the app (refinement.json):
///   Dictator --transcribe a.wav b.mp3 [--clean]
///   Dictator --refine "um so kal 5 baje no wait 6 baje" ["…"]
///   Dictator --transform Polish "some text"
enum CLI {
    static func run(_ arguments: [String]) async -> Int32 {
        var args = arguments
        var config = ConfigStore().config
        if let i = args.firstIndex(of: "--model"), i + 1 < args.count {
            config.modelID = args[i + 1]
            args.removeSubrange(i...(i + 1))
        }
        let dictionary = Settings().dictionary
        let llm = LLMEngine()
        defer { llm.stop() }

        let needsLLM = args.contains("--clean") || args.first == "--refine" || args.first == "--transform" || args.first == "--pipeline" || args.first == "--stream"
        if needsLLM {
            guard let model = config.modelPath else { print("No AI model configured"); return 1 }
            let t0 = Date()
            do { try await llm.start(model: model) } catch { print("LLM failed: \(error.localizedDescription)"); return 1 }
            print(String(format: "[%@ ready in %.1fs]", model.lastPathComponent, Date().timeIntervalSince(t0)))
        }

        switch args.first {
        case "--learn-test":
            let cases: [(String, String, String)] = [
                ("Hi. I work on voice arina daily.", "Hi. I work on Voice Arena daily.", "I work on voice arina daily."),
                ("This is not the right centers to use.", "This is not the right sentence to use.", "This is not the right centers to use."),
                ("Meet rahul at five.", "Meet Rahul at five.", "Meet rahul at five."),
                ("Send it to the team today.", "Send it to the client today.", "Send it to the team today."),
                ("We grew 20 percent.", "We grew 25 percent.", "We grew 20 percent."),
                ("I deployed to cube netties.", "I deployed to Kubernetes.", "I deployed to cube netties."),
                ("Old text. New dictated text here.", "Old text. Something else entirely written instead.", "New dictated text here."),
            ]
            for (before, after, pasted) in cases {
                let found = await MainActor.run { Learner.corrections(before: before, after: after, pasted: pasted) }
                print("\(found.isEmpty ? "—" : found.map { "\($0.0) → \($0.1)" }.joined(separator: ", "))   [\(after)]")
            }
            return 0
        case "--bench":
            // --bench <model folder> <manifest.tsv> [language]   → TSV: id, seconds, en-prob, hi-prob, hypothesis
            guard args.count >= 3 else { print("Usage: --bench <model folder> <manifest.tsv> [language]"); return 1 }
            let transcriber = Transcriber(folder: URL(fileURLWithPath: args[1]))
            do { try await transcriber.load() } catch { print("load failed: \(error)"); return 1 }
            let language = args.count > 3 ? args[3] : "en"
            let manifest = (try? String(contentsOfFile: args[2], encoding: .utf8)) ?? ""
            for line in manifest.split(separator: "\n") {
                let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard cols.count >= 2, let audio = try? AudioProcessor.loadAudioAsFloatArray(fromPath: cols[1]) else { continue }
                let detected = (try? await transcriber.detectLanguage(audio)) ?? (language: "?", probability: 0)
                let pEnglish = detected.language == "en" ? detected.probability : 0
                let t0 = Date()
                let hyp = (try? await transcriber.transcribe(audio, language: language)) ?? ""
                print([cols[0], String(format: "%.3f", Date().timeIntervalSince(t0)), String(format: "%.3f", pEnglish),
                       detected.language + String(format: ":%.2f", detected.probability), hyp.replacingOccurrences(of: "\t", with: " ")].joined(separator: "\t"))
            }
            return 0
        case "--engine":
            // --engine <manifest.tsv> [old|new|none] → the app's real dual-model router with a given audio preprocessing.
            // TSV: id, seconds, -, engine, text
            let prep = args.count > 2 ? args[2] : "new"
            let engine = SpeechEngine()
            do { try await engine.load() } catch { print("load failed: \(error)"); return 1 }
            let manifest = (try? String(contentsOfFile: args[1], encoding: .utf8)) ?? ""
            for line in manifest.split(separator: "\n") {
                let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard cols.count >= 2, let audio = try? AudioProcessor.loadAudioAsFloatArray(fromPath: cols[1]) else { continue }
                let input = prep == "old" ? AudioRecorder.normalized(audio) : prep == "new" ? AudioPreprocessor.process(audio) : audio
                let t0 = Date()
                let r = (try? await engine.transcribe(input, vocabulary: [], mode: .auto)) ?? SpeechEngine.Result(text: "", engine: "error")
                print([cols[0], String(format: "%.3f", Date().timeIntervalSince(t0)), "0", r.engine, r.text].joined(separator: "\t"))
            }
            return 0
        case "--pipeline":
            // --pipeline <manifest.tsv> → what the app does after key release. TSV: id, asr s, cleanup s, total s, engine, text
            let engine = SpeechEngine()
            do { try await engine.load() } catch { print("load failed: \(error)"); return 1 }
            let manifest = (try? String(contentsOfFile: args[1], encoding: .utf8)) ?? ""
            for line in manifest.split(separator: "\n") {
                let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard cols.count >= 2, let audio = try? AudioProcessor.loadAudioAsFloatArray(fromPath: cols[1]) else { continue }
                let t0 = Date()
                let heard = (try? await engine.transcribe(AudioRecorder.normalized(audio), vocabulary: dictionary.map(\.written), mode: .auto))
                    ?? SpeechEngine.Result(text: "", engine: "error")
                let t1 = Date()
                let r = await Refiner.refine(RefineRequest(raw: heard.text, config: config, dictionary: dictionary), llm: llm)
                let t2 = Date()
                print([cols[0], String(format: "%.2f", t1.timeIntervalSince(t0)), String(format: "%.2f", t2.timeIntervalSince(t1)),
                       String(format: "%.2f", t2.timeIntervalSince(t0)), heard.engine, r.text.replacingOccurrences(of: "\n", with: " ")].joined(separator: "\t"))
            }
            return 0
        case "--stream":
            // --stream <manifest.tsv> → feeds each file at real-time speed like a live mic, then "releases the key".
            // TSV: id, wait after release (s), audio s, -, engine, text
            let engine = SpeechEngine()
            do { try await engine.load() } catch { print("load failed: \(error)"); return 1 }
            let pipeline = await DictationPipeline(engine: engine, llm: llm)
            let manifest = (try? String(contentsOfFile: args[1], encoding: .utf8)) ?? ""
            for line in manifest.split(separator: "\n") {
                let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard cols.count >= 2, let audio = try? AudioProcessor.loadAudioAsFloatArray(fromPath: cols[1]) else { continue }
                await pipeline.begin(.init(config: config, dictionary: dictionary, recognition: .auto, appName: nil, contextBefore: nil))
                let step = Voice.sampleRate / 2
                var fed = 0
                while fed < audio.count {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    fed = min(audio.count, fed + step)
                    let available = fed
                    await pipeline.tick(totalSamples: available) { range in Array(audio[range.clamped(to: 0..<available)]) }
                }
                let released = Date()
                let out = await pipeline.finish(audio: audio)
                print([cols[0], String(format: "%.2f", Date().timeIntervalSince(released)), String(format: "%.1f", Double(audio.count) / 16_000),
                       String(format: "%.2f", Date().timeIntervalSince(released)), out.engine, out.text.replacingOccurrences(of: "\n", with: " ")].joined(separator: "\t"))
            }
            return 0
        case "--refine":
            for text in args.dropFirst() {
                let r = await Refiner.refine(RefineRequest(raw: text, config: config, dictionary: dictionary), llm: llm)
                print("IN : \(text)")
                print("LLM: \(r.llmOutput ?? r.llmError ?? "-") \(r.llmAccepted == false ? "[REJECTED]" : "")")
                print(String(format: "OUT: %@  [%.2fs, %d fixes]\n", r.text, r.seconds, r.fixes))
            }
            return 0
        case "--transform":
            guard args.count >= 3, let t = config.transforms.first(where: { $0.name.lowercased() == args[1].lowercased() }) else {
                print("Usage: --transform <name> \"text\""); return 1
            }
            for text in args.dropFirst(2) {
                let t0 = Date()
                let out = (try? await Refiner.transform(text, with: t, temperature: config.temperature, llm: llm)) ?? "(failed)"
                print(String(format: "IN : %@\nOUT: %@  [%.2fs]\n", text, out, Date().timeIntervalSince(t0)))
            }
            return 0
        default:
            break
        }

        let files = args.dropFirst().filter { !$0.hasPrefix("--") }
        let transcriber = Transcriber()
        let t0 = Date()
        do { try await transcriber.load() } catch { print("Model failed to load: \(error.localizedDescription)"); return 1 }
        print(String(format: "[speech model ready in %.1fs]", Date().timeIntervalSince(t0)))

        for file in files {
            do {
                let audio = AudioRecorder.normalized(try AudioProcessor.loadAudioAsFloatArray(fromPath: file))
                let t1 = Date()
                let raw = try await transcriber.transcribe(audio, vocabulary: dictionary.map(\.written))
                var line = String(format: "%@  (%.1fs audio, %.2fs, rms %.4f)\n  raw: %@", (file as NSString).lastPathComponent,
                                  Double(audio.count) / 16_000, Date().timeIntervalSince(t1), AudioRecorder.rms(audio), raw)
                if needsLLM {
                    let r = await Refiner.refine(RefineRequest(raw: raw, config: config, dictionary: dictionary), llm: llm)
                    line += String(format: "\n  out: %@  [%.2fs]", r.text, r.seconds)
                }
                print(line)
            } catch {
                print("\(file): \(error.localizedDescription)")
            }
        }
        return 0
    }
}
