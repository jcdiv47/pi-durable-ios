import SwiftUI

/// The Pi mark (`App/Icon/pi-logo-color.svg`), drawn as shapes so it stays sharp at any size and follows a widget's
/// rendering mode. It fills a 4×4 grid of cells: the coral bar and hook, the blue stem, the yellow leg.
struct PiLogo: View {
    var body: some View {
        ZStack {
            Piece(cells: [(0, 0), (3, 0), (3, 2), (2, 2), (2, 1), (0, 1)])
                .fill(Color(red: 0xF0 / 255, green: 0x90 / 255, blue: 0x82 / 255))
            Piece(cells: [(0, 1), (1, 1), (1, 2), (2, 2), (2, 3), (1, 3), (1, 4), (0, 4)])
                .fill(Color(red: 0x4D / 255, green: 0x9A / 255, blue: 0xBF / 255))
            Piece(cells: [(3, 2), (4, 2), (4, 4), (3, 4)])
                .fill(Color(red: 0xF1 / 255, green: 0xBE / 255, blue: 0x58 / 255))
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pi")
    }

    private struct Piece: Shape {
        let cells: [CGPoint]

        init(cells: [(CGFloat, CGFloat)]) {
            self.cells = cells.map { CGPoint(x: $0.0, y: $0.1) }
        }

        func path(in rect: CGRect) -> Path {
            let cell = min(rect.width, rect.height) / 4
            var path = Path()
            path.addLines(cells.map { CGPoint(x: rect.minX + $0.x * cell, y: rect.minY + $0.y * cell) })
            path.closeSubpath()
            return path
        }
    }
}
