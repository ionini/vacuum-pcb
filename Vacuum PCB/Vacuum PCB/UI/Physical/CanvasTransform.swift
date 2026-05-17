import SwiftUI

/// 2D affine mapping between board coordinates (mm) and on-screen SwiftUI points.
/// Pan is applied first (in points), then scale (pts per mm). Origin (0,0 mm)
/// lives at `offset` on screen.
struct CanvasTransform: Hashable {
    var ptsPerMm: Double
    var offset: CGSize

    static let `default` = CanvasTransform(ptsPerMm: 8.0, offset: .zero)

    func toScreen(_ p: Point) -> CGPoint {
        CGPoint(x: offset.width + p.x * ptsPerMm,
                y: offset.height + p.y * ptsPerMm)
    }

    func toWorld(_ p: CGPoint) -> Point {
        Point(x: (Double(p.x) - offset.width) / ptsPerMm,
              y: (Double(p.y) - offset.height) / ptsPerMm)
    }

    func toScreenSize(_ size: Size) -> CGSize {
        CGSize(width: size.width * ptsPerMm, height: size.height * ptsPerMm)
    }

    func snap(_ p: Point, grid: Double) -> Point {
        Point(x: (p.x / grid).rounded() * grid,
              y: (p.y / grid).rounded() * grid)
    }

    /// Builds a transform that fits `rect` (mm) into `viewSize` (pts) with `margin` pts of padding.
    static func fit(rect: Rect, in viewSize: CGSize, margin: Double = 24) -> CanvasTransform {
        let availW = max(1, Double(viewSize.width)  - 2 * margin)
        let availH = max(1, Double(viewSize.height) - 2 * margin)
        let scale = min(availW / max(rect.size.width, 0.001),
                        availH / max(rect.size.height, 0.001))
        let usedW = rect.size.width  * scale
        let usedH = rect.size.height * scale
        let offX = (Double(viewSize.width)  - usedW) / 2 - rect.origin.x * scale
        let offY = (Double(viewSize.height) - usedH) / 2 - rect.origin.y * scale
        return CanvasTransform(ptsPerMm: scale, offset: CGSize(width: offX, height: offY))
    }
}
