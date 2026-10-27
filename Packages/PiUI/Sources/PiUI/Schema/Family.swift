import CoreGraphics

/// Where a spec renders: the WidgetKit families of the Home Screen and Lock Screen, and a chat card
/// (spec "Layer 2 surfaces"). Live Activities, controls and snippets come with M3.
public enum SurfaceFamily: String, CaseIterable, Codable, Sendable, Hashable, Identifiable {
    case systemSmall, systemMedium, systemLarge
    case accessoryCircular, accessoryRectangular, accessoryInline
    case card

    public var id: String { rawValue }

    public static let widgetFamilies: [SurfaceFamily] = [.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline]

    public var isAccessory: Bool { [.accessoryCircular, .accessoryRectangular, .accessoryInline].contains(self) }

    /// Maximum Layer 1 slots; nil is unbounded (a card scrolls).
    public var slotLimit: Int? {
        switch self {
        case .systemSmall: 1
        case .systemMedium: 3
        case .systemLarge: 6
        case .accessoryCircular: 1
        case .accessoryRectangular: 2
        case .accessoryInline: 1
        case .card: nil
        }
    }

    /// Point size on a 6.3" iPhone (402 × 874), for previews and overflow checks. A card's height is its content's.
    public var size: CGSize {
        switch self {
        case .systemSmall: CGSize(width: 170, height: 170)
        case .systemMedium: CGSize(width: 364, height: 170)
        case .systemLarge: CGSize(width: 364, height: 382)
        case .accessoryCircular: CGSize(width: 76, height: 76)
        case .accessoryRectangular: CGSize(width: 172, height: 76)
        case .accessoryInline: CGSize(width: 257, height: 26)
        case .card: CGSize(width: 340, height: 0)
        }
    }

    /// Content inset WidgetKit applies inside the container (system families) or none (accessories).
    public var contentPadding: CGFloat {
        switch self {
        case .systemSmall, .systemMedium, .systemLarge: 16
        case .card: 14
        case .accessoryCircular, .accessoryRectangular, .accessoryInline: 0
        }
    }

    public var displayName: String {
        switch self {
        case .systemSmall: "Home Screen small"
        case .systemMedium: "Home Screen medium"
        case .systemLarge: "Home Screen large"
        case .accessoryCircular: "Lock Screen circular"
        case .accessoryRectangular: "Lock Screen rectangular"
        case .accessoryInline: "Lock Screen inline (one line of text)"
        case .card: "Chat card"
        }
    }
}

/// How a family is drawn: full color (light or dark), or tinted, which is how the Lock Screen and tinted Home
/// Screens show widgets (monochrome, with accented parts).
public enum SurfaceAppearance: String, CaseIterable, Codable, Sendable, Hashable {
    case light, dark, tinted
}
