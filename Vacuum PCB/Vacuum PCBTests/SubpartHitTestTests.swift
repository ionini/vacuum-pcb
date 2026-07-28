import Testing
import Foundation
@testable import Vacuum_PCB

/// `SubpartHitTest` answers "which sub-parts does this board point fall in?"
/// down the whole nesting chain, so the physical canvas's context menu can
/// offer to open each level. Board A embeds B at some pose; B embeds C at some
/// pose inside its own coordinates. A click on C must name both.
///
/// Every fixture here resolves through `librarySnapshots` (never the on-disk
/// parts folder), so the tests are hermetic: `Component.partRefHash` keys the
/// frozen document exactly the way a saved `.vpcb` does.
@MainActor
struct SubpartHitTestTests {

    // MARK: - Fixtures

    /// A library document that is just an outline of `size` at the origin.
    private func leafDoc(width: Double, height: Double) -> CircuitDocument {
        var doc = CircuitDocument.blank()
        doc.physical.boardOutline = Rect(
            origin: .zero, size: Size(width: width, height: height)
        )
        return doc
    }

    /// Places `child` (a library doc) into `parent` as a sub-part instance,
    /// pinning the snapshot the way a real save does.
    @discardableResult
    private func embed(
        _ child: CircuitDocument,
        named filename: String,
        label: String,
        at position: Point,
        rotation: Rotation = .r0,
        in parent: inout CircuitDocument
    ) -> UUID {
        let hash = child.contentHash()
        parent.librarySnapshots[hash] = child
        let component = Component(
            kind: .subpart, label: label, partRef: filename, partRefHash: hash
        )
        parent.logic.components.append(component)
        parent.physical.placements.append(Placement(
            componentId: component.id,
            position: position,
            rotation: rotation,
            layer: .top
        ))
        return component.id
    }

    /// Board A (100×100) ⊃ B at (10,10) ⊃ C at (5,5) in B's coordinates.
    /// B is 40×40, C is 10×10 — so in board space C covers (15,15)…(25,25).
    private func nestedBoard() -> CircuitDocument {
        var c = leafDoc(width: 10, height: 10)
        c.physical.boardOutline = Rect(origin: .zero, size: Size(width: 10, height: 10))

        var b = leafDoc(width: 40, height: 40)
        embed(c, named: "C.vpcb", label: "C1", at: Point(x: 5, y: 5), in: &b)

        var a = CircuitDocument.blank()
        a.physical.boardOutline = Rect(origin: .zero, size: Size(width: 100, height: 100))
        embed(b, named: "B.vpcb", label: "B1", at: Point(x: 10, y: 10), in: &a)
        return a
    }

    // MARK: - Nesting

    @Test("A point inside a nested sub-part names every level, outermost first")
    func nestedPointNamesBothLevels() {
        let hits = SubpartHitTest.hits(at: Point(x: 20, y: 20), in: nestedBoard())

        #expect(hits.count == 2)
        #expect(hits.map(\.displayName) == ["B", "C"])
        #expect(hits.map(\.depth) == [0, 1])
        #expect(hits[0].path == ["B1"])
        #expect(hits[1].path == ["B1", "C1"])
        #expect(hits[1].breadcrumb == "B1 ▸ C1")
        #expect(hits[1].partRef == "C.vpcb")
    }

    @Test("A point inside the parent but outside the child names only the parent")
    func pointInParentOnly() {
        // (40,40) is inside B (10,10)…(50,50) but past C's (15,15)…(25,25).
        let hits = SubpartHitTest.hits(at: Point(x: 40, y: 40), in: nestedBoard())

        #expect(hits.count == 1)
        #expect(hits[0].displayName == "B")
        #expect(hits[0].depth == 0)
    }

    @Test("Bare board area hits nothing")
    func pointOutsideEverything() {
        #expect(SubpartHitTest.hits(at: Point(x: 80, y: 80), in: nestedBoard()).isEmpty)
    }

    @Test("The outline is inclusive at its edges")
    func edgesCount() {
        let board = nestedBoard()
        // B spans (10,10)…(50,50) in board space; C spans (15,15)…(25,25).
        // Both of B's corners are on B alone — C starts 5 mm in.
        #expect(SubpartHitTest.hits(at: Point(x: 10, y: 10), in: board).count == 1)
        #expect(SubpartHitTest.hits(at: Point(x: 50, y: 50), in: board).count == 1)
        #expect(SubpartHitTest.hits(at: Point(x: 50.5, y: 50), in: board).isEmpty)
        // C's own corners count as inside, at both levels.
        #expect(SubpartHitTest.hits(at: Point(x: 15, y: 15), in: board).count == 2)
        #expect(SubpartHitTest.hits(at: Point(x: 25, y: 25), in: board).count == 2)
    }

    // MARK: - Pose

