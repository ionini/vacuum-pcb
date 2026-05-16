import Foundation

/// Force-directed placement, biased toward a small bounding box.
///
/// Each net pulls its pins together (spring), each component pushes the
/// others away (repulsion), and a weak global pull toward the centroid keeps
/// the cluster from drifting toward an edge while still letting net springs
/// shape the layout. After convergence (or N iterations) the result snaps to
/// the manufacturing grid pitch. The goal is "decent starting positions" —
/// the user is expected to nudge things by hand. Components clamp to the
/// board outline so nothing escapes the printable area.
enum AutoPlacer {
    /// Returns updated positions for every placed component. The caller
    /// writes them back to the document. Unplaced components are ignored —
    /// they need to be on the board first (use "Place all" in the parking
    /// lot panel).
    static func place(_ doc: CircuitDocument) -> [(componentId: UUID, position: Point)] {
        let outline = doc.physical.boardOutline
        guard outline.size.width > 0, outline.size.height > 0 else { return [] }
        let pitch = doc.manufacturing.gridPitch

        // Initial state: copy current positions for placed components.
        var positions: [UUID: Point] = [:]
        for placement in doc.physical.placements {
            positions[placement.componentId] = placement.position
        }
        guard positions.count >= 2 else { return positions.map { ($0.key, $0.value) } }

        // Pre-compute per-component repulsion radius — half the bounding box's
        // longer side, so two components don't sit closer than their bodies
        // touch even after settling.
        var radii: [UUID: Double] = [:]
        for placement in doc.physical.placements {
            guard let component = doc.logic.components.first(where: { $0.id == placement.componentId })
            else { continue }
            let b = component.footprint(doc.manufacturing).boundingRect
            radii[placement.componentId] = max(b.size.width, b.size.height) / 2
        }

        // Net-pin map for the spring force.
        struct PinAnchor {
            let componentId: UUID
            let offset: Point
            let footprintOffsetSquared: Double
        }
        var netPins: [(netId: UUID, pins: [PinAnchor])] = []
        for net in doc.logic.nets {
            var pins: [PinAnchor] = []
            for pinRef in net.pins {
                guard positions[pinRef.componentId] != nil,
                      let component = doc.logic.components.first(where: { $0.id == pinRef.componentId }),
                      let fp = component.footprint(doc.manufacturing).pin(pinRef.pinKey)
                else { continue }
                pins.append(PinAnchor(
                    componentId: pinRef.componentId,
                    offset: fp.offset,
                    footprintOffsetSquared: 0
                ))
            }
            if pins.count >= 2 { netPins.append((net.id, pins)) }
        }

        let iterations = 240
        // Tuning knobs. Spring stronger than centroid, repulsion grows as
        // bodies overlap. Step decays so the layout settles instead of
        // oscillating.
        let springK = 0.05
        let repulsionK = 8.0
        let centroidK = 0.004
        let centroid = Point(
            x: outline.origin.x + outline.size.width / 2,
            y: outline.origin.y + outline.size.height / 2
        )

        let ids = Array(positions.keys)
        for iter in 0..<iterations {
            let step = max(0.05, 1.0 - Double(iter) / Double(iterations))
            var forces: [UUID: (dx: Double, dy: Double)] = Dictionary(uniqueKeysWithValues: ids.map { ($0, (0.0, 0.0)) })

            // 1. Spring forces along nets. Pin-to-pin attraction pulls the
            // components themselves (translate the force from pin space to
            // component space).
            for (_, pins) in netPins {
                guard let anchor = pins.first else { continue }
                guard let pAnchorPos = positions[anchor.componentId] else { continue }
                let pAnchorPin = Point(x: pAnchorPos.x + anchor.offset.x, y: pAnchorPos.y + anchor.offset.y)
                for other in pins.dropFirst() {
                    guard let pOtherPos = positions[other.componentId] else { continue }
                    let pOtherPin = Point(x: pOtherPos.x + other.offset.x, y: pOtherPos.y + other.offset.y)
                    let dx = pOtherPin.x - pAnchorPin.x
                    let dy = pOtherPin.y - pAnchorPin.y
                    let fx = -springK * dx
                    let fy = -springK * dy
                    forces[other.componentId]?.dx += fx
                    forces[other.componentId]?.dy += fy
                    forces[anchor.componentId]?.dx -= fx
                    forces[anchor.componentId]?.dy -= fy
                }
            }

            // 2. Body repulsion. Coulomb-like 1/r² for non-touching parts,
            // hard push for overlapping ones.
            for i in 0..<ids.count {
                for j in (i + 1)..<ids.count {
                    let a = ids[i], b = ids[j]
                    guard let pa = positions[a], let pb = positions[b] else { continue }
                    let dx = pb.x - pa.x
                    let dy = pb.y - pa.y
                    let distSq = max(0.01, dx * dx + dy * dy)
                    let dist = distSq.squareRoot()
                    let safe = (radii[a] ?? 1) + (radii[b] ?? 1) + 1.5
                    let overlap = max(0, safe - dist)
                    let magnitude = repulsionK / distSq + overlap * 0.4
                    let fx = (dx / dist) * magnitude
                    let fy = (dy / dist) * magnitude
                    forces[b]?.dx += fx
                    forces[b]?.dy += fy
                    forces[a]?.dx -= fx
                    forces[a]?.dy -= fy
                }
            }

            // 3. Weak centroid pull keeps the cluster centered (and shrinks
            //    the bounding box as long as nets push pieces together).
            for id in ids {
                guard let p = positions[id] else { continue }
                forces[id]?.dx += (centroid.x - p.x) * centroidK
                forces[id]?.dy += (centroid.y - p.y) * centroidK
            }

            // Integrate, clamp inside the board outline.
            for id in ids {
                guard var p = positions[id], let f = forces[id] else { continue }
                p = Point(x: p.x + f.dx * step, y: p.y + f.dy * step)
                let r = radii[id] ?? 1
                p = Point(
                    x: min(outline.maxX - r, max(outline.minX + r, p.x)),
                    y: min(outline.maxY - r, max(outline.minY + r, p.y))
                )
                positions[id] = p
            }
        }

        // 4. Snap to grid.
        var result: [(componentId: UUID, position: Point)] = []
        for (id, p) in positions {
            let snapped = Point(
                x: (p.x / pitch).rounded() * pitch,
                y: (p.y / pitch).rounded() * pitch
            )
            result.append((id, snapped))
        }
        return result
    }
}
