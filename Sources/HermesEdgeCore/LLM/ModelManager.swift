import Foundation
import Combine

/// Manages on-device storage, background downloading, and integrity checking
/// for the quantized Gemma 4 E4B (4-bit) edge model.
@MainActor
public final class ModelManager: NSObject, ObservableObject, URLSessionDownloadDelegate, @unchecked Sendable {
    public static let shared = ModelManager()

    public nonisolated static let modelFilename = "gemma-4-E4B-it-Q4_K_M.gguf"
    public nonisolated static let defaultDownloadURL = URL(string: "https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF/resolve/main/gemma-4-E4B-it-Q4_K_M.gguf")!

    @Published public private(set) var isModelReady: Bool = false
    @Published public private(set) var isDownloading: Bool = false
    @Published public private(set) var downloadProgress: Double = 0.0 // 0.0 to 1.0
    @Published public private(set) var downloadSpeedDescription: String = ""
    @Published public private(set) var errorMessage: String? = nil

    private var downloadTask: URLSessionDownloadTask?
    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.quincearch.HermesEdge.modelDownload")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    public nonisolated static var defaultModelLocalURL: URL {
        // 1. Check user-accessible Documents directory (iTunes File Sharing / Files app)
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let docFile = docs.appendingPathComponent(modelFilename)
            if FileManager.default.fileExists(atPath: docFile.path) {
                return docFile
            }
            let docSub = docs.appendingPathComponent("models").appendingPathComponent(modelFilename)
            if FileManager.default.fileExists(atPath: docSub.path) {
                return docSub
            }

            // Also check for any .gguf file > 500MB directly in Documents
            if let files = try? FileManager.default.contentsOfDirectory(atPath: docs.path) {
                for file in files where file.hasSuffix(".gguf") {
                    let candidate = docs.appendingPathComponent(file)
                    let size = (try? FileManager.default.attributesOfItem(atPath: candidate.path)[.size] as? Int64) ?? 0
                    if size > 500_000_000 {
                        return candidate
                    }
                }
            }
        }

        // 2. Default to internal Application Support directory
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let modelsDir = appSupport.appendingPathComponent("models", isDirectory: true)
        if !FileManager.default.fileExists(atPath: modelsDir.path) {
            try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        }
        return modelsDir.appendingPathComponent(modelFilename)
    }

    public nonisolated var modelLocalURL: URL {
        Self.defaultModelLocalURL
    }

    public override init() {
        super.init()
        checkModelStatus()
    }

    public func checkModelStatus() {
        let path = modelLocalURL.path
        if FileManager.default.fileExists(atPath: path) {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
               let size = attrs[.size] as? Int64,
               size > 500_000_000 { // Must be at least ~500MB (quantized weights)
                isModelReady = true
                downloadProgress = 1.0
                AppLogger.shared.log("ModelManager: Valid model detected at \(path) (\(size / (1024*1024)) MB)", tag: "MODEL")
                return
            }
        }
        isModelReady = false
        AppLogger.shared.log("ModelManager: No model weights found yet (checked \(path))", tag: "MODEL")
    }

    /// Starts streaming the 4-bit Gemma model from Hugging Face directly to local storage.
    public func startDownload(from url: URL = defaultDownloadURL) {
        guard !isDownloading && !isModelReady else { return }
        errorMessage = nil
        isDownloading = true
        downloadProgress = 0.0

        downloadTask = urlSession.downloadTask(with: url)
        downloadTask?.resume()
    }

    public func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
        downloadProgress = 0.0
    }

    // MARK: - URLSessionDownloadDelegate

    public nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let progress = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0.0

        let mbWritten = Double(totalBytesWritten) / (1024 * 1024)
        let mbTotal = Double(totalBytesExpectedToWrite) / (1024 * 1024)

        Task { @MainActor in
            self.downloadProgress = progress
            self.downloadSpeedDescription = String(format: "%.1f MB / %.1f MB (%.0f%%)", mbWritten, mbTotal, progress * 100)
        }
    }

    public nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            let finalPath = self.modelLocalURL

            if FileManager.default.fileExists(atPath: finalPath.path) {
                try FileManager.default.removeItem(at: finalPath)
            }
            try FileManager.default.moveItem(at: location, to: finalPath)

            Task { @MainActor in
                self.isDownloading = false
                self.isModelReady = true
                self.downloadProgress = 1.0
            }
        } catch {
            Task { @MainActor in
                self.isDownloading = false
                self.errorMessage = "Failed to store model file: \(error.localizedDescription)"
            }
        }
    }

    public nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        if let error = error {
            Task { @MainActor in
                self.isDownloading = false
                self.errorMessage = error.localizedDescription
            }
        }
    }
}
