import Testing
import Foundation
import SwiftUI
@testable import Vacuum_PCB

/// Orthogonal schematic wire routing + 90° component rotation. All pure
/// geometry / model state, so these run fast and headless. Model layer is
/// main-actor-isolated, hence `@MainActor`.
@MainActor
struct SchematicRoutingTests {

    // MARK: - Helpers

    private func approx(_ a: CGFloat, _ b: CGFloat, _ tol: CGFloat = 0.01) -> Bool {
        abs(a - b) < tol
    }

    /// Every consecutive segment of the polyline must be axis-aligned — that
    /// is the whole point of orthogonal routing.
    private func expectOrthogonal(_ pts: [CGPoint], sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(pts.count >= 2)
        for i in 0..<(pts.count - 1) {
            let dx = abs(pts[i].x - pts[i + 1].x)
            let dy = abs(pts[i].y - pts[i + 1].y)
            #expect(dx < 0.01 || dy < 0.01,
                    "segment \(i) not axis-aligned: \(pts[i]) -> \(pts[i + 1])",
                    sourceLocation: sourceLocation)
        }
    }

    // MARK: - ExitDir

    @Test func exitDirSnapsToDominantAxis() {
        #expect(ExitDir.from(CGPoint(x: 45, y: 0)) == .right)
        #expect(ExitDir.from(CGPoint(x: -45, y: 0)) == .left)
        #expect(ExitDir.from(CGPoint(x: 0, y: 40)) == .down)   // +y is down
        #expect(ExitDir.from(CGPoint(x: 0, y: -40)) == .up)
        #expect(ExitDir.from(.zero) == .right)                 // fallback
        // Dominant axis wins when both components are non-zero.
        #expect(ExitDir.from(CGPoint(x: 50, y: 10)) == .right)
        #expect(ExitDir.from(CGPoint(x: 10, y: 50)) == .down)
    }

    @Test func exitDirFromSymbolSide() {
        #expect(ExitDir(side: .left) == .left)
        #expect(ExitDir(side: .right) == .right)
        #expect(ExitDir(side: .top) == .up)
        #expect(ExitDir(side: .bottom) == .down)
    }

    // MARK: - WireRouter.route

    @Test func alignedPinsRouteStraight() {
        // Two facing pins at the same height collapse to a single segment —
        // zero corners.
        let pts = WireRouter.route(from: CGPoint(x: 0, y: 0), .right,
                                   to: CGPoint(x: 100, y: 0), .left)
        #expect(pts.count == 2)
        #expect(approx(pts.first!.x, 0) && approx(pts.last!.x, 100))
        expectOrthogonal(pts)
    }

    @Test func offsetFacingPinsRouteOrthogonally() {
        // Facing pins at different heights → a Z (two corners) with all
        // segments axis-aligned and the endpoints preserved.
        let a = CGPoint(x: 0, y: 0), b = CGPoint(x: 120, y: 60)
        let pts = WireRouter.route(from: a, .right, to: b, .left)
        expectOrthogonal(pts)
        #expect(approx(pts.first!.x, a.x) && approx(pts.first!.y, a.y))
        #expect(approx(pts.last!.x, b.x) && approx(pts.last!.y, b.y))
        #expect(pts.count <= 4)                                // ≤ 2 corners
    }

    @Test func mixedExitsRouteWithSingleCornerNoOvershoot() {
        // Horizontal exit into a vertical exit → exactly one corner, and the
        // path must END at b (no stub overshoot past the pin).
        let a = CGPoint(x: 0, y: 0), b = CGPoint(x: 50, y: 50)
        let pts = WireRouter.route(from: a, .right, to: b, .down)
        expectOrthogonal(pts)
        #expect(pts.count == 3)
        #expect(approx(pts.last!.x, b.x) && approx(pts.last!.y, b.y))
    }

    @Test func freeEndRoutesFromAnchoredPinOnly() {
        // Rubber-band case: only the fixed pin stubs out; the cursor end is free.
        let a = CGPoint(x: 0, y: 0), cursor = CGPoint(x: 60, y: 40)
        let pts = WireRouter.route(from: a, .right, to: cursor, nil)
        expectOrthogonal(pts)
        #expect(approx(pts.first!.x, a.x) && approx(pts.first!.y, a.y))
        #expect(approx(pts.last!.x, cursor.x) && approx(pts.last!.y, cursor.y))
    }

    @Test func wireLeavesPinStraightOutNotThroughBody() {
        // Regression: a pin on the left edge wiring to a target on the lower
        // right must leave the pin going LEFT (straight out), then turn — never
        // cut back rightward through its own body.
        let a = CGPoint(x: 0, y: 0)
        let b = CGPoint(x: 200, y: 150)
        let pts = WireRouter.route(from: a, .left, to: b, .left)
        expectOrthogonal(pts)
        #expect(pts.count >= 2)
        #expect(pts[1].x < pts[0].x - 0.01)            // first move is leftward (outward)
        #expect(approx(pts[1].y, pts[0].y))            // ...and stays on the pin's row (a real stub)
        // No vertex sits to the right of the pin while still at the pin's row
        // (which would mean the wire ran through the body).
        for p in pts where approx(p.y, a.y) {
            #expect(p.x <= a.x + 0.01)
        }
    }

    @Test func wireLeavesTopPinUpward() {
        // A top-edge pin (exit .up) wiring downward must first step UP out of
        // the body, then route down and across.
        let pts = WireRouter.route(from: CGPoint(x: 0, y: 0), .up,
                                   to: CGPoint(x: 120, y: 200), .left)
        expectOrthogonal(pts)
        #expect(pts[1].y < pts[0].y - 0.01)            // first move is upward (outward)
        #expect(approx(pts[1].x, pts[0].x))
    }

    @Test func cleanCollapsesColinearOvershoot() {
        // A stub that points away from the route leaves a colinear backtrack;
        // `clean` must collapse it so the wire ends cleanly at the pin.
        let pts = WireRouter.clean([
            CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 0),
            CGPoint(x: 50, y: 64), CGPoint(x: 50, y: 50),   // overshoot to 64 then back
        ])
        #expect(pts == [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 0), CGPoint(x: 50, y: 50)])
    }

    @Test func roundedPathIsNonEmptyForACorner() {
        let path = WireRouter.roundedPath(
            [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 0), CGPoint(x: 50, y: 50)],
            radius: 9
        )
        #expect(!path.isEmpty)
    }

    @Test func distanceToPolylineMeasuresNearestSegment() {
        let poly = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100)]
        #expect(approx(WireRouter.distance(from: CGPoint(x: 50, y: 8), to: poly), 8))
        #expect(approx(WireRouter.distance(from: CGPoint(x: 92, y: 50), to: poly), 8))
    }

    // MARK: - ComponentSymbolMetrics.rotated

    @Test func rotateResistorSwapsSizeAndPinsToVertical() {
        let base = ComponentSymbolMetrics.metrics(for: .resistor)   // 90×30, pins on ±x
        let r = base.rotated(by: 1)                                  // 90° CW
        #expect(approx(r.size.width, 30) && approx(r.size.height, 90))
        // Pins move to the vertical axis (x≈0), one up one down.
        #expect(approx(r.pinOffset("1").x, 0) && approx(abs(r.pinOffset("1").y), 45))
        #expect(approx(r.pinOffset("2").x, 0) && approx(abs(r.pinOffset("2").y), 45))
        #expect(!approx(r.pinOffset("1").y, r.pinOffset("2").y))     // opposite sides
    }

    @Test func rotateByTwoFlipsPinsKeepsSize() {
        let base = ComponentSymbolMetrics.metrics(for: .resistor)
        let r = base.rotated(by: 2)
        #expect(approx(r.size.width, 90) && approx(r.size.height, 30))   // even turn: no swap
        #expect(approx(r.pinOffset("1").x, 45))                          // -45 → +45
        #expect(approx(r.pinOffset("2").x, -45))
    }

    @Test func rotateFullTurnIsIdentity() {
        let base = ComponentSymbolMetrics.metrics(for: .transistor)
        let r = base.rotated(by: 4)
        for key in ["gate", "a", "b"] {
            #expect(approx(r.pinOffset(key).x, base.pinOffset(key).x))
            #expect(approx(r.pinOffset(key).y, base.pinOffset(key).y))
        }
        #expect(approx(r.size.width, base.size.width) && approx(r.size.height, base.size.height))
    }

    // MARK: - SymbolSide.rotated

    @Test func symbolSideRotatesClockwise() {
        #expect(SymbolSide.right.rotated(by: 1) == .bottom)
        #expect(SymbolSide.bottom.rotated(by: 1) == .left)
        #expect(SymbolSide.left.rotated(by: 1) == .top)
        #expect(SymbolSide.top.rotated(by: 1) == .right)
        for side in [SymbolSide.left, .right, .top, .bottom] {
            #expect(side.rotated(by: 4) == side)
            #expect(side.rotated(by: -1) == side.rotated(by: 3))
        }
    }

    // MARK: - SchematicLayout rotation

    @Test func layoutRotationAccessorsCycle() {
        var layout = SchematicLayout.empty
        let id = UUID()
        layout.setPosition(Point(x: 10, y: 20), for: id)
        #expect(layout.rotation(for: id) == 0)

        layout.rotate(componentId: id, by: 1)
        #expect(layout.rotation(for: id) == 1)
        layout.rotate(componentId: id, by: 1)
        layout.rotate(componentId: id, by: 1)
        #expect(layout.rotation(for: id) == 3)
        layout.rotate(componentId: id, by: 1)                       // wraps to 0
        #expect(layout.rotation(for: id) == 0)

        layout.rotate(componentId: id, by: -1)                      // negative wraps
        #expect(layout.rotation(for: id) == 3)

        // Rotating preserves the stored position.
        #expect(layout.position(for: id) == Point(x: 10, y: 20))
        #expect(layout.rotation(for: UUID()) == 0)                  // unknown id
    }

    @Test func unrotatedPositionStaysByteStable() throws {
        // Old designs have no rotation key; an unrotated position must omit it
        // on encode (byte-stable) and decode back to nil.
        let p = SchematicPosition(componentId: UUID(), position: Point(x: 1, y: 2))
        let data = try JSONEncoder().encode(p)
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("rotationQuarterTurns"))

        let decoded = try JSONDecoder().decode(SchematicPosition.self, from: data)
        #expect(decoded.rotationQuarterTurns == nil)
    }

    @Test func rotatedPositionRoundTrips() throws {
        let p = SchematicPosition(componentId: UUID(), position: Point(x: 1, y: 2),
                                  rotationQuarterTurns: 3)
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(SchematicPosition.self, from: data)
        #expect(decoded.rotationQuarterTurns == 3)
    }
}
