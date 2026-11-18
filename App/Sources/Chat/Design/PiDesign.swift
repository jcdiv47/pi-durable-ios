import SwiftUI
import UIKit

/// The chat's design tokens: one place for its neutrals, status colors, corner radii, elevation and motion, so the
/// transcript's pieces (work rows, tool cards, result cards, tables, code) read as one system in light and dark.
///
/// Cool, slightly blue neutrals with solid hairlines, the app's accent as the one accent, and green, orange and red only
/// for status. The composer and the approval buttons keep the system's Liquid Glass; these tokens are for content.
/// Web cards (`show_ui`) read the same values as CSS variables (`PiDesign.css`).
enum PiDesign {
    // MARK: Color

    /// A color token: its light and dark values, which both the native views and web cards (as CSS variables) read.
    struct Swatch: Sendable {
        let name: String
        let light: UInt32
        var lightAlpha: Double = 1
        let dark: UInt32
        var darkAlpha: Double = 1

        var color: Color { Color(light: light, lightAlpha: lightAlpha, dark: dark, darkAlpha: darkAlpha) }
    }

    enum Swatches {
        static let surface = Swatch(name: "surface", light: 0xF4F6FA, dark: 0x16181D)
        static let sunken = Swatch(name: "sunken", light: 0xECEFF4, dark: 0x1F2229)
        static let raised = Swatch(name: "raised", light: 0xFFFFFF, dark: 0x1C1F25)
        static let hairline = Swatch(name: "hairline", light: 0x0F1B33, lightAlpha: 0.09, dark: 0xFFFFFF, darkAlpha: 0.09)
        static let hairlineStrong = Swatch(name: "hairline-strong", light: 0x0F1B33, lightAlpha: 0.16, dark: 0xFFFFFF, darkAlpha: 0.16)
        static let success = Swatch(name: "success", light: 0x1F9D55, dark: 0x3DD68C)
        static let warning = Swatch(name: "warning", light: 0xD97706, dark: 0xF5A524)
        static let danger = Swatch(name: "danger", light: 0xDC2626, dark: 0xF87171)
        static let added = Swatch(name: "added", light: 0x1F9D55, lightAlpha: 0.11, dark: 0x3DD68C, darkAlpha: 0.14)
        static let removed = Swatch(name: "removed", light: 0xDC2626, lightAlpha: 0.10, dark: 0xF87171, darkAlpha: 0.14)

        static let all = [surface, sunken, raised, hairline, hairlineStrong, success, warning, danger, added, removed]
    }

    enum Palette {
        /// A card in the transcript: a result card, a table, a code block.
        static let surface = Swatches.surface.color
        /// Inside a card, or a quiet control: a chip, a table's header, a code block's gutter.
        static let sunken = Swatches.sunken.color
        /// Lifted over the transcript: an expanded tool card.
        static let raised = Swatches.raised.color
        /// A solid one-point line around surfaces and between rows.
        static let hairline = Swatches.hairline.color
        static let hairlineStrong = Swatches.hairlineStrong.color

        static let accent = Color.accentColor
        static let success = Swatches.success.color
        static let warning = Swatches.warning.color
        static let danger = Swatches.danger.color

        /// Diff lines: a wash behind added and removed lines.
        static let added = Swatches.added.color
        static let removed = Swatches.removed.color
    }

    // MARK: Shape

    /// Corner radii, from a chip's to a sheet's. iOS sizes, so a little rounder than the web's.
    enum Radius {
        static let chip: CGFloat = 8
        static let control: CGFloat = 12
        static let card: CGFloat = 18
        static let bubble: CGFloat = 20
        static let window: CGFloat = 26
    }

    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    // MARK: Type

    enum Typeface {
        /// A card's kicker: "REMINDERS", "CALENDAR".
        static let kicker = Font.caption.weight(.bold)
        static let kickerTracking: CGFloat = 1
        static let label = Font.subheadline
        static let code = Font.callout.monospaced()
        static let codeSmall = Font.caption.monospaced()
        /// A table's cells: tabular numbers keep columns of figures aligned.
        static let cell = Font.subheadline.monospacedDigit()
    }

