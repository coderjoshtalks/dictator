import Foundation

// MARK: - Deterministic rules (always run; the fallback when the LLM is off or its output is rejected)

enum RuleCleaner {
    // Only unambiguous non-words: "aa", "matlab", "like" etc. are real Hindi/English words.
    private static let fillers = try! NSRegularExpression(
        pattern: #"(?i)(^|[\s,])(u+m+|u+h+m*|e+r+m+|h+m+|a+h+)(?=[\s,.!?]|$)[,]?"#)
    private static let newParagraph = try! NSRegularExpression(pattern: #"(?i)[,.]?\s*\bnew paragraph\b[,.]?\s*"#)
    private static let newLine = try! NSRegularExpression(pattern: #"(?i)[,.]?\s*\bnew line\b[,.]?\s*"#)
    private static let standaloneI = try! NSRegularExpression(pattern: #"(?<![\w'])i(?=('m|'ve|'ll|'d)?\b)(?![\w])"#)

    /// Before the LLM: dictionary replacements and (unless cleanup is off) filler removal.
    static func prepare(_ text: String, dictionary: [DictionaryEntry], removeFillers: Bool) -> String {
        let text = stripSoundLabels(text)
        var s = removeFillers ? replace(fillers, in: text, with: "$1") : text
        for entry in dictionary where entry.isReplacement {
            let pattern = #"(?i)\b"# + NSRegularExpression.escapedPattern(for: entry.spoken) + #"\b"#
            if let re = try? NSRegularExpression(pattern: pattern) {
                s = replace(re, in: s, with: NSRegularExpression.escapedTemplate(for: entry.written))
            }
        }
        return s.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"^[\s,]+"#, with: "", options: .regularExpression)
    }

    /// After the LLM: spoken "new line"/"new paragraph", "i" → "I", spacing and sentence capitals.
    static func finish(_ text: String, capitalizeFirst: Bool = true) -> String {
        var s = replace(newParagraph, in: text, with: "\n\n")
        s = replace(newLine, in: s, with: "\n")
        s = replace(standaloneI, in: s, with: "I")
        s = s.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #" +([,.!?])"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^[\s,]+"#, with: "", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespaces)
        return capitalizeSentences(s, capitalizeFirst: capitalizeFirst)
    }

    private static func capitalizeSentences(_ s: String, capitalizeFirst: Bool) -> String {
        var out = ""
        var capitalizeNext = capitalizeFirst
        for ch in s {
            if capitalizeNext, ch.isLetter {
                out.append(contentsOf: ch.uppercased())
                capitalizeNext = false
            } else {
                out.append(ch)
                if ".!?\n".contains(ch) { capitalizeNext = true }
                else if ch.isLetter { capitalizeNext = false }
            }
        }
        return out
    }

    private static func replace(_ re: NSRegularExpression, in s: String, with template: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    /// Sound labels Whisper writes for non-speech ("*sad*", "[Music]", "(beep)") — never something the user said.
    private static let soundLabels = try! NSRegularExpression(
        pattern: #"\*[^*\n]{1,30}\*|\[[^\]\n]{1,30}\]|\((?:music|applause|laugh\w*|beep\w*|click\w*|sound\w*|noise|silence|bell\w*|chime\w*|ding\w*|whistl\w*|static|inaudible|blank_audio)[^)\n]{0,20}\)"#,
        options: [.caseInsensitive])

    static func stripSoundLabels(_ text: String) -> String {
        replace(soundLabels, in: text, with: "")
            .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Whisper's well-known outputs for silence / noise.
    static func isHallucination(_ text: String) -> Bool {
        let t = stripSoundLabels(text).lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        let known = ["thank you", "thanks for watching", "thank you for watching", "you", "bye", "subscribe",
                     "please subscribe", "thank you so much", "so", "okay", "nan", "none", "null"]
        return t.isEmpty || known.contains(t)
    }
}

// MARK: - Local LLM server (llama.cpp's llama-server, Metal-accelerated)

final class LLMEngine {
    private var process: Process?
    private let port = Int.random(in: 41_000...48_000)
    private var ready = false
    private(set) var loadedModel: URL?

    var isRunning: Bool { ready && process?.isRunning == true }

    /// Starts the server with `model`, restarting it if a different model is running.
    func start(model: URL) async throws {
        if isRunning, loadedModel == model { return }
        stop()
        guard let server = Paths.llamaServer else { throw Self.error("llama.cpp runtime not installed") }
        guard FileManager.default.fileExists(atPath: model.path) else { throw Self.error("Model file not found: \(model.lastPathComponent)") }

        // A crashed previous run can leave a server behind.
        let cleanup = Process()
        cleanup.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        cleanup.arguments = ["-f", server.path]
        try? cleanup.run()
        cleanup.waitUntilExit()

        let p = Process()
        p.executableURL = server
        p.arguments = [
            "-m", model.path,
            "--host", "127.0.0.1", "--port", String(port),
            "-c", "8192", "-np", "1", "-ngl", "99",
            "--no-webui", "--log-disable",
            "--reasoning-budget", "0",
        ]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        process = p
        loadedModel = model
        for _ in 0..<240 {
            if await healthy() {
                ready = true
                _ = try? await chat(system: "Reply with OK.", examples: [], user: "hi", temperature: 0, maxTokens: 4)
                return
            }
            if !p.isRunning { break }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        stop()
        throw Self.error("The cleanup model did not start")
    }

    func stop() {
        process?.terminate()
        process = nil
        ready = false
        loadedModel = nil
    }

    private func healthy() async -> Bool {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
        req.timeoutInterval = 1
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    func chat(system: String, examples: [Example], user: String, temperature: Double, maxTokens: Int,
              timeout: TimeInterval = 20) async throws -> String {
        guard ready else { throw Self.error("The cleanup model is not running") }
        var messages: [[String: String]] = [["role": "system", "content": system]]
        for ex in examples {
            messages.append(["role": "user", "content": ex.input])
            messages.append(["role": "assistant", "content": ex.output])
        }
        messages.append(["role": "user", "content": user])
        let body: [String: Any] = [
            "messages": messages,
            "temperature": temperature,
            "max_tokens": maxTokens,
            "cache_prompt": true,
            "chat_template_kwargs": ["enable_thinking": false],
        ]
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = timeout
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (json["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any],
              let content = message["content"] as? String
        else { throw URLError(.cannotParseResponse) }
        return content
            .replacingOccurrences(of: #"(?s)<think>.*?</think>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "Dictator", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

// MARK: - The refinement pipeline

struct RefineRequest {
    var raw: String
    var config: RefinementConfig
    var dictionary: [DictionaryEntry]
    var appName: String? = nil
    /// Text already in the field before the cursor (from Accessibility), for context and capitalization.
    var contextBefore: String? = nil
}

struct RefineResult {
    var text: String
    var prepared: String
    var renderedPrompt: String?
    var llmOutput: String?
    var llmAccepted: Bool?
    var llmError: String?
    var fixes: Int
    var seconds: Double
}

enum Refiner {
    static func refine(_ req: RefineRequest, llm: LLMEngine?) async -> RefineResult {
        let start = Date()
        let level = req.config.level
        let prepared = RuleCleaner.prepare(req.raw, dictionary: req.dictionary, removeFillers: level != .none)
        let continuing = isContinuation(req.contextBefore)

        var result = RefineResult(text: "", prepared: prepared, fixes: 0, seconds: 0)
        var body = prepared
        let worthAsking = level == .medium || req.config.alwaysUseLLM || needsModel(raw: req.raw, prepared: prepared)
        if level != .none, worthAsking, let llm, llm.isRunning, !prepared.isEmpty {
            let system = renderPrompt(req.config.prompt(for: level), request: req)
            result.renderedPrompt = system
            let examples = req.config.examples(for: level).map {
                Example(input: "<transcript>\($0.input)</transcript>", output: $0.output)
            }
            let words = prepared.split(whereSeparator: \.isWhitespace).count
            do {
                var out = try await llm.chat(system: system, examples: examples,
                                             user: "<transcript>\(prepared)</transcript>",
                                             temperature: req.config.temperature,
                                             maxTokens: min(2048, words * 3 + 48), timeout: 15)
                out = out.replacingOccurrences(of: #"</?transcript>"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                result.llmOutput = out
                let ok = accept(original: prepared, rewrite: out, level: level, guardLevel: req.config.guardLevel)
                result.llmAccepted = ok
                if ok { body = out }
            } catch {
                result.llmError = error.localizedDescription
            }
        }
        result.text = RuleCleaner.finish(body, capitalizeFirst: !continuing)
        result.fixes = wordEdits(req.raw, result.text)
        result.seconds = Date().timeIntervalSince(start)
        return result
    }

    /// Light cleanup only calls the model when rules can't do the job: self-corrections, stutters, lists, long or unpunctuated text.
    static func needsModel(raw: String, prepared: String) -> Bool {
        let lower = " " + raw.lowercased().replacingOccurrences(of: #"[^\p{L}\p{N}' ]"#, with: " ", options: .regularExpression) + " "
        let cues = [" no wait ", " wait no ", " actually ", " sorry ", " i mean ", " scratch that ", " nahi nahi ", " matlab ",
                    " rather ", " correction ", " na na ", " first ", " second ", " point one ", " number one ", " um ", " uh "]
        if cues.contains(where: lower.contains) { return true }
        let words = lower.split(separator: " ")
        if words.count >= 40 { return true }
        if zip(words, words.dropFirst()).contains(where: { $0 == $1 && $0.count > 2 }) { return true }
        let trimmed = prepared.trimmingCharacters(in: .whitespaces)
        if words.count >= 6, let last = trimmed.last, !".?!".contains(last) { return true }
        return false
    }

    /// Fills {{dictionary}}, {{app}} and {{context}} in the user's prompt template.
    static func renderPrompt(_ template: String, request: RefineRequest) -> String {
        let words = Array(Set(request.dictionary.map(\.written))).sorted()
        let dictionary = words.isEmpty ? "" : "Spell these names and terms exactly like this: \(words.joined(separator: ", "))."
        let app = request.appName.map { "The text will be typed into \($0)." } ?? ""
        var context = ""
        if request.config.useScreenContext, let before = request.contextBefore?.trimmingCharacters(in: .whitespacesAndNewlines), !before.isEmpty {
            context = "Text already written just before the cursor (context only, never repeat it): \"\(before.suffix(400))\""
            if isContinuation(before) { context += " The dictation continues that sentence, so don't start with a capital letter unless the word needs one." }
        }
        let rendered = template
            .replacingOccurrences(of: "{{dictionary}}", with: dictionary)
            .replacingOccurrences(of: "{{app}}", with: app)
            .replacingOccurrences(of: "{{context}}", with: context)
        return rendered.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^\n"#, with: "", options: .regularExpression)
    }

    /// Runs a transform prompt over `text` (the user's selection or a fresh dictation).
    static func transform(_ text: String, with transform: Transform, temperature: Double, llm: LLMEngine) async throws -> String {
        var system = """
        You are a rewriting tool. You receive an instruction and a text, and you return the text rewritten according to \
        the instruction. Return only the rewritten text: no preamble, no explanations, no quotes, no code fences. \
        Never change the language unless the instruction explicitly asks you to translate: if the text mixes Hindi and \
        English (Hinglish), your output must mix them the same way, in Roman script. Never use Devanagari unless asked.
        """
        let samples = transform.samples.trimmingCharacters(in: .whitespacesAndNewlines)
        if !samples.isEmpty { system += "\n\nMatch the voice and style of these writing samples by the user:\n\(samples)" }
        // One worked example shows small models that the output must actually change.
        let example = Example(
            input: request("Fix grammar and make it clear and concise. Keep the language mix.",
                           "so me and him was going to market but it was closed only so we come back home"),
            output: "He and I were going to the market, but it was closed, so we came back home.")
        let words = text.split(whereSeparator: \.isWhitespace).count
        let out = try await llm.chat(system: system, examples: [example], user: request(transform.prompt, text),
                                     temperature: temperature, maxTokens: min(4096, words * 4 + 256), timeout: 60)
        return out.replacingOccurrences(of: #"^(Rewritten text:|Output:)\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^```[a-z]*\n|\n```$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func request(_ instruction: String, _ text: String) -> String {
        "Instruction: \(instruction)\n\nText:\n\(text)\n\nRewritten text:"
    }

    /// True when the cursor sits mid-sentence (so the dictation shouldn't start with a capital).
    static func isContinuation(_ before: String?) -> Bool {
        guard let last = before?.trimmingCharacters(in: .whitespaces).last else { return false }
        return !".!?\n:;".contains(last)
    }

    /// Guards against the classic small-model failures: answering the text, translating it,
    /// switching to Devanagari, or rewriting far beyond the chosen cleanup level.
    static func accept(original: String, rewrite: String, level: CleanupLevel, guardLevel: GuardLevel) -> Bool {
        guard !rewrite.isEmpty else { return false }
        let hasDevanagari = { (s: String) in s.unicodeScalars.contains { (0x0900...0x097F).contains($0.value) } }
        if hasDevanagari(rewrite) && !hasDevanagari(original) { return false }
        if guardLevel == .off { return true }

        let strict = guardLevel == .strict
        let a = original.split(whereSeparator: \.isWhitespace).count
        let b = rewrite.split(whereSeparator: \.isWhitespace).count
        let maxGrowth = strict ? 1.1 : 1.25
        let minShrink = level == .medium ? (strict ? 0.35 : 0.25) : (strict ? 0.55 : 0.45)
        if a >= 6 && (Double(b) > Double(a) * maxGrowth + 3 || Double(b) < Double(a) * minShrink) { return false }

        // Most of the rewrite's words should come from what was actually said.
        let norm = { (s: String) in Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)) }
        let novel = Double(norm(rewrite).subtracting(norm(original)).count) / Double(max(norm(rewrite).count, 1))
        let maxNovel = level == .medium ? (strict ? 0.4 : 0.6) : (strict ? 0.25 : 0.4)
        return norm(rewrite).count < 4 || novel <= maxNovel
    }

    /// Word-level edit distance: the number of "fixes" between what was heard and what was typed.
    static func wordEdits(_ a: String, _ b: String) -> Int {
        let x = a.lowercased().split { !$0.isLetter && !$0.isNumber }
        let y = b.lowercased().split { !$0.isLetter && !$0.isNumber }
        if x.isEmpty || y.isEmpty { return max(x.count, y.count) }
        var prev = Array(0...y.count)
        for i in 1...x.count {
            var cur = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                cur[j] = x[i - 1] == y[j - 1] ? prev[j - 1] : 1 + min(prev[j - 1], prev[j], cur[j - 1])
            }
            prev = cur
        }
        return prev[y.count]
    }
}
