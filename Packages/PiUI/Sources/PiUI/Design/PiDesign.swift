import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Pi's design tokens: one place for its neutrals, status colors, corner radii, elevation and motion, so the chat's
/// transcript (work rows, tool cards, result cards, tables, code), the cards Pi designs and the widgets read as one
/// system in light and dark. They live in PiUI so the renderer, the app and the widget share them.
///
/// Cool, slightly blue neutrals with solid hairlines, the app's accent as the one accent, and green, orange and red only
/// for status. The composer and the approval buttons keep the system's Liquid Glass; these tokens are for content.
public enum PiDesign {
    // MARK: Color

    public enum Palette {
        /// A card in the transcript: a result card, a table, a code block, a card Pi designed.
        public static let surface = Color(light: 0xF4F6FA, dark: 0x16181D)
        /// Inside a card, or a quiet control: a chip, a table's header, a code block's gutter.
        public static let sunken = Color(light: 0xECEFF4, dark: 0x1F2229)
        /// Lifted over the transcript: an expanded tool card; a widget's background.
        public static let raised = Color(light: 0xFFFFFF, dark: 0x1C1F25)
        /// A solid one-point line around surfaces and between rows.
        public static let hairline = Color(light: 0x0F1B33, lightAlpha: 0.09, dark: 0xFFFFFF, darkAlpha: 0.09)
        public static let hairlineStrong = Color(light: 0x0F1B33, lightAlpha: 0.16, dark: 0xFFFFFF, darkAlpha: 0.16)

        public static let accent = Color.accentColor
        public static let success = Color(light: 0x1F9D55, dark: 0x3DD68C)
        public static let warning = Color(light: 0xD97706, dark: 0xF5A524)
        public static let danger = Color(light: 0xDC2626, dark: 0xF87171)

        /// Diff lines: a wash behind added and removed lines.
        public static let added = Color(light: 0x1F9D55, lightAlpha: 0.11, dark: 0x3DD68C, darkAlpha: 0.14)
        public static let removed = Color(light: 0xDC2626, lightAlpha: 0.10, dark: 0xF87171, darkAlpha: 0.14)
    }

    // MARK: Shape

    /// Corner radii, from a chip's to a sheet's. iOS sizes, so a little rounder than the web's.
    public enum Radius {
        public static let chip: CGFloat = 8
        public static let control: CGFloat = 12
        public static let card: CGFloat = 18
        public static let bubble: CGFloat = 20
        /// A Home Screen widget's corner, as previews draw it.
        public static let widget: CGFloat = 24
        public static let window: CGFloat = 26
    }

    public enum Space {
        public static let xxs: CGFloat = 2
        public static let xs: CGFloat = 4
        public static let s: CGFloat = 8
        public static let m: CGFloat = 12
        public static let l: CGFloat = 16
        public static let xl: CGFloat = 24
    }

    // MARK: Type

    public enum Typeface {
        /// A card's kicker: "REMINDERS", "CALENDAR".
        public static let kicker = Font.caption.weight(.bold)
        public static let kickerTracking: CGFloat = 1
        public static let label = Font.subheadline
        public static let code = Font.callout.monospaced()
        public static let codeSmall = Font.caption.monospaced()
        /// A table's cells: tabular numbers keep columns of figures aligned.
        public static let cell = Font.subheadline.monospacedDigit()
    }

    // MARK: Motion

    public enum Motion {
        /// Opening and closing a row or card.
        public static let disclose = Animation.snappy(duration: 0.25)
        /// A state change inside a row: a status, a check.
        public static let state = Animation.smooth(duration: 0.2)
    }

    // MARK: Elevation

    /// How far a surface sits above the transcript: a hairline only, a card, or raised (with a soft shadow in light).
    public enum Elevation: Sendable {
        case flat, card, raised
    }
}

// MARK: - Modifiers

extension View {
    /// A content surface: fill, hairline, and for `.raised` a soft shadow (dark mode draws no shadows, only the line).
    public func piSurface(
        _ elevation: PiDesign.Elevation = .card,
        radius: CGFloat = PiDesign.Radius.card,
        fill: Color? = nil
    ) -> some View {
        modifier(PiSurfaceModifier(elevation: elevation, radius: radius, fill: fill))
    }

    /// A quiet capsule control: the "Worked" and "Thought" rows, the run's status, tool chips.
    public func piChip(tint: Color? = nil) -> some View {
        modifier(PiChipModifier(tint: tint))
    }

    /// A card's kicker style: a small bold caption with tracking.
    public func piKicker(_ tint: Color = .secondary) -> some View {
        font(PiDesign.Typeface.kicker).tracking(PiDesign.Typeface.kickerTracking).foregroundStyle(tint)
    }
}

private struct PiSurfaceModifier: ViewModifier {
    let elevation: PiDesign.Elevation
    let radius: CGFloat
    let fill: Color?
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                shape
                    .fill(fill ?? (elevation == .raised ? PiDesign.Palette.raised : PiDesign.Palette.surface))
                    .shadow(color: shadow, radius: elevation == .raised ? 10 : 3, y: elevation == .raised ? 4 : 1)
            }
            .overlay { shape.strokeBorder(PiDesign.Palette.hairline, lineWidth: 1) }
    }

    private var shadow: Color {
        guard colorScheme == .light else { return .clear }
        switch elevation {
        case .flat: return .clear
        case .card: return .black.opacity(0.04)
        case .raised: return .black.opacity(0.08)
        }
    }
}

private struct PiChipModifier: ViewModifier {
    let tint: Color?

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background {
                Capsule().fill(tint.map { $0.opacity(0.14) } ?? PiDesign.Palette.sunken)
            }
            .overlay { Capsule().strokeBorder(tint.map { $0.opacity(0.25) } ?? PiDesign.Palette.hairline, lineWidth: 1) }
    }
}

// MARK: - Color from hex

extension Color {
    /// A color that follows the appearance, from two 0xRRGGBB values.
    public init(light: UInt32, lightAlpha: CGFloat = 1, dark: UInt32, darkAlpha: CGFloat = 1) {
        #if canImport(UIKit)
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark, alpha: darkAlpha) : UIColor(hex: light, alpha: lightAlpha)
        })
        #else
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark, alpha: darkAlpha) : NSColor(hex: light, alpha: lightAlpha)
        })
        #endif
    }
}

#if canImport(UIKit)
extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}
#else
extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}
#endif
