import SwiftUI

/// The cassette mark used for VYBE, drawn as a symbol so it follows the current tint.
struct VybeCassetteIcon: View {
    var size: CGFloat = 20

    var body: some View {
        CassetteOutline()
            .stroke(style: StrokeStyle(lineWidth: max(size * 0.06, 1), lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

private struct CassetteOutline: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height) }
        func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height, width: w * rect.width, height: h * rect.height)
        }
        var path = Path()
        path.addRoundedRect(in: box(0.07, 0.08, 0.86, 0.84), cornerSize: CGSize(width: rect.width * 0.03, height: rect.height * 0.03))
        path.addRoundedRect(in: box(0.17, 0.24, 0.66, 0.33), cornerSize: CGSize(width: rect.width * 0.02, height: rect.height * 0.02))
        for x: CGFloat in [0.26, 0.60] {
            path.addEllipse(in: box(x, 0.325, 0.14, 0.16))
            path.move(to: point(x + 0.07, 0.365)); path.addLine(to: point(x + 0.07, 0.445))
        }
        path.move(to: point(0.23, 0.92)); path.addLine(to: point(0.29, 0.69))
        path.addLine(to: point(0.71, 0.69)); path.addLine(to: point(0.77, 0.92))
        for x: CGFloat in [0.13, 0.84] {
            for y: CGFloat in [0.14, 0.82] { path.addEllipse(in: box(x, y, 0.025, 0.025)) }
        }
        return path
    }
}

struct LibrarySectionIcon: View {
    let section: LibrarySection
    var selected = false
    var size: CGFloat = 19
    var weight: Font.Weight = .regular

    var body: some View {
        if section == .vybe {
            VybeCassetteIcon(size: size)
        } else {
            Image(systemName: selected ? section.selectedIcon : section.icon).font(.system(size: size, weight: weight))
        }
    }
}
