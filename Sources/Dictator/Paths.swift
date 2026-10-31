import Foundation

/// Where Dictator keeps its models and data: ~/Library/Application Support/Dictator
enum Paths {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Dictator", isDirectory: true)
    }()

    static let speechModel = root.appendingPathComponent("Models/hinglish-apex-w6", isDirectory: true)
    static let englishModel = root.appendingPathComponent("Models/whisper-turbo-632", isDirectory: true)
    static let models = root.appendingPathComponent("Models", isDirectory: true)
    static let lastRecording = root.appendingPathComponent("last-recording.wav")

    /// llama-server ships inside Dictator.app (Contents/Resources/llama); a dev build falls back to Application Support.
    static var llamaServer: URL? {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("llama/llama-server"))
        }
        let runtime = root.appendingPathComponent("Runtime", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(at: runtime, includingPropertiesForKeys: nil)) ?? []
        candidates += ([runtime] + entries.filter(\.hasDirectoryPath)).map { $0.appendingPathComponent("llama-server") }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// The Hinglish model is required; the English model is an accuracy upgrade for pure English.
    static var speechModelInstalled: Bool {
        ModelDownloader.isInstalled(Assets.speechHinglish, in: models)
    }

    static var englishModelInstalled: Bool {
        ModelDownloader.isInstalled(Assets.speechEnglish, in: models)
    }
}
