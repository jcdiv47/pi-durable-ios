import Foundation
import Testing
@testable import PiAppleTools

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "clip-download-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("MobileCLIP download")
struct ClipModelDownloadTests {
    @Test("The pinned files add up to the S2 model and tokenizer, each with a SHA-256")
    func manifest() {
        #expect(ClipModelDownload.files.count == 8)
        #expect(ClipModelDownload.files.allSatisfy { $0.sha256.count == 64 && $0.url.absoluteString.contains("/resolve/") && !$0.url.absoluteString.contains("/main/") })
        #expect((190_000_000...210_000_000).contains(ClipModelDownload.totalBytes))
    }

    @Test("A file that doesn't match its checksum fails the install and is deleted; nothing is installed")
    func checksumMismatch() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "source.txt")
        try Data("not the model".utf8).write(to: source)
        let wrong = ClipModelDownload.Remote(url: source, path: "clip-vocab.json", size: 13, sha256: String(repeating: "0", count: 64))
        let download = ClipModelDownload(directory: directory.appending(path: "models"), files: [wrong], configuration: .default)

        await #expect(throws: DownloadError.self) { try await download.install() }
        guard case .failed = await download.state() else { Issue.record("expected .failed"); return }
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "models/s2.partial/clip-vocab.json").path))
        #expect(ClipModelDownload.installed(in: directory.appending(path: "models")) == nil)
    }

    @Test("A file already downloaded and checked is not fetched again")
    func keepsCheckedFiles() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let models = directory.appending(path: "models")
        let staged = models.appending(path: "s2.partial/clip-vocab.json")
        try FileManager.default.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("vocab".utf8).write(to: staged)
        let file = ClipModelDownload.Remote(
            url: directory.appending(path: "missing.json"), path: "clip-vocab.json", size: 5,
            sha256: try ClipModelDownload.sha256(staged)
        )
        let download = ClipModelDownload(directory: models, files: [file], configuration: .default)
        // The source is missing, so only skipping the download gets as far as compiling (which then fails: no models).
        do { try await download.install() } catch {}
        #expect(FileManager.default.fileExists(atPath: staged.path))
        #expect(!String(describing: await download.state()).contains("doesn't exist"))
    }

    /// The real thing: 199 MB from Hugging Face, compiled and loaded. `PI_DOWNLOAD_TEST=1 swift test --filter download`.
    @Test("Downloads, checks, compiles and installs MobileCLIP-S2",
          .enabled(if: ProcessInfo.processInfo.environment["PI_DOWNLOAD_TEST"] == "1"), .timeLimit(.minutes(20)))
    func realDownload() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let download = ClipModelDownload(directory: directory, configuration: .default)
        try await download.install()
        #expect(await download.state() == .installed)
        let files = try #require(ClipModelDownload.installed(in: directory))
        #expect(files.model == "mobileclip-s2")
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "s2.partial").path))
        let encoder = try ClipEncoder(files)
        #expect(try encoder.embed(text: "a photo of a cat").count == ClipEncoder.dimensions)
    }
}
