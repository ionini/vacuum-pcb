import Foundation

/// Document mutations for the manufacturing constants, shared by the two
/// paths that can write them: the inspector's Apply button
/// (`ManufacturingSettingsView`) and the Edit-menu paste
/// (`ManufacturingPasteSheet`). Both must clamp *and* migrate route
/// endpoints, so the logic lives here instead of inside the settings view.
enum ManufacturingActions {

    /// Clamps every constant into its physically-printable range and writes
    /// it to the document, dragging any route endpoint that was sitting on a
    /// moved footprint pin along with it.
    static func commit(_ newMfg: ManufacturingConstants, to document: inout VPCBDocument) {
        let sanitizedMfg = sanitized(newMfg)
        let oldMfg = document.circuit.manufacturing
        guard sanitizedMfg != oldMfg else { return }
        // Migrate any route endpoint sitting at an old pin position over to
        // the new one, so changing padsOffset (or anything else that shifts
        // a footprint pin) doesn't strand routes on stale coordinates.
        migrateRouteEndpoints(oldMfg: oldMfg, newMfg: sanitizedMfg, in: &document)
        document.circuit.manufacturing = sanitizedMfg
    }

    // MARK: - Sanitisation

    /// Copy-and-mutate, NOT a memberwise rebuild: a rebuild silently resets any
    /// field someone forgets to list back to its init default on every Apply —
    /// which is exactly what happened to the envelope margins when they were
    /// added. With a mutated copy, an unlisted field simply passes through
    /// unclamped, which is the safe failure mode.
    static func sanitized(_ m: ManufacturingConstants) -> ManufacturingConstants {
        var s = m
        s.plateThickness = max(0.1, m.plateThickness)
        s.channelDiameter = max(0.05, m.channelDiameter)
        s.portBoreDiameter = max(0.05, m.portBoreDiameter)
        s.portBoreTaperDegrees = max(0.0, min(45.0, m.portBoreTaperDegrees))
        s.siliconeThickness = max(0.05, m.siliconeThickness)
        s.dimpleDiameter = max(0.1, m.dimpleDiameter)
        s.dimpleDepth = max(0.05, m.dimpleDepth)
        s.dimpleSphereOffset = max(0.0, m.dimpleSphereOffset)
        s.padsDiameter = max(0.1, m.padsDiameter)
        s.padsSeparation = max(0.0, m.padsSeparation)
        s.padsOffset = max(0.0, m.padsOffset)
        s.padsFilletRadius = max(0.0, m.padsFilletRadius)
        s.gridPitch = max(0.05, m.gridPitch)
        s.minChannelSpacing = max(0.05, m.minChannelSpacing)
        s.resistorChannelDiameter = max(0.05, m.resistorChannelDiameter)
        s.interLayerWall = max(0.1, m.interLayerWall)
        s.plateCornerFillet = max(0.0, m.plateCornerFillet)
        s.ledDimpleDiameter = max(0.1, m.ledDimpleDiameter)
        s.ledDimpleDepth = max(0.0, m.ledDimpleDepth)
        s.screwProtrusion = max(0.0, m.screwProtrusion)
        s.screwDomeBaseDiameter = max(ScrewGeometry.headDiameter + 0.2,
                                      m.screwDomeBaseDiameter)
        s.screwHeadDepth = max(0.1, m.screwHeadDepth)
        s.screwNutDepth = max(0.1, m.screwNutDepth)
        // Cap at the head diameter: a bore wider than the countersink would
        // swallow the head straight through the plate.
        s.screwThroughDiameter = max(0.5, min(ScrewGeometry.headDiameter,
                                              m.screwThroughDiameter))
        s.stencilThickness = max(0.05, m.stencilThickness)
        s.stencilViaPadding = max(0.0, min(2.0, m.stencilViaPadding))
        s.stencilScrewPadding = max(0.0, min(6.0, m.stencilScrewPadding))
        // Gasket paddings mirror the stencil paddings' ranges; the band width
        // just needs to stay positive (the capsule degenerates gracefully).
        s.connectorGasketWidth = max(0.0, m.connectorGasketWidth)
        s.connectorGasketViaPadding = max(0.0, min(2.0, m.connectorGasketViaPadding))
        s.connectorGasketScrewPadding = max(0.0, min(6.0, m.connectorGasketScrewPadding))
        s.connectorPadding = max(0.0, m.connectorPadding)
        s.castingMargin = max(0.0, m.castingMargin)
        s.moldWallThickness = max(0.0, m.moldWallThickness)
        s.minWallThickness = max(0.05, m.minWallThickness)
        s.preferredWallThickness = max(0.0, m.preferredWallThickness)
        s.testPointLabelSize = max(0.0, m.testPointLabelSize)
        s.modifierMarginXY = max(0.0, m.modifierMarginXY)
        s.modifierMarginZ = max(0.0, m.modifierMarginZ)
        // Slicer recipe for the `_resistors` part: density is a percentage;
        // the pattern token is passed to Bambu verbatim, just never blank
        // (a blank sparse_infill_pattern row would clear the slicer field).
        s.resistorInfillDensity = max(1.0, min(100.0, m.resistorInfillDensity))
        if s.resistorInfillPattern.trimmingCharacters(in: .whitespaces).isEmpty {
            s.resistorInfillPattern = "zigzag"
        }
        return s
    }

