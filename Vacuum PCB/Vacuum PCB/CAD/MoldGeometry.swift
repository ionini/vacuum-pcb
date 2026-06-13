import Foundation

/// Geometry of the silicone casting frame — the open-top/open-bottom "cookie
/// cutter" the silicone sheet is poured into. Pure XY math (no Euclid) so both
/// the mesh builder (`PlateBuilder.buildMold`) and the volume readout in the UI
/// share one source of truth for the cavity dimensions.
///
/// Layout (viewed from above), all concentric rounded rectangles:
///   • board outline                      — what the stencil eventually cuts
///   • + `castingMargin`  → cavity inner  — the pour area (kept flat, inboard
///                                           of the meniscus the silicone climbs
///                                           against the wall)
///   • + `moldWallThickness` → frame outer — the printed ring's outer edge
///
/// The frame is printed exactly `siliconeThickness` tall, so the wall height
/// equals the target sheet thickness and the silicone can't climb past it.
enum Mold {

    /// Inner cavity of the frame — the rounded rectangle the silicone is poured
    /// into. The board outline inflated by `castingMargin` on every side.
    static func cavityRect(outline: Rect, m: ManufacturingConstants) -> Rect {
        inflate(outline, by: max(0, m.castingMargin))
    }

    /// Outer edge of the printed frame: the cavity inflated by the wall
    /// thickness. Returns `nil` when the frame is disabled (`moldWallThickness`
    /// ≤ 0) — callers should skip building / showing the mold in that case.
    static func outerRect(outline: Rect, m: ManufacturingConstants) -> Rect? {
        guard m.moldWallThickness > 0 else { return nil }
        return inflate(cavityRect(outline: outline, m: m), by: m.moldWallThickness)
    }

    /// Corner-fillet radius applied to a concentric ring at `inset` outside the
    /// board outline. Inflating a rounded rect by `d` grows its corner radius by
    /// `d`; clamped to the rect so a wild fillet can't self-intersect (mirrors
    /// `PlateBuilder.plateBase`'s clamp).
    static func cornerRadius(for rect: Rect, baseFillet: Double, inset: Double) -> Double {
        let r = max(0, baseFillet) + max(0, inset)
        let clamp = min(rect.size.width / 2 * 0.99, rect.size.height / 2 * 0.99)
        return max(0, min(r, clamp))
    }

    /// Volume of silicone to pour into the cavity, in mm³. Cavity footprint
    /// (rounded-rect area) × sheet thickness. Accounts for the rounded corners
    /// so the dosed amount matches the printed frame rather than overshooting on
    /// a plain width×height.
    static func siliconeVolumeMM3(outline: Rect, m: ManufacturingConstants) -> Double {
        let cavity = cavityRect(outline: outline, m: m)
        let r = cornerRadius(for: cavity,
                             baseFillet: m.plateCornerFillet, inset: m.castingMargin)
        // Rounded rectangle area: full rect minus the four corner offcuts. Each
        // corner removes a square of side r and adds back a quarter-disc, i.e.
        // (4 - π)·r² of material is missing across all four corners.
        let area = cavity.size.width * cavity.size.height - (4 - Double.pi) * r * r
        return max(0, area) * max(0, m.siliconeThickness)
    }

    /// Convenience: pour volume in millilitres (1 mL = 1 cm³ = 1000 mm³).
    static func siliconeVolumeML(outline: Rect, m: ManufacturingConstants) -> Double {
        siliconeVolumeMM3(outline: outline, m: m) / 1000
    }

    /// Grows a rect outward by `d` on every side (negative `d` shrinks it).
    static func inflate(_ rect: Rect, by d: Double) -> Rect {
        Rect(
            origin: Point(x: rect.origin.x - d, y: rect.origin.y - d),
            size: Size(width: rect.size.width + 2 * d, height: rect.size.height + 2 * d)
        )
    }
}
