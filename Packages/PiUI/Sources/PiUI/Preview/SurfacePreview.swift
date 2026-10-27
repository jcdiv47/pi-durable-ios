import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// A spec drawn the way a family shows it, outside WidgetKit: for chat cards, the app's surface screens,
/// `preview_surface` PNGs and snapshot tests.
public struct FramedSurface: View {
    let spec: SurfaceSpec
    let family: SurfaceFamily
    let appearance: SurfaceAppearance
    let data: SurfaceData

    public init(spec: SurfaceSpec, family: SurfaceFamily, appearance: SurfaceAppearance, data: SurfaceData) {
        self.spec = spec
        self.family = family
        self.appearance = appearance
        self.data = data
    }

    /// The Lock Screen always draws accessories tinted, over the wallpaper.
    var tinted: Bool { family.isAccessory || appearance == .tinted }

    public var body: some View {
        let size = family.size
        let surface = SurfaceView(spec: spec, family: family, data: data, tinted: tinted)
        Group {
            if family.isAccessory {
                surface
                    .frame(width: size.width, height: size.height)
                    .padding(10)
                    .background(LinearGradient(colors: [Color(red: 0.16, green: 0.2, blue: 0.36), Color(red: 0.36, green: 0.22, blue: 0.4)], startPoint: .topLeading, endPoint: .bottomTrailing))
            } else if family == .card {
                surface
                    .padding(family.contentPadding)
                    .frame(width: size.width)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(background, in: .rect(cornerRadius: 18))
            } else {
                surface
                    .padding(family.contentPadding)
                    .frame(width: size.width, height: size.height)
                    .background(background, in: .rect(cornerRadius: 24))
            }
        }
        .environment(\.colorScheme, appearance == .light && !tinted ? .light : .dark)
    }

    private var background: AnyShapeStyle {
        tinted ? AnyShapeStyle(Color(white: 0.18)) : AnyShapeStyle(appearance == .dark ? Color(white: 0.11) : Color.white)
    }
}

@MainActor
public enum SurfacePreview {
    public struct Image: Sendable {
        public let family: SurfaceFamily
        public let appearance: SurfaceAppearance
        public let png: Data
        public let width: Int
        public let height: Int
    }

    /// PNG of the framed surface. Scale 2 keeps previews legible to a vision model at a modest size.
    public static func png(_ spec: SurfaceSpec, family: SurfaceFamily, appearance: SurfaceAppearance, data: SurfaceData, scale: CGFloat = 2) -> Image? {
        let renderer = ImageRenderer(content: FramedSurface(spec: spec, family: family, appearance: appearance, data: data))
        renderer.scale = scale
        guard let image = renderer.cgImage, let png = pngData(image) else { return nil }
        return Image(family: family, appearance: appearance, png: png, width: image.width, height: image.height)
    }

    /// Layout warnings: content taller than the family has room for gets compressed or clipped.
    public static func layoutWarnings(_ spec: SurfaceSpec, family: SurfaceFamily, data: SurfaceData) -> [String] {
        guard family != .card, family != .accessoryInline else { return [] }
        let size = family.size
        let inset = family.contentPadding
        let width = size.width - 2 * inset
        let available = size.height - 2 * inset
        let natural = SurfaceView(spec: spec, family: family, data: data, tinted: family.isAccessory)
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
        let renderer = ImageRenderer(content: natural)
        renderer.scale = 1
        guard let height = renderer.cgImage.map({ CGFloat($0.height) }), height > available + 4 else { return [] }
        return ["\(family.rawValue): the content needs about \(Int(height)) pt of height but has \(Int(available)); it will be squeezed or clipped. Drop a slot, lower maxItems, or shorten text."]
    }

    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
