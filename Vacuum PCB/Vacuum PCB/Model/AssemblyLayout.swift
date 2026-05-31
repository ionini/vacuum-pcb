import Foundation

/// Geometric layout of an assembly's boards, derived from the matings.
///
/// In assembly mode the document is a *set of separate PCBs* joined by
/// connector matings — not a single plate stack. The subpart placements
/// the user dropped on the schematic carry no useful physical pose (they
/// default to the parent board's centre, so every board lands on top of
/// every other one). The physical truth lives in the matings: two
/// connectors mate face-to-face in exactly **one** way — pin *i* of one half
/// sits directly over pin *i* of the other, and the two boards extend in
/// opposite directions from the shared connector.
///
/// `assemblyLayout()` walks the mating graph out from the parent board and
/// solves a rigid pose (90°-quantised rotation + translation) for each
/// subpart so its mated connector lands on its peer. The result feeds two
/// consumers:
///   * `applyingAssemblyLayout(_:)` rewrites each subpart placement's
///     `position` / `rotation` so the existing `flattenedForSimulation()`
///     pipeline emits every board's routes and components at their
///     laid-out world position (rigid transforms preserve channel lengths,
///     so the pneumatic solve is unaffected).
///   * the Simulate physical canvas draws each board's outline at its pose.
struct AssemblyLayout {
    /// One board in the laid-out assembly — the parent or a subpart instance.
    struct Board: Hashable {
        /// Subpart instance label ("U1"), or empty for the parent board.
        var label: String
        /// The board's own outline, in its local coordinate frame.
        var outline: Rect
        /// World pose, matching `Placement` semantics: a board-local point
        /// `p` maps to `position + R(rotation)·(p − outline.origin)`.
        var position: Point
        var rotation: Rotation

        /// The four outline corners transformed into world space, for drawing.
        func worldCorners() -> [Point] {
            let pose = BoardPose(position: position, rotation: rotation,
                                 origin: outline.origin)
            return [
                Point(x: outline.minX, y: outline.minY),
                Point(x: outline.maxX, y: outline.minY),
                Point(x: outline.maxX, y: outline.maxY),
                Point(x: outline.minX, y: outline.maxY),
            ].map(pose.apply)
        }
    }

    /// Parent board first, then one entry per subpart instance.
    var boards: [Board]
    /// Subpart instance component id → the placement pose the flatten should
    /// use instead of the user's (centre-of-board) default.
    var placementOverrides: [UUID: (position: Point, rotation: Rotation)]

    /// Bounding box of every board's world footprint — what the canvas fits to.
    var worldBounds: Rect {
        let pts = boards.flatMap { $0.worldCorners() }
        guard let first = pts.first else { return Rect(origin: .zero, size: Size(width: 1, height: 1)) }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for p in pts {
            minX = min(minX, p.x); minY = min(minY, p.y)
            maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        return Rect(origin: Point(x: minX, y: minY),
                    size: Size(width: maxX - minX, height: maxY - minY))
    }
}

/// Rigid board-local→world transform: rotate about the board's outline origin,
/// then translate. Matches the `toWorld` math the flatteners apply per subpart.
private struct BoardPose {
    var position: Point
    var rotation: Rotation
    var origin: Point

    func apply(_ p: Point) -> Point {
        let r = rotation.radians, c = cos(r), s = sin(r)
        let dx = p.x - origin.x, dy = p.y - origin.y
        return Point(x: position.x + dx * c - dy * s,
                     y: position.y + dx * s + dy * c)
    }

    /// Rotate a direction vector (no translation).
    func applyVector(_ v: Point) -> Point {
        let r = rotation.radians, c = cos(r), s = sin(r)
        return Point(x: v.x * c - v.y * s, y: v.x * s + v.y * c)
    }
}

extension CircuitDocument {

