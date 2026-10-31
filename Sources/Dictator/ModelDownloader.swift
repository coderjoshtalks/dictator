import CryptoKit
import Foundation

/// Downloads model files, verifies each one's SHA-256, and moves them into place.
/// Files already present with the right size and checksum are skipped, so an interrupted setup resumes.
@MainActor
final class ModelDownloader: NSObject, ObservableObject, URLSessionDownloadDelegate {
    @Published private(set) var progress: [String: Double] = [:]   // job key → 0…1
    @Published private(set) var errors: [String: String] = [:]

    private var current: (key: String, doneBytes: Int64, totalBytes: Int64)?
    private var continuation: CheckedContinuation<URL, Error>?
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)

    func isDownloading(_ key: String) -> Bool { progress[key] != nil }
    var isBusy: Bool { !progress.isEmpty }

    /// Downloads `files` into `folder`. Returns true when every file is in place and verified.
    func download(_ files: [RemoteFile], into folder: URL, key: String) async -> Bool {
        guard !isBusy else { return false }
        errors[key] = nil
        progress[key] = 0
        defer { progress[key] = nil; current = nil }
        let total = files.reduce(0) { $0 + $1.size }
        var done: Int64 = 0
        do {
            for file in files {
                let dest = folder.appendingPathComponent(file.path)
                if await Self.isValid(dest, file) {
                    done += file.size
                    progress[key] = Double(done) / Double(total)
                    continue
                }
                current = (key, done, total)
                let temp: URL = try await withCheckedThrowingContinuation { cont in
                    continuation = cont
                    session.downloadTask(with: file.url).resume()
                }
                guard await Self.isValid(temp, file) else {
                    try? FileManager.default.removeItem(at: temp)
                    throw Self.error("Checksum mismatch for \(file.path) — please try again")
                }
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: temp, to: dest)
                done += file.size
                progress[key] = Double(done) / Double(total)
            }
            return true
        } catch {
            errors[key] = error.localizedDescription
            return false
        }
    }

    nonisolated static func isInstalled(_ files: [RemoteFile], in folder: URL) -> Bool {
        files.allSatisfy { file in
            let attrs = try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(file.path).path)
            return (attrs?[.size] as? NSNumber)?.int64Value == file.size
        }
    }

    private static func isValid(_ url: URL, _ file: RemoteFile) async -> Bool {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard (attrs?[.size] as? NSNumber)?.int64Value == file.size else { return false }
        return await Task.detached { (try? sha256(of: url)) == file.sha256 }.value
    }

    nonisolated private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "Dictator", code: 3, userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: URLSessionDownloadDelegate (delivered on the main queue)

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        Task { @MainActor in
            guard let current else { return }
            progress[current.key] = Double(current.doneBytes + totalBytesWritten) / Double(max(current.totalBytes, 1))
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temp file is deleted when this returns, so move it somewhere we own first.
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let moved = (try? FileManager.default.moveItem(at: location, to: kept)) != nil
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        Task { @MainActor in
            let cont = continuation
            continuation = nil
            if moved && status == 200 { cont?.resume(returning: kept) }
            else { cont?.resume(throwing: Self.error("Download failed (HTTP \(status)). Check your internet connection.")) }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        Task { @MainActor in
            let cont = continuation
            continuation = nil
            cont?.resume(throwing: error)
        }
    }
}
