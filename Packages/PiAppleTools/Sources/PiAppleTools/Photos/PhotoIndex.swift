#if os(iOS)
import Foundation
import os
import Photos
import UIKit

/// The on-device photo index behind `photos_search`. It embeds each image asset once
/// with MobileCLIP, keeps the vectors in Application Support, and ranks them against a text query. Nothing leaves the
/// device; the tool returns asset IDs and dates only.
public actor PhotoIndex {
    public struct Status: Sendable, Equatable {
        public var modelInstalled: Bool
        public var authorized: Bool
        public var indexed: Int
        /// Image assets Pi can see; nil until the library was first read.
        public var total: Int?
        public var running: Bool
    }

    public static let shared = PhotoIndex()

    /// How many new photos a search embeds before it answers, when the index is behind.
    static let searchBatch = 300

    private let directory: URL
    private let locate: @Sendable () -> ClipModelFiles?
    /// The model the vectors in memory came from.
    private var model: String
    private var encoder: ClipEncoder?
    private var vectors: PhotoVectors
    private var total: Int?
    private var running: Task<Void, Never>?
    private let logger = Logger(subsystem: "dev.pi.durable", category: "photos")

    /// `locate` is asked again until it finds the model, so one downloaded in Settings is used without a relaunch.
    public init(
        directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("photo-index"),
        locate: @escaping @Sendable () -> ClipModelFiles? = { ClipModelFiles.installed() }
    ) {
        self.directory = directory
        self.locate = locate
        model = locate()?.model ?? "mobileclip"
        vectors = PhotoVectors.load(from: directory, model: model)
    }

    public static var authorized: Bool {
        [.authorized, .limited].contains(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    public func status() -> Status {
        Status(modelInstalled: (try? clip()) != nil, authorized: Self.authorized, indexed: vectors.count, total: total, running: running != nil)
    }

    // MARK: Search

    struct SearchArguments: Decodable {
        let query: String
        let from: String?
        let to: String?
        let favoritesOnly: Bool?
        let screenshotsOnly: Bool?
        let limit: Int?
    }

    /// JSON text: an actor can't hand a `[String: Any]` across.
    func search(_ args: SearchArguments) async throws -> String {
        let query = args.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw AppleToolError("query is empty") }
        guard let encoder = try clip() else {
            throw AppleToolError("Photo search needs the MobileCLIP model, which isn't on this iPhone yet. Tell the user to download it in Settings › Photo Search (about 200 MB, over Wi-Fi).")
        }
        try await authorize()
        // Behind (first use, or new photos): embed the newest ones before answering, then keep going in the background.
        let assets = library()
        total = assets.count
        if assets.contains(where: { needsEmbedding($0) }) {
            await embed(assets, limit: Self.searchBatch)
            startIndexing()
        }
        var filter = PhotoVectors.Filter(favoritesOnly: args.favoritesOnly ?? false, screenshotsOnly: args.screenshotsOnly ?? false)
        filter.from = try args.from.map { try ISODate.parse($0, field: "from") }
        filter.to = try args.to.map { try ISODate.parse($0, field: "to") }
        let vector = try encoder.embed(text: query)
        let limit = min(max(args.limit ?? 8, 1), 24)
        let matches = vectors.search(vector, filter: filter, limit: limit)
        var result: [String: Any] = [
            "query": query,
            "results": matches.map { match -> [String: Any] in
                var item: [String: Any] = ["id": match.entry.id, "score": (Double(match.score) * 1000).rounded() / 1000]
                if let created = match.entry.created { item["date"] = ISODate.format(created) }
                if match.entry.favorite { item["favorite"] = true }
                if match.entry.screenshot { item["screenshot"] = true }
                return item
            },
            "indexed": vectors.count,
            "total": assets.count,
        ]
        if vectors.count < assets.count {
            result["note"] = "\(vectors.count) of \(assets.count) photos are indexed so far (newest first); indexing continues while Pi is open or charging."
        }
        if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited {
            result["limitedAccess"] = true
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self)
    }

    // MARK: Indexing

    /// Indexes everything not yet indexed, newest first, in the background of this process. One run at a time.
    public func startIndexing() {
        guard running == nil, Self.authorized else { return }
        running = Task { [weak self] in
            guard let self else { return }
            await self.indexAll(deadline: nil)
            await self.finished()
        }
    }

    /// Indexes until done or `deadline` (a background task's time). Returns whether everything is indexed.
    @discardableResult
    public func indexAll(deadline: Date?) async -> Bool {
        guard Self.authorized, (try? clip()) != nil else { return false }
        let assets = library()
        total = assets.count
        return await embed(assets, limit: nil, deadline: deadline)
    }

    public func stop() {
        running?.cancel()
        running = nil
    }

    public func deleteIndex() throws {
        stop()
        vectors = PhotoVectors(model: model)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    /// Whether anything is left to index (for scheduling the charging-time task). Reads the library's metadata only.
    public func behind() -> Bool {
        guard Self.authorized, (try? clip()) != nil else { return false }
        let assets = library()
        total = assets.count
        return assets.contains { needsEmbedding($0) }
    }

    private func finished() {
        running = nil
    }

    /// Forgets the loaded model, after Settings deleted the downloaded one.
    public func unloadModel() {
        stop()
        encoder = nil
    }

    private func clip() throws -> ClipEncoder? {
        if let encoder { return encoder }
        guard let files = locate() else { return nil }
        let loaded = try ClipEncoder(files)
        if files.model != model {
            model = files.model
            vectors = PhotoVectors.load(from: directory, model: model)
        }
        encoder = loaded
        return loaded
    }

    private func authorize() async throws {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
        switch status {
        case .authorized, .limited: return
        case .notDetermined: throw AppleToolError("Pi has not been allowed to read photos yet, and iOS asks only while Pi is open. Ask the user to open Pi and try again.")
        default: throw AppleToolError("Photos access is not allowed. The user can turn it on in Settings › Privacy & Security › Photos › Pi.")
        }
    }

    /// Image assets Pi can see, newest first, with what the index keeps about them.
    private func library() -> [PhotoVectors.Entry] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var entries: [PhotoVectors.Entry] = []
        entries.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            entries.append(PhotoVectors.Entry(
                id: asset.localIdentifier, created: asset.creationDate, modified: asset.modificationDate,
                favorite: asset.isFavorite, screenshot: asset.mediaSubtypes.contains(.photoScreenshot)
            ))
        }
        return entries
    }

    private func needsEmbedding(_ entry: PhotoVectors.Entry) -> Bool {
        guard let known = vectors.entry(entry.id) else { return true }
        return known.modified != entry.modified
    }

    /// Embeds what `needsEmbedding` up to `limit` photos or `deadline`, saving every 100. Returns whether none is left.
    @discardableResult
    private func embed(_ assets: [PhotoVectors.Entry], limit: Int?, deadline: Date? = nil) async -> Bool {
        guard let encoder = try? clip() else { return false }
        vectors.retain(Set(assets.map(\.id)))
        let pending = assets.filter(needsEmbedding)
        var done = 0
        for entry in pending {
            if Task.isCancelled || done == limit || deadline.map({ Date.now >= $0 }) == true { break }
            // Favorites and so on change without a new image: keep the vector, refresh the entry.
            let image = await Self.image(entry.id)
            // Cancelled while waiting (stopped, or the index deleted): don't write into what replaced it.
            if Task.isCancelled { break }
            if let image {
                do {
                    vectors.upsert(entry, vector: try encoder.embed(image: image))
                } catch {
                    logger.error("Embedding \(entry.id, privacy: .private) failed: \(error.localizedDescription)")
                }
            }
            done += 1
            if done.isMultiple(of: 100) { save() }
        }
        save()
        return done == pending.count
    }

    private func save() {
        do { try vectors.save(to: directory) } catch { logger.error("Photo index not saved: \(error.localizedDescription)") }
    }

    /// A small rendition from the device, never from iCloud: the original if it's local, else the cached thumbnail.
    static func image(_ id: String) async -> CGImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return nil }
        if let image = await request(asset, delivery: .highQualityFormat) { return image }
        return await request(asset, delivery: .fastFormat)
    }

    private static func request(_ asset: PHAsset, delivery: PHImageRequestOptionsDeliveryMode) async -> CGImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = delivery
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        options.isSynchronous = false
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 320, height: 320), contentMode: .aspectFill, options: options) { image, _ in
                // `highQualityFormat` and `fastFormat` call back once.
                continuation.resume(returning: image?.cgImage)
            }
        }
    }
}
#endif