    /// Solve the board layout from the matings, rooted at the parent board.
    /// Returns `nil` for non-assembly documents (nothing to lay out).
    func assemblyLayout() -> AssemblyLayout? {
        guard isAssembly else { return nil }

        // A board instance in the mating graph.
        enum Node: Hashable { case parent, subpart(UUID) }

        // One end of a mating, resolved to the owning board + its connector.
        struct Site {
            let node: Node
            let component: Component
            let placement: Placement
            let outline: Rect
            let manufacturing: ManufacturingConstants
        }

        let snapshots = librarySnapshots

        // Resolve a `ConnectorEndpoint` to the board it lives on plus the
        // connector's component + (board-local) placement. nil if the
        // referenced connector/subpart can't be found (stale mating).
        func resolve(_ endpoint: ConnectorEndpoint) -> Site? {
            switch endpoint {
            case .topLevel(let id):
                guard let comp = logic.components.first(where: { $0.id == id && $0.kind == .connector }),
                      let placement = physical.placements.first(where: { $0.componentId == id })
                else { return nil }
                return Site(node: .parent, component: comp, placement: placement,
                            outline: physical.boardOutline, manufacturing: manufacturing)
            case .subpartSocket(let sid, let cid):
                guard let sub = logic.components.first(where: { $0.id == sid && $0.kind == .subpart }),
                      let part = sub.resolvedPart(snapshots: snapshots),
                      let comp = part.document.logic.components.first(where: { $0.id == cid && $0.kind == .connector }),
                      let placement = part.document.physical.placements.first(where: { $0.componentId == cid })
                else { return nil }
                return Site(node: .subpart(sid), component: comp, placement: placement,
                            outline: part.document.physical.boardOutline,
                            manufacturing: part.document.manufacturing)
            }
        }

        // World position of a connector pin given the board's pose.
        func pinWorld(_ site: Site, _ pose: BoardPose, key: String) -> Point? {
            let fp = site.component.footprint(site.manufacturing)
            guard let pin = fp.pins.first(where: { $0.key == key }) else { return nil }
            return pose.apply(site.placement.worldPosition(of: pin))
        }

        // World outward normal of a connector (the direction its protrusion
        // sticks out of its board).
        func outwardWorld(_ site: Site, _ pose: BoardPose) -> Point? {
            guard let edge = site.placement.edgeAnchor?.edge else { return nil }
            return pose.applyVector(edge.outwardNormal)
        }

        // The 90°-quantised rotation that best maps unit vector `u` onto `v`.
        func bestRotation(mapping u: Point, to v: Point) -> Rotation {
            var best: Rotation = .r0
            var bestDot = -Double.infinity
            for rot in Rotation.allCases {
                let r = rot.radians, c = cos(r), s = sin(r)
                let ru = Point(x: u.x * c - u.y * s, y: u.x * s + u.y * c)
                let dot = ru.x * v.x + ru.y * v.y
                if dot > bestDot { bestDot = dot; best = rot }
            }
            return best
        }

        // Pose for `child` so its connector mates against the already-placed
        // `ref` connector: child faces opposite to ref, and child pin 1 lands
        // on ref pin 1 (the role-driven pin-order reversal carries the rest).
        func childPose(ref: Site, refPose: BoardPose, child: Site) -> BoardPose? {
            guard let refOutward = outwardWorld(ref, refPose),
                  let childEdge = child.placement.edgeAnchor?.edge,
                  let refPin1 = pinWorld(ref, refPose, key: "1")
            else { return nil }
            let target = Point(x: -refOutward.x, y: -refOutward.y)
            let rot = bestRotation(mapping: childEdge.outwardNormal, to: target)

            let childFP = child.component.footprint(child.manufacturing)
            guard let pin1 = childFP.pins.first(where: { $0.key == "1" }) else { return nil }
            let childPin1Local = child.placement.worldPosition(of: pin1)
            let origin = child.outline.origin
            let r = rot.radians, c = cos(r), s = sin(r)
            let dx = childPin1Local.x - origin.x, dy = childPin1Local.y - origin.y
            let rotated = Point(x: dx * c - dy * s, y: dx * s + dy * c)
            let pos = Point(x: refPin1.x - rotated.x, y: refPin1.y - rotated.y)
            return BoardPose(position: pos, rotation: rot, origin: origin)
        }

        // Resolved mating edges.
        let edges: [(Site, Site)] = logic.matings.compactMap { mating in
            guard let a = resolve(mating.a), let b = resolve(mating.b) else { return nil }
            return (a, b)
        }

        // Parent is the fixed root; its pose is the identity (board-local ==
        // world), expressed as origin-at-outline-origin with no rotation.
        var poses: [Node: BoardPose] = [
            .parent: BoardPose(position: physical.boardOutline.origin,
                               rotation: .r0, origin: physical.boardOutline.origin)
        ]

        // Stored (user-dropped) pose for a subpart, used to seed clusters that
        // don't reach the parent and as the fallback for unmated subparts.
        func storedPose(_ subpartId: UUID) -> BoardPose? {
            guard let comp = logic.components.first(where: { $0.id == subpartId }),
                  let placement = physical.placements.first(where: { $0.componentId == subpartId }),
                  let part = comp.resolvedPart(snapshots: snapshots)
            else { return nil }
            return BoardPose(position: placement.position, rotation: placement.rotation,
                             origin: part.document.physical.boardOutline.origin)
        }

        // Propagate poses outward across mating edges until nothing new lands.
        func propagate() {
            var changed = true
            while changed {
                changed = false
                for (a, b) in edges {
                    if let ap = poses[a.node], poses[b.node] == nil, case .subpart = b.node {
                        if let p = childPose(ref: a, refPose: ap, child: b) { poses[b.node] = p; changed = true }
                    } else if let bp = poses[b.node], poses[a.node] == nil, case .subpart = a.node {
                        if let p = childPose(ref: b, refPose: bp, child: a) { poses[a.node] = p; changed = true }
                    }
                }
            }
        }
        propagate()

        // Seed any still-unplaced subpart cluster (mated only to each other,
        // never to the parent) from its stored pose, then re-propagate.
        let subpartIds = logic.components.filter { $0.kind == .subpart }.map(\.id)
        var madeProgress = true
        while madeProgress {
            madeProgress = false
            for id in subpartIds where poses[.subpart(id)] == nil {
                let touchesEdge = edges.contains { $0.0.node == .subpart(id) || $0.1.node == .subpart(id) }
                guard touchesEdge, let seed = storedPose(id) else { continue }
                poses[.subpart(id)] = seed
                propagate()
                madeProgress = true
                break
            }
        }

        // Assemble overrides + drawable board frames.
        var overrides: [UUID: (position: Point, rotation: Rotation)] = [:]
        var boards: [AssemblyLayout.Board] = [
            AssemblyLayout.Board(label: "", outline: physical.boardOutline,
                                 position: physical.boardOutline.origin, rotation: .r0)
        ]
        for id in subpartIds {
            guard let comp = logic.components.first(where: { $0.id == id }),
                  let part = comp.resolvedPart(snapshots: snapshots)
            else { continue }
            let outline = part.document.physical.boardOutline
            let pose = poses[.subpart(id)]
                ?? storedPose(id)
                ?? BoardPose(position: outline.origin, rotation: .r0, origin: outline.origin)
            overrides[id] = (pose.position, pose.rotation)
            boards.append(AssemblyLayout.Board(label: comp.label, outline: outline,
                                               position: pose.position, rotation: pose.rotation))
        }

        return AssemblyLayout(boards: boards, placementOverrides: overrides)
    }

    /// Apply a solved layout: rewrite each subpart placement's pose so the
    /// flatteners emit its geometry at the mated world position. Other
    /// placements (the parent's own components, connectors) are untouched.
    func applyingAssemblyLayout(_ layout: AssemblyLayout) -> CircuitDocument {
        var copy = self
        for i in copy.physical.placements.indices {
            if let pose = layout.placementOverrides[copy.physical.placements[i].componentId] {
                copy.physical.placements[i].position = pose.position
                copy.physical.placements[i].rotation = pose.rotation
            }
        }
        return copy
    }
}
