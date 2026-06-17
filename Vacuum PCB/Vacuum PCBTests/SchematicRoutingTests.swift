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

    // MARK: - Grid + lanes

    @Test func gridSnapRoundsToStep() {
        #expect(SchematicLayout.snapToGrid(Point(x: 23, y: 57)) == Point(x: 20, y: 60))
        #expect(SchematicLayout.snapToGrid(Point(x: -11, y: 9)) == Point(x: -20, y: 0))
        #expect(SchematicLayout.snapToGrid(Point(x: 30, y: 50)) == Point(x: 40, y: 60))   // .5 rounds away from zero
    }

    @Test func laneOffsetIsDeterministicAndCentered() {
        #expect(SchematicWireGeometry.laneOffset(forNetAt: 2) == 0)
        #expect(SchematicWireGeometry.laneOffset(forNetAt: 0) == -14)
        #expect(SchematicWireGeometry.laneOffset(forNetAt: 4) == 14)
        // Repeats every 5 nets (stable, no jitter).
        #expect(SchematicWireGeometry.laneOffset(forNetAt: 5) == SchematicWireGeometry.laneOffset(forNetAt: 0))
    }

    // MARK: - Waypoints (router)

    @Test func routeThreadsWaypoints() {
        let a = CGPoint(x: 0, y: 0), b = CGPoint(x: 200, y: 0)
        let pts = WireRouter.route(from: a, .right, to: b, .left,
                                   waypoints: [CGPoint(x: 100, y: 80)])
        expectOrthogonal(pts)
        #expect(pts.contains { approx($0.x, 100) && approx($0.y, 80) })   // passes through it
        #expect(approx(pts.first!.x, 0) && approx(pts.last!.x, 200))
    }

    @Test func projectionFindsNearestPointAndArclength() {
        let poly = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100)]
        let p1 = WireRouter.projection(of: CGPoint(x: 40, y: 9), onto: poly)
        #expect(approx(p1.point.x, 40) && approx(p1.point.y, 0))
        #expect(approx(p1.arclength, 40))
        let p2 = WireRouter.projection(of: CGPoint(x: 109, y: 50), onto: poly)
        #expect(approx(p2.point.x, 100) && approx(p2.point.y, 50))
        #expect(approx(p2.arclength, 150))
    }

    @Test func routeAvoidsObstacleInTrunk() {
        // A box straddling the centred channel forces the vertical trunk off
        // the obstacle's x-band.
        let a = CGPoint(x: 0, y: 0), b = CGPoint(x: 200, y: 60)
        let box = CGRect(x: 90, y: -50, width: 20, height: 200)   // blocks x∈(90,110)
        let pts = WireRouter.route(from: a, .right, to: b, .left, obstacles: [box])
        expectOrthogonal(pts)
        for i in 0..<(pts.count - 1) where approx(pts[i].x, pts[i + 1].x) {
            let x = pts[i].x   // a vertical segment
            #expect(x <= 90.01 || x >= 109.99, "vertical trunk x=\(x) runs through the obstacle")
        }
    }

    // MARK: - Waypoints (model)

    @Test func pinPairIsCanonical() {
        let x = PinRef(componentId: UUID(), pinKey: "a")
        let y = PinRef(componentId: UUID(), pinKey: "b")
        #expect(PinPair(x, y) == PinPair(y, x))
    }

    @Test func waypointStoreOrientsAndMutates() {
        var layout = SchematicLayout.empty
        let p1 = PinRef(componentId: UUID(), pinKey: "1")
        let p2 = PinRef(componentId: UUID(), pinKey: "2")
        layout.setWaypoints([Point(x: 10, y: 0), Point(x: 20, y: 0)], a: p1, b: p2)

        #expect(layout.waypoints(p1, p2) == [Point(x: 10, y: 0), Point(x: 20, y: 0)])
        #expect(layout.waypoints(p2, p1) == [Point(x: 20, y: 0), Point(x: 10, y: 0)])  // reversed

        layout.moveWaypoint(pair: PinPair(p1, p2), index: 0, to: Point(x: 99, y: 9))
        #expect(layout.waypoints(p1, p2).contains(Point(x: 99, y: 9)))

        layout.removeWaypoint(pair: PinPair(p1, p2), index: 0)
        #expect(layout.waypoints(p1, p2).count == 1)
        layout.removeWaypoint(pair: PinPair(p1, p2), index: 0)
        #expect(layout.waypoints(p1, p2).isEmpty)
        #expect(layout.wireWaypoints == nil)   // empties back to byte-stable nil
    }

    @Test func removingComponentDropsItsWaypoints() {
        var layout = SchematicLayout.empty
        let c = UUID()
        layout.setWaypoints([Point(x: 1, y: 1)],
                            a: PinRef(componentId: c, pinKey: "1"),
                            b: PinRef(componentId: UUID(), pinKey: "2"))
        layout.remove(componentId: c)
        #expect(layout.wireWaypoints == nil)
    }

    @Test func layoutWaypointsBackCompatAndByteStable() throws {
        let decoded = try JSONDecoder().decode(
            SchematicLayout.self, from: Data(#"{"positions":[]}"#.utf8))
        #expect(decoded.wireWaypoints == nil)

        let data = try JSONEncoder().encode(SchematicLayout.empty)
        #expect(!String(decoding: data, as: UTF8.self).contains("wireWaypoints"))
    }

    // MARK: - Rail taps vs. wired edges

    @MainActor @Test func railNetRendersAsTaps() {
        var doc = CircuitDocument.blank()
        let vac = Component(kind: .vacuumSource, label: "VAC")
        let q = Component(kind: .transistor, label: "Q1")
        doc.logic.components = [vac, q]
        doc.logic.nets = [Net(label: "n", pins: [
            PinRef(componentId: vac.id, pinKey: "p"),
            PinRef(componentId: q.id, pinKey: "a"),
        ])]
        doc.schematic.setPosition(Point(x: 100, y: 100), for: vac.id)
        doc.schematic.setPosition(Point(x: 240, y: 220), for: q.id)

        let rendered = SchematicWireGeometry.render(in: doc)
        #expect(rendered.count == 1)
        #expect(rendered[0].edges.isEmpty)
        #expect(rendered[0].taps.count == 2)
        #expect(rendered[0].taps.allSatisfy { $0.rail == .vacuumSource })
    }

    @MainActor @Test func railNetWiredWhenTapsOff() {
        var doc = CircuitDocument.blank()
        let vac = Component(kind: .vacuumSource, label: "VAC")
        let q = Component(kind: .transistor, label: "Q1")
        doc.logic.components = [vac, q]
        doc.logic.nets = [Net(label: "n", pins: [
            PinRef(componentId: vac.id, pinKey: "p"),
            PinRef(componentId: q.id, pinKey: "a"),
        ])]
        doc.schematic.setPosition(Point(x: 100, y: 100), for: vac.id)
        doc.schematic.setPosition(Point(x: 240, y: 220), for: q.id)

        let rendered = SchematicWireGeometry.render(in: doc, railTaps: false)
        #expect(rendered[0].taps.isEmpty)        // toggled off → wired, not tapped
        #expect(rendered[0].edges.count == 1)
    }

    @MainActor @Test func plainNetRendersAsOrthogonalEdges() {
        var doc = CircuitDocument.blank()
        let r1 = Component(kind: .resistor, label: "R1", resistorSize: .medium)
        let r2 = Component(kind: .resistor, label: "R2", resistorSize: .medium)
        doc.logic.components = [r1, r2]
        doc.logic.nets = [Net(label: "n", pins: [
            PinRef(componentId: r1.id, pinKey: "2"),
            PinRef(componentId: r2.id, pinKey: "1"),
        ])]
        doc.schematic.setPosition(Point(x: 100, y: 100), for: r1.id)
        doc.schematic.setPosition(Point(x: 320, y: 160), for: r2.id)

        let rendered = SchematicWireGeometry.render(in: doc)
        #expect(rendered[0].taps.isEmpty)
        #expect(rendered[0].edges.count == 1)
        expectOrthogonal(rendered[0].edges[0].points)
    }

    // MARK: - Palette drag payload

    @Test func paletteDragRoundTrips() {
        let cases: [(ComponentKind, PortDirection?)] = [
            (.transistor, nil), (.resistor, nil), (.led, nil),
            (.vacuumSource, nil), (.atmVent, nil), (.connector, nil),
            (.port, .input), (.port, .output),
        ]
        for (kind, dir) in cases {
            let encoded = SchematicPaletteDrag.primitive(kind, dir).dragString
            guard case let .primitive(k, d)? = SchematicPaletteDrag(dragString: encoded) else {
                Issue.record("could not decode \(encoded)")
                continue
            }
            #expect(k == kind)
            #expect(d == dir)
        }
        #expect(SchematicPaletteDrag(dragString: "garbage") == nil)
        #expect(SchematicPaletteDrag(dragString: "lib:foo.vpcb") == nil)   // library not draggable
    }
}
