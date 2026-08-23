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
        s.castingMargin = max(0.0, m.castingMargin)
        s.moldWallThickness = max(0.0, m.moldWallThickness)
        s.minWallThickness = max(0.05, m.minWallThickness)
        s.preferredWallThickness = max(0.0, m.preferredWallThickness)
        s.testPointLabelSize = max(0.0, m.testPointLabelSize)
        s.modifierMarginXY = max(0.0, m.modifierMarginXY)
        s.modifierMarginZ = max(0.0, m.modifierMarginZ)
        return s
    }

    static func sanitizedSize(_ s: Size) -> Size {
        Size(width: max(1, s.width), height: max(1, s.height))
    }

    // MARK: - Route endpoint migration

    /// Walks every transistor placement, compares old vs. new pin world
    /// positions, and rewrites any route segment's first/last `.point`
    /// waypoint that's sitting on an old pin position to the new one. Via
    /// waypoints are left alone — they have twins on the other side of the
    /// silicone and don't terminate at component pins.
    static func migrateRouteEndpoints(
        oldMfg: ManufacturingConstants, newMfg: ManufacturingConstants,
        in document: inout VPCBDocument
    ) {
        struct PinShift { let from: Point; let to: Point }
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
                    shifts.append(PinShift(from: oldWorld, to: newWorld))
                }
            }
        }
        guard !shifts.isEmpty else { return }

        let snapEps = 0.05
        func migrated(_ p: Point) -> Point {
            for s in shifts
            where abs(p.x - s.from.x) < snapEps && abs(p.y - s.from.y) < snapEps {
                return s.to
            }
            return p
        }

        for rIdx in document.circuit.physical.routes.indices {
            for sIdx in document.circuit.physical.routes[rIdx].segments.indices {
                let count = document.circuit.physical.routes[rIdx]
                    .segments[sIdx].waypoints.count
                guard count > 0 else { continue }
                let firstWP = document.circuit.physical.routes[rIdx]
                    .segments[sIdx].waypoints[0]
                if firstWP.kind != .via {
                    let newPos = migrated(firstWP.position)
                    if newPos != firstWP.position {
                        document.circuit.physical.routes[rIdx]
                            .segments[sIdx].waypoints[0].position = newPos
                    }
                }
                if count > 1 {
                    let lastWP = document.circuit.physical.routes[rIdx]
                        .segments[sIdx].waypoints[count - 1]
                    if lastWP.kind != .via {
                        let newPos = migrated(lastWP.position)
                        if newPos != lastWP.position {
                            document.circuit.physical.routes[rIdx]
                                .segments[sIdx].waypoints[count - 1].position = newPos
                        }
                    }
                }
            }
        }
    }
}
