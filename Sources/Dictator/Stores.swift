import Foundation
import ServiceManagement

/// Reads/writes a Codable value as JSON in ~/Library/Application Support/Dictator.
enum JSONFile {
    static func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: Paths.root.appendingPathComponent(name)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, to name: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? FileManager.default.createDirectory(at: Paths.root, withIntermediateDirectories: true)
        try? data.write(to: Paths.root.appendingPathComponent(name), options: .atomic)
    }
}

// MARK: - Simple preferences

final class Settings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var hotkey: Hotkey { didSet { defaults.set(hotkey.rawValue, forKey: "hotkey") } }
    @Published var sounds: Bool { didSet { defaults.set(sounds, forKey: "sounds") } }
    @Published var showBar: Bool { didSet { defaults.set(showBar, forKey: "showBar") } }
    @Published var microphoneUID: String { didSet { defaults.set(microphoneUID, forKey: "microphoneUID") } }
    @Published var recognition: RecognitionMode { didSet { defaults.set(recognition.rawValue, forKey: "recognition") } }
    @Published var keepLastRecording: Bool { didSet { defaults.set(keepLastRecording, forKey: "keepLastRecording") } }
    /// One entry per line: "Kubernetes" or "spoken form -> Written Form".
    @Published var dictionaryText: String { didSet { defaults.set(dictionaryText, forKey: "dictionary") } }
    /// Corrections learned automatically from edits ("heard -> Corrected"); also present in `dictionaryText`.
    @Published var learned: [String] { didSet { defaults.set(learned, forKey: "learned") } }
    @Published var learnFromEdits: Bool { didSet { defaults.set(learnFromEdits, forKey: "learnFromEdits") } }
    private var ignoredLearned: [String] { didSet { defaults.set(ignoredLearned, forKey: "ignoredLearned") } }

    init() {
        hotkey = Hotkey(rawValue: defaults.string(forKey: "hotkey") ?? "") ?? .fn
        sounds = defaults.object(forKey: "sounds") as? Bool ?? true
        showBar = defaults.object(forKey: "showBar") as? Bool ?? true
        microphoneUID = defaults.string(forKey: "microphoneUID") ?? ""
        recognition = RecognitionMode(rawValue: defaults.string(forKey: "recognition") ?? "") ?? .auto
        keepLastRecording = defaults.object(forKey: "keepLastRecording") as? Bool ?? true
        dictionaryText = defaults.string(forKey: "dictionary") ?? ""
        learned = defaults.stringArray(forKey: "learned") ?? []
        learnFromEdits = defaults.object(forKey: "learnFromEdits") as? Bool ?? true
        ignoredLearned = defaults.stringArray(forKey: "ignoredLearned") ?? []
    }

    func isIgnored(_ heard: String) -> Bool { ignoredLearned.contains(heard.lowercased()) }

    /// Adds a learned correction (no duplicates; a newer correction for the same word replaces the old one).
    func learn(heard: String, corrected: String) {
        let key = heard.lowercased()
        let line = "\(key) -> \(corrected)"
        guard !learned.contains(line) else { return }
        forget(heard: key, ignore: false)
        learned.append(line)
        dictionaryText += (dictionaryText.isEmpty || dictionaryText.hasSuffix("\n") ? "" : "\n") + line
    }

    /// Removes a learned correction; `ignore` stops it from being learned again.
    func forget(heard: String, ignore: Bool = true) {
        let key = heard.lowercased()
        let isKey = { (line: String) in DictionaryEntry.parse(line)?.spoken.lowercased() == key }
        learned.removeAll(where: isKey)
        dictionaryText = dictionaryText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .filter { !isKey($0) || !$0.contains("->") }.joined(separator: "\n")
        if ignore, !ignoredLearned.contains(key) { ignoredLearned.append(key) }
    }

    var dictionary: [DictionaryEntry] {
        dictionaryText.split(separator: "\n").compactMap { DictionaryEntry.parse(String($0)) }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            try? newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        }
    }
}

// MARK: - LLM / transforms configuration

final class ConfigStore: ObservableObject {
    private static let file = "refinement.json"
    @Published var config: RefinementConfig { didSet { if config != oldValue { JSONFile.save(config, to: Self.file) } } }

