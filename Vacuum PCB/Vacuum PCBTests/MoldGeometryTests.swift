import Testing
import Foundation
@testable import Vacuum_PCB

/// The silicone casting frame's geometry is pure XY math shared between the
/// mesh builder (`PlateBuilder.buildMold`) and the sidebar pour-volume readout.
/// These lock that math: the cavity is the board outline inflated by the
/// casting margin, the volume is the cavity's rounded-rect footprint × sheet
/// thickness, and the frame disables cleanly at zero wall thickness.
@MainActor
struct MoldGeometryTests {

    private let outline = Rect(origin: .zero, size: Size(width: 50, height: 30))

    private func mfg(margin: Double, wall: Double, fillet: Double, sheet: Double)
        -> ManufacturingConstants {
        var m = ManufacturingConstants.defaults
        m.castingMargin = margin
        m.moldWallThickness = wall
        m.plateCornerFillet = fillet
        m.siliconeThickness = sheet
        return m
    }

    @Test func cavityInflatesOutlineByMargin() {
        let cavity = Mold.cavityRect(outline: outline,
                                     m: mfg(margin: 2, wall: 3, fillet: 0, sheet: 0.5))
        #expect(cavity.origin.x == -2)
        #expect(cavity.origin.y == -2)
        #expect(cavity.size.width == 54)
        #expect(cavity.size.height == 34)
    }

    @Test func outerWrapsCavityByWall() {
        let m = mfg(margin: 2, wall: 3, fillet: 0, sheet: 0.5)
        let outer = Mold.outerRect(outline: outline, m: m)
        #expect(outer != nil)
        // board 50×30 + 2·(margin 2 + wall 3) = 60×40.
        #expect(outer?.size.width == 60)
        #expect(outer?.size.height == 40)
    }

    @Test func frameDisabledAtZeroWall() {
        let m = mfg(margin: 2, wall: 0, fillet: 0, sheet: 0.5)
        #expect(Mold.outerRect(outline: outline, m: m) == nil)
    }

    @Test func sharpBoardCavityRoundsByMargin() {
        // Even with a square-cornered board (fillet 0), offsetting the outline
        // outward by the margin rounds the cavity corners to radius = margin.
        // cavity 54×34, r = 2: area = 54·34 − (4−π)·2² ; volume = area · 0.5.
        let m = mfg(margin: 2, wall: 3, fillet: 0, sheet: 0.5)
        let expectedArea = 54.0 * 34.0 - (4 - Double.pi) * 4
        let mm3 = expectedArea * 0.5
        #expect(abs(Mold.siliconeVolumeMM3(outline: outline, m: m) - mm3) < 1e-6)
        #expect(abs(Mold.siliconeVolumeML(outline: outline, m: m) - mm3 / 1000) < 1e-9)
    }

    @Test func volumeAccountsForRoundedCorners() {
        // cavity 54×34, corner radius = fillet 2 + margin 2 = 4 (unclamped).
        // area = 54·34 − (4−π)·4² ; volume = area · 0.5.
        let m = mfg(margin: 2, wall: 3, fillet: 2, sheet: 0.5)
        let expectedArea = 54.0 * 34.0 - (4 - Double.pi) * 16
        #expect(abs(Mold.siliconeVolumeMM3(outline: outline, m: m)
                    - expectedArea * 0.5) < 1e-6)
    }

    @Test func volumeScalesWithSheetThickness() {
        let thin = Mold.siliconeVolumeMM3(outline: outline,
                                          m: mfg(margin: 2, wall: 3, fillet: 0, sheet: 0.1))
        let thick = Mold.siliconeVolumeMM3(outline: outline,
                                           m: mfg(margin: 2, wall: 3, fillet: 0, sheet: 0.5))
        #expect(abs(thick - thin * 5) < 1e-6)
    }
}
