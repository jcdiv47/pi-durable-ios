import CoreML
import CryptoKit
import Foundation
import Network
import os

/// MobileCLIP's compiled encoders and the CLIP tokenizer's files, wherever they are (docs/adr/0010-photo-search.md):
/// built into the app by `scripts/fetch-mobileclip.sh`, or downloaded in Settings › Photo Search.
public struct ClipModelFiles: Sendable, Equatable {
    /// The name the photo index records, so vectors from another model are never mixed in (`PhotoVectors`).
    public var model: String
    public var image: URL
    public var text: URL
    public var vocab: URL
    public var merges: URL

    /// The encoders `scripts/fetch-mobileclip.sh` put in the app (`MobileCLIPImage`, `MobileCLIPText`), or nil when the
    /// app was built without them.
    public static func bundled(_ bundle: Bundle = .main) -> ClipModelFiles? {
        guard let image = bundle.url(forResource: "MobileCLIPImage", withExtension: "mlmodelc"),
              let text = bundle.url(forResource: "MobileCLIPText", withExtension: "mlmodelc"),
              let vocab = bundle.url(forResource: "clip-vocab", withExtension: "json"),
              let merges = bundle.url(forResource: "clip-merges", withExtension: "txt")
        else { return nil }
        let model = bundle.url(forResource: "mobileclip-variant", withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            .map { "mobileclip-" + $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? "mobileclip"
        return ClipModelFiles(model: model, image: image, text: text, vocab: vocab, merges: merges)
    }

    /// The app's own encoders if it was built with them, else the downloaded ones.
    public static func installed() -> ClipModelFiles? {
        bundled() ?? ClipModelDownload.installed()
    }
}

/// Downloads MobileCLIP-S2 and the CLIP tokenizer into Application Support, so the app doesn't have to carry them
/// (docs/adr/0011-download-mobileclip.md). A background `URLSession` does the transfers: they go on while Pi is
/// suspended or not running, Wi-Fi only, and iOS relaunches Pi in the background when they finish. The files are
/// pinned to Hugging Face commits and checked against their SHA-256; Core ML then compiles the encoders, which needs
/// Pi running (the next time it opens, if the transfers finished while it was away). Files already checked are kept
/// when a download fails or is cancelled.
public actor ClipModelDownload {
    public enum State: Sendable, Equatable {
        case notDownloaded
        case downloading(received: Int64, total: Int64)
        /// Downloading, but not on Wi-Fi; iOS goes on by itself.
        case waitingForWiFi(received: Int64, total: Int64)
        /// Checking and compiling the downloaded files.
        case installing
        case installed
        case failed(String)
    }

    struct Remote: Sendable {
        let url: URL
        /// Inside the staging directory.
        let path: String
        let size: Int64
        let sha256: String
    }

    public static let shared = ClipModelDownload()

    static let variant = "s2"
    private static let mobileCLIP = "https://huggingface.co/apple/coreml-mobileclip/resolve/3e0a7bfb9fe83da8a3efaa3fd8f7df24214bb947/"
    private static let clip = "https://huggingface.co/openai/clip-vit-base-patch32/resolve/3d74acf9a28c67741b2f4f2ea7635f0aaf6f0268/"

    /// The same files as `scripts/fetch-mobileclip.sh`, at fixed commits.
    static let files: [Remote] = [
        remote(mobileCLIP, "mobileclip_s2_image.mlpackage/Manifest.json", "MobileCLIPImage.mlpackage/Manifest.json",
               617, "6a1a3f93b8dca6c237dbb5dc7b19bb3c987042d14860288304986c099d8796b6"),
        remote(mobileCLIP, "mobileclip_s2_image.mlpackage/Data/com.apple.CoreML/model.mlmodel", "MobileCLIPImage.mlpackage/Data/com.apple.CoreML/model.mlmodel",
               299_056, "2aeb3359f6cde65e9f9248ec2a742e9939bd4bbf48c2f55fcd255b4504d96a1b"),
        remote(mobileCLIP, "mobileclip_s2_image.mlpackage/Data/com.apple.CoreML/weights/weight.bin", "MobileCLIPImage.mlpackage/Data/com.apple.CoreML/weights/weight.bin",
               71_397_632, "6cbc7fb06b6072c1cae9c4496d67e0e6217adbf726dfeb82e44d4efe87c34c00"),
        remote(mobileCLIP, "mobileclip_s2_text.mlpackage/Manifest.json", "MobileCLIPText.mlpackage/Manifest.json",
               617, "ea6a189d82fee2ee36eadb99022cda66a7f6b50a4bf9cc1d9541c7ea3b4242a0"),
        remote(mobileCLIP, "mobileclip_s2_text.mlpackage/Data/com.apple.CoreML/model.mlmodel", "MobileCLIPText.mlpackage/Data/com.apple.CoreML/model.mlmodel",
               128_127, "b8651b6d030bae419a9548b41c8fae11f96b59cfa21b6e532a4c4434522b4b80"),
        remote(mobileCLIP, "mobileclip_s2_text.mlpackage/Data/com.apple.CoreML/weights/weight.bin", "MobileCLIPText.mlpackage/Data/com.apple.CoreML/weights/weight.bin",
               126_866_880, "8e8d5454f104b6cbb58d98bf11e038ff1f1943599efea111260a832f094cd0ce"),
        remote(clip, "vocab.json", "clip-vocab.json", 862_328, "5047b556ce86ccaf6aa22b3ffccfc52d391ea4accdab9c2f2407da5b742d4363"),
        remote(clip, "merges.txt", "clip-merges.txt", 524_657, "f526393189112391ce6f9795d4695f704121ce452c3aad1f5335cc41337eba85"),
    ]

    public static let totalBytes: Int64 = files.reduce(0) { $0 + $1.size }

    private static func remote(_ base: String, _ path: String, _ local: String, _ size: Int64, _ sha256: String) -> Remote {
        Remote(url: URL(string: base + path)!, path: local, size: size, sha256: sha256)
    }

    /// `Application Support/mobileclip`, out of iCloud backups.
    public static let defaultDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("mobileclip", isDirectory: true)

    /// The background session's identifier; iOS hands it back in `handleEventsForBackgroundURLSession`.
    public static let sessionIdentifier = "dev.jcdiv47.pidurable.mobileclip"

    private let directory: URL
    private let files: [Remote]
    private let transfers: Transfers
    private let network = WiFi()
    private var task: Task<Void, Error>?
    private var phase: State = .notDownloaded
    private let logger = Logger(subsystem: "dev.pi.durable", category: "photos")

    init(directory: URL = defaultDirectory, files: [Remote] = files, configuration: URLSessionConfiguration = .mobileCLIP) {
        self.directory = directory
        self.files = files
        // Creating the session reconnects to transfers from an earlier launch; finished ones land in staging.
        transfers = Transfers(configuration: configuration, staging: directory.appendingPathComponent(Self.variant + ".partial", isDirectory: true))
    }

    /// The compiled models, once a download finished.
    public static func installed(in directory: URL = defaultDirectory) -> ClipModelFiles? {
        let files = files(in: directory.appendingPathComponent(variant, isDirectory: true))
        let all = [files.image, files.text, files.vocab, files.merges]
        return all.allSatisfy { FileManager.default.fileExists(atPath: $0.path) } ? files : nil
    }

    public func state() -> State {
        if task == nil, Self.installed(in: directory) != nil { return .installed }
        guard case .downloading = phase else { return phase }
        let received = transfers.received(files)
        let total = Self.total(files)
        return network.onWiFi ? .downloading(received: received, total: total) : .waitingForWiFi(received: received, total: total)
    }

    /// Downloads and installs the model, or joins the download already running. Throws if it fails or is cancelled.
    public func install() async throws {
        if Self.installed(in: directory) != nil { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: requested.path, contents: nil)
        let running = task ?? Task { try await run() }
        task = running
        defer { if task == running { task = nil } }
        do {
            try await running.value
            phase = .installed
        } catch is CancellationError {
            phase = .notDownloaded
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            phase = .notDownloaded
            throw CancellationError()
        } catch {
            logger.error("MobileCLIP download failed: \(error.localizedDescription)")
            phase = .failed(error.localizedDescription)
            throw error
        }
    }

    /// At launch, and when iOS wakes Pi for the session: carries on with a download the user started and didn't
    /// cancel (the transfers may have finished while Pi was away; this checks and compiles them).
    public func resumeIfStarted() async {
        guard FileManager.default.fileExists(atPath: requested.path), Self.installed(in: directory) == nil else { return }
        try? await install()
    }

    /// iOS woke Pi for the background session (`handleEventsForBackgroundURLSession`): `completion` once its events
    /// are delivered. Kept before the session exists, since creating it delivers them.
    public static func handleEvents(completion: @escaping @Sendable () -> Void) {
        Transfers.eventsDelivered.withLock { $0 = completion }
        _ = shared
    }

    public func cancel() async {
        try? FileManager.default.removeItem(at: requested)
        task?.cancel()
        await transfers.cancelAll()
    }

    /// Deletes the downloaded model and anything half downloaded. The photo index must drop its encoder too
    /// (`PhotoIndex.unloadModel`).
    public func remove() async throws {
        await cancel()
        transfers.forget()
        phase = .notDownloaded
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    private static func total(_ files: [Remote]) -> Int64 { files.reduce(0) { $0 + $1.size } }

    private var staging: URL { directory.appendingPathComponent(Self.variant + ".partial", isDirectory: true) }
    /// Present from the tap on Download until it's installed, cancelled or removed.
    private var requested: URL { directory.appendingPathComponent("requested") }

    private func run() async throws {
        let manager = FileManager.default
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        var folder = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)

        phase = .downloading(received: 0, total: Self.total(files))
        var pending: [Remote] = []
        for file in files {
            if try Self.matches(staging.appendingPathComponent(file.path), file) {
                transfers.finished(file)
            } else {
                pending.append(file)
            }
        }
        if !pending.isEmpty {
            try await transfers.download(pending)
            for file in pending where !(try Self.matches(staging.appendingPathComponent(file.path), file)) {
                try? manager.removeItem(at: staging.appendingPathComponent(file.path))
                throw DownloadError("\(file.path) didn't match its checksum. Try again.")
            }
        }
        try Task.checkCancellation()

        phase = .installing
        // Compile into a fresh folder, load it once to be sure, then put it in place in one rename.
        let ready = directory.appendingPathComponent(Self.variant + ".new", isDirectory: true)
        if manager.fileExists(atPath: ready.path) { try manager.removeItem(at: ready) }
        try manager.createDirectory(at: ready, withIntermediateDirectories: true)
        for name in ["MobileCLIPImage", "MobileCLIPText"] {
            try Task.checkCancellation()
            let compiled = try await MLModel.compileModel(at: staging.appendingPathComponent(name + ".mlpackage"))
            try manager.moveItem(at: compiled, to: ready.appendingPathComponent(name + ".mlmodelc"))
        }
        for name in ["clip-vocab.json", "clip-merges.txt"] {
            try manager.copyItem(at: staging.appendingPathComponent(name), to: ready.appendingPathComponent(name))
        }
        _ = try ClipEncoder(Self.files(in: ready))
        let final = directory.appendingPathComponent(Self.variant, isDirectory: true)
        if manager.fileExists(atPath: final.path) { try manager.removeItem(at: final) }
        try manager.moveItem(at: ready, to: final)
        try? manager.removeItem(at: staging)
        try? manager.removeItem(at: requested)
        transfers.forget()
    }

    private static func files(in folder: URL) -> ClipModelFiles {
        ClipModelFiles(
            model: "mobileclip-" + variant,
            image: folder.appendingPathComponent("MobileCLIPImage.mlmodelc", isDirectory: true),
            text: folder.appendingPathComponent("MobileCLIPText.mlmodelc", isDirectory: true),
            vocab: folder.appendingPathComponent("clip-vocab.json"),
            merges: folder.appendingPathComponent("clip-merges.txt")
        )
    }

    /// Whether the file is there with the expected size and SHA-256.
    static func matches(_ url: URL, _ file: Remote) throws -> Bool {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64, size == file.size else { return false }
        return try sha256(url) == file.sha256
    }

    static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty { hasher.update(data: data) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct DownloadError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

extension URLSessionConfiguration {
    /// A background session that waits for Wi-Fi instead of spending cellular data or Low Data Mode on 200 MB, and
    /// relaunches Pi when it's done.
    static var mobileCLIP: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.background(withIdentifier: ClipModelDownload.sessionIdentifier)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.allowsExpensiveNetworkAccess = false
        configuration.allowsConstrainedNetworkAccess = false
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return configuration
    }
}

/// Whether the current network is one the session will use (for "Waiting for Wi-Fi").
private final class WiFi: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var usable = true

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let usable = path.status == .satisfied && !path.isExpensive && !path.isConstrained
            self?.lock.withLock { self?.usable = usable }
        }
        monitor.start(queue: DispatchQueue(label: "dev.pi.durable.mobileclip.network"))
    }