    @Test("Hit testing follows a rotated instance's pose")
    func rotatedInstance() {
        // B is corner-anchored and rotates about that corner: at r90 its local
        // +X runs along board +Y and its local +Y along board −X, so a local
        // (dx,dy) lands at board (10 − dy, 10 + dx). The 40×40 body therefore
        // swings into −X — B covers x ∈ [−30,10], y ∈ [10,50] — and C's local
        // (5,5)…(15,15) box lands at x ∈ [−5,5], y ∈ [15,25].
        var b = leafDoc(width: 40, height: 40)
        embed(leafDoc(width: 10, height: 10), named: "C.vpcb", label: "C1",
              at: Point(x: 5, y: 5), in: &b)

        var a = CircuitDocument.blank()
        a.physical.boardOutline = Rect(origin: .zero, size: Size(width: 100, height: 100))
        embed(b, named: "B.vpcb", label: "B1", at: Point(x: 10, y: 10),
              rotation: .r90, in: &a)

        // Centre of C under the rotated pose: local (10,10) → board (0, 20).
        let inside = SubpartHitTest.hits(at: Point(x: 0, y: 20), in: a)
        #expect(inside.map(\.displayName) == ["B", "C"])

        // Inside the swung-round body, clear of C.
        let parentOnly = SubpartHitTest.hits(at: Point(x: -20, y: 40), in: a)
        #expect(parentOnly.map(\.displayName) == ["B"])

        // Where C would have been without the rotation: now off B entirely.
        #expect(SubpartHitTest.hits(at: Point(x: 20, y: 20), in: a).isEmpty)
    }

    @Test("localPoint inverts the renderer's corner-anchored transform")
    func localPointRoundTrip() {
        // Library outlines don't have to start at the origin — the anchor rule
        // maps the outline's top-left corner onto `placement.position`, so a
        // non-zero origin has to survive the round trip.
        let outline = Rect(origin: Point(x: -7, y: 3), size: Size(width: 20, height: 12))
        let placement = Placement(
            componentId: UUID(), position: Point(x: 30, y: 40), rotation: .r270, layer: .top
        )
        let library = Point(x: -2, y: 9)

        // Forward transform, copied from `SubpartExpandedView.transformWorld`.
        let dx = library.x - outline.minX
        let dy = library.y - outline.minY
        let r = placement.rotation.radians
        let world = Point(
            x: placement.position.x + dx * cos(r) - dy * sin(r),
            y: placement.position.y + dx * sin(r) + dy * cos(r)
        )

        let back = SubpartHitTest.localPoint(world, in: placement, outline: outline)
        #expect(abs(back.x - library.x) < 1e-9)
        #expect(abs(back.y - library.y) < 1e-9)
    }

    // MARK: - Degenerate structures

    @Test("Overlapping siblings all report, each with its own chain")
    func overlappingSiblings() {
        // Socket-mated assemblies stack every sub-part at one origin, so the
        // menu has to list them rather than pick a winner.
        var a = CircuitDocument.blank()
        a.physical.boardOutline = Rect(origin: .zero, size: Size(width: 100, height: 100))
        embed(leafDoc(width: 30, height: 30), named: "B.vpcb", label: "B1",
              at: .zero, in: &a)
        embed(leafDoc(width: 20, height: 20), named: "D.vpcb", label: "D1",
              at: .zero, in: &a)

        let hits = SubpartHitTest.hits(at: Point(x: 5, y: 5), in: a)
        #expect(Set(hits.map(\.displayName)) == ["B", "D"])
        #expect(hits.allSatisfy { $0.depth == 0 })
    }

    @Test("A self-referencing library terminates instead of recursing forever")
    func cycleTerminates() {
        // A snapshot that embeds its own filename — the shape the renderer
        // guards with its `visiting` set. Hand-built because a real save can't
        // produce a document that contains itself.
        var loop = leafDoc(width: 40, height: 40)
        let inner = Component(
            kind: .subpart, label: "Loop", partRef: "Loop.vpcb",
            partRefHash: "loop-hash"
        )
        loop.logic.components.append(inner)
        loop.physical.placements.append(Placement(
            componentId: inner.id, position: .zero, rotation: .r0, layer: .top
        ))
        loop.librarySnapshots["loop-hash"] = loop

        var a = CircuitDocument.blank()
        a.physical.boardOutline = Rect(origin: .zero, size: Size(width: 100, height: 100))
        a.librarySnapshots["loop-hash"] = loop
        let outer = Component(
            kind: .subpart, label: "L1", partRef: "Loop.vpcb", partRefHash: "loop-hash"
        )
        a.logic.components.append(outer)
        a.physical.placements.append(Placement(
            componentId: outer.id, position: Point(x: 10, y: 10), rotation: .r0, layer: .top
        ))

        let hits = SubpartHitTest.hits(at: Point(x: 20, y: 20), in: a)
        #expect(hits.count == 1)
        #expect(hits[0].path == ["L1"])
    }
}
