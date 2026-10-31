import AppKit
import ApplicationServices

/// Learns from the user's corrections: after a dictation is pasted, the text field is checked a few times over the next
/// minute. If a dictated word was replaced by a similar-looking one ("arina" → "Arena"), that pair is added to the
/// dictionary, which both biases recognition and guarantees the replacement next time.
@MainActor
final class Learner {
    private struct Watch {
        let element: AXUIElement
        let pasted: String
        var baseline: String
    }

    /// Called with (heard, corrected) for each new correction.
    var onLearn: ((String, String) -> Void)?
    /// Words the user removed from the learned list are never learned again.
    var isIgnored: ((String) -> Bool)?

    /// Start watching the focused field for edits to `pasted`.
    func watch(pasted: String) {
        let text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.split(separator: " ").count >= 1 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self, let element = FocusContext.focusedElement(), let value = FocusContext.value(of: element),
                  value.contains(text) else { return }
            var watch = Watch(element: element, pasted: text, baseline: value)
            for delay in [10.0, 30.0, 60.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, let now = FocusContext.value(of: watch.element), now != watch.baseline else { return }
                    for (heard, corrected) in Self.corrections(before: watch.baseline, after: now, pasted: watch.pasted)
                    where !(self.isIgnored?(heard) ?? false) {
                        self.onLearn?(heard, corrected)
                    }
                    watch.baseline = now
                }
            }
        }
    }

    // MARK: Diffing

    private static let commonWords: Set<String> = Set("""
    the a an and or but if of to in on at for with from by as is are was were be been it its this that these those i you he she we
    they me him her us them my your our their not no yes so do does did have has had will would can could should may might just
    also very too then than there here what which who how when where why all any some more most much many one two hai ki ka ke ko
    """.split(whereSeparator: \.isWhitespace).map(String.init))

    /// Word substitutions inside the dictated text between `before` and `after`.
    static func corrections(before: String, after: String, pasted: String) -> [(String, String)] {
        // Narrow to the region that changed: strip the common prefix and suffix.
        let b = Array(before), a = Array(after)
        var prefix = 0
        while prefix < min(b.count, a.count), b[prefix] == a[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(b.count, a.count) - prefix, b[b.count - 1 - suffix] == a[a.count - 1 - suffix] { suffix += 1 }
        // Widen to whole words.
        while prefix > 0, b[prefix - 1].isLetter || b[prefix - 1].isNumber { prefix -= 1 }
        while suffix > 0, b[b.count - suffix].isLetter || b[b.count - suffix].isNumber { suffix -= 1 }
        let oldRegion = String(b[prefix..<(b.count - suffix)])
        let newRegion = String(a[prefix..<(a.count - suffix)])

        // Only learn from edits inside what Dictator typed.
        guard let pastedRange = before.range(of: pasted) else { return [] }
        let pastedStart = before.distance(from: before.startIndex, to: pastedRange.lowerBound)
        let pastedEnd = pastedStart + pasted.count
        guard prefix >= pastedStart, b.count - suffix <= pastedEnd else { return [] }

        let oldWords = words(oldRegion), newWords = words(newRegion)
        guard !oldWords.isEmpty, !newWords.isEmpty, oldWords.count <= 4, newWords.count <= 4 else { return [] }
        // A big rewrite is an edit of meaning, not a correction of a misheard word.
        if oldWords.count * 2 > max(words(pasted).count, 1) && words(pasted).count > 2 { return [] }

        var pairs: [(String, String)] = []
        if oldWords.count == 1 && newWords.count == 1 {
            if isCorrection(oldWords[0], newWords[0]) { pairs.append((oldWords[0].lowercased(), newWords[0])) }
        } else if oldWords.count == newWords.count {
            let changed = zip(oldWords, newWords).filter { $0 != $1 }
            let caseOnly = changed.filter { $0.lowercased() == $1.lowercased() }
            if !caseOnly.isEmpty && caseOnly.count < changed.count {
                // "voice arina" → "Voice Arena" is one name: learn the phrase, never "voice" → "Voice" on its own.
                let o = oldWords.joined(separator: " "), n = newWords.joined(separator: " ")
                if isCorrection(o, n) { pairs.append((o.lowercased(), n)) }
            } else {
                for (o, n) in changed where o.lowercased() != n.lowercased() && isCorrection(o, n) { pairs.append((o.lowercased(), n)) }
            }
        } else {
            // "voice arina" → "VoiceArena" / "Voice Arena": learn the whole phrase.
            let o = oldWords.joined(separator: " "), n = newWords.joined(separator: " ")
            if isCorrection(o, n) { pairs.append((o.lowercased(), n)) }
        }
        return pairs
    }

    private static func words(_ s: String) -> [String] {
        s.split { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "-" }.map(String.init)
    }

    private static func isCorrection(_ old: String, _ new: String) -> Bool {
        let o = old.lowercased(), n = new.lowercased()
        guard o != n || old != new else { return false }
        guard o.count >= 3, n.count >= 3, !commonWords.contains(o), !commonWords.contains(n) else { return false }
        guard !o.contains(where: \.isNumber), !n.contains(where: \.isNumber) else { return false }
        if o == n { return new.first?.isUppercase == true && old.first?.isUppercase == false && !new.contains(" ") }  // capitalised a name
        // Similar spelling or sound: a mishearing, not a different word choice.
        return Double(distance(o, n)) / Double(max(o.count, n.count)) <= 0.5
    }

    private static func distance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        var prev = Array(0...y.count)
        for i in 1...max(x.count, 1) where !x.isEmpty {
            var cur = [i] + Array(repeating: 0, count: y.count)
            for j in 1...max(y.count, 1) where !y.isEmpty {
                cur[j] = x[i - 1] == y[j - 1] ? prev[j - 1] : 1 + min(prev[j - 1], prev[j], cur[j - 1])
            }
            prev = cur
        }
        return prev[y.count]
    }
}
