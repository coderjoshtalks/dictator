import Foundation

/// Appends timestamped lines to ~/Library/Application Support/Dictator/dictator.log (never dictated text).
enum Log {
    static let url = Paths.root.appendingPathComponent("dictator.log")
    private static let queue = DispatchQueue(label: "dictator.log")
    private static let formatter = ISO8601DateFormatter()

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            try? FileManager.default.createDirectory(at: Paths.root, withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
