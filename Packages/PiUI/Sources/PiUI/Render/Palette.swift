import SwiftUI

/// Named colors a spec may use. Tinted rendering (Lock Screen, tinted Home Screen) ignores them and draws
/// accented parts in the system's tint instead.
public enum Palette {
    public static let names = ["accent", "blue", "green", "orange", "red", "pink", "purple", "teal", "yellow", "indigo", "mint", "cyan", "brown", "gray", "primary", "secondary"]

    public static func color(_ name: String?, default fallback: Color = .accentColor) -> Color {
        switch name {
        case "blue": .blue
        case "green": .green
        case "orange": .orange
        case "red": .red
        case "pink": .pink
        case "purple": .purple
        case "teal": .teal
        case "yellow": .yellow
        case "indigo": .indigo
        case "mint": .mint
        case "cyan": .cyan
        case "brown": .brown
        case "gray": .gray
        case "primary": .primary
        case "secondary": .secondary
        case "accent": .accentColor
        default: fallback
        }
    }

    static func tone(_ name: String?) -> Color {
        switch name {
        case "positive": .green
        case "warning": .orange
        case "critical": .red
        case "info": .blue
        default: .gray
        }
    }
}

/// What the renderer knows about where it draws.
public struct SurfaceEnvironment: Sendable, Hashable {
    public var family: SurfaceFamily
    /// Lock Screen and tinted Home Screen: monochrome, with accented parts.
    public var tinted: Bool
    /// Inside a real widget (WidgetKit-only views such as `AccessoryWidgetBackground` work there).
    public var inWidget: Bool
    /// The spec's `tint`.
    public var tint: String?

    public init(family: SurfaceFamily, tinted: Bool = false, inWidget: Bool = false, tint: String? = nil) {
        self.family = family
        self.tinted = tinted
        self.inWidget = inWidget
        self.tint = tint
    }
}

extension EnvironmentValues {
    @Entry var surface = SurfaceEnvironment(family: .card)
    @Entry var surfaceData = SurfaceData.empty
    /// The slot is alone in a widget and has the whole family to itself.
    @Entry var slotFills = false
}
