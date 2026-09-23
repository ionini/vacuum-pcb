import Testing
import Foundation
import Euclid
@testable import Vacuum_PCB

/// `Volume.sections`: a cavity split at its resistors. The 3D preview's
/// primary click lights a whole volume (resistor-merged, as it bench-tests);
/// the secondary click lights one section — the cavity only as far as its
/// resistors. These pin the partition and the highlight-id helpers that let
/// one highlight set name either.
@MainActor
struct PhysicalVolumeSectionsTests {

    private let top0 = Layer(plate: .top, depth: 0)

    /// Two vents on the top plate, each routed on T0 to one end of a resistor
    /// between them: nets nA — R1 — nB. Physically one open cavity (the
    /// serpentine bleeds through), but two resistor-free sections.
    private func resistorBridgedDoc() -> CircuitDocument {
        var doc = CircuitDocument.blank()
        doc.physical.boardOutline = Rect(origin: .zero, size: Size(width: 80, height: 40))
        doc.skipEdgeWallDRC = true
        let r = Component(kind: .resistor, label: "R1", resistorSize: .medium)
        let a = Component(kind: .atmVent, label: "A")
        let b = Component(kind: .atmVent, label: "B")
        doc.logic.components = [r, a, b]
        let rp = Placement(componentId: r.id, position: Point(x: 40, y: 20), rotation: .r0, layer: .top, depth: 0)
        doc.physical.placements = [
            rp,
            Placement(componentId: a.id, position: Point(x: 15, y: 20), rotation: .r0, layer: .top, depth: 0),
            Placement(componentId: b.id, position: Point(x: 65, y: 20), rotation: .r0, layer: .top, depth: 0),
        ]
        let fp = r.footprint(doc.manufacturing)
        let p1 = rp.worldPosition(of: fp.pin("1")!)
        let p2 = rp.worldPosition(of: fp.pin("2")!)
        let nA = Net(label: "nA", pins: [PinRef(componentId: a.id, pinKey: "p"), PinRef(componentId: r.id, pinKey: "1")])
        let nB = Net(label: "nB", pins: [PinRef(componentId: b.id, pinKey: "p"), PinRef(componentId: r.id, pinKey: "2")])
        doc.logic.nets = [nA, nB]
        doc.physical.routes = [
            Route(netId: nA.id, segments: [Segment(waypoints: [
                Waypoint(position: Point(x: 15, y: 20)), Waypoint(position: p1)], layer: top0)]),
            Route(netId: nB.id, segments: [Segment(waypoints: [
                Waypoint(position: Point(x: 65, y: 20)), Waypoint(position: p2)], layer: top0)]),
        ]
        return doc
    }

    @Test("a resistor-joined cavity is one volume with one section per side")
    func resistorSplitsSections() {
        let vols = physicalVolumes(resistorBridgedDoc())
        #expect(vols.count == 1)
        guard let v = vols.first else { return }
        #expect(v.plate == .top)
        #expect(v.resistors.count == 1)
        #expect(v.nets.count == 2)
        #expect(v.sections.count == 2)

        // Each section is single-net, the two sides are different nets, and
        // together they partition the volume's geometry (resistors excluded).
        let sectionNets = v.sections.map { Set($0.segments.map(\.net)) }
        #expect(sectionNets.allSatisfy { $0.count == 1 })
        #expect(sectionNets[0] != sectionNets[1])
        #expect(v.sections.reduce(0) { $0 + $1.segments.count } == v.segments.count)
        #expect(v.sections.reduce(0) { $0 + $1.holes.count } == v.holes.count)
        #expect(v.sections.allSatisfy { $0.holes.count == 2 })   // vent + resistor end

        // Render-only views the scene meshes: a section carries no resistor,
        // the resistors view carries only the serpentine.
        let s0 = v.sectionVolume(0)
        #expect(s0.id == v.sectionID(0))
        #expect(s0.resistors.isEmpty)
        #expect(s0.segments.count == v.sections[0].segments.count)
        let rv = v.resistorsVolume
        #expect(rv.id == v.resistorsID)
        #expect(rv.resistors.count == 1 && rv.segments.isEmpty && rv.holes.isEmpty)
        #expect(!PlateBuilder.volumeMesh(for: s0, resistorBridgedDoc().manufacturing).isEmpty)
    }

    @Test("a resistor-free cavity has exactly one section")
    func noResistorSingleSection() {
        var doc = resistorBridgedDoc()
        // Drop the resistor: the two nets become two separate cavities.
        doc.logic.components.removeAll { $0.kind == .resistor }
        doc.physical.placements.removeAll { p in !doc.logic.components.contains { $0.id == p.componentId } }
        for i in doc.logic.nets.indices { doc.logic.nets[i].pins.removeAll { $0.pinKey == "1" || $0.pinKey == "2" } }
        let vols = physicalVolumes(doc)
        #expect(vols.count == 2)
        #expect(vols.allSatisfy { $0.sections.count == 1 && $0.resistors.isEmpty })
        for v in vols {
            #expect(v.sections[0].segments.count == v.segments.count)
            #expect(v.sections[0].holes.count == v.holes.count)
        }
    }

    @Test("highlight-id helpers split volume and section parts")
    func highlightIDHelpers() {
        #expect(Volume.volumeID(fromHighlightID: "T3#1") == "T3")
        #expect(Volume.volumeID(fromHighlightID: "T3") == "T3")
        #expect(Volume.sectionKey(fromHighlightID: "T3#1") == "1")
        #expect(Volume.sectionKey(fromHighlightID: "B2#res") == Volume.resistorsSectionKey)
        #expect(Volume.sectionKey(fromHighlightID: "T3") == nil)
        #expect(Volume.plate(ofVolumeID: "T3") == .top)
        #expect(Volume.plate(ofVolumeID: "B12") == .bottom)
        #expect(Volume.plate(ofVolumeID: "x") == nil)
    }
}
