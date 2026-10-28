import SwiftUI
import UIKit

/// One attachment as the composer, the share sheet and the transcript draw it: a thumbnail for an image, a small card
/// with a symbol, a title and a line of detail for text and links. `remove` adds an ✕.
struct AttachmentChip: View {
    enum Look: Hashable {
        case image(file: String)
        case text(title: String, detail: String)
        case link(title: String, url: URL)
    }

    let look: Look
    var height: CGFloat = 64
    var remove: (() -> Void)?

    var body: some View {
        content
            .overlay(alignment: .topTrailing) {
                if let remove {
                    Button("Remove", systemImage: "xmark", action: remove)
                        .labelStyle(.iconOnly)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(.black.opacity(0.6), in: .circle)
                        .padding(4)
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("attachment.remove")
                }
            }
    }

    @ViewBuilder private var content: some View {
        switch look {
        case let .image(file):
            AttachmentImage(file: file, maxPixel: height * 3)
                .frame(width: height, height: height)
                .clipShape(.rect(cornerRadius: 12))
                .accessibilityLabel("Image")
        case let .text(title, detail):
            card(symbol: "doc.text", title: title, detail: detail)
                .padding(.trailing, remove == nil ? 0 : 18)
                .frame(width: 180, alignment: .leading)
                .background(.fill.tertiary, in: .rect(cornerRadius: 12))
        case let .link(title, url):
            card(symbol: "link", title: title, detail: url.host() ?? url.absoluteString)
                .padding(.trailing, remove == nil ? 0 : 18)
                .frame(width: 180, alignment: .leading)
                .background(.fill.tertiary, in: .rect(cornerRadius: 12))
        }
    }

    private func card(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(.tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.footnote.weight(.semibold)).lineLimit(1)
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(height: height, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }
}

extension AttachmentChip.Look {
    init(_ attachment: Attachment) {
        switch attachment.content {
        case let .image(file): self = .image(file: file)
        case let .text(text): self = .text(title: attachment.name ?? "Text", detail: Self.preview(text))
        case let .link(url): self = .link(title: attachment.name ?? url.host() ?? "Link", url: url)
        }
    }

    static func preview(_ text: String) -> String {
        String(text.prefix(200)).split(whereSeparator: \.isNewline).joined(separator: " ")
    }
}

/// An attachment's JPEG, decoded at the size it is drawn; a placeholder while it loads or when the file is gone.
struct AttachmentImage: View {
    let file: String
    var maxPixel: CGFloat = 600
    /// The whole image in the frame, instead of filling it.
    var fit = false
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: fit ? .fit : .fill)
            } else {
                Rectangle().fill(.fill.tertiary).overlay { Image(systemName: "photo").foregroundStyle(.secondary) }
            }
        }
        .task(id: file) {
            guard let url = Attachments.imageURL(file) else { return }
            let size = maxPixel
            image = await Task.detached {
                guard let full = UIImage(contentsOfFile: url.path) else { return nil }
                let scale = min(1, size / max(full.size.width, full.size.height, 1))
                return full.preparingThumbnail(of: CGSize(width: full.size.width * scale, height: full.size.height * scale))
            }.value
        }
    }
}

/// A row of chips that scrolls sideways.
struct AttachmentStrip: View {
    let attachments: [Attachment]
    var remove: ((Attachment) -> Void)?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    AttachmentChip(look: .init(attachment), remove: remove.map { remove in { remove(attachment) } })
                }
            }
        }
        .scrollIndicators(.hidden)
    }
}