    static func sanitizedSize(_ s: Size) -> Size {
        Size(width: max(1, s.width), height: max(1, s.height))
    }

    // MARK: - Route endpoint migration

    /// Walks every placement, compares old vs. new pin world positions, and
    /// patches any route segment's first/last `.point` waypoint that's
    /// sitting on an old pin position. Ordinary pins (transistor pads etc.)
    /// have their endpoint *moved* to the new position; connector pins get a
    /// straight "neck" segment *appended* from the old attach point to the
    /// new pin instead — the connector's padding slides the pin outward
    /// along the protrusion axis, so the drawn route keeps its shape and
    /// just grows a straight run out to the relocated pin. When the
    /// existing final leg is already collinear with the move (e.g. a neck
    /// segment added by a previous padding edit), the endpoint slides along
    /// it instead, so repeated edits don't pile up waypoints. Via waypoints
    /// are left alone — they have twins on the other side of the silicone
    /// and don't terminate at component pins.
    static func migrateRouteEndpoints(
        oldMfg: ManufacturingConstants, newMfg: ManufacturingConstants,
        in document: inout VPCBDocument
    ) {
        struct PinShift { let from: Point; let to: Point; let extend: Bool }
        var shifts: [PinShift] = []
        for placement in document.circuit.physical.placements {
            guard let component = document.circuit.logic.components
                    .first(where: { $0.id == placement.componentId })
            else { continue }
            let snapshots = document.circuit.librarySnapshots
            let oldFp = component.footprint(oldMfg, snapshots: snapshots)
            let newFp = component.footprint(newMfg, snapshots: snapshots)
            for newPin in newFp.pins {
                guard let oldPin = oldFp.pin(newPin.key) else { continue }
                let oldWorld = placement.worldPosition(of: oldPin)
                let newWorld = placement.worldPosition(of: newPin)
                if hypot(oldWorld.x - newWorld.x, oldWorld.y - newWorld.y) > 0.001 {
                    shifts.append(PinShift(from: oldWorld, to: newWorld,
                                           extend: component.kind == .connector))
                }
            }
        }
        guard !shifts.isEmpty else { return }

        let snapEps = 0.05
        func shift(at p: Point) -> PinShift? {
            shifts.first {
                abs(p.x - $0.from.x) < snapEps && abs(p.y - $0.from.y) < snapEps
            }
        }

        /// Patches the endpoint at `endIndex` (0 or waypoints.count - 1) in
        /// place, per the move-vs-extend rules above. `neighborIndex` is the
        /// adjacent interior waypoint (nil for single-point segments).
        func patch(_ waypoints: inout [Waypoint], endIndex: Int, neighborIndex: Int?) {
            let wp = waypoints[endIndex]
            guard wp.kind != .via, let s = shift(at: wp.position) else { return }
            if s.extend, let nIdx = neighborIndex {
                // Collinear when the final leg and the pin shift lie on one
                // line (normalised cross product ≈ 0) — then sliding the
                // endpoint IS the straight extension.
                let n = waypoints[nIdx].position
                let ax = wp.position.x - n.x, ay = wp.position.y - n.y
                let bx = s.to.x - n.x, by = s.to.y - n.y
                let cross = ax * by - ay * bx
                let scale = hypot(ax, ay) * hypot(bx, by)
                if scale > 0, abs(cross) / scale > 1e-6 {
                    let neck = Waypoint(position: s.to, kind: .point)
                    if endIndex == 0 { waypoints.insert(neck, at: 0) }
                    else { waypoints.append(neck) }
                    return
                }
            }
            waypoints[endIndex].position = s.to
        }

        for rIdx in document.circuit.physical.routes.indices {
            for sIdx in document.circuit.physical.routes[rIdx].segments.indices {
                var waypoints = document.circuit.physical.routes[rIdx]
                    .segments[sIdx].waypoints
                let count = waypoints.count
                guard count > 0 else { continue }
                patch(&waypoints, endIndex: 0,
                      neighborIndex: count > 1 ? 1 : nil)
                if count > 1 {
                    // Indices re-read after the first patch may have grown
                    // the array by one at the front.
                    let last = waypoints.count - 1
                    patch(&waypoints, endIndex: last, neighborIndex: last - 1)
                }
                if waypoints != document.circuit.physical.routes[rIdx]
                    .segments[sIdx].waypoints {
                    document.circuit.physical.routes[rIdx]
                        .segments[sIdx].waypoints = waypoints
                }
            }
        }
    }
}