    var onWiFi: Bool { lock.withLock { usable } }
}

/// The session's delegate. A task's description is its file's path in staging, so transfers that finish while Pi
/// wasn't running (delivered when the session is created again) still land in the right place.
private final class Transfers: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private enum Outcome { case done, failed(Error) }

    private let lock = NSLock()
    private let staging: URL
    private var session: URLSession!
    /// Bytes received per path, the file's size once it's finished.
    private var written: [String: Int64] = [:]
    private var outcomes: [String: Outcome] = [:]
    private var resumeData: [String: Data] = [:]
    private var waiter: (paths: Set<String>, continuation: CheckedContinuation<Void, Error>)?
    static let eventsDelivered = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)

    init(configuration: URLSessionConfiguration, staging: URL) {
        self.staging = staging
        super.init()
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func received(_ files: [ClipModelDownload.Remote]) -> Int64 {
        lock.withLock { files.reduce(0) { $0 + min(written[$1.path] ?? 0, $1.size) } }
    }

    func finished(_ file: ClipModelDownload.Remote) {
        lock.withLock { written[file.path] = file.size }
    }

    func forget() {
        lock.withLock { written = [:]; outcomes = [:]; resumeData = [:] }
    }

    func cancelAll() async {
        for task in await session.allTasks { task.cancel() }
    }

    /// Starts what isn't already running (a transfer from an earlier launch is joined), and waits for all of them.
    /// Throws the first failure.
    func download(_ files: [ClipModelDownload.Remote]) async throws {
        let paths = Set(files.map(\.path))
        lock.withLock { for path in paths { outcomes[path] = nil } }
        let running = Set(await session.allTasks.compactMap(\.taskDescription))
        for file in files where !running.contains(file.path) {
            try FileManager.default.createDirectory(
                at: staging.appendingPathComponent(file.path).deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let task: URLSessionDownloadTask = lock.withLock {
                resumeData.removeValue(forKey: file.path).map { session.downloadTask(withResumeData: $0) }
                    ?? session.downloadTask(with: file.url)
            }
            task.taskDescription = file.path
            task.countOfBytesClientExpectsToReceive = file.size
            task.resume()
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock {
                    waiter = (paths, continuation)
                    settle()
                }
            }
        } onCancel: {
            Task { await self.cancelAll() }
        }
    }

    /// Under the lock: ends the wait once every path has an outcome, or at the first failure.
    private func settle() {
        guard let waiter else { return }
        let results = waiter.paths.compactMap { outcomes[$0] }
        for case let .failed(error) in results {
            self.waiter = nil
            waiter.continuation.resume(throwing: error)
            return
        }
        if results.count == waiter.paths.count {
            self.waiter = nil
            waiter.continuation.resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let path = downloadTask.taskDescription else { return }
        lock.withLock { written[path] = totalBytesWritten }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file at `location` is gone once this returns: move it now.
        guard let path = downloadTask.taskDescription else { return }
        do {
            if let response = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
                throw DownloadError("Hugging Face answered \(response.statusCode).")
            }
            let destination = staging.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: location, to: destination)
            lock.withLock { outcomes[path] = .done }
        } catch {
            lock.withLock { outcomes[path] = .failed(error) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let path = task.taskDescription else { return }
        lock.withLock {
            if let error {
                if let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data { resumeData[path] = data }
                outcomes[path] = .failed(error)
            } else if outcomes[path] == nil {
                outcomes[path] = .failed(DownloadError("\(path) arrived empty."))
            }
            if case .done = outcomes[path] { written[path] = task.countOfBytesReceived }
            settle()
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let completion = Self.eventsDelivered.withLock { completion in
            defer { completion = nil }
            return completion
        }
        DispatchQueue.main.async { completion?() }
    }
}