    // MARK: Motion

    enum Motion {
        /// Opening and closing a row or card.
        static let disclose = Animation.snappy(duration: 0.25)
        /// A state change inside a row: a status, a check.
        static let state = Animation.smooth(duration: 0.2)
    }

    // MARK: Elevation

    /// How far a surface sits above the transcript: a hairline only, a card, or raised (with a soft shadow in light).
    enum Elevation {
        case flat, card, raised
    }

    // MARK: CSS

    /// The tokens as CSS custom properties for web cards: `--pi-<name>` in light, and again under
    /// `prefers-color-scheme: dark`. The accent is the app's, resolved for each appearance.
    static var css: String {
        func rgba(_ hex: UInt32, _ alpha: Double) -> String {
            let r = (hex >> 16) & 0xFF, g = (hex >> 8) & 0xFF, b = hex & 0xFF
            return alpha >= 1 ? String(format: "#%06X", hex) : "rgba(\(r), \(g), \(b), \(alpha))"
        }
        func accent(_ style: UIUserInterfaceStyle) -> String {
            // The app sets no accent color asset, so its accent is the system blue.
            let color = UIColor.systemBlue.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            return String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
        }
        let shared = [
            "--pi-radius-chip: \(Int(Radius.chip))px", "--pi-radius-control: \(Int(Radius.control))px",
            "--pi-radius-card: \(Int(Radius.card))px", "--pi-radius-window: \(Int(Radius.window))px",
            "--pi-space-xs: \(Int(Space.xs))px", "--pi-space-s: \(Int(Space.s))px", "--pi-space-m: \(Int(Space.m))px",
            "--pi-space-l: \(Int(Space.l))px", "--pi-space-xl: \(Int(Space.xl))px",
        ]
        let light = Swatches.all.map { "--pi-\($0.name): \(rgba($0.light, $0.lightAlpha))" }
            + ["--pi-accent: \(accent(.light))", "--pi-text: #0B0F17", "--pi-secondary: rgba(60, 67, 82, 0.72)", "--pi-tertiary: rgba(60, 67, 82, 0.45)", "--pi-background: #FFFFFF", "color-scheme: light dark"]
        let dark = Swatches.all.map { "--pi-\($0.name): \(rgba($0.dark, $0.darkAlpha))" }
            + ["--pi-accent: \(accent(.dark))", "--pi-text: #F2F4F8", "--pi-secondary: rgba(225, 230, 240, 0.65)", "--pi-tertiary: rgba(225, 230, 240, 0.4)", "--pi-background: #000000"]
        return ":root { \((shared + light).joined(separator: "; ")); }\n@media (prefers-color-scheme: dark) { :root { \(dark.joined(separator: "; ")); } }"
    }
}

// MARK: - Modifiers

extension View {
    /// A content surface: fill, hairline, and for `.raised` a soft shadow (dark mode draws no shadows, only the line).
    func piSurface(
        _ elevation: PiDesign.Elevation = .card,
        radius: CGFloat = PiDesign.Radius.card,
        fill: Color? = nil
    ) -> some View {
        modifier(PiSurfaceModifier(elevation: elevation, radius: radius, fill: fill))
    }

    /// A quiet capsule control: the "Worked" and "Thought" rows, the run's status, tool chips.
    func piChip(tint: Color? = nil) -> some View {
        modifier(PiChipModifier(tint: tint))
    }

    /// A card's kicker style: small caps-like bold caption with tracking.
    func piKicker(_ tint: Color = .secondary) -> some View {
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
    init(light: UInt32, lightAlpha: CGFloat = 1, dark: UInt32, darkAlpha: CGFloat = 1) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark, alpha: darkAlpha) : UIColor(hex: light, alpha: lightAlpha)
        })
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}
