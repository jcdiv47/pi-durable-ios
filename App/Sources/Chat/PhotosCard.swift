import Photos
import SwiftUI

/// `photos_search` (docs/adr/0010-photo-search.md): the matches' IDs and dates. The thumbnails are read from the
/// library here, on the device; the model only ever saw the IDs.
struct PhotosResult: Decodable {
    struct Match: Decodable, Hashable, Identifiable {
        let id: String
        let date: String?
        let score: Double?
        let favorite: Bool?
    }

    let query: String
    let results: [Match]
    let indexed: Int?
    let total: Int?
    let note: String?
}

struct PhotosCard: View {
    let value: PhotosResult
    @State private var shown: PhotosResult.Match?

    var body: some View {
        ResultCardShell(
            source: "Photos",
            symbol: "photo.on.rectangle.angled",
            tint: .orange,
            title: "\u{201C}\(value.query)\u{201D}",
            subtitle: value.results.count == 1 ? "1 match" : "\(value.results.count) matches",
            share: value.query,
            expandable: value.results.count > 8
        ) { expanded in
            VStack(alignment: .leading, spacing: 8) {
                if value.results.isEmpty {
                    Text("No matching photos.").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                        ForEach(expanded ? value.results : Array(value.results.prefix(8))) { match in
                            Button {
                                shown = match
                            } label: {
                                PhotoThumbnail(id: match.id)
                                    .overlay(alignment: .bottomTrailing) {
                                        if match.favorite == true {
                                            Image(systemName: "heart.fill").font(.caption2).foregroundStyle(.white).padding(4).shadow(radius: 2)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(match.date.flatMap(ISODate.date).map { "Photo from \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "Photo")
                        }
                    }
                }
                if let note = value.note {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .sheet(item: $shown) { match in
            PhotoViewer(match: match)
        }
    }
}

/// A square thumbnail from the library; a gray tile when the photo is gone or access was taken away.
struct PhotoThumbnail: View {
    let id: String
    @State private var image: UIImage?

    var body: some View {
        Color(.tertiarySystemFill)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .clipShape(.rect(cornerRadius: 8))
            .task(id: id) { image = await PhotoLoader.image(id, size: CGSize(width: 240, height: 240), mode: .aspectFill) }
    }
}

struct PhotoViewer: View {
    let match: PhotosResult.Match
    @State private var image: UIImage?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(match.date.flatMap(ISODate.date)?.formatted(date: .abbreviated, time: .shortened) ?? "Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if let image {
                    ToolbarItem(placement: .topBarLeading) {
                        ShareLink(item: Image(uiImage: image), preview: SharePreview("Photo", image: Image(uiImage: image)))
                    }
                }
            }
        }
        // The full view may fetch the original from iCloud; thumbnails never do.
        .task { image = await PhotoLoader.image(match.id, size: CGSize(width: 1400, height: 1400), mode: .aspectFit, network: true) }
    }
}

enum PhotoLoader {
    /// The asset's image at about `size` points, or nil when it is gone or Pi may not read it.
    @MainActor
    static func image(_ id: String, size: CGSize, mode: PHImageContentMode, network: Bool = false) async -> UIImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = network
        let scale = 3.0
        let pixels = CGSize(width: size.width * scale, height: size.height * scale)
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(for: asset, targetSize: pixels, contentMode: mode, options: options) { image, _ in
                // `highQualityFormat` calls back once.
                continuation.resume(returning: image)
            }
        }
    }
}