    init() {
        config = JSONFile.load(RefinementConfig.self, from: Self.file) ?? RefinementConfig()
    }

    func resetPrompt(for level: CleanupLevel) {
        config.prompts[level.rawValue] = Defaults.prompts[level.rawValue]
        config.examples[level.rawValue] = Defaults.examples[level.rawValue]
    }

    /// Transforms that get a ⌃⌥1…8 shortcut, in order.
    var activeTransforms: [Transform] {
        guard config.transformsEnabled else { return [] }
        return Array(config.transforms.filter(\.enabled).prefix(8))
    }
}

// MARK: - History

struct HistoryItem: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case dictation, transform }
    var id = UUID()
    var kind: Kind = .dictation
    var date: Date
    /// Dictation: what the speech model heard. Transform: the original selected text.
    var raw: String
    var text: String
    var app: String?
    var seconds: Double
    var transform: String? = nil
    var cleanup: String? = nil
    var engine: String? = nil
}

final class History: ObservableObject {
    private static let file = "history.json"
    @Published private(set) var items: [HistoryItem] = []
    private let limit = 500

    init() {
        items = JSONFile.load([HistoryItem].self, from: Self.file) ?? []
    }

    func add(_ item: HistoryItem) {
        items.insert(item, at: 0)
        if items.count > limit { items.removeLast(items.count - limit) }
        JSONFile.save(items, to: Self.file)
    }

    func delete(_ item: HistoryItem) {
        items.removeAll { $0.id == item.id }
        JSONFile.save(items, to: Self.file)
    }

    func clear() {
        items.removeAll()
        JSONFile.save(items, to: Self.file)
    }
}

// MARK: - Insights (lifetime counters; history is capped, these are not)

struct StatsData: Codable {
    var words = 0
    var seconds = 0.0
    var fixes = 0
    var dictations = 0
    var transforms = 0
    var wordsByApp: [String: Int] = [:]
    var wordsByDay: [String: Int] = [:]   // "yyyy-MM-dd" → words
}

final class Stats: ObservableObject {
    private static let file = "stats.json"
    @Published private(set) var data: StatsData

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    init() {
        data = JSONFile.load(StatsData.self, from: Self.file) ?? StatsData()
    }

    func recordDictation(words: Int, seconds: Double, fixes: Int, app: String?) {
        data.words += words
        data.seconds += seconds
        data.fixes += fixes
        data.dictations += 1
        data.wordsByApp[app ?? "Unknown", default: 0] += words
        data.wordsByDay[Self.dayFormatter.string(from: Date()), default: 0] += words
        JSONFile.save(data, to: Self.file)
    }

    func recordTransform() {
        data.transforms += 1
        JSONFile.save(data, to: Self.file)
    }

    var wordsPerMinute: Int {
        data.seconds > 5 ? Int((Double(data.words) / (data.seconds / 60)).rounded()) : 0
    }

    /// Minutes saved versus typing at 40 wpm.
    var minutesSaved: Int {
        max(0, Int((Double(data.words) / 40 - data.seconds / 60).rounded()))
    }

    private var activeDays: Set<String> { Set(data.wordsByDay.filter { $0.value > 0 }.keys) }

    var currentStreak: Int {
        let cal = Calendar(identifier: .gregorian)
        var day = Date()
        // Today not dictated yet still keeps yesterday's streak alive.
        if !activeDays.contains(Self.dayFormatter.string(from: day)) {
            day = cal.date(byAdding: .day, value: -1, to: day)!
        }
        var streak = 0
        while activeDays.contains(Self.dayFormatter.string(from: day)) {
            streak += 1
            day = cal.date(byAdding: .day, value: -1, to: day)!
        }
        return streak
    }

    var longestStreak: Int {
        let cal = Calendar(identifier: .gregorian)
        let dates = activeDays.compactMap { Self.dayFormatter.date(from: $0) }.sorted()
        var best = 0, run = 0
        var previous: Date?
        for date in dates {
            if let p = previous, cal.dateComponents([.day], from: p, to: date).day == 1 { run += 1 } else { run = 1 }
            best = max(best, run)
            previous = date
        }
        return best
    }
}
